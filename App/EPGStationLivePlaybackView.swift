import SwiftUI
import RingonomiCore
#if canImport(UIKit)
import UIKit
#endif

/// A live EPGStation channel selected from the program guide.
///
/// The address is captured when the selection is made.  This prevents a later
/// settings edit from silently changing an already-open player.
struct EPGStationLivePlaybackSelection: Identifiable {
    let id = UUID()
    let address: String
    let channelID: Int
    let title: String
}

private enum EPGStationLivePlaybackFocus: Hashable {
    case surface
    case playPause
    case quality
    case viewport
    case menuClose
    case loadingClose
    case retry
    case failureClose
    case qualityPrompt
    case qualityClose
    case qualityChoice(Int)
}

/// Direct EPGStation live playback.
///
/// This view intentionally owns neither a server session nor a VOD playback
/// model.  EPGStation supplies the stream URL and the existing VLC
/// live controller owns decoder readiness, pause state, and teardown.
struct EPGStationLivePlaybackView: View {
    let item: EPGStationLivePlaybackSelection
    let onContinuousDisplayChanged: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focus: EPGStationLivePlaybackFocus?
    @StateObject private var store = EPGStationLivePlaybackStore()
    @State private var displayedURL: URL?
    @State private var menuVisible = false
    @State private var qualityCardRequested = false
    @State private var hasAppeared = false
    @State private var isClosing = false
    @State private var isBackgrounded = false
    @State private var controllerSuspended = false
    @StateObject private var viewportSettings = VideoViewportSettings()
#if canImport(TVVLCKit)
    @StateObject private var controller = PlaybackController()
#endif

    private var qualityCardVisible: Bool {
        qualityCardRequested &&
        !effectiveLoading &&
        effectiveFailure == nil &&
        !store.qualities.isEmpty &&
        !viewportSettings.isPresented
    }

    private var effectiveLoading: Bool {
        guard effectiveFailure == nil else { return false }
        if store.isLoading { return true }
#if canImport(TVVLCKit)
        return displayedURL != nil && controller.isLoading
#else
        return false
#endif
    }

    private var effectiveFailure: String? {
        if let error = store.error { return error }
#if canImport(TVVLCKit)
        // During a replacement request the old controller failure can still
        // be published until VLC receives the new URL.  The store request is
        // the authoritative loading state in that interval.
        if !store.isLoading, displayedURL != nil { return controller.failure }
#endif
        return nil
    }

    private var playerHasStream: Bool {
        store.stream != nil && displayedURL != nil && !store.awaitingQualitySelection
    }

    private var menuIsVisible: Bool {
        menuVisible && !qualityCardVisible && playerHasStream && !effectiveLoading && effectiveFailure == nil
            && !viewportSettings.isPresented
    }

    private var needsContinuousDisplay: Bool {
        guard hasAppeared,
              !isBackgrounded,
              !store.isSuspended,
              effectiveFailure == nil,
              store.isLoading || displayedURL != nil else {
            return false
        }
#if canImport(TVVLCKit)
        return !controller.isPaused
#else
        return false
#endif
    }

    var body: some View {
        ZStack {
#if canImport(TVVLCKit)
            if let displayedURL {
                VideoViewportMedia(crop: viewportSettings.crop, videoRect: controller.videoRect) {
                    VLCVideo(url: displayedURL, controller: controller)
                }
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            playerSurface
#else
            unavailableView
#endif

            // Keep the top controls in the same view tree as the player.  A
            // sheet would dismantle NativeVLC and can interrupt a live stream.
            controlsOverlay
                .offset(y: menuIsVisible ? 0 : 320)
                .opacity(menuIsVisible ? 1 : 0)
                .disabled(!menuIsVisible)
                .allowsHitTesting(menuIsVisible)
                .accessibilityHidden(!menuIsVisible)
                .zIndex(1)

            qualityPrompt
                .opacity(store.awaitingQualitySelection && !qualityCardVisible ? 1 : 0)
                .disabled(!store.awaitingQualitySelection || qualityCardVisible || viewportSettings.isPresented)
                .allowsHitTesting(store.awaitingQualitySelection && !qualityCardVisible && !viewportSettings.isPresented)
                .accessibilityHidden(!store.awaitingQualitySelection || qualityCardVisible || viewportSettings.isPresented)
                .zIndex(2)

            if effectiveLoading {
                loadingOverlay
                    .zIndex(3)
            } else if let effectiveFailure {
                failureOverlay(message: effectiveFailure)
                    .zIndex(3)
            }

            qualityCard
                .offset(y: qualityCardVisible ? 0 : 28)
                .opacity(qualityCardVisible ? 1 : 0)
                .disabled(!qualityCardVisible)
                .allowsHitTesting(qualityCardVisible)
                .accessibilityHidden(!qualityCardVisible)
                .zIndex(4)

            if viewportSettings.isPresented,
               !effectiveLoading,
               effectiveFailure == nil,
               !isBackgrounded,
               playerHasStream {
                VideoViewportSettingsView(settings: viewportSettings) {
                    closeViewportPanel(returnToMenu: menuVisible)
                }
                .zIndex(5)
            }
        }
        .background(.black)
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            if isBackgrounded {
                resumePlaybackFromBackground()
            } else {
                store.load(address: item.address, channelID: item.channelID)
            }
            updateContinuousDisplay()
        }
        .onDisappear {
            hasAppeared = false
            viewportSettings.close()
            onContinuousDisplayChanged(false)
            if !isBackgrounded && !isClosing {
                store.stop()
#if canImport(TVVLCKit)
                controller.stop()
#endif
            }
        }
        .onExitCommand(perform: handleExitCommand)
#if canImport(UIKit)
        // UIApplication notifications are the primary lifecycle boundary on
        // tvOS.  scenePhase below is only a fallback for delayed transitions.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            suspendPlaybackForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            suspendPlaybackForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            resumePlaybackFromBackground()
        }
#endif
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
#if canImport(UIKit)
                guard UIApplication.shared.applicationState != .active else { return }
#endif
                suspendPlaybackForBackground()
            } else {
                resumePlaybackFromBackground()
            }
        }
        .onChange(of: store.isLoading, initial: true) { _, loading in
            if effectiveFailure != nil {
                viewportSettings.close()
                focus = .retry
            } else if loading {
                viewportSettings.close()
                qualityCardRequested = false
                menuVisible = false
                focus = .loadingClose
            } else if store.awaitingQualitySelection {
                viewportSettings.close()
                qualityCardRequested = false
                menuVisible = false
                focus = .qualityPrompt
            } else if !effectiveLoading, playerHasStream {
                focus = .surface
            }
            updateContinuousDisplay()
        }
        .onChange(of: store.error) { _, newError in
            guard newError != nil else { return }
            viewportSettings.close()
            qualityCardRequested = false
            menuVisible = false
#if canImport(TVVLCKit)
            if displayedURL != nil, controller.failure == nil {
                // Keep a failed HLS/TS decoder from continuing in the
                // background while the error action waits for the user.
                controller.suspendForBackground()
                controllerSuspended = true
            }
#endif
            focus = .retry
            updateContinuousDisplay()
        }
        .onChange(of: store.stream) { _, newStream in
            guard newStream == nil else { return }
            viewportSettings.close()
            // A new address/load has no playable stream.  Do not leave the
            // old native surface visible behind a connection error.
            guard displayedURL != nil else { return }
            displayedURL = nil
            controllerSuspended = false
#if canImport(TVVLCKit)
            controller.stop()
#endif
        }
        .onChange(of: store.streamRevision) { _, _ in
            guard let stream = store.stream else { return }
            viewportSettings.close()
            let oldURL = displayedURL
            let wasControllerSuspended = controllerSuspended
            displayedURL = stream.url
            menuVisible = false
            qualityCardRequested = false
#if canImport(TVVLCKit)
            if wasControllerSuspended {
                // Background resume may return a new HLS URL.  Resume the
                // controller first, then immediately replace its old URL
                // when necessary.  The controller's generation guard drops
                // the old pending load.
                controller.resumeFromBackground()
                controller.load(stream.url)
            } else if oldURL != nil, oldURL == stream.url {
                // A TS retry has the same URL.  Force the native controller
                // through its fresh-media path instead of relying on
                // VLCVideo.updateUIView, whose URL equality guard is
                // intentional during ordinary SwiftUI updates.
                controller.retry()
            }
            if controller.isPaused {
                store.stopKeepAlive()
            }
#endif
            controllerSuspended = false
            if effectiveLoading {
                focus = .loadingClose
            } else if effectiveFailure != nil {
                focus = .retry
            } else if oldURL != stream.url || wasControllerSuspended {
                focus = .surface
            }
            updateContinuousDisplay()
        }
#if canImport(TVVLCKit)
        .onChange(of: controller.isLoading, initial: true) { _, loading in
            if effectiveFailure != nil {
                viewportSettings.close()
                // Suspending a failed decoder can publish loading after
                // the error actions have appeared.  Keep their focus rather
                // than targeting a loading button that is no longer shown.
                focus = .retry
            } else if loading {
                viewportSettings.close()
                qualityCardRequested = false
                menuVisible = false
                focus = .loadingClose
            } else if !effectiveLoading, playerHasStream {
                focus = .surface
            }
            updateContinuousDisplay()
        }
        .onChange(of: controller.failure) { _, newFailure in
            guard newFailure != nil else {
                updateContinuousDisplay()
                return
            }
            viewportSettings.close()
            store.stopKeepAlive()
            qualityCardRequested = false
            menuVisible = false
            focus = effectiveFailure == nil ? .loadingClose : .retry
            updateContinuousDisplay()
        }
        .onChange(of: controller.isPaused) { _, _ in
            updateContinuousDisplay()
        }
#endif
        .onChange(of: item.id) { _, _ in
            viewportSettings.reset()
            menuVisible = false
            qualityCardRequested = false
            focus = nil
        }
        .onChange(of: qualityCardRequested) { _, requested in
            guard requested, !effectiveLoading, effectiveFailure == nil else { return }
            focus = .qualityChoice(selectedQualityIndex)
        }
        .onChange(of: needsContinuousDisplay, initial: true) { _, needed in
            onContinuousDisplayChanged(needed)
        }
#if canImport(TVVLCKit)
        .onPlayPauseCommand {
            guard !viewportSettings.isPresented,
                  effectiveFailure == nil,
                  displayedURL != nil else { return }
            togglePause()
        }
#endif
    }

    private var selectedQualityIndex: Int {
        guard let selected = store.selectedQuality,
              let index = store.qualities.firstIndex(where: { $0.id == selected.id }) else {
            return 0
        }
        return index
    }

#if canImport(TVVLCKit)
    private var playerSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .focusable(
                playerHasStream && !effectiveLoading && effectiveFailure == nil && !menuIsVisible && !qualityCardVisible && !viewportSettings.isPresented,
                interactions: .activate
            )
            .focusEffectDisabled()
            .focused($focus, equals: .surface)
            .allowsHitTesting(playerHasStream && !effectiveLoading && effectiveFailure == nil && !menuIsVisible && !qualityCardVisible && !viewportSettings.isPresented)
            .accessibilityHidden(!playerHasStream || effectiveLoading || effectiveFailure != nil || menuIsVisible || qualityCardVisible || viewportSettings.isPresented)
            .accessibilityLabel("EPGStationライブ再生")
            .onMoveCommand { direction in
                guard playerHasStream,
                      !effectiveLoading,
                      effectiveFailure == nil,
                      !viewportSettings.isPresented else { return }
                switch direction {
                case .up, .down:
                    showMenu()
                default:
                    break
                }
            }
            .onTapGesture { showMenu() }
    }
#else
    private var unavailableView: some View {
        VStack(spacing: 16) {
            Text("TS再生ライブラリが必要です")
                .font(.headline)
            Text("TVVLCKitを導入してビルドしてください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
#endif

    private var controlsOverlay: some View {
        VStack(spacing: 16) {
            Text(item.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 24) {
#if canImport(TVVLCKit)
                Button(controller.isPaused ? "再生" : "一時停止") {
                    togglePause()
                }
                .focused($focus, equals: .playPause)
#endif

                if store.qualities.count > 1 {
                    Button(qualityButtonTitle) {
                        showQualityCard()
                    }
                    .focused($focus, equals: .quality)
                    .disabled(effectiveLoading || effectiveFailure != nil)
                    .accessibilityLabel("画質を選択")
                }

                Button("画面", action: openViewportPanel)
                    .focused($focus, equals: .viewport)
                    .disabled(effectiveLoading || effectiveFailure != nil || !playerHasStream)

                Button("閉じる", action: close)
                    .focused($focus, equals: .menuClose)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.86))
        .focusSection()
        .onMoveCommand { direction in
            switch direction {
            case .down:
                hideMenu()
            default:
                break
            }
        }
    }

    private var qualityButtonTitle: String {
        guard let selected = store.selectedQuality else { return "画質" }
        return "画質: \(selected.name)"
    }

    private var qualityPrompt: some View {
        VStack(spacing: 20) {
            Text("画質を選択してください")
                .font(.title2)
            Text("無変換の配信が設定されていないため、自動でエンコードを開始しません。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button("画質を選択", action: showQualityCard)
                    .focused($focus, equals: .qualityPrompt)
                Button("閉じる", action: close)
                    .focused($focus, equals: .qualityClose)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.96))
        .focusSection()
        .defaultFocus($focus, .qualityPrompt)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 18) {
            ProgressView()
            Text("読み込み中…")
                .font(.headline)
            Text(item.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button("閉じる", action: close)
                .focused($focus, equals: .loadingClose)
                .padding(.top, 12)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .focusSection()
        .defaultFocus($focus, .loadingClose)
    }

    private func failureOverlay(message: String) -> some View {
        VStack(spacing: 18) {
            Text("再生できません")
                .font(.title2)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            HStack(spacing: 24) {
                Button("再試行") {
                    qualityCardRequested = false
                    menuVisible = false
#if canImport(TVVLCKit)
                    if displayedURL != nil {
                        controller.prepareQualityChange()
                    }
#endif
                    store.retry()
                }
                .focused($focus, equals: .retry)
                Button("閉じる", action: close)
                    .focused($focus, equals: .failureClose)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .focusSection()
        .defaultFocus($focus, .retry)
    }

    private var qualityCard: some View {
        GeometryReader { geometry in
            qualityCardContents(scrollHeight: max(100, min(560, geometry.size.height - 320)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func qualityCardContents(scrollHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("画質")
                .font(.title2)
            Text("視聴する配信を選択")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(store.qualities.enumerated()), id: \.offset) { index, quality in
                            Button {
                                selectQuality(quality)
                            } label: {
                                HStack(spacing: 14) {
                                    Text(quality.id == store.selectedQuality?.id ? "✓" : "")
                                        .frame(width: 24)
                                    Text(quality.name).lineLimit(2)
                                    Spacer(minLength: 16)
                                    Text(quality.format.rawValue.uppercased())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .focused($focus, equals: .qualityChoice(index))
                            .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: scrollHeight)
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo(selectedQualityIndex, anchor: .center)
                }
                .onChange(of: focus) { _, target in
                    guard let target,
                          case let .qualityChoice(index) = target else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }

            Button("戻る") {
                closeQualityCard()
            }
            .focused($focus, equals: .qualityClose)
        }
        .padding(42)
        .frame(minWidth: 520, maxWidth: 700)
        .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 20))
        .focusSection()
        .defaultFocus($focus, .qualityChoice(selectedQualityIndex), priority: .userInitiated)
    }

    private func showMenu() {
        guard playerHasStream,
              !effectiveLoading,
              effectiveFailure == nil,
              !viewportSettings.isPresented else { return }
        qualityCardRequested = false
        menuVisible = true
#if canImport(TVVLCKit)
        focus = .playPause
#else
        focus = .menuClose
#endif
    }

    private func hideMenu() {
        menuVisible = false
        focus = .surface
    }

    private func showQualityCard() {
        guard !store.qualities.isEmpty,
              !effectiveLoading,
              effectiveFailure == nil,
              !viewportSettings.isPresented else { return }
        focus = nil
        qualityCardRequested = true
    }

    private func closeQualityCard() {
        qualityCardRequested = false
        focus = store.awaitingQualitySelection ? .qualityPrompt : .quality
    }

    private func openViewportPanel() {
        guard menuIsVisible,
              playerHasStream,
              !effectiveLoading,
              effectiveFailure == nil else { return }
        qualityCardRequested = false
        viewportSettings.open()
        focus = nil
    }

    private func closeViewportPanel(returnToMenu: Bool) {
        viewportSettings.close()
        guard returnToMenu,
              playerHasStream,
              !effectiveLoading,
              effectiveFailure == nil else {
            focus = .surface
            return
        }
        focus = .viewport
    }

    private func selectQuality(_ quality: EPGStationLiveQuality) {
        if store.selectedQuality?.id == quality.id, store.stream != nil, store.error == nil {
            closeQualityCard()
            return
        }
        viewportSettings.close()
        qualityCardRequested = false
        menuVisible = false
#if canImport(TVVLCKit)
        if displayedURL != nil {
            controller.prepareQualityChange()
        }
#endif
        store.selectQuality(quality)
        focus = store.isLoading ? .loadingClose : .surface
    }

#if canImport(TVVLCKit)
    private func togglePause() {
        guard !effectiveLoading, effectiveFailure == nil, displayedURL != nil else { return }
        if controller.isPaused,
           let selectedQuality = store.selectedQuality,
           selectedQuality.format == .hls {
            // Clear the native pause intent while the old HLS media is
            // gated, then obtain a fresh server-side stream before loading
            // its new playlist URL.  TS playback keeps the controller's
            // existing live reconnect path.
            controller.prepareQualityChange()
            controller.togglePause()
            store.refreshSelectedQuality()
        } else {
            controller.togglePause()
            if controller.isPaused {
                store.stopKeepAlive()
            }
        }
        updateContinuousDisplay()
    }
#endif

    private func handleExitCommand() {
        // One Menu press performs exactly one transition: card -> panel,
        // panel -> surface, surface -> dismiss.
        if viewportSettings.isPresented {
            closeViewportPanel(returnToMenu: menuVisible)
        } else if qualityCardVisible {
            closeQualityCard()
        } else if menuIsVisible {
            hideMenu()
        } else if store.awaitingQualitySelection {
            close()
        } else {
            close()
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        qualityCardRequested = false
        menuVisible = false
        viewportSettings.close()
        onContinuousDisplayChanged(false)
        store.stop()
#if canImport(TVVLCKit)
        controller.stop()
#endif
        dismiss()
    }

    private func updateContinuousDisplay() {
        onContinuousDisplayChanged(needsContinuousDisplay)
    }

    private func suspendPlaybackForBackground() {
        guard hasAppeared, !isClosing, !isBackgrounded else { return }
        isBackgrounded = true
        viewportSettings.close()
        qualityCardRequested = false
        menuVisible = false
        let canSuspendController = displayedURL != nil && effectiveFailure == nil
        store.suspendForBackground()
#if canImport(TVVLCKit)
        if canSuspendController {
            controller.suspendForBackground()
            controllerSuspended = true
        }
#endif
        updateContinuousDisplay()
    }

    private func resumePlaybackFromBackground() {
#if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
#endif
        guard hasAppeared, isBackgrounded, !isClosing else { return }
        isBackgrounded = false
        store.resumeFromBackground()
        updateContinuousDisplay()
    }
}
