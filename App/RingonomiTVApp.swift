import SwiftUI
import RingonomiCore

@main
struct RingonomiTVApp: App {
    init() {
#if DEBUG
        AccountKeychain.checkStorage(arguments: ProcessInfo.processInfo.arguments)
        PlaybackAccessibilityDiagnostics.start(arguments: ProcessInfo.processInfo.arguments)
#endif
    }
    var body: some Scene { WindowGroup { LibraryView() } }
}
struct LibraryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("appAppearanceMode") private var appearanceValue = AppAppearanceMode.system.rawValue
    @AppStorage("appColorStyle") private var colorStyleValue = AppColorStyle.standard.rawValue
    @AppStorage("serverAddress") private var address = ""
    @State private var draftAddress = ""
    @State private var loadedAddressDraft = false
    @AppStorage("quality") private var quality = "720p"
    @AppStorage("guideSubchannels") private var guideSubchannels = false
    @State private var channels: [Channel] = []
    @State private var error: String?
    @State private var channelError: String?
    @State private var loading = false
    @StateObject private var playbackPresentation = PlaybackPresentationStore()
    private var playback: Playback? {
        get { playbackPresentation.current }
        nonmutating set { playbackPresentation.present(newValue) }
    }
    @StateObject private var playbackIdleTimer = PlaybackIdleTimer()
    @State private var selectedTab = 0
    @State private var settingsPath: [SettingsDestination] = []
    @StateObject private var reservations = ReservationStore()
    @StateObject private var keywords = KeywordReservationStore()
    @StateObject private var resumeStore = RecordingResumeStore()
    @StateObject private var account = BackendAccountStore(storage: AccountKeychain())
    @StateObject private var liveFavorites = LiveChannelFavoritesStore()
    @State private var loadGeneration = UUID()
#if DEBUG
    @State private var launchArgumentsHandled = false
    @State private var accountCheckHandled = false
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
    private var connectionKey: ConnectionLoadKey {
        ConnectionLoadKey(address: effectiveAddress, revision: account.revision)
    }
    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceValue) ?? .system
    }
    private var colorStyle: AppColorStyle {
        AppColorStyle(rawValue: colorStyleValue) ?? .standard
    }
    private var palette: AppColorPalette {
        colorStyle.palette(for: appearanceMode.preferredColorScheme ?? systemColorScheme)
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LiveChannelLibraryView(
                    channels: channels, loading: loading, error: channelError,
                    configured: !effectiveAddress.isEmpty, favorites: liveFavorites,
                    onRefresh: { Task { await refresh() } },
                    onPlay: { channel in
                        do {
                            let client = try RingonomiClient.connected(to: effectiveAddress)
                            playback = Playback(client: client, channelID: channel.displayChannelId, recordingID: nil, title: channel.name, initialQuality: quality)
                        } catch { self.error = error.localizedDescription }
                    }
                )
                .id(connectionKey)
            }.tabItem { Label("ライブ", systemImage: "tv") }.tag(0)
            RecordingLibraryView(address: effectiveAddress, resumeStore: resumeStore) { recording, client in
                openRecording(recording, client: client)
            }.id(connectionKey).tabItem { Label("録画", systemImage: "film") }.tag(1)
            ProgramGuideView(address: effectiveAddress, reservations: reservations) { channel in
                do {
                    let client = try RingonomiClient.connected(to: effectiveAddress)
                    playback = Playback(client: client, channelID: channel.displayChannelId,
                                        recordingID: nil, title: channel.name, initialQuality: quality)
                } catch { self.error = error.localizedDescription }
            }.id(connectionKey).tabItem { Label("番組表", systemImage: "calendar") }.tag(2)
            ReservationListView(address: effectiveAddress, store: reservations, keywords: keywords)
                .id(connectionKey)
                .tabItem { Label("予約", systemImage: "record.circle") }.tag(3)
            NavigationStack(path: $settingsPath) {
                Form {
                    TextField("視聴サーバーURL（ポート番号を含む）", text: $draftAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(reservations.saving || keywords.saving || account.isBusy)
                    Picker("画質", selection: $quality) {
                        ForEach(["1080p", "720p", "540p", "360p"], id: \.self) { Text($0) }
                    }
                    Toggle("番組表に副チャンネルを表示", isOn: $guideSubchannels)
                    Button("接続して読み込む") { applyConnection() }
                        .disabled(loading || account.isBusy || reservations.saving || keywords.saving)
                    Text("Apple TVのIPではなく、視聴サーバーのURLを入力してください。")
                    if loading { ProgressView() }
                    if let error { Text(error).foregroundStyle(.red) }
                    if let channelError { Text(channelError).foregroundStyle(.red) }
                    AppearanceSettingsFields(modeValue: $appearanceValue, styleValue: $colorStyleValue)
                    AppSection("Mirakurun") {
                        NavigationLink("Mirakurunの番組表") { MirakurunProgramGuideView() }
                        NavigationLink("Mirakurun直接視聴") {
                            MirakurunServiceView()
                        }
                        Text("Mirakurunのサービス一覧から、raw TSを直接再生します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    AppSection("EPGStation") {
                        NavigationLink("EPGStationの番組表") { EPGStationProgramGuideView() }
                        NavigationLink("EPGStationの録画") {
                            EPGStationLibraryView()
                        }
                        NavigationLink("EPGStationの予約") {
                            EPGStationReservationListView()
                        }
                        NavigationLink("EPGStationのキーワード予約") { EPGStationRuleListView() }
                        Text("EPGStationの録画一覧から、保存済みの動画を再生します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    AppSection("ファイルライブラリ") {
                        NavigationLink("SMB共有の動画") { SMBPlaybackLibraryView() }
                    }
                    AccountSettingsView(address: effectiveAddress, account: account)
                        .disabled(reservations.saving || keywords.saving)
                }
                .navigationFormViewport()
                .appNavigationTitle(Text("設定"))
                .navigationDestination(for: SettingsDestination.self) { destination in
                    switch destination {
                    case .mirakurun:
                        MirakurunServiceView()
                    case .mirakurunGuide:
                        MirakurunProgramGuideView()
                    case .epgstation:
                        EPGStationLibraryView()
                    case .epgstationReservations:
                        EPGStationReservationListView()
                    case .epgstationRules:
                        EPGStationRuleListView()
                    case .epgstationGuide:
                        EPGStationProgramGuideView()
                    case .smb:
                        SMBPlaybackLibraryView()
                    }
                }
            }
            .tabItem { Label("設定", systemImage: "gear") }.tag(4)
        }
        .onAppear {
            if !loadedAddressDraft { draftAddress = address; loadedAddressDraft = true }
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--show-smb") {
                selectedTab = 4
                settingsPath = [.smb]
            }
            if arguments.contains("--show-mirakurun") || arguments.contains("--play-mirakurun-service") {
                selectedTab = 4
                settingsPath = [.mirakurun]
            }
            if arguments.contains("--show-mirakurun-guide") {
                selectedTab = 4
                settingsPath = [.mirakurunGuide]
            }
            if arguments.contains("--show-epgstation") || arguments.contains("--play-epgstation-recording") {
                selectedTab = 4
                settingsPath = [.epgstation]
            }
            if arguments.contains("--show-epgstation-reservations") || arguments.contains("--epgstation-reservation") {
                selectedTab = 4
                settingsPath = [.epgstationReservations]
            }
            if arguments.contains("--show-epgstation-rules") || arguments.contains("--epgstation-rule") {
                selectedTab = 4
                settingsPath = [.epgstationRules]
            }
            if arguments.contains("--show-epgstation-guide") {
                selectedTab = 4
                settingsPath = [.epgstationGuide]
            }
#endif
        }
        .task(id: connectionKey) {
            channels = []
            channelError = nil
            liveFavorites.configure(address: effectiveAddress)
            playback = nil
            reservations.invalidateConnection()
            keywords.invalidateConnection()
            if effectiveAddress.isEmpty { selectedTab = 4 }
            else {
                async let reservationReload: () = reservations.refresh(address: effectiveAddress)
                async let keywordReload: () = keywords.refresh(address: effectiveAddress)
                await refresh()
                _ = await (reservationReload, keywordReload)
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--show-recordings") { selectedTab = 1 }
                if ProcessInfo.processInfo.arguments.contains("--show-guide") { selectedTab = 2 }
                if ProcessInfo.processInfo.arguments.contains("--show-reservations") { selectedTab = 3 }
                if ProcessInfo.processInfo.arguments.contains("--show-settings") { selectedTab = 4 }
                if !accountCheckHandled, ProcessInfo.processInfo.arguments.contains("--test-account-invalid-login") {
                    accountCheckHandled = true
                    selectedTab = 4
                    // A new fictional username cannot lock out an existing
                    // account. No password or token is written to the log.
                    await account.login(address: effectiveAddress,
                                        username: "ringonomi-check-" + UUID().uuidString,
                                        password: UUID().uuidString)
                    let expectedFailure = account.error?.contains("HTTP 401") == true
                    print("RingonomiAccountLogin: expected401=\(expectedFailure)")
                }
#endif
            }
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--show-mirakurun") || arguments.contains("--play-mirakurun-service") {
                selectedTab = 4
                settingsPath = [.mirakurun]
            }
            if arguments.contains("--show-mirakurun-guide") {
                selectedTab = 4
                settingsPath = [.mirakurunGuide]
            }
            if arguments.contains("--show-epgstation") || arguments.contains("--play-epgstation-recording") {
                selectedTab = 4
                settingsPath = [.epgstation]
            }
            if arguments.contains("--show-epgstation-reservations") || arguments.contains("--epgstation-reservation") {
                selectedTab = 4
                settingsPath = [.epgstationReservations]
            }
            if arguments.contains("--show-epgstation-rules") || arguments.contains("--epgstation-rule") {
                selectedTab = 4
                settingsPath = [.epgstationRules]
            }
#endif
        }
        .task(id: effectiveAddress) {
            await account.restore(address: effectiveAddress)
        }
        .disabled(playback != nil && !playbackPresentation.isDetached)
        .accessibilityHidden(playback != nil && !playbackPresentation.isDetached)
        .safeAreaInset(edge: .bottom) {
            if playbackPresentation.isDetached, let item = playback {
                VStack(alignment: .leading, spacing: 12) {
                    if let notice = playbackPresentation.notice {
                        Text(notice).font(.callout).foregroundStyle(.orange)
                    }
                    HStack(spacing: 30) {
                        Text(item.title).lineLimit(1)
                        Button("全画面へ戻る") { playbackPresentation.restoreInline() }
                        Button("再生を終了") { playbackPresentation.present(nil) }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .overlay {
            if let item = playback {
                PlaybackView(item: item, resumeStore: resumeStore,
                             closeRequest: playbackPresentation.closeRequest,
                             restoreRequest: playbackPresentation.restoreRequest,
                             onClose: { playbackPresentation.didClose(item.id, success: $0) },
                             onDetachedChanged: { playbackPresentation.setDetached($0, for: item.id) },
                             onPictureInPictureNoticeChanged: { playbackPresentation.setNotice($0, for: item.id) }) { needsDisplay in
                    guard playback?.id == item.id else { return }
                    playbackIdleTimer.setNeedsContinuousDisplay(needsDisplay)
                }
                .id(item.id)
                // Preserve the subtree, its layer, quality and keep-alive task
                // while the library accepts input below system PiP.
                .opacity(playbackPresentation.isDetached ? 0 : 1)
                .allowsHitTesting(!playbackPresentation.isDetached)
                .disabled(playbackPresentation.isDetached)
                .accessibilityHidden(playbackPresentation.isDetached)
                .ignoresSafeArea()
            }
        }
        .environment(\.playbackHandoff, PlaybackHandoff(stopPrevious: { [weak playbackPresentation] in
            await playbackPresentation?.stopForAnotherPlayer() ?? true
        }))
        .onChange(of: playback?.id) { _, id in
            if id == nil {
                playbackIdleTimer.setNeedsContinuousDisplay(false)
                // Refresh current-program labels after watching while the
                // live library keeps its filters and selected channel.
                if selectedTab == 0, scenePhase == .active, !loading {
                    Task { await refresh() }
                }
            }
        }
        .alert("接続エラー", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("閉じる") { error = nil }
        } message: { Text(error ?? "") }
        .preferredColorScheme(appearanceMode.preferredColorScheme)
        .environment(\.appAppearanceMode, appearanceMode)
        .environment(\.appColorStyle, colorStyle)
        .tint(palette.accent)
        .background(palette.background.ignoresSafeArea())
    }
    @MainActor private func refresh() async {
        let expected = UUID()
        let requestedAddress = effectiveAddress
        loadGeneration = expected
        loading = true
        channelError = nil
        defer { if loadGeneration == expected { loading = false } }
        do {
            let client = try RingonomiClient.connected(to: requestedAddress)
            let result = try await client.channels()
            guard !Task.isCancelled, expected == loadGeneration, requestedAddress == effectiveAddress else { return }
            channels = result
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
                if recording.isFree {
                    openRecording(recording, client: client,
                                  fromBeginning: arguments.contains("--recording-from-start"))
                }
            }
            if arguments.contains("--test-recording-failure") {
                playback = Playback(client: client, channelID: nil, recordingID: -1,
                                    title: "接続エラーの検証", initialQuality: quality)
            }
#endif
        } catch {
            guard !Task.isCancelled, expected == loadGeneration, requestedAddress == effectiveAddress else { return }
            channelError = (error as? ConnectionError)?.errorDescription
                ?? "チャンネルを読み込めませんでした。接続先を確認し、再試行してください。"
        }
    }

    private func applyConnection() {
        error = nil
        do {
            let next = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try RingonomiClient(address: next)
            if next == address {
                Task {
                    await account.restore(address: effectiveAddress)
                    await refresh()
                }
            } else { address = next }
        } catch { self.error = error.localizedDescription }
    }

    private func openRecording(_ recording: Recording, client: RingonomiClient, fromBeginning: Bool = false) {
        let id = resumeStore.identity(for: recording, client: client)
        let savedPosition = fromBeginning ? nil : resumeStore.position(for: recording, client: client)
        playback = Playback(client: client, channelID: nil, recordingID: recording.playbackID,
                            title: recording.title, initialQuality: quality,
                            resumeID: id, durationHint: recording.recordedVideo.duration,
                            recordingStatus: recording.recordedVideo.status,
                            savedPosition: savedPosition, recordedFileID: recording.recordedVideo.id)
    }
}

private struct ConnectionLoadKey: Hashable {
    let address: String
    let revision: Int
}

private enum SettingsDestination: Hashable {
    case smb
    case mirakurun
    case mirakurunGuide
    case epgstation
    case epgstationReservations
    case epgstationRules
    case epgstationGuide
}
