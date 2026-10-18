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
    private var wantsPause = false
    private var gate = PlaybackReadinessGate()
    private var monitor: Task<Void, Never>?
    private var waitingSince = Date()
    private var lastFrameDate = Date.distantPast
    private var lastPictures = 0
    private var lastLog = Date.distantPast
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
        guard !isStopped else { return }
        isLoading = true
        waitingSince = Date()
        player.audio?.isMuted = true
        gate.reset()
    }
    func load(_ url: URL) {
        guard currentURL != url else { return }
        isStopped = false
        currentURL = url
        monitor?.cancel()
        resetAudioCatalog()
        player.stop()
        failure = nil
        gate.reset()
        lastFrameDate = .distantPast
        lastPictures = 0
        waitingSince = Date()
        isLoading = true
        player.media = VLCMedia(url: url)
        player.audio?.isMuted = true
        player.play()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self else { return }
                self.updateStatus()
            }
        }
    }
    func togglePause() {
        guard !isStopped, failure == nil else { return }
        wantsPause.toggle()
        if !isLoading {
            if wantsPause { player.pause(); player.audio?.isMuted = true }
            else { beginWaiting(); player.play() }
        }
        updateStatus()
    }
    func retry() {
        guard !isStopped, let url = currentURL else { return }
        currentURL = nil
        load(url)
    }
    func stop() {
        monitor?.cancel()
        monitor = nil
        isStopped = true
        currentURL = nil
        clearAudioCatalog(notifyUI: false)
        player.audio?.isMuted = true
        player.stop()
        player.drawable = nil
    }
    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateStatus() }
    }
    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateStatus() }
    }
    private func beginWaiting() {
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

    private var currentAudioStatistics: (decoded: Int, played: Int) {
        guard let media = player.media else { return (0, 0) }
        let stats = media.statistics
        return (Int(stats.decodedAudio), Int(stats.playedAudioBuffers))
    }

    private func captureAudioBaseline() {
        let stats = currentAudioStatistics
        audioBaselineDecoded = stats.decoded
        audioBaselinePlayed = stats.played
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
        let stats = currentAudioStatistics
        audioBaselineDecoded = stats.decoded
        audioBaselinePlayed = stats.played
        audioNeedsFreshBuffers = true
        gate.reset()
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

    private func updateStatus() {
        guard !isStopped, currentURL != nil, failure == nil else { return }
        if player.state == .error || player.state == .ended {
            failure = "配信が中断されました。接続を確認して再試行してください。"
            player.audio?.isMuted = true
            player.pause()
            isLoading = false
            status = "再生できません"
            return
        }
        refreshAudioTracks()
        if isLoading { player.audio?.isMuted = true }
        let valid = player.hasVideoOut && player.videoSize.width > 0 && player.time.intValue > 0
        if valid, let media = player.media {
            let stats = media.statistics
            let pictures = Int(stats.displayedPictures)
            if pictures > lastPictures { lastFrameDate = Date() }
            lastPictures = pictures
            if !isLoading, !wantsPause, Date().timeIntervalSince(lastFrameDate) > 1.5 { beginWaiting() }
            let decodedAudio = Int(stats.decodedAudio)
            let playedAudioBuffers = Int(stats.playedAudioBuffers)
            // VLC may reset decoder statistics when replacing a track.
            // A counter from the old decoder must not become an unreachable
            // threshold for the new one.
            if decodedAudio < audioBaselineDecoded { audioBaselineDecoded = 0 }
            if playedAudioBuffers < audioBaselinePlayed { audioBaselinePlayed = 0 }
            let audioProgressed = audioNeedsFreshBuffers
                ? decodedAudio > audioBaselineDecoded && playedAudioBuffers > audioBaselinePlayed
                : decodedAudio > 0 && playedAudioBuffers > 0
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
                print("RingonomiTVLive: pictures=\(pictures) loading=\(isLoading) muted=\(player.audio?.isMuted == true)")
            }
#endif
        }
        if isLoading, Date().timeIntervalSince(waitingSince) > 30 {
            failure = "読み込みがタイムアウトしました。接続を確認して再試行してください。"
            player.pause()
            player.audio?.isMuted = true
            isLoading = false
        }
        let size = player.videoSize
        if failure != nil { status = "再生できません" }
        else if isLoading { status = "読み込み中…" }
        else { status = "\(wantsPause ? "一時停止" : "再生中") · \(Int(size.width))×\(Int(size.height))" }
    }
}
struct VLCVideo: UIViewRepresentable {
    let url: URL
    let controller: PlaybackController
    func makeCoordinator() -> PlaybackController { controller }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        controller.player.drawable = view
        controller.load(url)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { controller.load(url) }
    static func dismantleUIView(_ view: UIView, coordinator: PlaybackController) {
        coordinator.stop()
    }
}
#endif
