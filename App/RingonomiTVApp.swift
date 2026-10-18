import SwiftUI
import AVKit
import RingonomiCore
#if canImport(TVVLCKit)
@preconcurrency import TVVLCKit
#endif

@main
struct RingonomiTVApp: App {
    var body: some Scene { WindowGroup { LibraryView() } }
}
struct Playback: Identifiable {
    let id = UUID()
    let client: RingonomiClient
    let channelID: String?
    let videoID: Int?
    let title: String
    let initialQuality: String
    func url(quality: String, session: String) -> URL {
        if let videoID { return client.recordingURL(id: videoID, session: session, quality: quality) }
        return client.endpoint(["api", "streams", "live", channelID ?? "invalid", quality, "mpegts"])
    }
}
struct LibraryView: View {
    @AppStorage("serverAddress") private var address = ""
    @AppStorage("quality") private var quality = "720p"
    @AppStorage("guideSubchannels") private var guideSubchannels = false
    @State private var channels: [Channel] = []
    @State private var recordings: [Recording] = []
    @State private var error: String?
    @State private var loading = false
    @State private var playback: Playback?
    @State private var selectedTab = 0
    @StateObject private var reservations = ReservationStore()
#if DEBUG
    /// A private test server may be supplied without persisting its address in user defaults.
    private var runtimeServerAddress: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--server-url"), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
#endif
    private var effectiveAddress: String {
#if DEBUG
        return runtimeServerAddress ?? address
#else
        return address
#endif
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                List(channels) { channel in
                    Button {
                        do {
                            let client = try RingonomiClient(address: effectiveAddress)
                            playback = Playback(client: client, channelID: channel.displayChannelId, videoID: nil, title: channel.name, initialQuality: quality)
                        } catch { self.error = error.localizedDescription }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(channel.name).font(.headline)
                            Text(channel.programPresent?.title ?? "番組情報なし")
                            Text(channel.programPresent?.description ?? "").font(.caption).lineLimit(2)
                        }
                    }
                }.navigationTitle("りんごのみTV · ライブ")
                .toolbar { Button("更新") { Task { await refresh() } }.disabled(loading) }
            }.tabItem { Label("ライブ", systemImage: "tv") }.tag(0)
            NavigationStack {
                List(recordings) { recording in
                    Button {
                        do {
                            let client = try RingonomiClient(address: effectiveAddress)
                            playback = Playback(client: client, channelID: nil, videoID: recording.recordedVideo.id,
                                                title: recording.title, initialQuality: quality)
                        } catch { self.error = error.localizedDescription }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(recording.title).font(.headline)
                            Text(recording.description).lineLimit(3)
                        }
                    }
                }.navigationTitle("最近の録画")
            }.tabItem { Label("録画", systemImage: "film") }.tag(1)
            ProgramGuideView(address: effectiveAddress, reservations: reservations) { channel in
                do {
                    let client = try RingonomiClient(address: effectiveAddress)
                    playback = Playback(client: client, channelID: channel.displayChannelId,
                                        videoID: nil, title: channel.name, initialQuality: quality)
                } catch { self.error = error.localizedDescription }
            }.tabItem { Label("番組表", systemImage: "calendar") }.tag(2)
            ReservationListView(address: effectiveAddress, store: reservations)
                .tabItem { Label("予約", systemImage: "record.circle") }.tag(3)
            Form {
                TextField("視聴サーバーURL（ポート番号を含む）", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(reservations.saving)
                Picker("画質", selection: $quality) {
                    ForEach(["1080p", "720p", "540p", "360p"], id: \.self) { Text($0) }
                }
                Toggle("番組表に副チャンネルを表示", isOn: $guideSubchannels)
                Button("接続して読み込む") { Task { await refresh() } }.disabled(loading)
                Text("Apple TVのIPではなく、視聴サーバーのURLを入力してください。")
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }.tabItem { Label("設定", systemImage: "gear") }.tag(4)
        }
        .task {
            if effectiveAddress.isEmpty { selectedTab = 4 }
            else {
                await refresh()
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--show-guide") { selectedTab = 2 }
                if ProcessInfo.processInfo.arguments.contains("--show-reservations") { selectedTab = 3 }
#endif
            }
        }
        .task(id: effectiveAddress) { await reservations.refresh(address: effectiveAddress) }
        .fullScreenCover(item: $playback) { item in PlaybackView(item: item) }
        .alert("接続エラー", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("閉じる") { error = nil }
        } message: { Text(error ?? "") }
    }
    @MainActor private func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let client = try RingonomiClient(address: effectiveAddress)
            channels = try await client.channels()
#if DEBUG
            // 実機検証時だけ指定チャンネルを直接開ける。通常起動には影響しない。
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--play-channel"), index + 1 < arguments.count,
               let channel = channels.first(where: { $0.displayChannelId == arguments[index + 1] }) {
                playback = Playback(client: client, channelID: channel.displayChannelId, videoID: nil, title: channel.name, initialQuality: quality)
            }
#endif
            recordings = try await client.fetch(["api", "videos"], as: RecordingsResponse.self).recordedPrograms
#if DEBUG
            if let index = arguments.firstIndex(of: "--play-recording"), index + 1 < arguments.count,
               let recording = recordings.first(where: { String($0.id) == arguments[index + 1] && $0.isFree }) {
                playback = Playback(client: client, channelID: nil, videoID: recording.recordedVideo.id,
                                    title: recording.title, initialQuality: quality)
            }
            if arguments.contains("--test-recording-failure") {
                playback = Playback(client: client, channelID: nil, videoID: -1,
                                    title: "接続エラーの検証", initialQuality: quality)
            }
#endif
        } catch { self.error = error.localizedDescription }
    }
}
struct PlaybackView: View {
    let item: Playback
    @Environment(\.dismiss) private var dismiss
    @State private var quality: String
    @State private var session = UUID().uuidString
    @State private var maintenanceError: String?
    init(item: Playback) {
        self.item = item
        _quality = State(initialValue: item.initialQuality)
    }
    private var streamURL: URL { item.url(quality: quality, session: session) }
#if canImport(TVVLCKit)
    @StateObject private var controller = PlaybackController()
    @StateObject private var recordingController = RecordingPlaybackController()
    private var isRecording: Bool { item.videoID != nil }
    private var isLoading: Bool { isRecording ? recordingController.isLoading : controller.isLoading }
    private var failure: String? { isRecording ? recordingController.failure : controller.failure }
#endif
    var body: some View {
        ZStack(alignment: .topTrailing) {
#if canImport(TVVLCKit)
            if isRecording {
                NativeRecordingVideo(url: streamURL, controller: recordingController).ignoresSafeArea()
            } else {
                VLCVideo(url: streamURL, controller: controller).ignoresSafeArea()
            }
            if isLoading || failure != nil {
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    if isLoading {
                        ProgressView().scaleEffect(1.6)
                        Text("映像と音声を準備しています…")
                    }
                    if let failure {
                        Text(failure).multilineTextAlignment(.center)
                        Button("再試行") {
                            if isRecording { recordingController.retry() } else { controller.retry() }
                        }
                    }
                }.padding(60).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title).font(.headline).lineLimit(2)
                Text(isRecording ? recordingController.status : controller.status).font(.caption)
                if item.videoID != nil { Text(recordingController.playbackTime).font(.caption).monospacedDigit() }
                if let maintenanceError { Text(maintenanceError).font(.caption) }
            }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
#else
            VStack(spacing: 30) {
                Text("TS再生ライブラリが必要です")
                Text("READMEの手順でTVVLCKitを導入してビルドしてください。")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
#endif
            HStack(spacing: 24) {
#if canImport(TVVLCKit)
                if item.videoID != nil {
                    Button("10秒戻る") { recordingController.seek(seconds: -10) }.disabled(isLoading || failure != nil)
                    Button("30秒進む") { recordingController.seek(seconds: 30) }.disabled(isLoading || failure != nil)
                }
                Menu("画質：\(quality)") {
                    ForEach(["1080p", "720p", "540p", "360p"], id: \.self) { value in
                        Button(value == quality ? "✓ \(value)" : value) {
                            guard value != quality else { return }
                            if isRecording { recordingController.prepareQualityChange() }
                            else { controller.prepareQualityChange() }
                            session = UUID().uuidString
                            quality = value
                        }
                    }
                }.disabled(isLoading)
#endif
                Button("閉じる") { dismiss() }
            }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }.onExitCommand { dismiss() }
#if canImport(TVVLCKit)
        .onPlayPauseCommand {
            if isRecording { recordingController.togglePause() } else { controller.togglePause() }
        }
        .task(id: streamURL) {
            guard let videoID = item.videoID else { return }
            let currentSession = session
            let currentQuality = quality
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(4))
                    if failure != nil { continue }
                    try await item.client.keepRecordingAlive(id: videoID, session: currentSession, quality: currentQuality)
                    maintenanceError = nil
#if DEBUG
                    print("RingonomiTVRecording: keep-alive OK quality=\(currentQuality)")
#endif
                } catch is CancellationError { break }
                catch {
                    if Task.isCancelled { break }
                    maintenanceError = "接続の維持に失敗しました。再試行しています。"
                }
            }
        }
#endif
    }
}
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
