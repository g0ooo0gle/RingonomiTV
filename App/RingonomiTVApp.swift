import SwiftUI
import RingonomiCore

@main
struct RingonomiTVApp: App {
    var body: some Scene { WindowGroup { LibraryView() } }
}
struct LibraryView: View {
    @AppStorage("serverAddress") private var address = ""
    @AppStorage("quality") private var quality = "720p"
    @AppStorage("guideSubchannels") private var guideSubchannels = false
    @State private var channels: [Channel] = []
    @State private var error: String?
    @State private var loading = false
    @State private var playback: Playback?
    @State private var selectedTab = 0
    @StateObject private var reservations = ReservationStore()
    @StateObject private var keywords = KeywordReservationStore()
    @StateObject private var resumeStore = RecordingResumeStore()
#if DEBUG
    @State private var launchArgumentsHandled = false
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
                            playback = Playback(client: client, channelID: channel.displayChannelId, recordingID: nil, title: channel.name, initialQuality: quality)
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
            RecordingLibraryView(address: effectiveAddress, resumeStore: resumeStore) { recording, client in
                openRecording(recording, client: client)
            }.tabItem { Label("録画", systemImage: "film") }.tag(1)
            ProgramGuideView(address: effectiveAddress, reservations: reservations) { channel in
                do {
                    let client = try RingonomiClient(address: effectiveAddress)
                    playback = Playback(client: client, channelID: channel.displayChannelId,
                                        recordingID: nil, title: channel.name, initialQuality: quality)
                } catch { self.error = error.localizedDescription }
            }.tabItem { Label("番組表", systemImage: "calendar") }.tag(2)
            ReservationListView(address: effectiveAddress, store: reservations, keywords: keywords)
                .tabItem { Label("予約", systemImage: "record.circle") }.tag(3)
            Form {
                TextField("視聴サーバーURL（ポート番号を含む）", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(reservations.saving || keywords.saving)
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
                if ProcessInfo.processInfo.arguments.contains("--show-recordings") { selectedTab = 1 }
                if ProcessInfo.processInfo.arguments.contains("--show-guide") { selectedTab = 2 }
                if ProcessInfo.processInfo.arguments.contains("--show-reservations") { selectedTab = 3 }
#endif
            }
        }
        .task(id: effectiveAddress) {
            await reservations.refresh(address: effectiveAddress)
            await keywords.refresh(address: effectiveAddress)
        }
        .fullScreenCover(item: $playback) { item in PlaybackView(item: item, resumeStore: resumeStore) }
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
            let arguments = launchArgumentsHandled ? [] : ProcessInfo.processInfo.arguments
            launchArgumentsHandled = true
            if let index = arguments.firstIndex(of: "--play-channel"), index + 1 < arguments.count,
               let channel = channels.first(where: { $0.displayChannelId == arguments[index + 1] }) {
                playback = Playback(client: client, channelID: channel.displayChannelId, recordingID: nil, title: channel.name, initialQuality: quality)
            }
            if let index = arguments.firstIndex(of: "--play-recording"), index + 1 < arguments.count,
               let id = Int(arguments[index + 1]) {
                let recording = try await client.recording(id: id)
                if recording.isFree { openRecording(recording, client: client) }
            }
            if arguments.contains("--test-recording-failure") {
                playback = Playback(client: client, channelID: nil, recordingID: -1,
                                    title: "接続エラーの検証", initialQuality: quality)
            }
#endif
        } catch { self.error = error.localizedDescription }
    }

    private func openRecording(_ recording: Recording, client: RingonomiClient) {
        let id = resumeStore.identity(for: recording, client: client)
        let savedPosition = resumeStore.position(for: recording, client: client)
        playback = Playback(client: client, channelID: nil, recordingID: recording.playbackID,
                            title: recording.title, initialQuality: quality,
                            resumeID: id, durationHint: recording.recordedVideo.duration,
                            recordingStatus: recording.recordedVideo.status,
                            savedPosition: savedPosition, recordedFileID: recording.recordedVideo.id)
    }
}
