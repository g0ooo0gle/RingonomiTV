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
    private var currentURL: URL?
    private var wantsPause = false
    private var gate = PlaybackReadinessGate()
    private var monitor: Task<Void, Never>?
    private var waitingSince = Date()
    private var lastFrameDate = Date.distantPast
    private var lastPictures = 0
    private var lastLog = Date.distantPast
    override init() { super.init(); player.delegate = self }
    func prepareQualityChange() {
        isLoading = true
        waitingSince = Date()
        player.audio?.isMuted = true
        gate.reset()
    }
    func load(_ url: URL) {
        guard currentURL != url else { return }
        currentURL = url
        monitor?.cancel()
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
        guard failure == nil else { return }
        wantsPause.toggle()
        if !isLoading {
            if wantsPause { player.pause(); player.audio?.isMuted = true }
            else { beginWaiting(); player.play() }
        }
        updateStatus()
    }
    func retry() {
        guard let url = currentURL else { return }
        currentURL = nil
        load(url)
    }
    func stop() {
        monitor?.cancel()
        monitor = nil
        player.audio?.isMuted = true
        player.stop()
        player.drawable = nil
        currentURL = nil
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
    private func updateStatus() {
        guard currentURL != nil, failure == nil else { return }
        if isLoading { player.audio?.isMuted = true }
        if player.state == .error || player.state == .ended {
            failure = "配信が中断されました。接続を確認して再試行してください。"
            player.audio?.isMuted = true
            player.pause()
            isLoading = false
            status = "再生できません"
            return
        }
        let valid = player.hasVideoOut && player.videoSize.width > 0 && player.time.intValue > 0
        if valid, let media = player.media {
            let stats = media.statistics
            let pictures = Int(stats.displayedPictures)
            if pictures > lastPictures { lastFrameDate = Date() }
            lastPictures = pictures
            if !isLoading, !wantsPause, Date().timeIntervalSince(lastFrameDate) > 1.5 { beginWaiting() }
            let ready = gate.update(hasVideo: true, pictures: pictures,
                                    audioReady: player.numberOfAudioTracks > 0 && stats.decodedAudio > 0 && stats.playedAudioBuffers > 0)
            if isLoading, ready, Date().timeIntervalSince(lastFrameDate) < 1 {
                isLoading = false
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
