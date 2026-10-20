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
    let smbConnection: SMBConnection?

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        durationHint: Double? = nil,
        resumePosition: Double = 0,
        identity: String? = nil,
        smbConnection: SMBConnection? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.durationHint = durationHint
        self.resumePosition = resumePosition
        self.identity = identity
        self.smbConnection = smbConnection
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
    private(set) var player: VLCMediaPlayer
    private var smbAuthentication: RNGSMBPlaybackAuthentication?

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
    // Incremented after the background track metadata read completes so the
    // video surface recomputes its aspect-correct rectangle.
    @Published private(set) var videoGeometryRevision = 0

    private var selection: FilePlaybackSelection?
    private var currentURL: URL?
    private var durationHint: Double?
    private var nativeInputDurationSeconds: Double?
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
    private var isRetiringPlayer = false
    private var stopRequested = false

    private weak var videoSurface: UIView?
    private var gate = PlaybackReadinessGate()
    private var endGate = FilePlaybackEndGate()
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
    private var cachedVideoSampleAspectRatio: RingonomiVLCVideoSampleAspectRatio?
    private var videoGeometryReadToken = UUID()
    private var videoGeometryReadScheduled = false

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
        player = VLCMediaPlayer()
        super.init()
        player.delegate = self
        player.audio?.isMuted = true
    }

    deinit {
        // SwiftUI releases this controller on the main thread after stop().
        // Keep an extra native reference until that destruction has finished,
        // then release it away from UI work just like a replaced player.
#if DEBUG
        if !isStopped { NSLog("RingonomiFileLifecycle: released-without-stop") }
#endif
        smbAuthentication?.invalidate()
        StoppedVLCPlayerRetirement(player, context: .file,
            retainedResources: smbAuthentication.map { [$0] } ?? []).releaseAfterCurrentTurn {}
    }

    var canSeek: Bool {
        canSeekRelative && durationSeconds != nil
    }

    /// Relative moves need a current timestamp, rather than a total duration.
    /// The position gate still verifies that the demuxer actually moved.
    var canSeekRelative: Bool {
        !isStopped && !isSuspendedForBackground && !isLoading
            && failure == nil && isSeekable
            && (durationSeconds != nil || (!isEnded && rawPlaybackSeconds != nil))
    }

    var videoRect: CGRect {
        guard let bounds = videoSurface?.bounds else { return .zero }
        return RingonomiVLCVideoGeometry.fittedRect(
            in: bounds, codedSize: player.videoSize,
            sampleAspectRatio: cachedVideoSampleAspectRatio)
    }

    func attachSurface(_ view: UIView) {
        videoSurface = view
        player.drawable = view
    }

    private func resetVideoGeometryCache(notifyUI: Bool = true) {
        videoGeometryReadToken = UUID()
        videoGeometryReadScheduled = false
        cachedVideoSampleAspectRatio = nil
        if notifyUI { videoGeometryRevision &+= 1 }
    }

    /// `VLCMedia.tracksInformation` may synchronously parse the media. Read
    /// it once after the readiness gate opens, away from the main actor, and
    /// publish only a generation-scoped result.
    private func scheduleVideoGeometryReadIfNeeded(codedSize: CGSize) {
        guard !isStopped, !isSuspendedForBackground, !isLoading,
              failure == nil, !videoGeometryReadScheduled,
              let media = player.media,
              codedSize.width.isFinite, codedSize.height.isFinite,
              codedSize.width > 0, codedSize.height > 0 else { return }

        let activeTrackID = player.currentVideoTrackIndex >= 0
            ? Int(player.currentVideoTrackIndex) : nil
        let token = videoGeometryReadToken
        videoGeometryReadScheduled = true
        DispatchQueue.global(qos: .utility).async {
            let aspectRatio = RingonomiVLCVideoGeometry.sampleAspectRatio(
                from: media.tracksInformation,
                activeTrackID: activeTrackID,
                codedSize: codedSize
            )
            Task { @MainActor [weak self] in
                guard let self, self.videoGeometryReadToken == token,
                      !self.isStopped, !self.isSuspendedForBackground else { return }
                self.cachedVideoSampleAspectRatio = aspectRatio
                self.videoGeometryRevision &+= 1
#if DEBUG
                let activeTrackDescription = activeTrackID.map(String.init) ?? "nil"
                let codedSizeDescription = "\(codedSize.width)x\(codedSize.height)"
                if let aspectRatio {
                    print("RingonomiVLCGeometry: sar=\(aspectRatio.numerator)/\(aspectRatio.denominator) coded=\(codedSizeDescription) activeTrack=\(activeTrackDescription)")
                } else {
                    print("RingonomiVLCGeometry: sar=none coded=\(codedSizeDescription) activeTrack=\(activeTrackDescription)")
                }
#endif
            }
        }
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
        guard canSeekRelative, seconds.isFinite else { return }
        // An unknown-length stream must provide a real native timestamp;
        // a requested or cached position is not a safe basis for a move.
        let current = durationSeconds == nil ? rawPlaybackSeconds : safeCurrentSeconds
        guard let current,
              let target = clamp(current + seconds, duration: durationSeconds),
              milliseconds(target) != nil else { return }
        seekToPosition(target)
    }

    func seek(to seconds: Double) {
        guard canSeek, seconds.isFinite,
              let target = clamp(seconds, duration: durationSeconds),
              milliseconds(target) != nil else { return }
        seekToPosition(target)
    }

    private func seekToPosition(_ target: Double) {
        // The rightmost seek-bar position means the end of a completed
        // recording. Asking the TS decoder to seek into its final fraction
        // of a second can leave its input teardown blocked. End explicitly
        // without opening that tail; growing/unknown-duration files and
        // media that have never produced a frame cannot take this shortcut.
        if let completedDuration = durationHint, lastPictures > 0,
           target >= max(0, completedDuration - 0.11) {
            targetSeconds = target
#if DEBUG
            print("RingonomiFileExplicitEnd: target=\(target)")
#endif
            finishPlayback()
            return
        }

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
        endGate.reset()
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
        refreshDurationAndSeekability()
        if player.state == .error {
            fail("録画を再生できませんでした。接続先とファイル状態を確認してください。")
            return
        }
        var preservingTrustedPosition = false
        if player.state == .ended, !isEnded {
            if pendingPositionSeconds != nil {
                if canFinishAtEndWithPendingPosition() {
                    clearPendingPositionRequest()
                    finishPlayback()
                } else {
                    // A stale ended callback can arrive while a seek is still
                    // pending. Do not turn that callback into an EOF bookmark;
                    // return from Home using the last position that passed the
                    // readiness gate.
                    preservingTrustedPosition = true
                    targetSeconds = lastTrustedSeconds ?? targetSeconds
#if DEBUG
                    print("RingonomiFileLifecycle: endedDuringPendingSeek preservedTrusted=\(lastTrustedSeconds ?? -1)")
#endif
                }
            } else {
                finishPlayback()
            }
        }
        if preservingTrustedPosition {
            targetSeconds = lastTrustedSeconds ?? targetSeconds
        } else if !isLoading, !isEnded {
            targetSeconds = safeCurrentSeconds
        }
        if !preservingTrustedPosition, !isLoading, failure == nil { reportProgress(force: true) }
        endGate.reset()
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
        requestPlayerStop()
        player.drawable = nil
        // Keep media attached to the stopped instance. Foreground resume
        // replaces it entirely; an asynchronous nil assignment here can
        // still be running when that old instance is released.
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
        smbAuthentication?.invalidate()
        isSuspendedForBackground = false
        generation &+= 1
        endGate.reset()
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
        resetVideoGeometryCache(notifyUI: false)
        monitor?.cancel()
        monitor = nil
        stopTask?.cancel()
        stopTask = nil
        player.delegate = nil
        player.audio?.isMuted = true
        player.drawable = nil
        clearAudioCatalog(notifyUI: false)
        onContinuousDisplayChanged = nil
        onProgress = nil
        requestPlayerStop()
        holdPlayerUntilStopped()
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
        // The old instance is only used to observe the asynchronous stop
        // below.  Its delegate must be detached before the replacement so a
        // queued state notification cannot be mistaken for the new media.
        player.delegate = nil
        currentURL = url
        generation &+= 1
        resetVideoGeometryCache()
        endGate.reset()
        pendingLoadGeneration = generation
        pendingLoadURL = url
        let effectiveDuration = durationHint ?? durationSeconds
        // Unknown-length SMB streams cannot reliably restore a timestamp.
        // Restart them at the beginning after Retry or foreground return.
        let canRestorePosition = selection?.smbConnection == nil || effectiveDuration != nil
        targetSeconds = canRestorePosition
            ? (clamp(position, duration: effectiveDuration) ?? 0) : 0
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
        nativeInputDurationSeconds = nil
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
        // `resetReadinessBaseline()` may still see the previous decoder
        // before the asynchronous stop completes.  A new load must never
        // use that old generation's counters as EOF evidence.
        clearUnavailableStatisticsBaseline()
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
        requestPlayerStop()
        startPendingLoadIfReady(for: generation)
    }

    private func startPendingLoadIfReady(for expectedGeneration: Int) {
        guard !isStopped, !isSuspendedForBackground,
              expectedGeneration == generation,
              pendingLoadGeneration == generation,
              let url = pendingLoadURL,
              currentURL == url,
              !isRetiringPlayer,
              player.state == .stopped else { return }

        pendingLoadURL = nil
        pendingLoadGeneration = 0
        // TVVLCKit 3.7 may ignore equivalent media URLs, and clearing media
        // is asynchronous. Retire the stopped instance so its cleanup cannot
        // race with opening the same file for Replay or foreground resume.
        let oldPlayer = player
        oldPlayer.delegate = nil
        oldPlayer.drawable = nil
        oldPlayer.audio?.isMuted = true
        // Native release owns media cleanup. Scheduling an asynchronous
        // media detach immediately before release can stall VLC teardown.

        let oldAuthentication = smbAuthentication
        oldAuthentication?.invalidate()
        let freshPlayer: VLCMediaPlayer
        let freshAuthentication: RNGSMBPlaybackAuthentication?
        let freshMedia = VLCMedia(url: url)
        do {
            if let connection = selection?.smbConnection {
                _ = try connection.relativePath(for: url)
                let credentials = try SMBCredentialsKeychain().load(for: connection)
                guard credentials?.domain.isEmpty != false else {
                    throw SMBError.invalidConnection
                }
                freshPlayer = VLCMediaPlayer(options: [
                    "--quiet", "--verbose=-1", "--keystore=memory"
                ])
                freshPlayer.libraryInstance.loggers = nil
                if let credentials {
                    // Supply credentials before opening the file so SMB does
                    // not need an anonymous probe before requesting a login.
                    // The fresh player's instance owns any in-memory cache.
                    freshMedia.addOptions([
                        "smb-user": credentials.username,
                        "smb-pwd": credentials.password
                    ])
                }
                freshAuthentication = RNGSMBPlaybackAuthentication(
                    library: freshPlayer.libraryInstance,
                    username: credentials?.username, password: credentials?.password)
                guard freshAuthentication != nil else { throw SMBError.invalidConnection }
            } else {
                freshPlayer = VLCMediaPlayer()
                freshAuthentication = nil
            }
        } catch {
            fail("共有を開けませんでした。接続設定とログイン情報を確認してください。")
            return
        }
        freshPlayer.delegate = self
        if let videoSurface { freshPlayer.drawable = videoSurface }
        freshPlayer.audio?.isMuted = true
        // The fresh player has a different media/track set. Invalidate any
        // background metadata read belonging to the retired instance before
        // exposing the new one to the readiness loop.
        resetVideoGeometryCache()
        player = freshPlayer
        smbAuthentication = freshAuthentication
        stopRequested = false
        freshPlayer.media = freshMedia
        freshPlayer.audio?.isMuted = true
        if pendingPositionSeconds != nil, pendingPositionStartedAt == nil {
            pendingPositionStartedAt = Date()
        }
        freshPlayer.play()
        retireStoppedPlayer(oldPlayer, authentication: oldAuthentication)
    }

    private func retireStoppedPlayer(_ oldPlayer: VLCMediaPlayer,
                                     authentication: RNGSMBPlaybackAuthentication? = nil) {
        isRetiringPlayer = true
        let retirement = StoppedVLCPlayerRetirement(oldPlayer, context: .file,
            retainedResources: authentication.map { [$0] } ?? [])
        // Start after this stack unwinds so its local references cannot make
        // the final native release fall back onto the main thread. VLC release
        // can wait for decoder callbacks that themselves need the main queue.
        retirement.releaseAfterCurrentTurn { [weak self] in
            self?.isRetiringPlayer = false
        }
    }

    private func updateStatus() {
        guard !isStopped, !isSuspendedForBackground, failure == nil,
              currentURL != nil, !isEnded else { return }

        if pendingLoadURL != nil {
            startPendingLoadIfReady(for: generation)
            if pendingLoadURL != nil {
                if Date().timeIntervalSince(waitingSince) > 30 {
                    fail("読み込みがタイムアウトしました。接続を確認して再試行してください。")
                }
                return
            }
        }

        // Refresh duration before handling `.ended`; the pending-position EOF
        // check must use the media's actual finite duration when available.
        refreshDurationAndSeekability()

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
                if canFinishAtEndWithPendingPosition() {
                    clearPendingPositionRequest()
                    finishPlayback()
                } else {
                    failPositionRequest()
                }
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

        if processPositionRequest() { return }
        refreshAudioTracks()

        let size = player.videoSize
        let hasVideo = player.hasVideoOut && size.width > 0 && size.height > 0
        if hasVideo, !isLoading {
            scheduleVideoGeometryReadIfNeeded(codedSize: size)
        }
        if canReadPlaybackStatistics, let media = player.media {
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

            let detectedEnd = endGate.update(
                currentSeconds: rawPlaybackSeconds,
                duration: durationHint,
                position: Double(player.position),
                remainingSeconds: rawRemainingSeconds,
                isPaused: player.state == .paused,
                hasPendingSeek: pendingPositionSeconds != nil,
                displayedPictures: totalPictures,
                playedAudioBuffers: playedAudio,
                at: ProcessInfo.processInfo.systemUptime
            )
            if detectedEnd {
#if DEBUG
                print("RingonomiFileEndGate: confirmed current=\(rawPlaybackSeconds ?? -1) duration=\(durationHint ?? -1) position=\(player.position) remaining=\(rawRemainingSeconds ?? -1)")
#endif
                finishPlayback()
                return
            }
#if DEBUG
            if Date().timeIntervalSince(lastDebugStatusDate) >= 5 {
                lastDebugStatusDate = Date()
                let rawSeconds = rawPlaybackSeconds ?? -1
                let remainingMilliseconds = player.remainingTime?.value?.doubleValue ?? -1
                let remainingSeconds = remainingMilliseconds >= 0 ? remainingMilliseconds / 1000 : -1
                let mediaLengthMilliseconds = media.length.value?.doubleValue ?? -1
                let mediaLengthSeconds = mediaLengthMilliseconds >= 0 ? mediaLengthMilliseconds / 1000 : -1
                print("RingonomiFileStats: rawSeconds=\(rawSeconds) position=\(player.position) remainingSeconds=\(remainingSeconds) mediaLengthSeconds=\(mediaLengthSeconds) inputLengthSeconds=\(nativeInputDurationSeconds ?? -1) seekable=\(player.isSeekable) parsedStatus=\(media.parsedStatus.rawValue) readBytes=\(stats.readBytes) demuxReadBytes=\(stats.demuxReadBytes) inputBitrate=\(stats.inputBitrate) demuxBitrate=\(stats.demuxBitrate) pictures=\(totalPictures) delta=\(pictures) decodedAudio=\(decodedAudio) playedAudio=\(playedAudio) loading=\(isLoading) muted=\(player.audio?.isMuted == true) state=\(player.state.rawValue)")
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
            // VLCMedia.statistics is not meaningful while a player is
            // stopped/opening (and some TVVLCKit builds expose stale native
            // memory there).  Preserve the current generation's counters so
            // a transient video-output loss does not turn old cumulative
            // frames into new frames when output returns.
            gate.reset()
            endGate.reset()
            lastFrameDate = .distantPast
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
        endGate.reset()
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
            clearPendingPositionRequest()
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
        clearPendingPositionRequest()
        retryFromBeginningAfterPositionFailure = true
        let message = wasInitial
            ? "指定位置から再生できませんでした。再試行すると先頭から開始します。"
            : "指定位置へ移動できませんでした。再試行すると先頭から開始します。"
#if DEBUG
        print("RingonomiFilePosition: failed initial=\(wasInitial)")
#endif
        fail(message)
    }

    private func clearPendingPositionRequest() {
        pendingPositionSeconds = nil
        pendingPositionStartedAt = nil
        pendingPositionApplied = false
        pendingPositionAppliedAt = nil
        pendingPositionFallbackApplied = false
        pendingPositionIsInitial = false
    }

    private func canFinishAtEndWithPendingPosition() -> Bool {
        let requested = pendingPositionSeconds
        let actual = rawPlaybackSeconds
        let normalizedPosition = Double(player.position)
        let remaining = rawRemainingSeconds
        let displayedPictures: Int
        if canReadPlaybackStatistics, let media = player.media {
            displayedPictures = max(0, Int(media.statistics.displayedPictures))
        } else {
            // Native EOF can drop the video output before this check runs.
            // `lastPictures` is reset at every new generation, so it is safe
            // evidence from this media only; zero still rejects a no-frame
            // or opening/stopped path.
            displayedPictures = max(0, lastPictures)
        }
#if DEBUG
        print("RingonomiFileEndCheck: requested=\(requested ?? -1) rawActual=\(actual ?? -1) position=\(normalizedPosition) remaining=\(remaining ?? -1) state=\(player.state.rawValue) pictures=\(displayedPictures) generationMatch=\(pendingPositionGeneration == generation) applied=\(pendingPositionApplied)")
#endif
        guard pendingPositionGeneration == generation,
              pendingPositionApplied,
              let requested,
              displayedPictures > 0 else { return false }

        if let duration = validDuration(durationSeconds ?? durationHint) {
            let tolerance = positionTolerance(for: requested, duration: duration)
            if abs(duration - requested) <= tolerance,
               let actual,
               abs(duration - actual) <= tolerance,
               abs(actual - requested) <= tolerance {
                return true
            }
        }

        // At the end of an HTTP MPEG-TS seek, VLC 3.0.17 can report ended
        // without emitting a final time/position event. Its cached VLCTime,
        // normalized position, and remaining time can therefore still belong
        // to the pre-seek position. Treat native `.ended` as authoritative
        // only for an explicit end-position request on a completed recording
        // with decoded output from this generation. Unknown/growing files and
        // frame-less EOF remain failures.
        guard player.state == .ended,
              let completedDuration = validDuration(durationHint),
              displayedPictures > 0 else { return false }
        let completedTolerance = positionTolerance(for: requested, duration: completedDuration)
        return abs(completedDuration - requested) <= completedTolerance
    }

    private func refreshDurationAndSeekability() {
        // An unparsed SMB media descriptor can have no length even while its
        // active input knows the duration. Read that authoritative clock rather
        // than estimating a duration from normalized playback position.
        nativeInputDurationSeconds = selection?.smbConnection != nil
            ? validDuration(RNGVLCPlayerDurationSeconds(player)) : nil
        if let inputDuration = nativeInputDurationSeconds {
            durationSeconds = inputDuration
        } else if let milliseconds = player.media?.length.value?.doubleValue,
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
        endGate.reset()
        isEnded = true
        wantsPause = true
        isPaused = true
        isLoading = false
        waitingSince = Date()
        player.audio?.isMuted = true
        // A paused input at TS EOF can stall native teardown even after VLC
        // reports stopped. EOF is terminal, so stop instead of pausing the
        // decoder and create a fresh instance for the next explicit action.
        requestPlayerStop()
        if let duration = durationSeconds { currentSeconds = duration }
        status = "再生終了（再生ボタンで最初から）"
        updateContinuousDisplayNeed()
        reportProgress(force: true)
#if DEBUG
        let rawActual = rawPlaybackSeconds ?? -1
        let remaining = rawRemainingSeconds ?? -1
        let displayedPictures: Int
        if canReadPlaybackStatistics, let media = player.media {
            displayedPictures = max(0, Int(media.statistics.displayedPictures))
        } else {
            displayedPictures = max(0, lastPictures)
        }
        print("RingonomiFileEnded: time=\(currentSeconds) duration=\(durationSeconds ?? -1) rawActual=\(rawActual) position=\(player.position) remaining=\(remaining) state=\(player.state.rawValue) pictures=\(displayedPictures)")
#endif
    }

    private func beginWaiting() {
        guard !isSuspendedForBackground, !isStopped else { return }
        if !isLoading {
            resetReadinessBaseline()
            gate.reset()
            endGate.reset()
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
        endGate.reset()
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

    private var rawRemainingSeconds: Double? {
        guard let value = player.remainingTime?.value?.doubleValue,
              value.isFinite else { return nil }
        let seconds = value / 1000
        return seconds.isFinite ? seconds : nil
    }

    /// `VLCMedia.statistics` is backed by native decoder state.  The media
    /// object can remain attached while the player is stopped or opening, but
    /// its counters are not a valid snapshot in those states.  Requiring a
    /// live video output also prevents stale counters from an old decoder from
    /// being used during a fresh same-URL replay.
    private var canReadPlaybackStatistics: Bool {
        guard player.state != .stopped,
              player.state != .opening,
              player.state != .ended,
              player.state != .error else { return false }
        let size = player.videoSize
        return player.hasVideoOut && size.width > 0 && size.height > 0
    }

    private func clearUnavailableStatisticsBaseline() {
        pictureBaseline = 0
        lastPictures = 0
        lastFrameDate = .distantPast
        audioBaselineDecoded = 0
        audioBaselinePlayed = 0
        audioNeedsFreshBuffers = true
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
        if canReadPlaybackStatistics, let media = player.media {
            let stats = media.statistics
            audioBaselineDecoded = max(0, Int(stats.decodedAudio))
            audioBaselinePlayed = max(0, Int(stats.playedAudioBuffers))
            pictureBaseline = max(0, Int(stats.displayedPictures))
        } else {
            clearUnavailableStatisticsBaseline()
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

    private func requestPlayerStop() {
        guard !stopRequested, player.state != .stopped else { return }
        stopRequested = true
        player.stop()
    }

    /// Keep the controller alive until its native player has stopped. Media
    /// cleanup belongs to native release, avoiding a competing async detach.
    private func holdPlayerUntilStopped() {
        stopTask?.cancel()
        guard player.state != .stopped else { return }
        stopTask = Task { @MainActor [self] in
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                if self.player.state == .stopped {
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
        if scheme == "smb" {
            guard let connection = selection?.smbConnection,
                  let path = try? connection.relativePath(for: url) else { return false }
            return !path.isRoot
        }
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
        // Double rounds Int64.max up to an out-of-range value. A checked
        // conversion preserves long recordings without trapping at that edge.
        return Int64(exactly: value.rounded())
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
