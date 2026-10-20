import SwiftUI
import Combine
import RingonomiCore
@preconcurrency import AVFoundation

/// HLSの先読みと最初の映像を確認してから、ロード表示と音声ミュートを解除する。
@MainActor
final class RecordingPlaybackController: ObservableObject {
    let player = AVPlayer()
    let pictureInPicture = RecordingPictureInPicture()
    private var pictureInPictureObservation: AnyCancellable?
    let captions = RecordingCaptionController()
    @Published private(set) var status = "読み込み中…"
    @Published private(set) var playbackTime = "00:00"
    @Published private(set) var isLoading = true
    @Published private(set) var failure: String?
    @Published private(set) var commercialSkipNotice: String?
    @Published private(set) var canUndoCommercialSkip = false
    private var commercialTimeline: RecordingChapterTimeline?
    private var commercialMetadataUsable = false
    private var commercialMetadataComplete = false
    private var automaticCommercialSkipEnabled = false
    private var commercialSkipPolicy = CommercialSkipPolicy()
    private var lastCommercialSkip: (from: Double, to: Double)?
    private var commercialNoticeUntil = 0.0
    private var commercialUndoUntil = 0.0
    private var currentURL: URL?
    // SwiftUI may dismantle the representable while queued KVO/asset tasks
    // are still waiting on the main actor.  This gate keeps those callbacks
    // from touching published state after teardown.
    private var isStopped = false
    // Background transitions keep the SwiftUI controller alive, but the
    // AVPlayer item, observers, and preparation tasks are released until the
    // app becomes active again.  Repeated lifecycle notifications are safe.
    private var isSuspendedForBackground = false
    private var isChangingQuality = false
    private var wantsPause = false
    private var sceneSearchShouldResume: Bool?
    private var pendingSceneSeek: Double?
    private var targetSeconds: Double = 0
    private var preparing = false
    private var prerolled = false
    private var preparationInFlight = false
    private var playbackStartRequested = false
    private var advancedSincePreroll = false
    private var generation = 0
    private weak var videoLayer: AVPlayerLayer?
    private var observations: [NSKeyValueObservation] = []
    private var layerObservation: NSKeyValueObservation?
    private var clockToken: Any?
    private var endToken: NSObjectProtocol?
    private var timer: Task<Void, Never>?
    private var waitingSince: Date?
    private var lastLog = Date.distantPast
    private var durationHint: Double?
    private var lastTrustedPosition: Double?
    private var lastTrustedDuration: Double?
    private var lastCheckpoint = Date.distantPast
    private var reachedEnd = false
    private var onCheckpoint: ((Double, Double?, Bool) -> Void)?
    @Published private(set) var audioOptions: [PlaybackAudioOption] = []
    @Published private(set) var selectedAudioID: String?
    @Published private(set) var audioSelectionError: String?
    private var audioTask: Task<Void, Never>?
    private var audioGeneration = 0
    private var audioSourceID: UUID?
    private weak var audioDiscoveryItem: AVPlayerItem?
    private var audioGroup: AVMediaSelectionGroup?
    private var audioOptionMap: [String: AVMediaSelectionOption] = [:]
    private var preferredAudioKey: String?
    private var audioDiscoveryCompleted = false
    private var audioRestoreAttempted = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = true
        pictureInPictureObservation = pictureInPicture.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Selects one of the options discovered on the current asset.  The
    /// identifier is source-scoped, so an option from a previous quality or
    /// retry cannot accidentally select a reused track index.
    func selectAudioTrack(id: String) {
        selectAudioTrack(id: id, forcedPause: nil)
    }

    private func selectAudioTrack(id: String, forcedPause: Bool?) {
        // Menus can outlive an item replacement or a quality change.  Ignore
        // those callbacks while the normal ready gate is closed instead of
        // reporting a misleading selection error to the user.
        guard !isStopped, !isLoading, !preparing, failure == nil,
              let item = player.currentItem,
              item.status == .readyToPlay,
              player.status == .readyToPlay else { return }
        guard let group = audioGroup,
              let option = audioOptionMap[id],
              audioOptions.contains(where: { $0.id == id }),
              group.options.contains(where: { $0.isEqual(option) }) else {
            audioSelectionError = "選択した音声を利用できません。"
            return
        }

        let previousID = selectedAudioID
        let previousOption = item.currentMediaSelection.selectedMediaOption(in: group)
        let shouldRemainPaused = forcedPause ?? (wantsPause || player.timeControlStatus == .paused)
        let capturedSeconds = safeTime()
        let wasAtEnd = reachedEnd

        let isAlreadySelected = isSameAudioOption(previousOption, option)
        if isAlreadySelected {
            selectedAudioID = id
            preferredAudioKey = audioOptions.first(where: { $0.id == id })?.preferenceKey
            audioSelectionError = nil
            return
        }

        // Selecting a media option can momentarily change the player's
        // timing state. Freeze both playback and audio before doing so, then
        // run the same seek/preroll gate used by normal playback.
        player.pause()
        player.isMuted = true

        item.select(option, in: group)
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        guard isSameAudioOption(selected, option) else {
            // Keep the previous selection when the player rejects the change.
            if let previousOption {
                item.select(previousOption, in: group)
            }
            selectedAudioID = previousID
            audioSelectionError = "音声を切り替えられませんでした。"
            wantsPause = shouldRemainPaused
            prepareExistingPosition(capturedSeconds, preservingEndState: wasAtEnd)
            return
        }

        selectedAudioID = id
        preferredAudioKey = audioOptions.first(where: { $0.id == id })?.preferenceKey
        audioSelectionError = nil
        wantsPause = shouldRemainPaused
        prepareExistingPosition(capturedSeconds, preservingEndState: wasAtEnd)
#if DEBUG
        print("RingonomiTVAudio: selectedID=\(id)")
#endif
    }

    private func isSameAudioOption(
        _ lhs: AVMediaSelectionOption?,
        _ rhs: AVMediaSelectionOption?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.isEqual(rhs)
        default: return false
        }
    }

    private func resetAudioSelection(clearPreferred: Bool, notifyUI: Bool = true) {
        audioGeneration &+= 1
        audioTask?.cancel()
        audioTask = nil
        audioSourceID = nil
        audioDiscoveryItem = nil
        audioGroup = nil
        audioOptionMap.removeAll()
        if notifyUI {
            audioOptions = []
            selectedAudioID = nil
            audioSelectionError = nil
        }
        audioDiscoveryCompleted = false
        audioRestoreAttempted = false
        if clearPreferred { preferredAudioKey = nil }
    }

    private func discoverAudio(for item: AVPlayerItem) {
        guard !isStopped, player.currentItem === item else { return }
        guard audioDiscoveryItem !== item else { return }
        audioDiscoveryItem = item
        audioTask?.cancel()
        audioGeneration &+= 1
        let expectedAudioGeneration = audioGeneration
        let sourceID = UUID()
        audioSourceID = sourceID
        audioGroup = nil
        audioOptionMap.removeAll()
        audioOptions = []
        selectedAudioID = nil
        audioSelectionError = nil
        audioDiscoveryCompleted = false
        audioRestoreAttempted = false
        let asset = item.asset

        audioTask = Task { @MainActor [weak self, weak item] in
            do {
                let group = try await asset.loadMediaSelectionGroup(for: .audible)
                try Task.checkCancellation()
                guard let self,
                      let item,
                      !self.isStopped,
                      self.audioGeneration == expectedAudioGeneration,
                      self.audioSourceID == sourceID,
                      self.player.currentItem === item else { return }
                self.applyAudioGroup(
                    group,
                    item: item,
                    sourceID: sourceID,
                    expectedGeneration: expectedAudioGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      let item,
                      !self.isStopped,
                      self.audioGeneration == expectedAudioGeneration,
                      self.audioSourceID == sourceID,
                      self.player.currentItem === item else { return }
                self.audioOptions = []
                self.selectedAudioID = nil
                self.audioSelectionError = "音声トラックを読み込めませんでした。"
#if DEBUG
                print("RingonomiTVAudio: discovery failed")
#endif
            }
        }
    }

    private func applyAudioGroup(
        _ group: AVMediaSelectionGroup?,
        item: AVPlayerItem,
        sourceID: UUID,
        expectedGeneration: Int
    ) {
        guard !isStopped,
              audioGeneration == expectedGeneration,
              audioSourceID == sourceID,
              player.currentItem === item else { return }
        audioDiscoveryCompleted = true
        guard let group, !group.options.isEmpty else {
            // Some streams have no selectable alternate audio.  That is a
            // valid engine default, not a playback error.
            audioGroup = group
            audioOptions = []
            audioOptionMap.removeAll()
            selectedAudioID = nil
            audioSelectionError = nil
            restorePreferredAudioIfReady()
#if DEBUG
            print("RingonomiTVAudio: optionCount=0 selectedID=nil")
#endif
            return
        }

        let descriptors = group.options.enumerated().map { index, option in
            PlaybackAudioDescriptor(trackID: index, name: option.displayName)
        }
        let options = PlaybackAudioCatalog.options(sourceID: sourceID, descriptors: descriptors)
        guard !options.isEmpty else {
            // An oversized/rejected catalog is unknown, not proof that a
            // previously selected track is missing.
            audioDiscoveryCompleted = false
            audioGroup = group
            audioOptions = []
            audioOptionMap.removeAll()
            selectedAudioID = nil
            audioSelectionError = nil
#if DEBUG
            print("RingonomiTVAudio: optionCount=0 selectedID=nil")
#endif
            return
        }

        audioGroup = group
        audioOptions = options
        guard options.count == group.options.count else {
            audioOptions = []
            audioOptionMap.removeAll()
            audioDiscoveryCompleted = false
            audioSelectionError = nil
            return
        }
        audioOptionMap = Dictionary(uniqueKeysWithValues: zip(options, group.options).map { pair in
            (pair.0.id, pair.1)
        })
        audioSelectionError = nil

        if let current = item.currentMediaSelection.selectedMediaOption(in: group),
           let currentIndex = group.options.firstIndex(where: { $0.isEqual(current) }),
           options.indices.contains(currentIndex) {
            selectedAudioID = options[currentIndex].id
        }
        restorePreferredAudioIfReady()
#if DEBUG
        print("RingonomiTVAudio: optionCount=\(options.count) selectedID=\(selectedAudioID ?? "nil")")
#endif
    }

    /// Restore only after discovery and the initial video gate are complete.
    /// Missing/ambiguous choices leave the engine's audio in place and explain
    /// why it could not be restored without guessing a track.
    private func restorePreferredAudioIfReady() {
        guard !isStopped,
              !audioRestoreAttempted,
              !isLoading,
              !preparing,
              failure == nil,
              audioDiscoveryCompleted else { return }
        audioRestoreAttempted = true
        let preference = PlaybackAudioCatalog.preferenceMatch(named: preferredAudioKey, in: audioOptions)
        guard let preferredID = preference.selectedID else {
            if let notice = preference.notice { audioSelectionError = notice }
            return
        }
        // The player is paused as part of the initial seek/preroll even when
        // the user did not request pause. Preserve only the explicit intent.
        selectAudioTrack(id: preferredID, forcedPause: wantsPause)
    }
    /// 動画を読み込み始める前に一度だけ設定する。
    func configurePosition(seconds: Double, durationHint: Double?, onCheckpoint: @escaping (Double, Double?, Bool) -> Void) {
        guard currentURL == nil else { return }
        self.durationHint = durationHint
        targetSeconds = RecordingResumePolicy.clamp(seconds: seconds, duration: durationHint) ?? 0
        self.onCheckpoint = onCheckpoint
        updateTime()
    }

    func flushPosition() { checkpoint(force: true) }

    private var videoOutputIsReady: Bool {
        // tvOS stops drawing into the inline layer while PiP owns its video.
        // Seek/preroll/item readiness still gate playback and checkpoints;
        // only the active native PiP presentation replaces the layer check.
        videoLayer?.isReadyForDisplay == true || pictureInPicture.hasActiveVideoPresentation
    }

    private func checkpoint(force: Bool = false, notify: Bool = true) {
        guard !isStopped else { return }
        // seek/preroll中の一時的な0秒や、最初のフレームを待つ時計は保存しない。
        if !preparing, !isLoading, failure == nil, prerolled,
           player.currentItem?.status == .readyToPlay, videoOutputIsReady {
            lastTrustedPosition = safeTime()
            let duration = player.currentItem?.duration.seconds ?? .nan
            lastTrustedDuration = duration.isFinite && duration > 0 ? duration : durationHint
        }
        guard let position = lastTrustedPosition,
              force || Date().timeIntervalSince(lastCheckpoint) >= 2 else { return }
        lastCheckpoint = Date()
        if notify {
            onCheckpoint?(position, lastTrustedDuration, reachedEnd)
        }
    }
    func attach(_ layer: AVPlayerLayer) {
        layerObservation?.invalidate()
        videoLayer = layer
        layer.player = player
        pictureInPicture.attach(to: layer)
        layer.videoGravity = .resizeAspect
        layerObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.revealWhenReady() }
        }
    }
    func load(_ url: URL, preservingEndState: Bool = false) {
        guard !isSuspendedForBackground, currentURL != url else { return }
        let keepEnded = reachedEnd && (preservingEndState || isChangingQuality)
        isStopped = false
        isSuspendedForBackground = false
        isChangingQuality = false
        currentURL = url
        commercialMetadataUsable = commercialMetadataComplete && commercialTimeline != nil
        resetAudioSelection(clearPreferred: false)
        reachedEnd = keepEnded
        generation += 1
        cancelPreparation()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let endToken {
            NotificationCenter.default.removeObserver(endToken)
            self.endToken = nil
        }
        if keepEnded {
            // Quality can be chosen at EOF without restarting the recording.
            // Remember the new URL and defer decoding until replay or seek.
            timer?.cancel()
            timer = nil
            if let clockToken {
                player.removeTimeObserver(clockToken)
                self.clockToken = nil
            }
            captions.stop()
            player.replaceCurrentItem(with: nil)
            preparing = false
            prerolled = false
            playbackStartRequested = false
            isLoading = false
            waitingSince = nil
            status = "再生終了（再生ボタンで最初から）"
            updateTime()
#if DEBUG
            print("RingonomiRecordingEnded: deferred target=\(targetSeconds) loading=\(isLoading) paused=\(wantsPause) hasItem=\(player.currentItem != nil)")
#endif
            return
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        captions.attach(to: item, targetSeconds: targetSeconds)
        preparing = true
        prerolled = false
        playbackStartRequested = false
        beginWaiting()
        player.replaceCurrentItem(with: item)
        let expected = generation
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.itemStatusChanged(expected) }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.playbackStateChanged() }
        })
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, !self.isStopped, !self.isSuspendedForBackground,
                      !self.isChangingQuality, !self.preparing,
                      self.player.currentItem === item else { return }
                self.status = "再生終了（再生ボタンで最初から）"
                self.player.pause()
                self.wantsPause = true
                self.isLoading = false
                self.waitingSince = nil
                self.reachedEnd = true
                self.pictureInPicture.returnToInline()
                self.checkpoint(force: true)
#if DEBUG
                print("RingonomiRecordingEnded: reached time=\(self.safeTime())")
#endif
            }
        }
        if clockToken == nil {
            clockToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateTime() }
            }
        }
        startTimer()
    }

    /// Saves the last trusted position and releases the decoder while the app
    /// is backgrounded.  The resume path creates a fresh AVPlayerItem instead
    /// of trying to continue the item that was interrupted by Home/system UI.
    func suspendForBackground() {
        guard !isStopped, !isSuspendedForBackground, currentURL != nil, failure == nil,
              !pictureInPicture.ownsPlayback else { return }

        checkpoint(force: true)
        if !preparing, !isLoading, prerolled {
            lastTrustedPosition = safeTime()
        }
        if let trusted = lastTrustedPosition {
            targetSeconds = RecordingResumePolicy.clamp(seconds: trusted, duration: lastTrustedDuration ?? durationSeconds) ?? max(0, trusted)
        }

        isSuspendedForBackground = true
#if DEBUG
        print("RingonomiRecordingLifecycle: suspended target=\(targetSeconds) paused=\(wantsPause) ended=\(reachedEnd)")
#endif
        generation += 1
        resetAudioSelection(clearPreferred: false, notifyUI: false)
        cancelPreparation()
        timer?.cancel()
        timer = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        layerObservation?.invalidate()
        layerObservation = nil
        if let clockToken {
            player.removeTimeObserver(clockToken)
            self.clockToken = nil
        }
        if let endToken {
            NotificationCenter.default.removeObserver(endToken)
            self.endToken = nil
        }
        // Clear the last caption before releasing its renderer. stop() does
        // not publish because it is also used during view teardown.
        captions.tick(seconds: targetSeconds, frameSize: .zero, isReady: false)
        captions.stop()
        player.replaceCurrentItem(with: nil)
        isChangingQuality = false
        preparing = false
        prerolled = false
        playbackStartRequested = false
        preparationInFlight = false
        advancedSincePreroll = false
        isLoading = true
        waitingSince = nil
        player.isMuted = true
        status = "読み込み中…"
        updateTime()
    }

    /// Rebuilds the recording item from the trusted checkpoint.  Resume is
    /// intentionally a no-op for an error or an unstarted/resume-prompt view.
    func resumeFromBackground() {
        guard isSuspendedForBackground, !isStopped, failure == nil,
              let url = currentURL else { return }
        isSuspendedForBackground = false
#if DEBUG
        print("RingonomiRecordingLifecycle: resumed target=\(targetSeconds) paused=\(wantsPause) ended=\(reachedEnd)")
#endif
        if let videoLayer { attach(videoLayer) }
        if reachedEnd {
            // There are no future frames to preroll at EOF. Keep the ended
            // controls available and create a new item only when the user
            // chooses replay or another position.
            resetAudioSelection(clearPreferred: false)
            isLoading = false
            status = "再生終了（再生ボタンで最初から）"
            updateTime()
#if DEBUG
            print("RingonomiRecordingEnded: deferred target=\(targetSeconds) loading=\(isLoading) paused=\(wantsPause) hasItem=\(player.currentItem != nil)")
#endif
            return
        }
        currentURL = nil
        load(url)
    }

    private func itemStatusChanged(_ expected: Int) {
        guard !isStopped, !isSuspendedForBackground,
              expected == generation, let item = player.currentItem else { return }
        switch item.status {
        case .failed: fail("録画を読み込めませんでした。接続先と配信状態を確認してください。")
        case .readyToPlay:
            guard preparing else { return }
            discoverAudio(for: item)
            preparePosition(expected)
        default: break
        }
    }
    private func preparePosition(_ expected: Int) {
        guard !isStopped, !isSuspendedForBackground, !isChangingQuality,
              expected == generation, preparing, !prerolled, !preparationInFlight,
              player.status == .readyToPlay,
              player.currentItem?.status == .readyToPlay else { return }
        preparationInFlight = true
        player.pause()
        // The new HLS item may have a different duration from the catalog.
        // Clamp again after it becomes ready so EOF is never a seek target.
        targetSeconds = RecordingResumePolicy.clamp(seconds: targetSeconds, duration: durationSeconds) ?? 0
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        guard target.isValid, target.isNumeric else {
            fail("再生位置を読み込めませんでした。最初から再生し直してください。")
            return
        }
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped, self.generation == expected, self.preparing else { return }
                guard finished, self.player.status == .readyToPlay else {
                    self.fail("再生位置を読み込めませんでした。再試行してください。")
                    return
                }
                // readyToPlayと停止状態を確認してから呼び、APIの例外条件を避ける。
                self.player.pause()
                self.player.preroll(atRate: 1) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isStopped, self.generation == expected, self.preparing else { return }
                        guard finished else {
                            self.fail("映像と音声の準備に失敗しました。再試行してください。")
                            return
                        }
                        self.prerolled = true
                        self.preparationInFlight = false
                        if !self.videoOutputIsReady {
                            // 一部のHLSはprerollだけでは最初の映像を出力しない。
                            // 先読み後にミュートで描画を開始し、最初のフレームまで覆いを保つ。
                            self.player.isMuted = true
                            self.playbackStartRequested = true
                            self.player.playImmediately(atRate: 1)
                        }
                        self.revealWhenReady()
                    }
                }
            }
        }
    }
    private func revealWhenReady() {
        guard !isStopped, !isSuspendedForBackground, !isChangingQuality,
              failure == nil, preparing, prerolled,
              player.currentItem?.status == .readyToPlay,
              videoOutputIsReady else { return }
        if let seconds = pendingSceneSeek {
            pendingSceneSeek = nil
            let maximum = durationSeconds.map { max(0, $0 - 0.1) } ?? seconds
            commercialSkipPolicy.resetAfterManualSeek()
            clearCommercialSkipNotice()
            prepareExistingPosition(min(maximum, max(0, seconds)))
            return
        }
        if wantsPause {
            // A user-paused item is ready as soon as preroll and the first
            // frame are available. It must not wait for an actual playing
            // transition just to report the paused state.
            playbackStartRequested = false
            player.pause()
            player.isMuted = true
            preparing = false
            advancedSincePreroll = false
            isLoading = false
            waitingSince = nil
            restorePreferredAudioIfReady()
            // A restored track goes through prepareExistingPosition, which
            // reopens the loading gate. Do not reveal the old item underneath
            // it.
            if preparing { return }
            status = reachedEnd ? "再生終了（再生ボタンで最初から）" : "一時停止"
            updateTime()
            checkpoint(force: true)
#if DEBUG
            print("RingonomiTVNativeReady: target=\(targetSeconds) actual=\(player.currentTime().seconds) rate=\(player.rate) muted=\(player.isMuted) layerReady=\(videoLayer?.isReadyForDisplay == true) pipActive=\(pictureInPicture.hasActiveVideoPresentation) paused=true timeControl=\(player.timeControlStatus.rawValue)")
#endif
            return
        }

        // Keep the readiness gate closed while the new item is still waiting
        // to play. AVPlayer can expose a first frame before the transport
        // has actually entered .playing; unmuting here would briefly produce
        // audio over a stale or black frame. Request play once while muted and
        // let the KVO callback/timer call this method again.
        player.isMuted = true
        if player.timeControlStatus != .playing {
            if !playbackStartRequested {
                playbackStartRequested = true
                player.play()
            }
            guard player.timeControlStatus == .playing else { return }
        }

        playbackStartRequested = false
        preparing = false
        advancedSincePreroll = false
        isLoading = false
        waitingSince = nil
        restorePreferredAudioIfReady()
        // A restored track goes through prepareExistingPosition, which
        // reopens the loading gate. Do not reveal the old item underneath it.
        if preparing { return }
        // The item is already playing here; no extra play call is needed.
        player.isMuted = false
        status = reachedEnd ? "再生終了（再生ボタンで最初から）" : "再生中"
        updateTime()
        checkpoint(force: true)
#if DEBUG
        print("RingonomiTVNativeReady: target=\(targetSeconds) actual=\(player.currentTime().seconds) rate=\(player.rate) muted=\(player.isMuted) layerReady=\(videoLayer?.isReadyForDisplay == true) pipActive=\(pictureInPicture.hasActiveVideoPresentation) timeControl=\(player.timeControlStatus.rawValue)")
#endif
    }
    private func playbackStateChanged() {
        guard !isStopped, !isSuspendedForBackground, failure == nil, !preparing else { return }
        if pictureInPicture.usesSystemTransport, !isLoading, prerolled {
            // PiP's system controls operate AVPlayer directly. Adopt their
            // intent before enforcing the inline pause state.
            if player.timeControlStatus == .playing || player.rate > 0 {
                wantsPause = false
            } else if player.timeControlStatus == .paused, !reachedEnd {
                wantsPause = true
            }
        }
        if wantsPause {
            player.pause()
            player.isMuted = true
            status = reachedEnd ? "再生終了（再生ボタンで最初から）" : "一時停止"
            return
        }
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            // 再バッファも時計を止め、同じ位置で音声・映像を準備し直す。
            // preroll直後の通常のwaitingはAVPlayerに任せ、多重準備で開始を妨げない。
            if advancedSincePreroll { prepareExistingPosition(safeTime()) }
            else { beginWaiting() }
        case .playing:
            guard prerolled, videoOutputIsReady else { beginWaiting(); return }
            isLoading = false
            waitingSince = nil
            player.isMuted = wantsPause
            status = "再生中"
        case .paused:
            if wantsPause { status = "一時停止" }
        @unknown default: break
        }
    }
    private func beginWaiting() {
        guard !isSuspendedForBackground else { return }
        isLoading = true
        failure = nil
        status = "読み込み中…"
        player.isMuted = true
        if waitingSince == nil { waitingSince = Date() }
    }
    func prepareQualityChange() {
        guard !isStopped, !isSuspendedForBackground else { return }
        flushPosition()
        if !isLoading { targetSeconds = safeTime() }
        captions.reset(for: targetSeconds)
        resetAudioSelection(clearPreferred: false)
        // Do not preroll the old item in the interval before load replaces it.
        isChangingQuality = true
        generation += 1
        cancelPreparation()
        preparing = true
        prerolled = false
        playbackStartRequested = false
        beginWaiting()
    }
    func togglePause() {
        guard !isStopped, !isSuspendedForBackground, failure == nil else { return }
        if reachedEnd {
            reachedEnd = false
            wantsPause = false
            commercialSkipPolicy.resetAfterManualSeek()
            clearCommercialSkipNotice()
            prepareExistingPosition(0)
            return
        }
        wantsPause.toggle()
        if preparing { return }
        if wantsPause {
            targetSeconds = safeTime()
            player.pause()
            player.isMuted = true
            status = "一時停止"
            flushPosition()
        } else {
            prepareExistingPosition(safeTime())
        }
    }
    /// Freeze the recording while the user browses scene thumbnails. The
    /// stored intent is restored through the same frame/preroll gate as seek.
    func beginSceneSearch() -> Bool {
        guard !isStopped, !isSuspendedForBackground, !isLoading,
              failure == nil, sceneSearchShouldResume == nil else { return false }
        sceneSearchShouldResume = !wantsPause
        if !wantsPause { togglePause() }
        return true
    }

    func endSceneSearch(at seconds: Double? = nil, preparePlayback: Bool = true) {
        guard let shouldResume = sceneSearchShouldResume else { return }
        sceneSearchShouldResume = nil
        wantsPause = !shouldResume
        guard !isStopped, preparePlayback, failure == nil else { return }
        if let seconds, seconds.isFinite {
            if isLoading || isSuspendedForBackground {
                pendingSceneSeek = max(0, seconds)
            } else {
                seek(to: seconds)
            }
        } else if shouldResume, !isLoading, !isSuspendedForBackground {
            prepareExistingPosition(safeTime())
        }
    }

    func configureCommercialTimeline(_ timeline: RecordingChapterTimeline?, isComplete: Bool) {
        guard !isStopped else { return }
        commercialTimeline = timeline
        commercialMetadataComplete = isComplete
        commercialMetadataUsable = isComplete && timeline != nil
        commercialSkipPolicy.reset()
        clearCommercialSkipNotice()
    }

    func setAutomaticCommercialSkip(_ enabled: Bool) {
        guard !isStopped, enabled != automaticCommercialSkipEnabled else { return }
        automaticCommercialSkipEnabled = enabled
        commercialSkipPolicy.reset()
    }

    func undoCommercialSkip() {
        guard !isStopped, !isLoading, failure == nil, canUndoCommercialSkip,
              ProcessInfo.processInfo.systemUptime < commercialUndoUntil,
              commercialMetadataUsable, let lastCommercialSkip, let commercialTimeline else { return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        guard duration.isFinite, duration > 0, lastCommercialSkip.from < duration - 0.1 else { return }
        commercialSkipPolicy.suppressCurrentInterval(in: commercialTimeline, at: lastCommercialSkip.from)
        clearCommercialSkipNotice()
        prepareExistingPosition(lastCommercialSkip.from)
#if DEBUG
        print("RingonomiCommercialSkip: undo target=\(lastCommercialSkip.from)")
#endif
    }

    private func updateAutomaticCommercialSkip() {
        let now = ProcessInfo.processInfo.systemUptime
        if canUndoCommercialSkip && now >= commercialUndoUntil {
            lastCommercialSkip = nil
            canUndoCommercialSkip = false
        }
        if commercialSkipNotice != nil && now >= commercialNoticeUntil { commercialSkipNotice = nil }
        guard automaticCommercialSkipEnabled, commercialMetadataUsable, let timeline = commercialTimeline,
              !timeline.commercialSections.isEmpty, timeline.hasChapterBoundaries,
              !isLoading, !preparing, prerolled, failure == nil, !wantsPause, !reachedEnd,
              player.timeControlStatus == .playing, player.rate > 0,
              videoOutputIsReady else { return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        guard duration.isFinite, duration > 0 else { return }
        guard abs(duration - timeline.duration) <= 2 else {
            commercialMetadataUsable = false
            commercialSkipNotice = "録画時間とCM情報が一致しないため、自動スキップを停止しました。"
            commercialNoticeUntil = now + 8
            return
        }
        let from = safeTime()
        guard let target = commercialSkipPolicy.automaticSeekTarget(
            timeline: timeline, at: from, enabled: automaticCommercialSkipEnabled, isPlayingReady: true
        ), target <= duration - CommercialSkipPolicy.minimumTailMargin else { return }
        lastCommercialSkip = (from: from, to: target)
        canUndoCommercialSkip = true
        commercialUndoUntil = now + 30
        commercialSkipNotice = "CMをスキップしました。チャプターから元の位置に戻せます。"
        commercialNoticeUntil = now + 6
        prepareExistingPosition(target)
#if DEBUG
        print("RingonomiCommercialSkip: automatic from=\(from) target=\(target)")
#endif
    }

    private func clearCommercialSkipNotice() {
        lastCommercialSkip = nil
        canUndoCommercialSkip = false
        commercialSkipNotice = nil
        commercialNoticeUntil = 0
        commercialUndoUntil = 0
    }

    func seek(seconds: Double) {
        seek(to: safeTime() + seconds)
    }
    var currentSeconds: Double { isLoading ? targetSeconds : safeTime() }
    /// The best known duration for the current recording.  During initial
    /// loading AVPlayer may not know the HLS duration yet, so the catalog hint
    /// is used only when it is finite and positive.
    var durationSeconds: Double? {
        let playerDuration = player.currentItem?.duration.seconds ?? .nan
        if playerDuration.isFinite, playerDuration > 0 { return playerDuration }
        if let durationHint, durationHint.isFinite, durationHint > 0 { return durationHint }
        return nil
    }
    var videoRect: CGRect { videoLayer?.videoRect ?? .zero }
    var isPaused: Bool { wantsPause }

    func seek(to seconds: Double) {
        guard !isStopped, !isSuspendedForBackground, !isLoading,
              failure == nil, seconds.isFinite else { return }
        let maximum = durationSeconds.map { max(0, $0 - 0.1) } ?? Double.greatestFiniteMagnitude
        commercialSkipPolicy.resetAfterManualSeek()
        clearCommercialSkipNotice()
        prepareExistingPosition(min(maximum, max(0, seconds)))
    }
    private func prepareExistingPosition(_ seconds: Double, preservingEndState: Bool = false) {
        guard !isStopped, !isSuspendedForBackground else { return }
        flushPosition()
        targetSeconds = seconds
        captions.reset(for: seconds)
        if !preservingEndState { reachedEnd = false }
        if player.currentItem == nil, let url = currentURL {
            currentURL = nil
            load(url, preservingEndState: preservingEndState)
            return
        }
        generation += 1
        cancelPreparation()
        preparing = true
        prerolled = false
        playbackStartRequested = false
        beginWaiting()
        preparePosition(generation)
    }
    func retry() {
        guard !isStopped, !isSuspendedForBackground, let url = currentURL else { return }
        currentURL = nil
        load(url)
    }
    private func safeTime() -> Double {
        guard player.currentItem != nil else { return targetSeconds }
        let value = player.currentTime().seconds
        return value.isFinite && value >= 0 ? value : targetSeconds
    }
    private func updateTime() {
        guard !isStopped, !isSuspendedForBackground else { return }
        if !preparing, prerolled, safeTime() > targetSeconds + 0.25 {
            advancedSincePreroll = true
        }
        let seconds = isLoading ? targetSeconds : safeTime()
        captions.tick(seconds: seconds, frameSize: videoRect.size,
                      isReady: !preparing && !isLoading && failure == nil && prerolled)
        let whole = Int(max(0, min(seconds, 100_000_000)))
        playbackTime = String(format: "%02d:%02d", whole / 60, whole % 60)
#if DEBUG
        if Date().timeIntervalSince(lastLog) >= 5 {
            lastLog = Date()
            print("RingonomiTVNative: time=\(safeTime()) rate=\(player.rate) loading=\(isLoading) muted=\(player.isMuted) layerReady=\(videoLayer?.isReadyForDisplay == true) pipActive=\(pictureInPicture.hasActiveVideoPresentation) itemStatus=\(player.currentItem?.status.rawValue ?? -1) playerStatus=\(player.status.rawValue) preparing=\(preparing) prerolled=\(prerolled) inFlight=\(preparationInFlight)")
        }
#endif
    }
    private func startTimer() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self, !self.isStopped, !self.isSuspendedForBackground else { return }
                if let since = self.waitingSince, Date().timeIntervalSince(since) > 30 {
                    self.fail("読み込みがタイムアウトしました。接続を確認して再試行してください。")
                }
                if self.player.currentItem?.status == .failed {
                    self.fail("再生が中断されました。接続を確認して再試行してください。")
                }
                if self.failure == nil, self.preparing { self.preparePosition(self.generation) }
                self.revealWhenReady()
                self.updateTime()
                self.checkpoint()
                self.updateAutomaticCommercialSkip()
            }
        }
    }
    private func fail(_ message: String) {
        guard !isStopped, !isSuspendedForBackground, failure == nil else { return }
        clearCommercialSkipNotice()
        checkpoint(force: true)
        if !preparing, !isLoading { targetSeconds = safeTime() }
        timer?.cancel()
        resetAudioSelection(clearPreferred: false)
        generation += 1
        cancelPreparation()
        preparing = false
        playbackStartRequested = false
        captions.stop()
        failure = message
        status = "再生できません"
        isLoading = false
        waitingSince = nil
#if DEBUG
        print("RingonomiTVNativeError: \(message)")
#endif
    }
    private func cancelPreparation() {
        preparationInFlight = false
        player.pause()
        player.isMuted = true
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
    }
    func stop() {
        guard !pictureInPicture.ownsPlayback else { return }
        pictureInPicture.invalidate()
        // `onDisappear`/the explicit close path normally flushes first.  Keep
        // the final trusted position up to date here as a fallback, but do
        // not call the resume-store closure while SwiftUI is dismantling the
        // graph; that closure publishes RecordingResumeStore.revision.
        checkpoint(force: true, notify: false)
        isStopped = true
        isSuspendedForBackground = false
        commercialTimeline = nil
        commercialMetadataUsable = false
        commercialMetadataComplete = false
        commercialSkipPolicy.reset()
        lastCommercialSkip = nil
        captions.stop()
        onCheckpoint = nil
        resetAudioSelection(clearPreferred: true, notifyUI: false)
        generation += 1
        timer?.cancel()
        timer = nil
        cancelPreparation()
        playbackStartRequested = false
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        layerObservation?.invalidate()
        layerObservation = nil
        if let clockToken { player.removeTimeObserver(clockToken); self.clockToken = nil }
        if let endToken { NotificationCenter.default.removeObserver(endToken); self.endToken = nil }
        player.replaceCurrentItem(with: nil)
        pictureInPicture.releaseAudioSession()
        currentURL = nil
        videoLayer = nil
    }
}
@MainActor
final class RecordingVideoSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}
struct NativeRecordingVideo: UIViewRepresentable {
    let url: URL
    let controller: RecordingPlaybackController
    func makeCoordinator() -> RecordingPlaybackController { controller }
    func makeUIView(context: Context) -> RecordingVideoSurface {
        let view = RecordingVideoSurface()
        view.backgroundColor = .black
        if let layer = view.playerLayer { controller.attach(layer) }
        controller.load(url)
        return view
    }
    func updateUIView(_ view: RecordingVideoSurface, context: Context) { controller.load(url) }
    static func dismantleUIView(_ view: RecordingVideoSurface, coordinator: RecordingPlaybackController) {
        guard !coordinator.pictureInPicture.ownsPlayback else { return }
        coordinator.stop()
        view.playerLayer?.player = nil
    }
}
