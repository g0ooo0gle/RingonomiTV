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
    private var currentURL: URL?
    // A cancelled monitor/delegate callback can still be queued on the main
    // actor while SwiftUI is dismantling the representable.  Teardown must
    // not publish into that invalidating graph.
    private var isStopped = false
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
        let size = player.videoSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGRect(x: (bounds.width - size.width * scale) / 2,
                      y: (bounds.height - size.height * scale) / 2,
                      width: size.width * scale, height: size.height * scale)
    }

    func attachSurface(_ view: UIView) {
        videoSurface = view
        player.drawable = view
    }
    private var gate = PlaybackReadinessGate()
    private var monitor: Task<Void, Never>?
    // TVVLCKit stops the native player asynchronously. Keep a fresh URL
    // pending until the stop state is observable, otherwise assigning the
    // same URL can be treated as a no-op by libVLC.
    private var pendingLoadURL: URL?
    private var pendingLoadGeneration = 0
    private var loadGeneration = 0
    private var waitingSince = Date()
    private var lastFrameDate = Date.distantPast
    private var lastPictures = 0
    private var lastLog = Date.distantPast
#if DEBUG
    private var lastLogUptime: Double?
    private var lastLogPictures = 0
    private var pendingStateLogDate = Date.distantPast
#endif
    private var audioSourceID: UUID?
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
    private struct PendingAudioSelection {
        let id: String
        let rawID: Int32
        let previousID: String?
        let previousRawID: Int32?
        let rememberPreference: Bool
        let startedAt: Date
    }
    private var pendingAudioSelection: PendingAudioSelection?
    override init() { super.init(); player.delegate = self }

    func selectAudioTrack(id: String) {
        guard !isStopped, currentURL != nil, failure == nil, !isLoading else { return }
        guard
              pendingAudioSelection == nil,
              !audioRecoveryPending,
              audioSourceID != nil,
              let rawID = audioTrackIDsByOptionID[id],
              audioOptions.contains(where: { $0.id == id }) else {
            audioSelectionError = "選択した音声を利用できません。"
            return
        }
        _ = applyAudioTrack(id: id, rawID: rawID, rememberPreference: true)
    }

    func prepareQualityChange() {
        guard !isStopped, !isSuspendedForBackground else { return }
        // Ignore callbacks from the old media until SwiftUI supplies the new URL.
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        loadGeneration &+= 1
        isChangingQuality = true
        monitor?.cancel()
        monitor = nil
        isLoading = true
        waitingSince = Date()
        player.audio?.isMuted = true
        gate.reset()
    }
    func load(_ url: URL) {
        guard !isSuspendedForBackground, currentURL != url else { return }
        isStopped = false
        isSuspendedForBackground = false
        player.delegate = self
        isChangingQuality = false
        currentURL = url
        loadGeneration &+= 1
        let expectedLoadGeneration = loadGeneration
        pendingLoadURL = url
        pendingLoadGeneration = expectedLoadGeneration
        monitor?.cancel()
        resetAudioCatalog()
        // Calling stop() for an already-stopped player still dispatches
        // libvlc_media_player_stop_async. Do not enqueue that extra stop just
        // before the pending loader observes .stopped and calls play().
        if player.state != .stopped { player.stop() }
        failure = nil
        gate.reset()
        lastFrameDate = .distantPast
        lastPictures = 0
#if DEBUG
        lastLog = .distantPast
        lastLogUptime = nil
        lastLogPictures = 0
        pendingStateLogDate = .distantPast
#endif
        waitingSince = Date()
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
    func retry() {
        guard !isStopped, !isSuspendedForBackground, let url = currentURL else { return }
        currentURL = nil
        load(url)
    }

    private func startPendingLoadIfReady(for expectedGeneration: Int? = nil) {
        guard !isStopped, !isSuspendedForBackground, !isChangingQuality, failure == nil,
              let url = pendingLoadURL,
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
        player.media = VLCMedia(url: url)
        if let videoSurface { player.drawable = videoSurface }
        player.audio?.isMuted = true
#if DEBUG
        print("RingonomiLivePending: start state=\(player.state.rawValue)")
#endif
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
        isSuspendedForBackground = true
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        loadGeneration &+= 1
#if DEBUG
        print("RingonomiLiveLifecycle: suspended paused=\(wantsPause)")
#endif
        monitor?.cancel()
        monitor = nil
        isLoading = true
        waitingSince = Date()
        gate.reset()
        lastFrameDate = .distantPast
        lastPictures = 0
        player.audio?.isMuted = true
        player.delegate = nil
        if player.state != .stopped { player.stop() }
        player.drawable = nil
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
        monitor?.cancel()
        monitor = nil
        isStopped = true
        isSuspendedForBackground = false
        pendingLoadURL = nil
        pendingLoadGeneration = 0
        loadGeneration &+= 1
        currentURL = nil
        player.delegate = nil
        clearAudioCatalog(notifyUI: false)
        player.audio?.isMuted = true
        if player.state != .stopped { player.stop() }
        player.drawable = nil
        videoSurface = nil
    }
    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateStatus() }
    }
    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateStatus() }
    }
    private func beginWaiting() {
        guard !isSuspendedForBackground else { return }
        if !isLoading { waitingSince = Date(); gate.reset() }
        isLoading = true
        player.audio?.isMuted = true
        status = "読み込み中…"
    }

    private func resetAudioCatalog() {
        audioSourceID = UUID()
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
        pendingAudioSelection = nil
    }

    private func clearAudioCatalog(notifyUI: Bool = true) {
        audioSourceID = nil
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
        pendingAudioSelection = nil
    }

    private func clearDiscoveredAudioOptions() {
        audioTrackIDsByOptionID.removeAll(keepingCapacity: false)
        if !audioOptions.isEmpty { audioOptions = [] }
        if selectedAudioID != nil { selectedAudioID = nil }
        lastPreferredAudioAttemptID = nil
    }

    private struct NativePlaybackStatistics {
        let displayedPictures: Int
        let decodedAudio: Int
        let playedAudioBuffers: Int
    }

    private var currentNativeStatistics: NativePlaybackStatistics? {
        switch player.state {
        case .buffering, .playing, .paused:
            break
        default:
            return nil
        }
        guard let media = player.media, player.hasVideoOut else { return nil }
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

    private func refreshAudioTracks() {
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
        var rawIDsByOptionID: [String: Int32] = [:]

        for (offset, rawIndex) in rawIndexes.enumerated() {
            guard let numericID = integerValue(rawIndex), numericID >= 0,
                  let trackID = Int32(exactly: numericID) else { continue }
            let name = offset < rawNames.count ? stringValue(rawNames[offset]) : nil
            guard !isDisabledAudioName(name) else { continue }
            descriptors.append(PlaybackAudioDescriptor(trackID: numericID, name: name))
            rawIDsByOptionID["\(sourceID.uuidString):\(numericID)"] = trackID
        }

        guard !descriptors.isEmpty else {
            clearDiscoveredAudioOptions()
            logAudioCatalog(options: [], currentRawID: currentRawAudioTrackID)
            return
        }

        let options = PlaybackAudioCatalog.options(sourceID: sourceID, descriptors: descriptors)
        guard !options.isEmpty else {
            clearDiscoveredAudioOptions()
            logAudioCatalog(options: [], currentRawID: currentRawAudioTrackID)
            return
        }

        var optionMap: [String: Int32] = [:]
        for option in options {
            if let rawID = rawIDsByOptionID[option.id] {
                optionMap[option.id] = rawID
            }
        }
        guard !optionMap.isEmpty else {
            clearDiscoveredAudioOptions()
            logAudioCatalog(options: [], currentRawID: currentRawAudioTrackID)
            return
        }

        let filteredOptions = options.filter { optionMap[$0.id] != nil }
        if audioTrackIDsByOptionID != optionMap { audioTrackIDsByOptionID = optionMap }
        if audioOptions != filteredOptions { audioOptions = filteredOptions }
        let currentRawID = currentRawAudioTrackID

        resolvePendingAudioSelection(currentRawID: currentRawID)
        if audioRecoveryPending, currentRawID == audioRecoveryRawID {
            audioRecoveryPending = false
            audioRecoveryRawID = nil
        }

        let preferredID = hasExplicitAudioSelection
            ? PlaybackAudioCatalog.preferredID(named: preferredAudioName, in: audioOptions)
            : nil
        if let preferredID, let preferredRawID = optionMap[preferredID] {
            if currentRawID == preferredRawID {
                selectedAudioID = preferredID
            } else if lastPreferredAudioAttemptID != preferredID {
                lastPreferredAudioAttemptID = preferredID
                _ = applyAudioTrack(id: preferredID, rawID: preferredRawID, rememberPreference: false)
            }
        } else if let preferredAudioName,
                  hasExplicitAudioSelection,
                  !audioOptions.contains(where: { $0.preferenceKey == preferredAudioName }),
                  !didReportMissingAudioForSource {
            didReportMissingAudioForSource = true
            audioSelectionError = "選択していた音声はこの配信では利用できません。"
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
        if let previousRawID = pending.previousRawID {
            player.currentAudioTrackIndex = previousRawID
        }
        let actualRawID = currentRawAudioTrackID
        audioRecoveryRawID = pending.previousRawID
        audioRecoveryPending = actualRawID != pending.previousRawID
        captureAudioBaseline()
        selectedAudioID = pending.previousID
        if wantsPause, !isLoading {
            isLoading = false
            player.pause()
            player.audio?.isMuted = true
        } else {
            isLoading = true
            waitingSince = Date()
            player.audio?.isMuted = true
            if player.state == .paused { player.play() }
        }
        audioSelectionError = "音声を切り替えられませんでした。"
#if DEBUG
        let actualDescription = actualRawID.map(String.init) ?? "nil"
        print("RingonomiTVAudio: selection rawID=\(pending.rawID) actual=\(actualDescription) success=false")
#endif
    }

    private func applyAudioTrack(id: String, rawID: Int32, rememberPreference: Bool) -> Bool {
        guard currentURL != nil, failure == nil,
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
            previousID: selectedAudioID,
            previousRawID: previousRawID,
            rememberPreference: rememberPreference,
            startedAt: Date()
        )
        pendingAudioSelection = pending
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
        guard !isStopped, !isSuspendedForBackground, !isChangingQuality,
              currentURL != nil, failure == nil else { return }

        if pendingLoadURL != nil {
            startPendingLoadIfReady(for: expectedLoadGeneration)
            guard pendingLoadURL != nil else { return }
            if isLoading, Date().timeIntervalSince(waitingSince) > 30 {
#if DEBUG
                print("RingonomiLivePending: pendingfail state=\(player.state.rawValue)")
#endif
                fail("読み込みがタイムアウトしました。接続を確認して再試行してください。")
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
                print("RingonomiTVLive: pictures=\(pictures) loading=\(isLoading) muted=\(player.audio?.isMuted == true) uptime=\(uptime) fps=\(rate) state=\(player.state.rawValue)")
                lastLogUptime = uptime
                lastLogPictures = pictures
            }
#endif
        } else {
            // Keep timeout monitoring alive, but do not turn an unavailable
            // native statistics read into a new zero baseline.
            audioBaselinePending = true
            gate.reset()
        }
        // Losing the video output entirely must close the gate as well as a
        // stalled picture counter. Otherwise audio can continue over black video.
        if !isLoading, !wantsPause, Date().timeIntervalSince(lastFrameDate) > 1.5 { beginWaiting() }
        if isLoading, Date().timeIntervalSince(waitingSince) > 30 {
            fail("読み込みがタイムアウトしました。接続を確認して再試行してください。")
            return
        }
        let size = player.videoSize
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

    private func fail(_ message: String) {
        guard !isStopped, failure == nil else { return }
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
