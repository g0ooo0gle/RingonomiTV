import SwiftUI
import RingonomiCore

struct Playback: Identifiable {
    let id = UUID()
    let client: RingonomiClient
    let channelID: String?
    /// 番組詳細・配信APIへ渡す録画番組ID。録画ファイルIDとは別。
    let recordingID: Int?
    let title: String
    let initialQuality: String
    let resumeID: RecordingResumeID?
    let durationHint: Double?
    let recordingStatus: String?
    let savedPosition: Double?
    let recordedFileID: Int?

    init(client: RingonomiClient, channelID: String?, recordingID: Int?, title: String, initialQuality: String,
         resumeID: RecordingResumeID? = nil, durationHint: Double? = nil,
         recordingStatus: String? = nil, savedPosition: Double? = nil, recordedFileID: Int? = nil) {
        self.client = client
        self.channelID = channelID
        self.recordingID = recordingID
        self.title = title
        self.initialQuality = initialQuality
        self.resumeID = resumeID
        self.durationHint = durationHint
        self.recordingStatus = recordingStatus
        self.savedPosition = savedPosition
        self.recordedFileID = recordedFileID
    }

    static func timestamp(_ seconds: Double) -> String {
        let whole = Int(max(0, min(seconds.isFinite ? seconds : 0, 100_000_000)))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
    func url(quality: String, session: String) -> URL {
        if let recordingID { return client.recordingURL(id: recordingID, session: session, quality: quality) }
        return client.endpoint(["api", "streams", "live", channelID ?? "invalid", quality, "mpegts"])
    }
}
struct PlaybackView: View {
    let item: Playback
    let resumeStore: RecordingResumeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var quality: String
    @State private var session = UUID().uuidString
    @State private var maintenanceError: String?
    @State private var hasStarted = false
    init(item: Playback, resumeStore: RecordingResumeStore) {
        self.item = item
        self.resumeStore = resumeStore
        _quality = State(initialValue: item.initialQuality)
    }
    private var streamURL: URL { item.url(quality: quality, session: session) }
#if canImport(TVVLCKit)
    @StateObject private var controller = PlaybackController()
    @StateObject private var recordingController = RecordingPlaybackController()
    private var isRecording: Bool { item.recordingID != nil }
    private var isLoading: Bool { isRecording ? recordingController.isLoading : controller.isLoading }
    private var failure: String? { isRecording ? recordingController.failure : controller.failure }
    private var audioOptions: [PlaybackAudioOption] { isRecording ? recordingController.audioOptions : controller.audioOptions }
    private var selectedAudioID: String? { isRecording ? recordingController.selectedAudioID : controller.selectedAudioID }
    private var audioSelectionError: String? { isRecording ? recordingController.audioSelectionError : controller.audioSelectionError }
#endif
    var body: some View {
        Group {
            if hasStarted {
                playerBody
            } else if let position = item.savedPosition {
                VStack(spacing: 30) {
                    Text(item.title).font(.title2).multilineTextAlignment(.center)
                    Text("前回は \(Playback.timestamp(position)) まで再生しました。")
                    Button("続きから再生") { beginPlayback(at: position) }
                    Button("最初から再生") { beginPlayback(at: 0) }
                    Button("閉じる") { close() }
                }.padding(80).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            if !hasStarted, item.savedPosition == nil { beginPlayback(at: 0) }
        }
        .onExitCommand { close() }
        .onDisappear { flushPosition() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushPosition() }
        }
    }

    private func beginPlayback(at seconds: Double) {
#if canImport(TVVLCKit)
        if let id = item.resumeID {
            let store = resumeStore
            let mediaStatus = item.recordingStatus
            recordingController.configurePosition(seconds: seconds, durationHint: item.durationHint) {
                position, duration, reachedEnd in
                store.save(id, seconds: position, duration: duration, status: mediaStatus, reachedEnd: reachedEnd)
            }
        }
#endif
        hasStarted = true
    }

    private func flushPosition() {
#if canImport(TVVLCKit)
        if item.recordingID != nil { recordingController.flushPosition() }
#endif
    }

    private func close() {
        flushPosition()
        dismiss()
    }

    private var playerBody: some View {
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
                if item.recordingID != nil { Text(recordingController.playbackTime).font(.caption).monospacedDigit() }
                if let maintenanceError { Text(maintenanceError).font(.caption) }
                if let audioSelectionError { Text(audioSelectionError).font(.caption).foregroundStyle(.orange) }
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
                if item.recordingID != nil {
                    Button("10秒戻る") { recordingController.seek(seconds: -10) }.disabled(isLoading || failure != nil)
                    Button("30秒進む") { recordingController.seek(seconds: 30) }.disabled(isLoading || failure != nil)
                    if let recordingID = item.recordingID {
                        RecordingChapterControls(client: item.client, recordingID: recordingID,
                                                 fileID: item.recordedFileID, controller: recordingController)
                    }
                }
                if audioOptions.count > 1 {
                    Menu("音声") {
                        ForEach(audioOptions) { option in
                            Button(option.id == selectedAudioID ? "✓ \(option.name)" : option.name) {
                                if isRecording { recordingController.selectAudioTrack(id: option.id) }
                                else { controller.selectAudioTrack(id: option.id) }
                            }
                        }
                    }.disabled(isLoading || failure != nil)
                        .accessibilityLabel("音声を選択")
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
                Button("閉じる") { close() }
            }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
#if canImport(TVVLCKit)
        .onPlayPauseCommand {
            if isRecording { recordingController.togglePause() } else { controller.togglePause() }
        }
        .task(id: streamURL) {
            guard let recordingID = item.recordingID else { return }
            let currentSession = session
            let currentQuality = quality
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(4))
                    if failure != nil { continue }
                    try await item.client.keepRecordingAlive(id: recordingID, session: currentSession, quality: currentQuality)
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
