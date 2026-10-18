import SwiftUI
@preconcurrency import AVFoundation

/// HLSはAppleの再生基盤で準備し、時計を止めたまま音声・映像を先読みする。
@MainActor
final class RecordingPlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var status = "読み込み中…"
    @Published private(set) var playbackTime = "00:00"
    @Published private(set) var isLoading = true
    @Published private(set) var failure: String?
    private var currentURL: URL?
    private var wantsPause = false
    private var targetSeconds: Double = 0
    private var preparing = false
    private var prerolled = false
    private var preparationInFlight = false
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

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = true
    }
    func attach(_ layer: AVPlayerLayer) {
        videoLayer = layer
        layer.player = player
        layer.videoGravity = .resizeAspect
        layerObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.revealWhenReady() }
        }
    }
    func load(_ url: URL) {
        guard currentURL != url else { return }
        currentURL = url
        generation += 1
        cancelPreparation()
        observations.removeAll()
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        preparing = true
        prerolled = false
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
                guard let self, let item, self.player.currentItem === item else { return }
                self.status = "再生終了"
                self.player.pause()
                self.isLoading = false
                self.waitingSince = nil
            }
        }
        if clockToken == nil {
            clockToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateTime() }
            }
        }
        startTimer()
    }
    private func itemStatusChanged(_ expected: Int) {
        guard expected == generation, let item = player.currentItem else { return }
        switch item.status {
        case .failed: fail("録画を読み込めませんでした。接続先と配信状態を確認してください。")
        case .readyToPlay:
            guard preparing else { return }
            preparePosition(expected)
        default: break
        }
    }
    private func preparePosition(_ expected: Int) {
        guard expected == generation, preparing, !prerolled, !preparationInFlight,
              player.status == .readyToPlay,
              player.currentItem?.status == .readyToPlay else { return }
        preparationInFlight = true
        player.pause()
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, self.preparing else { return }
                guard finished, self.player.status == .readyToPlay else {
                    self.fail("再生位置を読み込めませんでした。再試行してください。")
                    return
                }
                // readyToPlayと停止状態を確認してから呼び、APIの例外条件を避ける。
                self.player.pause()
                self.player.preroll(atRate: 1) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == expected, self.preparing else { return }
                        guard finished else {
                            self.fail("映像と音声の準備に失敗しました。再試行してください。")
                            return
                        }
                        self.prerolled = true
                        self.preparationInFlight = false
                        self.revealWhenReady()
                    }
                }
            }
        }
    }
    private func revealWhenReady() {
        guard failure == nil, preparing, prerolled,
              player.currentItem?.status == .readyToPlay,
              videoLayer?.isReadyForDisplay == true else { return }
        preparing = false
        advancedSincePreroll = false
        isLoading = false
        waitingSince = nil
        player.isMuted = wantsPause
        if wantsPause { player.pause() } else { player.play() }
        status = wantsPause ? "一時停止" : "再生中"
        updateTime()
#if DEBUG
        print("RingonomiTVNativeReady: target=\(targetSeconds) actual=\(player.currentTime().seconds) rate=\(player.rate) muted=\(player.isMuted) layerReady=true")
#endif
    }
    private func playbackStateChanged() {
        guard failure == nil, !preparing else { return }
        if wantsPause {
            player.pause()
            player.isMuted = true
            status = "一時停止"
            return
        }
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            // 再バッファも時計を止め、同じ位置で音声・映像を準備し直す。
            // preroll直後の通常のwaitingはAVPlayerに任せ、多重準備で開始を妨げない。
            if advancedSincePreroll { prepareExistingPosition(safeTime()) }
            else { beginWaiting() }
        case .playing:
            guard prerolled, videoLayer?.isReadyForDisplay == true else { beginWaiting(); return }
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
        isLoading = true
        failure = nil
        status = "読み込み中…"
        player.isMuted = true
        if waitingSince == nil { waitingSince = Date() }
    }
    func prepareQualityChange() {
        if !isLoading { targetSeconds = safeTime() }
        generation += 1
        cancelPreparation()
        preparing = true
        prerolled = false
        beginWaiting()
    }
    func togglePause() {
        guard failure == nil else { return }
        wantsPause.toggle()
        if preparing { return }
        if wantsPause {
            targetSeconds = safeTime()
            player.pause()
            player.isMuted = true
            status = "一時停止"
        } else {
            prepareExistingPosition(safeTime())
        }
    }
    func seek(seconds: Double) {
        guard !isLoading, failure == nil else { return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        let maximum = duration.isFinite && duration > 0 ? max(0, duration - 0.1) : Double.greatestFiniteMagnitude
        prepareExistingPosition(min(maximum, max(0, safeTime() + seconds)))
    }
    private func prepareExistingPosition(_ seconds: Double) {
        targetSeconds = seconds
        generation += 1
        cancelPreparation()
        preparing = true
        prerolled = false
        beginWaiting()
        preparePosition(generation)
    }
    func retry() {
        guard let url = currentURL else { return }
        targetSeconds = safeTime()
        currentURL = nil
        load(url)
    }
    private func safeTime() -> Double {
        let value = player.currentTime().seconds
        return value.isFinite && value >= 0 ? value : targetSeconds
    }
    private func updateTime() {
        if !preparing, prerolled, safeTime() > targetSeconds + 0.25 {
            advancedSincePreroll = true
        }
        let seconds = isLoading ? targetSeconds : safeTime()
        let whole = Int(max(0, min(seconds, 100_000_000)))
        playbackTime = String(format: "%02d:%02d", whole / 60, whole % 60)
#if DEBUG
        if Date().timeIntervalSince(lastLog) >= 5 {
            lastLog = Date()
            print("RingonomiTVNative: time=\(safeTime()) rate=\(player.rate) loading=\(isLoading) muted=\(player.isMuted) layerReady=\(videoLayer?.isReadyForDisplay == true)")
        }
#endif
    }
    private func startTimer() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self else { return }
                if let since = self.waitingSince, Date().timeIntervalSince(since) > 30 {
                    self.fail("読み込みがタイムアウトしました。接続を確認して再試行してください。")
                }
                if self.player.currentItem?.status == .failed {
                    self.fail("再生が中断されました。接続を確認して再試行してください。")
                }
                if self.failure == nil, self.preparing { self.preparePosition(self.generation) }
                self.revealWhenReady()
                self.updateTime()
            }
        }
    }
    private func fail(_ message: String) {
        guard failure == nil else { return }
        timer?.cancel()
        generation += 1
        cancelPreparation()
        preparing = false
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
        generation += 1
        timer?.cancel()
        timer = nil
        cancelPreparation()
        observations.removeAll()
        layerObservation = nil
        if let clockToken { player.removeTimeObserver(clockToken); self.clockToken = nil }
        if let endToken { NotificationCenter.default.removeObserver(endToken); self.endToken = nil }
        player.replaceCurrentItem(with: nil)
        currentURL = nil
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
        coordinator.stop()
        view.playerLayer?.player = nil
    }
}
