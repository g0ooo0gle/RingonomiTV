import Foundation
import SwiftUI
import RingonomiCore
#if canImport(TVVLCKit)
@preconcurrency import TVVLCKit
#endif

#if canImport(TVVLCKit)
@MainActor
final class PlaybackController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    // TVVLCKit 3.7.0 does not accept a mute command-line option at init time.
    // Mute is applied after the player is created and while the readiness gate is closed.
    let player = VLCMediaPlayer()
    @Published private(set) var status = "読み込み中…"
    @Published private(set) var isLoading = true
    @Published private(set) var failure: String?
    @Published private(set) var audioOptions: [PlaybackAudioOption] = []
    @Published private(set) var selectedAudioID: String?
    @Published private(set) var audioSelectionError: String?
    // Incremented after the background track metadata read completes so
    // SwiftUI re-evaluates `videoRect` without parsing from the getter.
    @Published private(set) var videoGeometryRevision = 0
    let captions = LiveCaptionController()
    private var usesLiveCaptionRelay = false
    private var currentURL: URL?
    private var resolvedMediaURL: URL?
    private var mediaConnection: PlaybackMediaConnection?
    private var mediaResolution: Task<Void, Never>?

    func configureLiveConnection(client: RingonomiClient) {
        guard currentURL == nil else { return }
        mediaConnection?.invalidate()
        usesLiveCaptionRelay = true
        mediaConnection = PlaybackMediaConnection(liveClient: client) { [weak self] batch in
            self?.captions.accept(batch)
        }
    }

    private func invalidateMediaConnection() {
        mediaResolution?.cancel(); mediaResolution = nil
        mediaConnection?.invalidate()
        captions.stop()
    }
    // A cancelled monitor/delegate callback can still be queued on the main
    // actor while SwiftUI is dismantling the representable.  Teardown must
    // not publish into that invalidating graph.
    private var isStopped = false
    // A final handoff cannot be undone by a queued updateUIView load. Regular
    // stop() remains reusable for EPGStation's retry/reconfiguration path.
    private var isClosingPermanently = false
    // Background transitions keep the controller alive, but the VLC decoder
    // and its polling task must be released until the app is foregrounded
    // again.  This flag also makes repeated lifecycle notifications safe.
    private var isSuspendedForBackground = false
    // A prepared live connection can become unusable while it is paused.
    // Resume always creates fresh media; an in-progress initial/quality/retry
    // load continues without starting a duplicate load.
    private var isChangingQuality = false
    @Published private var wantsPause = false
    var isPaused: Bool { wantsPause }
    private weak var videoSurface: UIView?
    var videoRect: CGRect {
        guard let bounds = videoSurface?.bounds else { return .zero }
        return RingonomiVLCVideoGeometry.fittedRect(
            in: bounds, codedSize: player.videoSize,
            sampleAspectRatio: cachedVideoSampleAspectRatio)
    }

    func attachSurface(_ view: UIView) {
        guard !isClosingPermanently else { return }
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

    private var gate = PlaybackReadinessGate()
    private var monitor: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopWaitGeneration = 0
    private var stopRequested = false
    // TVVLCKit stops the native player asynchronously. Keep a fresh URL
    // pending until the stop state is observable, otherwise assigning the
    // same URL can be treated as a no-op by libVLC.
    private var pendingLoadURL: URL?
    private var pendingLoadGeneration = 0
    private var loadGeneration = 0
    /// Tracks the bounded startup phase for the current media generation.
    /// The deadline is deliberately separate from `isLoading`: that flag is
    /// also used for pause, audio-track, and quality-change UI state, while
    /// this state machine must reject stale transport/player callbacks.
    private var startupDeadline = LivePlaybackStartupDeadline()
    private var lastFrameDate = Date.distantPast
    private var lastPictures = 0
    private var lastLog = Date.distantPast
#if DEBUG
    private var lastLogUptime: Double?
    private var lastLogPictures = 0
    private var pendingStateLogDate = Date.distantPast
    private var waitingDiagnosticDate = Date.distantPast
#endif
    private var audioSourceID: UUID?
    /// The native track list may change while VLC keeps the same source UUID.
    /// Keep a separate catalog generation so an old menu item cannot target a
    /// newly reused raw track ID.
    private var audioCatalogGeneration: PlaybackAudioCatalogGeneration?
    private var audioTrackIDsByOptionID: [String: Int32] = [:]
    private var preferredAudioName: String?
    private var hasExplicitAudioSelection = false
    private var didReportMissingAudioForSource = false
    private var lastPreferredAudioAttemptID: String?
    private var lastAudioCatalogSignature: String?
    private var audioBaselineDecoded = 0
    private var audioBaselinePlayed = 0
    private var audioNeedsFreshBuffers = true
    // A native statistics read can be unavailable while the player is being
    // replaced or while VLC is still opening/buffering. Keep the previous
    // baseline in that case, then establish a new baseline from the first
    // valid sample before waiting for a subsequent audio counter advance.
    private var audioBaselinePending = false
    private var audioRecoveryPending = false
    private var audioRecoveryRawID: Int32?
    private var audioRecoveryCatalogGeneration: UInt64?
    private struct PendingAudioSelection {
        let id: String
        let rawID: Int32
        let catalogGeneration: UInt64
        let previousID: String?
        let previousRawID: Int32?
        let rememberPreference: Bool
        let startedAt: Date
    }
    private var pendingAudioSelection: PendingAudioSelection?
    private var cachedVideoSampleAspectRatio: RingonomiVLCVideoSampleAspectRatio?
    private var videoGeometryReadToken = UUID()
    private var videoGeometryReadScheduled = false
    private var audioCatalogChangeNotice: String {
        "音声の構成が変わりました。現在の音声を確認してください。"
    }
    override init() { super.init(); player.delegate = self }

    deinit {
        StoppedVLCPlayerRetirement(player, context: .live).releaseAfterCurrentTurn {}
    }

    func selectAudioTrack(id: String) {
        guard !isStopped, currentURL != nil, failure == nil, !isLoading else { return }
        // The 500 ms monitor is not the only catalog boundary. Refresh once
        // immediately before accepting UI input so a reused raw ID cannot be
        // selected between monitor ticks.
        guard player.media != nil else {
            audioSelectionError = "選択した音声を利用できません。"
            return
        }
        refreshAudioTracks(restorePreference: false)
        guard let catalog = audioCatalogGeneration else {
            audioSelectionError = "選択した音声を利用できません。"
            return
        }
        guard
              pendingAudioSelection == nil,
              !audioRecoveryPending,
              let rawID = catalog.rawID(for: id),
              catalog.contains(optionID: id, rawID: rawID),
              audioOptions.contains(where: { $0.id == id }) else {
            audioSelectionError = "選択した音声を利用できません。"
            return
        }
        _ = applyAudioTrack(id: id, rawID: rawID,
                            catalogGeneration: catalog.generation,
                            rememberPreference: true)
    }

    func prepareQualityChange() {
        guard !isStopped, !isSuspendedForBackground else { return }
        startupDeadline.invalidate()
        invalidateMediaConnection()
        resolvedMediaURL = nil
        // Ignore callbacks from the old media until SwiftUI supplies the new URL.
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        loadGeneration &+= 1
        let expectedLoadGeneration = loadGeneration
        // SwiftUI may take a few seconds to publish the replacement URL. Keep
        // that gap bounded so a lost quality-card callback cannot leave the
        // controller loading forever.
        startupDeadline.begin(generation: expectedLoadGeneration, phase: .waitingForMedia)
        isChangingQuality = true
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self else { return }
                self.updateStatus(expectedLoadGeneration: expectedLoadGeneration)
            }
        }
        resetVideoGeometryCache()
        isLoading = true
        player.audio?.isMuted = true
        gate.reset()
    }
    func load(_ url: URL) {
        guard !isClosingPermanently, !isSuspendedForBackground,
              currentURL != url else { return }
        stopTask?.cancel()
        stopTask = nil
        stopWaitGeneration &+= 1
        isStopped = false
        isSuspendedForBackground = false
        player.delegate = self
        isChangingQuality = false
        invalidateMediaConnection()
        resolvedMediaURL = mediaConnection == nil ? url : nil
        currentURL = url
        if usesLiveCaptionRelay { captions.prepare() }
        loadGeneration &+= 1
        let expectedLoadGeneration = loadGeneration
        startupDeadline.invalidate()
        startupDeadline.begin(generation: expectedLoadGeneration, phase: .preparingPlayer)
        pendingLoadURL = url
        pendingLoadGeneration = expectedLoadGeneration
        monitor?.cancel()
        resetVideoGeometryCache()
        resetAudioCatalog()
        // Calling stop() for an already-stopped player still dispatches
        // libvlc_media_player_stop_async. Do not enqueue that extra stop just
        // before the pending loader observes .stopped and calls play().
        requestPlayerStop()
        failure = nil
        gate.reset()
        lastFrameDate = .distantPast
        lastPictures = 0
#if DEBUG
        lastLog = .distantPast
        lastLogUptime = nil
        lastLogPictures = 0
        pendingStateLogDate = .distantPast
        waitingDiagnosticDate = .distantPast
#endif
        isLoading = true
        status = "読み込み中…"
        player.audio?.isMuted = true
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self else { return }
                self.updateStatus(expectedLoadGeneration: expectedLoadGeneration)
            }
        }
        if let mediaConnection {
            mediaResolution = Task { @MainActor [weak self] in
                do {
                    let resolved = try await mediaConnection.resolve(source: url, kind: .media) { [weak self] error in
                        guard let self, self.loadGeneration == expectedLoadGeneration else { return }
                        self.fail(error.localizedDescription)
                    }
                    guard let self, !Task.isCancelled, self.loadGeneration == expectedLoadGeneration,
                          !self.isStopped, !self.isSuspendedForBackground else { return }
                    self.resolvedMediaURL = resolved
                    self.startPendingLoadIfReady(for: expectedLoadGeneration)
                } catch {
                    guard let self, !Task.isCancelled, !(error is CancellationError),
                          self.loadGeneration == expectedLoadGeneration else { return }
                    self.fail(error.localizedDescription)
                }
            }
        }
        startPendingLoadIfReady(for: expectedLoadGeneration)
    }
    func togglePause() {
        guard !isStopped, !isSuspendedForBackground, failure == nil else { return }
        if wantsPause {
            let shouldReload = shouldReloadAfterPause
            wantsPause = false
            if shouldReload {
                // Reuse the quality URL, but create fresh VLC media so the
                // normal readiness gate applies before playback is revealed.
#if DEBUG
                print("RingonomiLivePause: reconnecting with fresh media")
#endif
                retry()
            } else if !isLoading {
                beginWaiting()
                player.play()
            }
        } else {
            wantsPause = true
            if !isLoading {
                player.pause()
                player.audio?.isMuted = true
            }
        }
        updateStatus()
    }
    /// UIから現在選択中のURLを渡せば、画質変更の通知が失われた
    /// 場合も旧画質へ戻らず、新しい再生世代を開始できる。
    func retry(_ requestedURL: URL? = nil) {
        guard !isStopped, !isSuspendedForBackground,
              let url = requestedURL ?? currentURL else { return }
        currentURL = nil
        load(url)
    }

    private func startPendingLoadIfReady(for expectedGeneration: Int? = nil) {
        guard !isStopped, !isSuspendedForBackground, !isChangingQuality, failure == nil,
              let url = pendingLoadURL, let resolvedMediaURL,
              pendingLoadGeneration == loadGeneration,
              currentURL == url else { return }
        if let expectedGeneration,
           pendingLoadGeneration != expectedGeneration || loadGeneration != expectedGeneration {
            return
        }
        guard player.state == .stopped else {
#if DEBUG
            if Date().timeIntervalSince(pendingStateLogDate) >= 5 {
                pendingStateLogDate = Date()
                print("RingonomiLivePending: waitingForStop state=\(player.state.rawValue)")
            }
#endif
            return
        }

        // Clear the pending marker before assigning media so a synchronous
        // VLC callback cannot try to start the same input twice.
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        stopRequested = false
        player.media = VLCMedia(url: resolvedMediaURL)
        if let videoSurface { player.drawable = videoSurface }
        player.audio?.isMuted = true
#if DEBUG
        print("RingonomiLivePending: start state=\(player.state.rawValue)")
#endif
        startupDeadline.playerStarted(generation: loadGeneration, usesRelay: mediaConnection != nil)
        player.play()
    }

    private var isTerminalPlaybackState: Bool {
        switch player.state {
        case .stopped, .ended, .error:
            return true
        default:
            return false
        }
    }

    private var shouldReloadAfterPause: Bool {
        // A prepared stream is always rebuilt on resume.  During initial,
        // quality-change, or retry preparation, just clear the pause intent
        // and let the existing pending load finish.
        !isLoading && !isChangingQuality && currentURL != nil
    }

    /// Releases the live decoder while the application is in the background.
    /// The URL and the user's pause intent remain available for a fresh media
    /// load when the app becomes active again.
    func suspendForBackground() {
        guard !isStopped, !isSuspendedForBackground, currentURL != nil, failure == nil else { return }
        startupDeadline.invalidate()
        isSuspendedForBackground = true
        invalidateMediaConnection()
        resolvedMediaURL = nil
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        loadGeneration &+= 1
#if DEBUG
        print("RingonomiLiveLifecycle: suspended paused=\(wantsPause)")
#endif
        monitor?.cancel()
        monitor = nil
        isLoading = true
        gate.reset()
        lastFrameDate = .distantPast
        lastPictures = 0
        resetVideoGeometryCache()
        player.audio?.isMuted = true
        player.delegate = nil
        player.drawable = nil
        requestPlayerStop()
        status = "読み込み中…"
    }

    /// Recreates the live media after a background transition.  A paused
    /// stream keeps `wantsPause`; the readiness gate will pause the new media
    /// before unmuting it.
    func resumeFromBackground() {
        guard isSuspendedForBackground, !isStopped, failure == nil,
              let url = currentURL else { return }
        isSuspendedForBackground = false
#if DEBUG
        print("RingonomiLiveLifecycle: resumed paused=\(wantsPause)")
#endif
        currentURL = nil
        load(url)
    }

    func stop() {
        guard !isStopped else { return }
        startupDeadline.invalidate()
        invalidateMediaConnection()
        resolvedMediaURL = nil
        monitor?.cancel()
        monitor = nil
        stopTask?.cancel()
        stopTask = nil
        stopWaitGeneration &+= 1
        let expectedStopWaitGeneration = stopWaitGeneration
        isStopped = true
        isSuspendedForBackground = false
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        loadGeneration &+= 1
        currentURL = nil
        player.delegate = nil
        resetVideoGeometryCache(notifyUI: false)
        clearAudioCatalog(notifyUI: false)
        player.audio?.isMuted = true
        player.drawable = nil
        requestPlayerStop()
        videoSurface = nil
        holdPlayerUntilStopped(for: expectedStopWaitGeneration)
    }
    /// A new backend must not create its decoder until this input has stopped.
    func stopBeforeClosing() async -> Bool {
        isClosingPermanently = true
        stop()
        await mediaConnection?.stop()
        for _ in 0..<100 {
            if player.state == .stopped { return true }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
        }
        return player.state == .stopped
    }

    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateStatus() }
    }
    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateStatus() }
    }
    private func beginWaiting(reason: String = "operation") {
        guard !isSuspendedForBackground else { return }
        if !isLoading {
#if DEBUG
            logWaitingDiagnostic(reason: reason, force: true)
#endif
            gate.reset()
            startupDeadline.begin(generation: loadGeneration, phase: .buffering)
        }
        isLoading = true
        player.audio?.isMuted = true
        status = "読み込み中…"
    }

    private func resetAudioCatalog() {
        audioSourceID = UUID()
        audioCatalogGeneration = nil
        audioTrackIDsByOptionID.removeAll(keepingCapacity: false)
        audioOptions = []
        selectedAudioID = nil
        audioSelectionError = nil
        didReportMissingAudioForSource = false
        lastPreferredAudioAttemptID = nil
        lastAudioCatalogSignature = nil
        audioBaselineDecoded = 0
        audioBaselinePlayed = 0
        audioNeedsFreshBuffers = true
        audioBaselinePending = false
        audioRecoveryPending = false
        audioRecoveryRawID = nil
        audioRecoveryCatalogGeneration = nil
        pendingAudioSelection = nil
    }

    private func clearAudioCatalog(notifyUI: Bool = true) {
        audioSourceID = nil
        audioCatalogGeneration = nil
        audioTrackIDsByOptionID.removeAll(keepingCapacity: false)
        if notifyUI {
            audioOptions = []
            selectedAudioID = nil
            audioSelectionError = nil
        }
        preferredAudioName = nil
        hasExplicitAudioSelection = false
        didReportMissingAudioForSource = false
        lastPreferredAudioAttemptID = nil
        lastAudioCatalogSignature = nil
        audioBaselineDecoded = 0
        audioBaselinePlayed = 0
        audioNeedsFreshBuffers = false
        audioBaselinePending = false
        audioRecoveryPending = false
        audioRecoveryRawID = nil
        audioRecoveryCatalogGeneration = nil
        pendingAudioSelection = nil
    }

    private func clearDiscoveredAudioOptions() {
        // Keep the source alive, but publish an empty generation. This
        // invalidates pending/recovery/selected state even when VLC later
        // reuses the same raw IDs for a recovered list.
        let previousGeneration = audioCatalogGeneration?.generation
        let invalidatedPending = pendingAudioSelection != nil
            || audioRecoveryPending || selectedAudioID != nil
        let hadCatalogChangeNotice = audioSelectionError == audioCatalogChangeNotice
        if let sourceID = audioSourceID {
            let empty = audioCatalogGeneration.map {
                $0.replacing(sourceID: sourceID, descriptors: [])
            } ?? PlaybackAudioCatalogGeneration(sourceID: sourceID, descriptors: [])
            audioCatalogGeneration = empty
        } else {
            audioCatalogGeneration = nil
        }
        audioTrackIDsByOptionID.removeAll(keepingCapacity: false)
        if !audioOptions.isEmpty { audioOptions = [] }
        if selectedAudioID != nil { selectedAudioID = nil }
        lastPreferredAudioAttemptID = nil
        pendingAudioSelection = nil
        audioRecoveryPending = false
        audioRecoveryRawID = nil
        audioRecoveryCatalogGeneration = nil
        didReportMissingAudioForSource = false
        audioSelectionError = invalidatedPending || hadCatalogChangeNotice
            ? audioCatalogChangeNotice : nil
#if DEBUG
        if previousGeneration != audioCatalogGeneration?.generation {
            print("RingonomiTVAudioCatalog: generation=\(audioCatalogGeneration?.generation ?? 0) options=0 usable=false invalidated=\(invalidatedPending)")
        }
#endif
    }

    private struct NativePlaybackStatistics {
        let displayedPictures: Int
        let decodedAudio: Int
        let playedAudioBuffers: Int
    }

    private var canReadNativeStatistics: Bool {
        switch player.state {
        // VLC can keep ESAdded as its last state after a new broadcast track
        // appears. It does not imply a stopped decoder. Video output and
        // actual frame/audio counters must still pass the readiness gate.
        case .buffering, .playing, .paused, .esAdded:
            return true
        default:
            return false
        }
    }

    private var currentNativeStatistics: NativePlaybackStatistics? {
        guard canReadNativeStatistics,
              let media = player.media, player.hasVideoOut else { return nil }
        let size = player.videoSize
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }

        let stats = media.statistics
        let pictures = Int(stats.displayedPictures)
        let decodedAudio = Int(stats.decodedAudio)
        let playedAudioBuffers = Int(stats.playedAudioBuffers)
        guard pictures >= 0, pictures < 100_000_000,
              decodedAudio >= 0, playedAudioBuffers >= 0 else { return nil }
        // A zero picture count after an established video stream is the
        // default/unavailable value seen during native teardown. Do not let
        // it overwrite the last trusted counter or make the gate advance.
        guard pictures > 0 || lastPictures == 0 else { return nil }
        return NativePlaybackStatistics(
            displayedPictures: pictures,
            decodedAudio: decodedAudio,
            playedAudioBuffers: playedAudioBuffers
        )
    }

    private var currentAudioStatistics: (decoded: Int, played: Int)? {
        guard let stats = currentNativeStatistics,
              stats.decodedAudio > 0 || stats.playedAudioBuffers > 0 else {
            return nil
        }
        return (stats.decodedAudio, stats.playedAudioBuffers)
    }

    private func captureAudioBaseline() {
        if let stats = currentAudioStatistics {
            audioBaselineDecoded = stats.decoded
            audioBaselinePlayed = stats.played
            audioBaselinePending = false
        } else {
            audioBaselinePending = true
        }
        audioNeedsFreshBuffers = true
        gate.reset()
    }

    private func refreshAudioTracks(restorePreference: Bool = true) {
        guard !isStopped, currentURL != nil, failure == nil,
              let sourceID = audioSourceID, player.media != nil else { return }

        let rawIndexes = arrayValues(from: player.audioTrackIndexes)
        let rawNames = arrayValues(from: player.audioTrackNames)
        guard rawIndexes.count <= PlaybackAudioCatalog.maximumTracks else {
            clearDiscoveredAudioOptions()
            logAudioCatalog(options: [], currentRawID: currentRawAudioTrackID)
            return
        }
        var descriptors: [PlaybackAudioDescriptor] = []

        for (offset, rawIndex) in rawIndexes.enumerated() {
            guard let numericID = integerValue(rawIndex), numericID >= 0,
                  Int32(exactly: numericID) != nil else { continue }
            let name = offset < rawNames.count ? stringValue(rawNames[offset]) : nil
            guard !isDisabledAudioName(name) else { continue }
            descriptors.append(PlaybackAudioDescriptor(trackID: numericID, name: name))
        }

        let nextCatalog = audioCatalogGeneration.map {
            $0.replacing(sourceID: sourceID, descriptors: descriptors)
        } ?? PlaybackAudioCatalogGeneration(sourceID: sourceID, descriptors: descriptors)
        let catalogChanged = audioCatalogGeneration != nextCatalog
        audioCatalogGeneration = nextCatalog

        if catalogChanged {
            // Keep the explicit label preference so a recovered/renamed list
            // can be restored by name, but discard every ID-bound operation.
            let invalidatedPending = pendingAudioSelection != nil
                || audioRecoveryPending || selectedAudioID != nil
            let hadCatalogChangeNotice = audioSelectionError == audioCatalogChangeNotice
            pendingAudioSelection = nil
            audioRecoveryPending = false
            audioRecoveryRawID = nil
            audioRecoveryCatalogGeneration = nil
            selectedAudioID = nil
            lastPreferredAudioAttemptID = nil
            didReportMissingAudioForSource = false
            audioSelectionError = invalidatedPending || hadCatalogChangeNotice
                ? audioCatalogChangeNotice : nil
#if DEBUG
            print("RingonomiTVAudioCatalog: generation=\(nextCatalog.generation) options=\(nextCatalog.options.count) usable=\(nextCatalog.isUsable) invalidated=\(invalidatedPending)")
#endif
        }

        let optionMap: [String: Int32] = Dictionary(uniqueKeysWithValues: nextCatalog.options.compactMap { option -> (String, Int32)? in
            guard let rawID = nextCatalog.rawID(for: option.id) else { return nil }
            return (option.id, rawID)
        })
        let filteredOptions = nextCatalog.options
        if audioTrackIDsByOptionID != optionMap { audioTrackIDsByOptionID = optionMap }
        if audioOptions != filteredOptions { audioOptions = filteredOptions }
        let currentRawID = currentRawAudioTrackID

        guard !filteredOptions.isEmpty else {
            logAudioCatalog(options: [], currentRawID: currentRawID)
            return
        }

        resolvePendingAudioSelection(currentRawID: currentRawID)
        if audioRecoveryPending,
           audioRecoveryCatalogGeneration == nextCatalog.generation,
           currentRawID == audioRecoveryRawID {
            audioRecoveryPending = false
            audioRecoveryRawID = nil
            audioRecoveryCatalogGeneration = nil
        }

        let preference = PlaybackAudioCatalog.preferenceMatch(
            named: hasExplicitAudioSelection ? preferredAudioName : nil, in: audioOptions)
        if let preferredID = preference.selectedID, let preferredRawID = optionMap[preferredID] {
            if currentRawID == preferredRawID {
                selectedAudioID = preferredID
                audioSelectionError = nil
            } else if restorePreference, lastPreferredAudioAttemptID != preferredID {
                lastPreferredAudioAttemptID = preferredID
                _ = applyAudioTrack(id: preferredID, rawID: preferredRawID,
                                    catalogGeneration: nextCatalog.generation,
                                    rememberPreference: false)
            }
        } else if let notice = preference.notice, !didReportMissingAudioForSource {
            didReportMissingAudioForSource = true
            audioSelectionError = notice
        }

        if let currentRawID,
           let currentOption = audioOptions.first(where: { optionMap[$0.id] == currentRawID }) {
            if selectedAudioID != currentOption.id { selectedAudioID = currentOption.id }
        } else if selectedAudioID != nil {
            selectedAudioID = nil
        }
        logAudioCatalog(options: audioOptions, currentRawID: currentRawAudioTrackID)
    }

    private func resolvePendingAudioSelection(currentRawID: Int32?) {
        guard let pending = pendingAudioSelection else { return }
        guard let catalog = audioCatalogGeneration,
              catalog.generation == pending.catalogGeneration,
              catalog.contains(optionID: pending.id, rawID: pending.rawID) else {
            pendingAudioSelection = nil
            audioRecoveryPending = false
            audioRecoveryRawID = nil
            audioRecoveryCatalogGeneration = nil
            selectedAudioID = nil
            audioSelectionError = audioCatalogChangeNotice
            return
        }
        if currentRawID == pending.rawID {
            pendingAudioSelection = nil
            if selectedAudioID != pending.id { selectedAudioID = pending.id }
            if pending.rememberPreference,
               let option = audioOptions.first(where: { $0.id == pending.id }) {
                hasExplicitAudioSelection = true
                preferredAudioName = option.preferenceKey
            }
            audioSelectionError = nil
            if wantsPause, !isLoading {
                player.pause()
                player.audio?.isMuted = true
            }
#if DEBUG
            let actualDescription = currentRawID.map(String.init) ?? "nil"
            print("RingonomiTVAudio: selection rawID=\(pending.rawID) actual=\(actualDescription) success=true")
#endif
            return
        }

        guard Date().timeIntervalSince(pending.startedAt) >= 2 else { return }

        pendingAudioSelection = nil
        if let previousRawID = pending.previousRawID,
           catalog.generation == pending.catalogGeneration {
            player.currentAudioTrackIndex = previousRawID
        }
        let actualRawID = currentRawAudioTrackID
        audioRecoveryRawID = pending.previousRawID
        audioRecoveryPending = actualRawID != pending.previousRawID
        audioRecoveryCatalogGeneration = pending.catalogGeneration
        captureAudioBaseline()
        selectedAudioID = pending.previousID
        if wantsPause, !isLoading {
            isLoading = false
            player.pause()
            player.audio?.isMuted = true
        } else {
            beginWaiting(reason: "audio_selection_recovery")
            if player.state == .paused { player.play() }
        }
        audioSelectionError = "音声を切り替えられませんでした。"
#if DEBUG
        let actualDescription = actualRawID.map(String.init) ?? "nil"
        print("RingonomiTVAudio: selection rawID=\(pending.rawID) actual=\(actualDescription) success=false")
#endif
    }

    private func applyAudioTrack(id: String,
                                 rawID: Int32,
                                 catalogGeneration: UInt64,
                                 rememberPreference: Bool) -> Bool {
        guard currentURL != nil, failure == nil,
              let catalog = audioCatalogGeneration,
              catalog.generation == catalogGeneration,
              catalog.contains(optionID: id, rawID: rawID),
              let mappedRawID = audioTrackIDsByOptionID[id], mappedRawID == rawID,
              let option = audioOptions.first(where: { $0.id == id }) else { return false }

        let previousRawID = currentRawAudioTrackID
        if previousRawID == rawID {
            if selectedAudioID != id { selectedAudioID = id }
            if rememberPreference {
                hasExplicitAudioSelection = true
                preferredAudioName = option.preferenceKey
            }
            audioSelectionError = nil
            if wantsPause, !isLoading {
                player.pause()
                player.audio?.isMuted = true
            }
            return true
        }

        let pending = PendingAudioSelection(
            id: id,
            rawID: rawID,
            catalogGeneration: catalogGeneration,
            previousID: selectedAudioID,
            previousRawID: previousRawID,
            rememberPreference: rememberPreference,
            startedAt: Date()
        )
        pendingAudioSelection = pending
        if rememberPreference {
            // A deliberate, current-generation choice dismisses the stale
            // catalog-change notice immediately; a failed ACK reports its own
            // error through resolvePendingAudioSelection.
            audioSelectionError = nil
        }
        captureAudioBaseline()
        if wantsPause {
            player.audio?.isMuted = true
        } else if isLoading {
            player.audio?.isMuted = true
        } else {
            beginWaiting()
        }
        player.currentAudioTrackIndex = rawID

        let actualRawID = currentRawAudioTrackID
        if actualRawID == rawID {
            resolvePendingAudioSelection(currentRawID: actualRawID)
        }
#if DEBUG
        let actualDescription = actualRawID.map(String.init) ?? "nil"
        let result = actualRawID == rawID ? "true" : "pending"
        print("RingonomiTVAudio: selection rawID=\(rawID) actual=\(actualDescription) success=\(result)")
#endif
        return true
    }

    private func logAudioCatalog(options: [PlaybackAudioOption], currentRawID: Int32?) {
#if DEBUG
        let rawID = currentRawID.map(String.init) ?? "nil"
        let signature = "\(options.count):\(rawID):\(options.map(\.id).joined(separator: ","))"
        guard signature != lastAudioCatalogSignature else { return }
        lastAudioCatalogSignature = signature
        print("RingonomiTVAudio: optionCount=\(options.count) currentRawID=\(rawID)")
#endif
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
        if let number = value as? NSNumber { return number.intValue }
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
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.caseInsensitiveCompare("Disabled") == .orderedSame
    }

    private func updateStatus(expectedLoadGeneration: Int? = nil) {
        if let expectedLoadGeneration, expectedLoadGeneration != loadGeneration { return }
        guard !isStopped, !isSuspendedForBackground,
              currentURL != nil, failure == nil else { return }

        // A quality card can be dismissed after the old media has already
        // been retired.  Keep polling only the waiting-for-media deadline
        // until SwiftUI supplies the replacement URL.
        if isChangingQuality {
#if DEBUG
            logStartupPhaseIfChanged()
#endif
            if let phase = startupDeadline.timedOutPhase(generation: loadGeneration) {
                fail(phase.timeoutMessage)
            }
            return
        }

        // Transport progress is meaningful only during initial startup. A
        // relay may continue publishing its last phase while VLC is already
        // playing; feeding that stale snapshot into a later buffering
        // deadline would make the phase jump backwards and defeat the
        // generation guard.
        if let phase = startupDeadline.currentPhase,
           phase != .waitingForMedia, phase != .buffering {
            startupDeadline.observe(mediaConnection?.startupProgress,
                                     generation: loadGeneration)
        }
#if DEBUG
        logStartupPhaseIfChanged()
#endif
        if pendingLoadURL != nil {
            startPendingLoadIfReady(for: expectedLoadGeneration)
            guard pendingLoadURL != nil else { return }
            if let phase = startupDeadline.timedOutPhase(generation: loadGeneration) {
#if DEBUG
                print("RingonomiLivePending: pendingfail state=\(player.state.rawValue)")
#endif
                fail(phase.timeoutMessage)
            }
            return
        }

        if isTerminalPlaybackState {
            // A paused stream is allowed to outlive its transport.  Keep the
            // user's pause state visible and rebuild the media only when they
            // explicitly resume.  Initial loading failures remain visible.
            if wantsPause, !isLoading {
                status = "一時停止"
                return
            }
            if player.state == .error || player.state == .ended || !isLoading {
                fail("配信が中断されました。接続を確認して再試行してください。")
                return
            }
            // A not-yet-started player can report stopped while loading.
            // Keep polling so the normal loading timeout remains reachable.
        }
        refreshAudioTracks()
        let codedVideoSize = player.videoSize
        if !isLoading, player.hasVideoOut {
            scheduleVideoGeometryReadIfNeeded(codedSize: codedVideoSize)
        }
        if isLoading { player.audio?.isMuted = true }
        if player.time.intValue > 0, let stats = currentNativeStatistics {
            let pictures = stats.displayedPictures
            if pictures > lastPictures { lastFrameDate = Date() }
            lastPictures = pictures
            let decodedAudio = stats.decodedAudio
            let playedAudioBuffers = stats.playedAudioBuffers
            let hasAudioCounters = decodedAudio > 0 || playedAudioBuffers > 0
            if !hasAudioCounters {
                // Keep the old baseline. A zero pair can be the native
                // default while opening/tearing down, not an audio ACK.
                audioBaselinePending = true
            } else if audioBaselinePending
                        || decodedAudio < audioBaselineDecoded
                        || playedAudioBuffers < audioBaselinePlayed {
                // The first valid sample after an unavailable read, or after
                // a decoder counter rollback, establishes the new baseline.
                // It must not itself satisfy the fresh-buffer requirement.
                audioBaselineDecoded = decodedAudio
                audioBaselinePlayed = playedAudioBuffers
                audioBaselinePending = false
                audioNeedsFreshBuffers = true
            }
            let audioProgressed = !audioBaselinePending && (audioNeedsFreshBuffers
                ? decodedAudio > audioBaselineDecoded && playedAudioBuffers > audioBaselinePlayed
                : decodedAudio > 0 && playedAudioBuffers > 0)
            let ready = gate.update(hasVideo: true, pictures: pictures,
                                    audioReady: player.numberOfAudioTracks > 0 && pendingAudioSelection == nil
                                        && !audioRecoveryPending && audioProgressed)
            if isLoading, ready, Date().timeIntervalSince(lastFrameDate) < 1 {
                isLoading = false
                startupDeadline.finish(generation: loadGeneration)
                audioNeedsFreshBuffers = false
                if wantsPause { player.pause() }
                player.audio?.isMuted = wantsPause
#if DEBUG
                print("RingonomiTVLiveReady: pictures=\(pictures) audio=\(stats.decodedAudio) muted=\(player.audio?.isMuted == true)")
#endif
            }
#if DEBUG
            if Date().timeIntervalSince(lastLog) >= 5 {
                lastLog = Date()
                let uptime = ProcessInfo.processInfo.systemUptime
                let elapsed = lastLogUptime.map { uptime - $0 } ?? 0
                let rate = elapsed > 0 && pictures >= lastLogPictures
                    ? String(format: "%.1f", Double(pictures - lastLogPictures) / elapsed) : "n/a"
                print("RingonomiTVLive: pictures=\(pictures) loading=\(isLoading) muted=\(player.audio?.isMuted == true) uptime=\(uptime) timeMS=\(player.time.intValue) fps=\(rate) state=\(player.state.rawValue) decodedAudio=\(decodedAudio) playedAudio=\(playedAudioBuffers) baselineDecoded=\(audioBaselineDecoded) baselinePlayed=\(audioBaselinePlayed) baselinePending=\(audioBaselinePending) freshAudio=\(audioNeedsFreshBuffers)")
                lastLogUptime = uptime
                lastLogPictures = pictures
            }
#endif
        } else {
#if DEBUG
            logWaitingDiagnostic(reason: player.time.intValue > 0
                ? "statistics_unavailable" : "timeline_unavailable")
#endif
            // Keep timeout monitoring alive, but do not turn an unavailable
            // native statistics read into a new zero baseline.
            audioBaselinePending = true
            gate.reset()
        }
        // Losing the video output entirely must close the gate as well as a
        // stalled picture counter. Otherwise audio can continue over black video.
        if !isLoading, !wantsPause, Date().timeIntervalSince(lastFrameDate) > 1.5 {
            beginWaiting(reason: "video_progress_stalled")
        }
        // Accept a fresh, stable audio/video sample before evaluating its
        // deadline. A frame arriving at the boundary must not be discarded
        // merely because this monitor runs every 250 ms.
        if isLoading, let phase = startupDeadline.timedOutPhase(generation: loadGeneration) {
            fail(phase.timeoutMessage)
            return
        }
        let size = player.videoSize
        if usesLiveCaptionRelay {
            captions.tick(seconds: Double(player.time.intValue) / 1_000, frameSize: size,
                          isReady: !isLoading && failure == nil)
        }
        if failure != nil { status = "再生できません" }
        else if isLoading { status = "読み込み中…" }
        else {
            let playbackStatus = wantsPause ? "一時停止" : "再生中"
            if let width = Int(exactly: Double(size.width)),
               let height = Int(exactly: Double(size.height)), width > 0, height > 0 {
                status = "\(playbackStatus) · \(width)×\(height)"
            } else {
                status = playbackStatus
            }
        }
    }

#if DEBUG
    private var lastStartupDiagnostic: String?

    private func logStartupPhaseIfChanged() {
        let phase = startupDeadline.currentPhase?.rawValue ?? "complete"
        let attempt = mediaConnection?.startupProgress?.attempt ?? 0
        let signature = "\(loadGeneration):\(phase):\(attempt)"
        guard signature != lastStartupDiagnostic else { return }
        lastStartupDiagnostic = signature
        print("RingonomiLiveStartup: phase=\(phase) attempt=\(attempt)")
    }

    // No URLs, program names, or track names are logged. Waiting diagnostics
    // also run when the normal frame log cannot obtain a usable sample.
    private func logWaitingDiagnostic(reason: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(waitingDiagnosticDate) >= 5 else { return }
        waitingDiagnosticDate = now
        let size = player.videoSize
        var counters = "unavailable"
        if canReadNativeStatistics, let media = player.media {
            let stats = media.statistics
            counters = "pictures=\(stats.displayedPictures) decodedAudio=\(stats.decodedAudio) playedAudio=\(stats.playedAudioBuffers)"
        }
        let frameAge = lastFrameDate == .distantPast
            ? "none" : String(format: "%.2f", now.timeIntervalSince(lastFrameDate))
        print("RingonomiLiveWaiting: reason=\(reason) state=\(player.state.rawValue)"
            + " timeMS=\(player.time.intValue) videoOut=\(player.hasVideoOut)"
            + " size=\(size.width)x\(size.height) \(counters)"
            + " lastPictures=\(lastPictures) frameAge=\(frameAge)"
            + " tracks=\(player.numberOfAudioTracks) audioID=\(player.currentAudioTrackIndex)"
            + " pendingAudio=\(pendingAudioSelection != nil) recoveringAudio=\(audioRecoveryPending)"
            + " loading=\(isLoading) paused=\(wantsPause)")
    }
#endif

    private func requestPlayerStop() {
        guard !stopRequested, player.state != .stopped else { return }
        stopRequested = true
        player.stop()
    }

    /// Keep the controller alive until its native player has stopped. The
    /// generation check prevents a cancelled stop wait from clearing a task
    /// belonging to a later load on the same controller.
    private func holdPlayerUntilStopped(for expectedGeneration: Int) {
        stopTask?.cancel()
        guard player.state != .stopped else { return }
        stopTask = Task { @MainActor [self] in
            for _ in 0..<40 {
                guard !Task.isCancelled,
                      self.isStopped,
                      self.stopWaitGeneration == expectedGeneration else { return }
                if self.player.state == .stopped {
                    if self.stopWaitGeneration == expectedGeneration {
                        self.stopTask = nil
                    }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard self.stopWaitGeneration == expectedGeneration else { return }
            self.stopTask = nil
        }
    }

    private func fail(_ message: String) {
        guard !isStopped, failure == nil else { return }
        startupDeadline.invalidate()
        invalidateMediaConnection()
        resolvedMediaURL = nil
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        loadGeneration &+= 1
        monitor?.cancel()
        monitor = nil
        player.audio?.isMuted = true
        player.pause()
        failure = message
        isLoading = false
        status = "再生できません"
#if DEBUG
        print("RingonomiTVLiveError: \(message)")
#endif
    }
}
struct VLCVideo: UIViewRepresentable {
    let url: URL
    let controller: PlaybackController
    func makeCoordinator() -> PlaybackController { controller }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        controller.attachSurface(view)
        controller.load(url)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { controller.load(url) }
    static func dismantleUIView(_ view: UIView, coordinator: PlaybackController) {
        coordinator.stop()
    }
}
#endif
