import Foundation
import SwiftUI
import RingonomiCore
#if canImport(UIKit)
import UIKit
#endif

#if canImport(TVVLCKit)
@preconcurrency import TVVLCKit
#endif

/// A standalone media item used by file based players such as EPGStation.
///
/// `identity` is deliberately separate from the URL.  A server may expose
/// the same URL for a new recording, and a resume bookmark must not silently
/// move to that new item.
struct FilePlaybackSelection: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let title: String
    let durationHint: Double?
    let resumePosition: Double
    let identity: String?

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        durationHint: Double? = nil,
        resumePosition: Double = 0,
        identity: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.durationHint = durationHint
        self.resumePosition = resumePosition
        self.identity = identity
    }
}

#if canImport(TVVLCKit)

/// VLC-backed playback for a single HTTP/file media resource.
///
/// This controller intentionally does not share the live controller.  A file
/// URL can be paused and sought independently, and reusing the live retry
/// state machine would leave a stopped live transport attached to a VOD URL.
@MainActor
final class VLCFilePlaybackController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()

    @Published private(set) var status = "読み込み中…"
    @Published private(set) var isLoading = true
    @Published private(set) var failure: String?
    @Published private(set) var currentSeconds = 0.0
    @Published private(set) var durationSeconds: Double?
    @Published private(set) var isPaused = false
    @Published private(set) var isEnded = false
    @Published private(set) var isSeekable = false
    @Published private(set) var audioOptions: [PlaybackAudioOption] = []
    @Published private(set) var selectedAudioID: String?
    @Published private(set) var audioSelectionError: String?

    private var selection: FilePlaybackSelection?
    private var currentURL: URL?
    private var durationHint: Double?
    private var targetSeconds = 0.0
    // A VLC time assignment is asynchronous. Keep the request separate from
    // the trusted playback position so an old/zero time cannot overwrite a
    // resume bookmark while a new file or seek is preparing.
    private var pendingPositionSeconds: Double?
    private var pendingPositionGeneration = 0
    private var pendingPositionApplied = false
    private var pendingPositionAppliedAt: Date?
    private var pendingPositionFallbackApplied = false
    private var pendingPositionStartedAt: Date?
    private var pendingPositionIsInitial = false
    private var retryFromBeginningAfterPositionFailure = false
    private var lastTrustedSeconds: Double?
    private var lastTrustedDuration: Double?
    private var lastTrustedEnded = false
    private var wantsPause = false
    private var isStopped = false
    private var isSuspendedForBackground = false
    private var generation = 0

    private weak var videoSurface: UIView?
    private var gate = PlaybackReadinessGate()
    private var monitor: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var pendingLoadURL: URL?
    private var pendingLoadGeneration = 0
    private var waitingSince = Date()
    private var lastFrameDate = Date.distantPast
    private var lastPictures = 0
    private var pictureBaseline = 0
    private var lastProgressPosition: Double?
    private var lastProgressDuration: Double?
    private var lastProgressEnded = false
    private var lastBookmarkPosition: Double?
    private var lastBookmarkDuration: Double?
    private var lastBookmarkEnded = false
    private var lastBookmarkDate = Date.distantPast
    private var continuousDisplay = false
#if DEBUG
    private var lastDebugStatusDate = Date.distantPast
    private var lastDebugPositionDate = Date.distantPast
#endif

    private var audioSourceID: UUID?
    private var audioTrackIDsByOptionID: [String: Int32] = [:]
    private var preferredAudioName: String?
    private var hasExplicitAudioSelection = false
    private var didAttemptPreferredAudio = false
    private var pendingAudioSelection: PendingAudioSelection?
    private var audioBaselineDecoded = 0
    private var audioBaselinePlayed = 0
    private var audioNeedsFreshBuffers = true

    private struct PendingAudioSelection {
        let id: String
        let rawID: Int32
        let previousID: String?
        let previousRawID: Int32?
        let startedAt: Date
    }

    private var onContinuousDisplayChanged: ((Bool) -> Void)?
    private var onProgress: ((Double, Double?, Bool) -> Void)?

    override init() {
        super.init()
        player.delegate = self
        player.audio?.isMuted = true
    }

    var canSeek: Bool {
        !isStopped && !isLoading && failure == nil && isSeekable && durationSeconds != nil
    }

    func attachSurface(_ view: UIView) {
        videoSurface = view
        player.drawable = view
    }

    /// Starts or updates the selected file.  Repeated SwiftUI updates with
    /// the same item are intentionally idempotent.
    func start(
        item: FilePlaybackSelection,
        onContinuousDisplayChanged: @escaping (Bool) -> Void,
        onProgress: @escaping (Double, Double?, Bool) -> Void
    ) {
        self.onContinuousDisplayChanged = onContinuousDisplayChanged
        self.onProgress = onProgress

        if !isStopped, selection?.id == item.id, currentURL == item.url {
            return
        }

        isStopped = false
        isSuspendedForBackground = false
        selection = item
        durationHint = validDuration(item.durationHint)
        targetSeconds = clamp(item.resumePosition, duration: durationHint) ?? 0
        lastTrustedSeconds = targetSeconds
        lastTrustedDuration = durationHint
        lastTrustedEnded = false
        retryFromBeginningAfterPositionFailure = false
        currentURL = nil
        wantsPause = false
        beginLoad(item.url, at: targetSeconds)
    }

    func retry() {
        guard !isStopped, !isSuspendedForBackground, let selection else { return }
        let position: Double
        if isEnded || retryFromBeginningAfterPositionFailure {
            position = 0
        } else if let lastTrustedSeconds {
            position = lastTrustedSeconds
        } else {
            position = targetSeconds
        }
        beginLoad(selection.url, at: clamp(position, duration: durationSeconds ?? durationHint) ?? 0)
    }

    func replay() {
        guard !isStopped, !isSuspendedForBackground, let selection else { return }
        wantsPause = false
        // A deliberate replay starts a new trusted timeline. If the user
        // closes while the new decoder is still preparing, do not report the
        // previous EOF position as if it were the current bookmark.
        lastTrustedSeconds = 0
        lastTrustedDuration = durationSeconds ?? durationHint
        lastTrustedEnded = false
        beginLoad(selection.url, at: 0)
    }

    func togglePause() {
        guard !isStopped, !isSuspendedForBackground, failure == nil else { return }

        if isEnded {
            replay()
            return
        }

        wantsPause.toggle()
        isPaused = wantsPause
        if wantsPause {
            if !isLoading {
                player.pause()
                player.audio?.isMuted = true
                isPaused = true
                status = "一時停止"
                updateContinuousDisplayNeed()
                reportProgress(force: true)
            }
        } else if !isLoading {
            beginWaiting()
            player.play()
        }
        // Loading/buffering still represents an active playback intent. Keep
        // the display awake until the user pauses, reaches EOF, or an error
        // puts the player into a terminal state.
        updateContinuousDisplayNeed()
        updateStatus()
    }

    func seek(seconds: Double) {
        guard seconds.isFinite else { return }
        seek(to: safeCurrentSeconds + seconds)
    }

    func seek(to seconds: Double) {
        guard canSeek, seconds.isFinite,
              let duration = durationSeconds,
              let target = clamp(seconds, duration: duration) else { return }

        if isEnded, let selection {
            // EOF may have released the VLC media during a Home transition.
            // An explicit seek is allowed to create a fresh decoder, while
            // the automatic lifecycle path keeps EOF untouched.
            wantsPause = wantsPause || isPaused
            beginLoad(selection.url, at: target)
            return
        }

        targetSeconds = target
        isEnded = false
        wantsPause = wantsPause || isPaused
        beginWaiting()
        resetReadinessBaseline()
        player.audio?.isMuted = true
        updateContinuousDisplayNeed()
        queuePositionRequest(target, isInitial: false)
        updateStatus()
    }

    func selectAudioTrack(id: String) {
        guard !isStopped, !isLoading, failure == nil,
              let rawID = audioTrackIDsByOptionID[id],
              audioOptions.contains(where: { $0.id == id }) else { return }
        applyAudioTrack(id: id, rawID: rawID, allowWhileLoading: false)
    }

    /// Releases the decoder while Home/background is visible while retaining
    /// the current item and trusted position for a fresh load on return.
    func suspendForBackground() {
        // An error is an explicit user-visible terminal state.  Do not turn a
        // Home transition into an implicit retry; the Retry button owns that
        // transition.  EOF is handled separately below so it stays EOF after
        // the decoder is released.
        guard !isStopped, !isSuspendedForBackground, currentURL != nil,
              failure == nil else { return }
        if player.state == .error {
            fail("録画を再生できませんでした。接続先とファイル状態を確認してください。")
            return
        }
        if player.state == .ended, !isEnded {
            finishPlayback()
        }
        if !isLoading, !isEnded { targetSeconds = safeCurrentSeconds }
        if !isLoading, failure == nil { reportProgress(force: true) }
        isSuspendedForBackground = true
        generation &+= 1
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        monitor?.cancel()
        monitor = nil
        isLoading = true
        isPaused = wantsPause
        waitingSince = Date()
        gate.reset()
        player.audio?.isMuted = true
        player.delegate = nil
        if player.state != .stopped { player.stop() }
        player.drawable = nil
        clearMediaWhenStopped()
        updateContinuousDisplayNeed()
#if DEBUG
        print("RingonomiFileLifecycle: suspended target=\(targetSeconds) paused=\(wantsPause) ended=\(isEnded)")
#endif
    }

    func resumeFromBackground() {
        guard isSuspendedForBackground, !isStopped, failure == nil,
              let selection else { return }
        isSuspendedForBackground = false

        if isEnded {
            // There are no future frames to prepare at EOF. Keep the ended
            // controls available and wait for an explicit Replay/seek action.
            isLoading = false
            isPaused = true
            status = "再生終了（再生ボタンで最初から）"
            updateContinuousDisplayNeed()
#if DEBUG
            print("RingonomiFileLifecycle: resumed-at-end target=\(targetSeconds)")
#endif
            return
        }

        player.delegate = self
        if let videoSurface { player.drawable = videoSurface }
        beginLoad(selection.url, at: targetSeconds)
#if DEBUG
        print("RingonomiFileLifecycle: resumed target=\(targetSeconds) paused=\(wantsPause)")
#endif
    }

    /// Stops callbacks and decoder work. The representable calls this during
    /// dismantling, so it reports only the last trusted position callback and
    /// deliberately does not publish a final UI update.
    func stop() {
        guard !isStopped else { return }
        reportTrustedProgressForStop()
#if DEBUG
        print("RingonomiFileLifecycle: stopped trusted=\(lastTrustedSeconds ?? -1) ended=\(lastTrustedEnded)")
#endif
        isStopped = true
        isSuspendedForBackground = false
        generation &+= 1
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        pendingPositionSeconds = nil
        pendingPositionGeneration = generation
        pendingPositionApplied = false
        pendingPositionAppliedAt = nil
        pendingPositionFallbackApplied = false
        pendingPositionStartedAt = nil
        pendingPositionIsInitial = false
        currentURL = nil
        selection = nil
        monitor?.cancel()
        monitor = nil
        stopTask?.cancel()
        stopTask = nil
        player.delegate = nil
        player.audio?.isMuted = true
        player.pause()
        player.drawable = nil
        clearAudioCatalog(notifyUI: false)
        onContinuousDisplayChanged = nil
        onProgress = nil
        if player.state != .stopped { player.stop() }
        clearMediaWhenStopped()
        videoSurface = nil
    }

    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.updateStatus()
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.updateStatus()
        }
    }

    private func beginLoad(_ url: URL, at position: Double) {
        guard isSupported(url) else {
            fail("この録画形式のURLには対応していません。")
            return
        }

        stopTask?.cancel()
        stopTask = nil
        isStopped = false
        isSuspendedForBackground = false
        player.delegate = self
        currentURL = url
        generation &+= 1
        pendingLoadGeneration = generation
        pendingLoadURL = url
        let effectiveDuration = durationHint ?? durationSeconds
        targetSeconds = clamp(position, duration: effectiveDuration) ?? 0
        pendingPositionSeconds = nil
        pendingPositionGeneration = generation
        pendingPositionApplied = false
        pendingPositionAppliedAt = nil
        pendingPositionFallbackApplied = false
        pendingPositionStartedAt = nil
        pendingPositionIsInitial = false
        if targetSeconds > positionTolerance(for: targetSeconds, duration: effectiveDuration) {
            pendingPositionSeconds = targetSeconds
            // Start the seek timeout when the new VLC media is attached, not
            // while the previous decoder is still stopping.
            pendingPositionStartedAt = nil
            pendingPositionIsInitial = true
        }
        retryFromBeginningAfterPositionFailure = false
        failure = nil
        isLoading = true
        isPaused = wantsPause
        isEnded = false
        durationSeconds = durationHint
        isSeekable = false
        status = "読み込み中…"
        waitingSince = Date()
        lastFrameDate = .distantPast
        lastPictures = 0
        lastProgressPosition = nil
        lastProgressDuration = nil
        lastProgressEnded = false
        updateContinuousDisplayNeed()
#if DEBUG
        lastDebugStatusDate = .distantPast
        lastDebugPositionDate = .distantPast
#endif
        gate.reset()
        resetReadinessBaseline()
        resetAudioCatalog(notifyUI: true)
        player.audio?.isMuted = true

#if DEBUG
        print("RingonomiFileLoad: generation=\(generation) target=\(targetSeconds) initialPosition=\(pendingPositionSeconds != nil)")
#endif

        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self, !self.isStopped, !self.isSuspendedForBackground else { return }
                self.updateStatus()
            }
        }

        // VLC stops asynchronously.  A pending URL is only attached after
        // the stopped state is observed, preventing same-URL reuse races.
        if player.state != .stopped { player.stop() }
        startPendingLoadIfReady(for: generation)
    }

    private func startPendingLoadIfReady(for expectedGeneration: Int) {
        guard !isStopped, !isSuspendedForBackground,
              expectedGeneration == generation,
              pendingLoadGeneration == generation,
              let url = pendingLoadURL,
              currentURL == url,
              player.state == .stopped else { return }

        pendingLoadURL = nil
        pendingLoadGeneration = 0
        player.media = VLCMedia(url: url)
        if let videoSurface { player.drawable = videoSurface }
        player.audio?.isMuted = true
        if pendingPositionSeconds != nil, pendingPositionStartedAt == nil {
            pendingPositionStartedAt = Date()
        }
        player.play()
    }

    private func updateStatus() {
        guard !isStopped, !isSuspendedForBackground, failure == nil, currentURL != nil else { return }

        if pendingLoadURL != nil {
            startPendingLoadIfReady(for: generation)
            if pendingLoadURL != nil {
                if Date().timeIntervalSince(waitingSince) > 30 {
                    fail("読み込みがタイムアウトしました。接続を確認して再試行してください。")
                }
                return
            }
        }

        switch player.state {
        case .error:
            if pendingPositionSeconds != nil {
                failPositionRequest()
            } else {
                fail("録画を再生できませんでした。接続先とファイル状態を確認してください。")
            }
            return
        case .ended:
            if pendingPositionSeconds != nil {
                failPositionRequest()
            } else {
                finishPlayback()
            }
            return
        case .stopped:
            if !isLoading {
                fail("録画の再生が停止しました。再試行してください。")
                return
            }
        default:
            break
        }

        refreshDurationAndSeekability()
        if processPositionRequest() { return }
        refreshAudioTracks()

        let size = player.videoSize
        let hasVideo = player.hasVideoOut && size.width > 0 && size.height > 0
        if let media = player.media {
            let stats = media.statistics
            let totalPictures = max(0, Int(stats.displayedPictures))
            if totalPictures < pictureBaseline || totalPictures < lastPictures {
                // Some VLC decoder paths reset statistics when a seek or
                // demuxer restart occurs. Rebase the picture counter rather
                // than waiting for it to catch up to an obsolete baseline.
                pictureBaseline = totalPictures
                lastPictures = totalPictures
                lastFrameDate = .distantPast
                gate.reset()
            }
            if totalPictures > lastPictures { lastFrameDate = Date() }
            lastPictures = totalPictures
            // displayedPictures is a lifetime counter for the media. After a
            // seek it may remain nonzero, so the gate must see only frames
            // displayed after the current decoder/position baseline.
            let pictures = max(0, totalPictures - pictureBaseline)

            let decodedAudio = max(0, Int(stats.decodedAudio))
            let playedAudio = max(0, Int(stats.playedAudioBuffers))
            if decodedAudio < audioBaselineDecoded { audioBaselineDecoded = 0 }
            if playedAudio < audioBaselinePlayed { audioBaselinePlayed = 0 }
            let audioReady: Bool
            if player.numberOfAudioTracks <= 0 {
                audioReady = true
            } else {
                audioReady = audioNeedsFreshBuffers
                    ? decodedAudio > audioBaselineDecoded && playedAudio > audioBaselinePlayed
                    : decodedAudio > 0 && playedAudio > 0
            }
#if DEBUG
            if Date().timeIntervalSince(lastDebugStatusDate) >= 5 {
                lastDebugStatusDate = Date()
                print("RingonomiFileStats: pictures=\(totalPictures) delta=\(pictures) decodedAudio=\(decodedAudio) playedAudio=\(playedAudio) loading=\(isLoading) muted=\(player.audio?.isMuted == true) state=\(player.state.rawValue)")
            }
#endif

            let ready = gate.update(
                hasVideo: hasVideo,
                pictures: pictures,
                audioReady: audioReady,
                at: ProcessInfo.processInfo.systemUptime
            )
            if isLoading, ready, Date().timeIntervalSince(lastFrameDate) < 1,
               pendingAudioSelection == nil {
                isLoading = false
                audioNeedsFreshBuffers = false
                if wantsPause {
                    player.pause()
                    player.audio?.isMuted = true
                    isPaused = true
                    status = "一時停止"
                } else {
                    player.audio?.isMuted = false
                    isPaused = false
                    status = "再生中"
                }
                updateContinuousDisplayNeed()
                reportProgress(force: true)
#if DEBUG
                print("RingonomiFileReady: pictures=\(pictures) muted=\(player.audio?.isMuted == true) paused=\(wantsPause)")
#endif
            }
        } else {
            gate.reset()
        }

        if !isLoading, !wantsPause, Date().timeIntervalSince(lastFrameDate) > 1.5 {
            beginWaiting()
        }
        if isLoading, Date().timeIntervalSince(waitingSince) > 30 {
            fail("読み込みがタイムアウトしました。接続を確認して再試行してください。")
            return
        }

        let time = safeCurrentSeconds
        if !isLoading { currentSeconds = time }
        if failure == nil, isLoading {
            status = "読み込み中…"
        } else if failure == nil, wantsPause {
            status = "一時停止"
        }
        reportProgress()
        resolvePendingAudioSelection()
    }

    /// Queues a VLC seek and keeps the readiness gate closed until the native
    /// player reports the requested position. Assigning `player.time` does
    /// not synchronously move a VLC decoder, so accepting the next old frame
    /// here would reveal stale video after a seek.
    private func queuePositionRequest(_ seconds: Double, isInitial: Bool) {
        guard !isStopped, !isSuspendedForBackground, currentURL != nil,
              let target = clamp(seconds, duration: durationSeconds ?? durationHint) else {
            failPositionRequest()
            return
        }
        targetSeconds = target
        pendingPositionSeconds = target
        pendingPositionGeneration = generation
        pendingPositionApplied = false
        pendingPositionAppliedAt = nil
        pendingPositionFallbackApplied = false
        pendingPositionStartedAt = Date()
        pendingPositionIsInitial = isInitial
        resetReadinessBaseline()
        player.audio?.isMuted = true
        updateContinuousDisplayNeed()
#if DEBUG
        print("RingonomiFilePosition: request target=\(target) initial=\(isInitial)")
        lastDebugPositionDate = .distantPast
#endif
    }

    /// Returns true while a requested position is still being prepared. The
    /// caller must return before refreshing the normal audio/video readiness
    /// gate; otherwise counters and frames from the old position can unmute.
    private func processPositionRequest() -> Bool {
        guard let requested = pendingPositionSeconds else { return false }
        guard pendingPositionGeneration == generation else {
            pendingPositionSeconds = nil
            pendingPositionStartedAt = nil
            pendingPositionApplied = false
            pendingPositionAppliedAt = nil
            pendingPositionFallbackApplied = false
            return false
        }

#if DEBUG
        if Date().timeIntervalSince(lastDebugPositionDate) >= 1 {
            lastDebugPositionDate = Date()
            let rawSeconds = rawPlaybackSeconds ?? -1
            print("RingonomiFilePositionPending: requested=\(requested) rawSeconds=\(rawSeconds) position=\(player.position) state=\(player.state.rawValue) seekable=\(player.isSeekable) applied=\(pendingPositionApplied)")
        }
#endif

        let startedAt = pendingPositionStartedAt ?? Date()
        pendingPositionStartedAt = startedAt
        if !pendingPositionApplied {
            guard player.isSeekable else {
                if Date().timeIntervalSince(startedAt) >= 8 {
                    failPositionRequest()
                }
                return true
            }

            let target = clamp(requested, duration: durationSeconds ?? durationHint) ?? requested
            targetSeconds = target
            pendingPositionSeconds = target
            pendingPositionApplied = true
            pendingPositionAppliedAt = Date()
            pendingPositionFallbackApplied = false
            resetReadinessBaseline()
            player.audio?.isMuted = true
            // Decode muted frames while the gate waits for the seek to take
            // effect. This also preserves an explicit pause intent below.
            player.pause()
            guard let millisecondValue = milliseconds(target) else {
                failPositionRequest()
                return true
            }
            player.time = VLCTime(number: NSNumber(value: millisecondValue))
            player.play()
#if DEBUG
            print("RingonomiFilePosition: applied target=\(target) initial=\(pendingPositionIsInitial)")
#endif
            return true
        }

        let effectiveDuration = validDuration(durationSeconds ?? durationHint)
        let tolerance = positionTolerance(for: requested, duration: effectiveDuration)
        if let actual = rawPlaybackSeconds, abs(actual - requested) <= tolerance {
            targetSeconds = requested
            pendingPositionSeconds = nil
            pendingPositionStartedAt = nil
            pendingPositionApplied = false
            pendingPositionAppliedAt = nil
            pendingPositionFallbackApplied = false
            resetReadinessBaseline()
#if DEBUG
            print("RingonomiFilePosition: ack target=\(requested) actual=\(actual)")
#endif
            return true
        }

        // Some HTTP MPEG-TS demux paths accept the time command but leave the
        // decoder at its old timestamp. VLC's input core normally performs
        // this ratio fallback itself, so keep the app-level retry bounded to a
        // single attempt and only use a finite, effective media duration.
        if !pendingPositionFallbackApplied,
           let appliedAt = pendingPositionAppliedAt,
           Date().timeIntervalSince(appliedAt) >= 1,
           let duration = effectiveDuration {
            let ratio = min(1.0, max(0.0, requested / duration))
            guard ratio.isFinite else {
                failPositionRequest()
                return true
            }
            pendingPositionFallbackApplied = true
            player.position = Float(ratio)
#if DEBUG
            print("RingonomiFilePosition: strategy=position target=\(requested) duration=\(duration) ratio=\(ratio)")
#endif
        }

        if Date().timeIntervalSince(startedAt) >= 8 {
            failPositionRequest()
        }
        return true
    }

    private func failPositionRequest() {
        let wasInitial = pendingPositionIsInitial
        pendingPositionSeconds = nil
        pendingPositionStartedAt = nil
        pendingPositionApplied = false
        pendingPositionAppliedAt = nil
        pendingPositionFallbackApplied = false
        pendingPositionIsInitial = false
        retryFromBeginningAfterPositionFailure = true
        let message = wasInitial
            ? "指定位置から再生できませんでした。再試行すると先頭から開始します。"
            : "指定位置へ移動できませんでした。再試行すると先頭から開始します。"
#if DEBUG
        print("RingonomiFilePosition: failed initial=\(wasInitial)")
#endif
        fail(message)
    }

    private func refreshDurationAndSeekability() {
        if let milliseconds = player.media?.length.value?.doubleValue,
           milliseconds.isFinite, milliseconds > 0 {
            durationSeconds = milliseconds / 1000
        } else if durationSeconds == nil {
            durationSeconds = durationHint
        }
        isSeekable = player.isSeekable
    }

    private func finishPlayback() {
        guard !isStopped, !isSuspendedForBackground else { return }
        guard !isEnded else { return }
        isEnded = true
        wantsPause = true
        isPaused = true
        isLoading = false
        waitingSince = Date()
        player.audio?.isMuted = true
        if let duration = durationSeconds { currentSeconds = duration }
        status = "再生終了（再生ボタンで最初から）"
        updateContinuousDisplayNeed()
        reportProgress(force: true)
#if DEBUG
        print("RingonomiFileEnded: time=\(currentSeconds) duration=\(durationSeconds ?? -1)")
#endif
    }

    private func beginWaiting() {
        guard !isSuspendedForBackground, !isStopped else { return }
        if !isLoading {
            resetReadinessBaseline()
            gate.reset()
            waitingSince = Date()
            isLoading = true
        }
        failure = nil
        status = "読み込み中…"
        player.audio?.isMuted = true
        updateContinuousDisplayNeed()
    }

    private func fail(_ message: String) {
        guard !isStopped, !isSuspendedForBackground, failure == nil else { return }
        player.audio?.isMuted = true
        player.pause()
        failure = message
        isLoading = false
        isPaused = false
        status = "再生できません"
        updateContinuousDisplayNeed()
        reportProgress(force: true)
#if DEBUG
        print("RingonomiFileError: \(message)")
#endif
    }

    private var safeCurrentSeconds: Double {
        guard let value = player.time.value?.doubleValue,
              value.isFinite, value >= 0 else { return targetSeconds }
        let seconds = value / 1000
        return clamp(seconds, duration: durationSeconds) ?? max(0, seconds)
    }

    private var rawPlaybackSeconds: Double? {
        guard let value = player.time.value?.doubleValue,
              value.isFinite, value >= 0 else { return nil }
        let seconds = value / 1000
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    private func positionTolerance(for _: Double, duration: Double?) -> Double {
        let relative = validDuration(duration).map { $0 * 0.01 } ?? 0
        return max(0.75, min(2.0, relative))
    }

    private func reportProgress(force: Bool = false) {
        guard !isStopped, !isLoading, failure == nil else { return }
        let position = isEnded ? (durationSeconds ?? safeCurrentSeconds) : safeCurrentSeconds
        let duration = durationSeconds
        let changed = force
            || lastProgressPosition.map { abs($0 - position) >= 0.25 } == true
            || lastProgressPosition == nil
            || lastProgressDuration != duration
            || lastProgressEnded != isEnded
        guard changed else { return }
        lastProgressPosition = position
        lastProgressDuration = duration
        lastProgressEnded = isEnded
        lastTrustedSeconds = position
        lastTrustedDuration = duration
        lastTrustedEnded = isEnded
        currentSeconds = position

        // `currentSeconds` drives the on-screen clock and can update several
        // times per second.  The callback persists a resume bookmark, so
        // keep ordinary writes bounded while still flushing meaningful state
        // transitions immediately (pause, seek completion, EOF, Home, and
        // an explicit close/stop handled by reportTrustedProgressForStop()).
        let now = Date()
        let bookmarkChanged = force
            || lastBookmarkPosition == nil
            || lastBookmarkDuration != duration
            || lastBookmarkEnded != isEnded
            || abs((lastBookmarkPosition ?? position) - position) >= 5
            || now.timeIntervalSince(lastBookmarkDate) >= 5
        guard bookmarkChanged else { return }
        lastBookmarkPosition = position
        lastBookmarkDuration = duration
        lastBookmarkEnded = isEnded
        lastBookmarkDate = now
        onProgress?(position, duration, isEnded)
    }

    /// Sends only the last position that passed the readiness gate. This is
    /// intentionally callback-only because `stop()` is also called while a
    /// SwiftUI representable is being dismantled; publishing new state there
    /// can invalidate the view graph reentrantly.
    private func reportTrustedProgressForStop() {
        guard let position = lastTrustedSeconds,
              position.isFinite, position >= 0,
              let onProgress else { return }
        onProgress(position, lastTrustedDuration, lastTrustedEnded)
    }

    private func updateContinuousDisplayNeed() {
        let needed = !isStopped && !isSuspendedForBackground
            && failure == nil && !wantsPause && !isEnded
        guard needed != continuousDisplay else { return }
        continuousDisplay = needed
        onContinuousDisplayChanged?(needed)
    }

    private func resetReadinessBaseline() {
        if let media = player.media {
            let stats = media.statistics
            audioBaselineDecoded = max(0, Int(stats.decodedAudio))
            audioBaselinePlayed = max(0, Int(stats.playedAudioBuffers))
            pictureBaseline = max(0, Int(stats.displayedPictures))
        } else {
            audioBaselineDecoded = 0
            audioBaselinePlayed = 0
            pictureBaseline = 0
        }
        audioNeedsFreshBuffers = true
        lastPictures = pictureBaseline
        lastFrameDate = .distantPast
        gate.reset()
    }

    private func resetAudioCatalog(notifyUI: Bool) {
        audioSourceID = UUID()
        audioTrackIDsByOptionID.removeAll(keepingCapacity: false)
        pendingAudioSelection = nil
        didAttemptPreferredAudio = false
        if notifyUI {
            audioOptions = []
            selectedAudioID = nil
            audioSelectionError = nil
        }
    }

    private func clearAudioCatalog(notifyUI: Bool) {
        audioSourceID = nil
        audioTrackIDsByOptionID.removeAll(keepingCapacity: false)
        pendingAudioSelection = nil
        preferredAudioName = nil
        hasExplicitAudioSelection = false
        didAttemptPreferredAudio = false
        if notifyUI {
            audioOptions = []
            selectedAudioID = nil
            audioSelectionError = nil
        }
    }

    private func refreshAudioTracks() {
        guard !isStopped, currentURL != nil, failure == nil,
              let sourceID = audioSourceID, player.media != nil else { return }
        let indexes = arrayValues(from: player.audioTrackIndexes)
        let names = arrayValues(from: player.audioTrackNames)
        guard indexes.count <= PlaybackAudioCatalog.maximumTracks else {
            audioOptions = []
            audioTrackIDsByOptionID.removeAll(keepingCapacity: false)
            return
        }

        var descriptors: [PlaybackAudioDescriptor] = []
        var rawByOptionID: [String: Int32] = [:]
        for (offset, value) in indexes.enumerated() {
            guard let integer = integerValue(value), integer >= 0,
                  let rawID = Int32(exactly: integer) else { continue }
            let name = offset < names.count ? stringValue(names[offset]) : nil
            guard !isDisabledAudioName(name) else { continue }
            descriptors.append(PlaybackAudioDescriptor(trackID: integer, name: name))
            rawByOptionID["\(sourceID.uuidString):\(integer)"] = rawID
        }

        let options = PlaybackAudioCatalog.options(sourceID: sourceID, descriptors: descriptors)
        let filtered = options.filter { rawByOptionID[$0.id] != nil }
        audioTrackIDsByOptionID = rawByOptionID
        if audioOptions != filtered { audioOptions = filtered }

        let currentRaw = currentRawAudioTrackID
        if let currentRaw,
           let current = filtered.first(where: { rawByOptionID[$0.id] == currentRaw }) {
            selectedAudioID = current.id
        } else {
            selectedAudioID = nil
        }

        if !didAttemptPreferredAudio,
           !isLoading,
           hasExplicitAudioSelection,
           let preferredAudioName,
           let preferredID = PlaybackAudioCatalog.preferredID(named: preferredAudioName, in: filtered),
           let preferredRawID = rawByOptionID[preferredID],
           currentRaw != preferredRawID {
            didAttemptPreferredAudio = true
            applyAudioTrack(id: preferredID, rawID: preferredRawID, allowWhileLoading: false)
        } else if !hasExplicitAudioSelection {
            didAttemptPreferredAudio = true
        }
    }

    private func applyAudioTrack(id: String, rawID: Int32, allowWhileLoading: Bool) {
        guard !isStopped, failure == nil,
              let mapped = audioTrackIDsByOptionID[id], mapped == rawID,
              let option = audioOptions.first(where: { $0.id == id }) else { return }
        let previousID = selectedAudioID
        let previousRawID = currentRawAudioTrackID
        if previousRawID == rawID {
            selectedAudioID = id
            if !option.name.isEmpty { preferredAudioName = option.preferenceKey }
            hasExplicitAudioSelection = true
            audioSelectionError = nil
            return
        }
        guard allowWhileLoading || !isLoading else { return }
        pendingAudioSelection = PendingAudioSelection(
            id: id, rawID: rawID, previousID: previousID,
            previousRawID: previousRawID, startedAt: Date()
        )
        resetReadinessBaseline()
        player.audio?.isMuted = true
        if !wantsPause { beginWaiting() }
        player.currentAudioTrackIndex = rawID
    }

    private func resolvePendingAudioSelection() {
        guard let pending = pendingAudioSelection else { return }
        if currentRawAudioTrackID == pending.rawID {
            pendingAudioSelection = nil
            selectedAudioID = pending.id
            preferredAudioName = audioOptions.first(where: { $0.id == pending.id })?.preferenceKey
            hasExplicitAudioSelection = true
            audioSelectionError = nil
            if wantsPause {
                player.pause()
                player.audio?.isMuted = true
            }
            return
        }
        guard Date().timeIntervalSince(pending.startedAt) >= 2 else { return }
        if let previousRawID = pending.previousRawID {
            player.currentAudioTrackIndex = previousRawID
        }
        pendingAudioSelection = nil
        selectedAudioID = pending.previousID
        audioSelectionError = "音声を切り替えられませんでした。"
        resetReadinessBaseline()
        if !wantsPause { player.play() }
    }

    private var currentRawAudioTrackID: Int32? {
        Int32(exactly: Int(player.currentAudioTrackIndex))
    }

    private func arrayValues(from value: Any) -> [Any] {
        if let array = value as? [Any] { return array }
        if let array = value as? NSArray { return array.map { $0 } }
        return []
    }

    private func integerValue(_ value: Any) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        if let value = value as? Int32 { return Int(value) }
        if let value = value as? Int64 { return Int(exactly: value) }
        return nil
    }

    private func stringValue(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        return nil
    }

    private func isDisabledAudioName(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Disabled") == .orderedSame
    }

    private func clearMediaWhenStopped() {
        stopTask?.cancel()
        guard player.state != .stopped else {
            player.media = nil
            return
        }
        stopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                if self.player.state == .stopped {
                    self.player.media = nil
                    self.stopTask = nil
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            self.stopTask = nil
        }
    }

    private func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    private func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func clamp(_ value: Double, duration: Double?) -> Double? {
        guard value.isFinite else { return nil }
        let lower = max(0, value)
        guard let duration = validDuration(duration) else { return lower }
        return min(lower, max(0, duration - 0.1))
    }

    private func milliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let value = seconds * 1000
        guard value.isFinite else { return nil }

        // VLCTime(number:) accepts an NSNumber, so retain the 64-bit millisecond
        // range instead of narrowing a long recording to VLCTime(int:)'s
        // 32-bit argument. Leave one value below Int64.max because Double's
        // rounded representation of the endpoint can otherwise overflow the
        // integer conversion.
        let maximum = Double(Int64.max - 1)
        guard value <= maximum else { return nil }
        let rounded = value.rounded()
        guard rounded <= maximum else { return nil }
        return Int64(rounded)
    }
}

typealias FilePlaybackController = VLCFilePlaybackController

@MainActor
final class FilePlaybackVideoSurface: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }
}

struct NativeFilePlaybackVideo: UIViewRepresentable {
    let url: URL
    let controller: VLCFilePlaybackController

    func makeCoordinator() -> VLCFilePlaybackController { controller }

    func makeUIView(context: Context) -> FilePlaybackVideoSurface {
        let view = FilePlaybackVideoSurface(frame: .zero)
        controller.attachSurface(view)
        return view
    }

    func updateUIView(_ view: FilePlaybackVideoSurface, context: Context) {
        controller.attachSurface(view)
    }

    static func dismantleUIView(_ view: FilePlaybackVideoSurface, coordinator: VLCFilePlaybackController) {
        coordinator.stop()
    }
}

#endif
