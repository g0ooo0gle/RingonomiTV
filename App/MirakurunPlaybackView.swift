import SwiftUI
import RingonomiCore
#if canImport(UIKit)
import UIKit
#endif

struct MirakurunPlaybackSelection: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

private enum MirakurunPlaybackFocus: Hashable {
    case surface
    case playPause
    case audio
    case viewport
    case miniPlayer
    case menuClose
    case loadingClose
    case failureClose
    case retry
}

/// A small in-player surface for a raw Mirakurun transport stream.
///
/// This view intentionally does not create a `Playback` or a `RingonomiClient`.
/// Mirakurun has no KonomiTV session, quality route, or keep-alive operation;
/// its service stream is handed directly to the existing VLC controller.
struct MirakurunPlaybackView: View {
    let item: MirakurunPlaybackSelection
    let closeRequest: UUID?
    let restoreRequest: UUID?
    let togglePauseRequest: UInt64
    let isMiniPlayer: Bool
    let onMiniPlayerChanged: (Bool) -> Void
    let onCloseStarted: () -> UUID?
    let onClose: (UUID, Bool) -> Void
    let onNoticeChanged: (String?) -> Void
    let onTransportChanged: (PlaybackTransportState) -> Void
    let onContinuousDisplayChanged: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focus: MirakurunPlaybackFocus?
    @State private var menuVisible = false
    @State private var hasAppeared = false
    @State private var isClosing = false
    @State private var closeFailure: String?
    @State private var closeTask: Task<Void, Never>?
    @StateObject private var viewportSettings = VideoViewportSettings()
#if canImport(TVVLCKit)
    @StateObject private var controller = PlaybackController()
#endif

#if canImport(TVVLCKit)
    private var isLoading: Bool { controller.isLoading }
    private var failure: String? { controller.failure ?? closeFailure }
    private var needsContinuousDisplay: Bool {
        failure == nil && !isClosing && !controller.isPaused
    }
#else
    private var isLoading: Bool { true }
    private var failure: String? { nil }
    private var needsContinuousDisplay: Bool { false }
#endif

    private var isMenuVisible: Bool {
        acceptsInlineInput && menuVisible && !isLoading && failure == nil
            && !viewportSettings.isPresented
    }

    private var acceptsInlineInput: Bool { !isMiniPlayer && !isClosing }
    private var readyFocus: MirakurunPlaybackFocus {
        failure != nil ? .retry : (isLoading ? .loadingClose : .surface)
    }
#if canImport(TVVLCKit)
    private var transport: PlaybackTransportState {
        PlaybackTransportState(isPaused: controller.isPaused,
                               canToggle: hasAppeared && isMiniPlayer && !isClosing && !isLoading && failure == nil)
    }
    private var playbackNotice: String? {
        isMiniPlayer ? failure ?? (isLoading ? "映像と音声を準備しています…" : nil) : nil
    }
#endif

    var body: some View {
        ZStack {
#if canImport(TVVLCKit)
            VideoViewportMedia(crop: viewportSettings.crop, videoRect: controller.videoRect) {
                VLCVideo(url: item.url, controller: controller)
                    .ignoresSafeArea()
            }
            surface
            controlsOverlay
                .offset(y: isMenuVisible ? 0 : 320)
                .opacity(isMenuVisible ? 1 : 0)
                .disabled(!isMenuVisible)
                .allowsHitTesting(isMenuVisible)
                .accessibilityHidden(!isMenuVisible)
                .zIndex(1)
            if isClosing {
                VStack(spacing: 20) {
                    ProgressView("再生を終了しています…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            } else if let failure {
                failureOverlay(message: failure)
            } else if isLoading {
                loadingOverlay
            }
            if viewportSettings.isPresented {
                VideoViewportSettingsView(
                    settings: viewportSettings,
                    onClose: closeViewport
                )
                .zIndex(5)
            }
#else
            VStack(spacing: 24) {
                Text("TS再生ライブラリが必要です")
                Text("TVVLCKitを導入してビルドしてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
#endif
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
        .tint(.cyan)
        .onAppear {
            hasAppeared = true
            updateContinuousDisplay()
        }
        .onDisappear {
            hasAppeared = false
            closeTask?.cancel()
            closeTask = nil
            viewportSettings.close()
            onContinuousDisplayChanged(false)
        }
        .onExitCommand(perform: handleExitCommand)
        .onChange(of: closeRequest, initial: true) { _, request in
            if request != nil { close() }
        }
        .onChange(of: isMiniPlayer) { _, mini in
            viewportSettings.close()
            menuVisible = false
            focus = !mini && !isClosing ? readyFocus : nil
#if DEBUG
            print("RingonomiMirakurunMini: active=\(mini)")
#endif
        }
        .onChange(of: restoreRequest) { _, request in
            guard request != nil, closeRequest == nil, acceptsInlineInput else { return }
            focus = readyFocus
        }
#if canImport(UIKit)
        // UIApplication notifications are the primary lifecycle boundary on
        // tvOS. scenePhase remains a fallback for delayed Home transitions.
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
#if canImport(TVVLCKit)
        .onChange(of: controller.isLoading, initial: true) { _, loading in
            if loading {
                viewportSettings.close()
                menuVisible = false
                focus = acceptsInlineInput ? .loadingClose : nil
            } else if failure == nil {
                focus = acceptsInlineInput ? .surface : nil
            }
            updateContinuousDisplay()
        }
        .onChange(of: failure) { _, newFailure in
            if newFailure != nil {
                viewportSettings.close()
            }
            menuVisible = false
            if newFailure != nil, isMiniPlayer { onMiniPlayerChanged(false) }
            focus = acceptsInlineInput ? readyFocus : nil
            updateContinuousDisplay()
        }
        .onChange(of: controller.isPaused) { _, _ in
            updateContinuousDisplay()
        }
        .onChange(of: transport, initial: true) { _, value in onTransportChanged(value) }
        .onChange(of: playbackNotice, initial: true) { _, value in onNoticeChanged(value) }
        .onChange(of: togglePauseRequest) { previous, current in
            guard isMiniPlayer, !isClosing, failure == nil,
                  !(current &- previous).isMultiple(of: 2) else { return }
            controller.togglePause()
        }
        .onChange(of: controller.audioOptions) { _, options in
            if isMenuVisible, options.count < 2, focus == .audio || focus == nil {
                focus = .playPause
            }
        }
#endif
        .onChange(of: item.id) { _, _ in
            viewportSettings.reset()
            viewportSettings.close()
        }
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
#if canImport(TVVLCKit)
        .onPlayPauseCommand {
            guard acceptsInlineInput, failure == nil, !viewportSettings.isPresented else { return }
            controller.togglePause()
        }
#endif
    }

#if canImport(TVVLCKit)
    private var surface: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .focusable(
                acceptsInlineInput && !isLoading && failure == nil && !isMenuVisible && !viewportSettings.isPresented,
                interactions: .activate
            )
            .focusEffectDisabled()
            .focused($focus, equals: .surface)
            .allowsHitTesting(
                acceptsInlineInput && !isLoading && failure == nil && !isMenuVisible && !viewportSettings.isPresented
            )
            .accessibilityHidden(
                !acceptsInlineInput || isLoading || failure != nil || isMenuVisible || viewportSettings.isPresented
            )
            .accessibilityLabel("Mirakurun再生メニュー")
            .onMoveCommand { direction in
                guard acceptsInlineInput, !isLoading, failure == nil, !viewportSettings.isPresented else { return }
                switch direction {
                case .up, .down:
                    showMenu()
                default:
                    break
                }
            }
            .onTapGesture { showMenu() }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("読み込み中…")
                .font(.headline)
            Text(item.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(.black)
        .focusSection()
        .defaultFocus($focus, .loadingClose)
        .overlay(alignment: .bottom) {
            Button("閉じる", action: close)
                .focused($focus, equals: .loadingClose)
                .padding(.bottom, 48)
        }
    }

    private var controlsOverlay: some View {
        VStack(spacing: 16) {
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 24) {
                Button(controller.isPaused ? "再生" : "一時停止") {
                    controller.togglePause()
                }
                .focused($focus, equals: .playPause)

                if controller.audioOptions.count > 1 {
                    PlaybackAudioMenu(options: controller.audioOptions,
                                      selectedID: controller.selectedAudioID,
                                      isDisabled: isLoading || failure != nil,
                                      onSelect: { controller.selectAudioTrack(id: $0) })
                    .focused($focus, equals: .audio)
                }

                Button("画面調整", action: openViewport)
                    .focused($focus, equals: .viewport)
                    .disabled(isLoading || failure != nil)

                Button("小窓") { onMiniPlayerChanged(true) }
                    .focused($focus, equals: .miniPlayer)
                    .disabled(isLoading || failure != nil || isClosing)
                    .accessibilityLabel("アプリ内小窓で表示")
                    .accessibilityIdentifier("mirakurun.miniPlayer")

                Button("閉じる", action: close)
                    .focused($focus, equals: .menuClose)
            }
            if let audioSelectionError = controller.audioSelectionError {
                Text(audioSelectionError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.84))
        .focusSection()
        .onMoveCommand { direction in
            switch direction {
            case .down:
                hideMenu()
            case .up:
                break
            default:
                break
            }
        }
    }

    private func failureOverlay(message: String) -> some View {
        VStack(spacing: 18) {
            Text("再生できません")
                .font(.title2)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button("再試行") {
                    menuVisible = false
                    focus = .surface
                    if closeFailure != nil { close() }
                    else { controller.retry() }
                }
                .focused($focus, equals: .retry)
                Button("閉じる", action: close)
                    .focused($focus, equals: .failureClose)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.9))
        .focusSection()
        .defaultFocus($focus, .retry)
    }

    private func showMenu() {
        guard acceptsInlineInput, !isLoading, failure == nil, !viewportSettings.isPresented else { return }
        menuVisible = true
        focus = .playPause
    }

    private func hideMenu() {
        menuVisible = false
        focus = .surface
    }

    private func handleExitCommand() {
        guard acceptsInlineInput else { return }
        if viewportSettings.isPresented {
            closeViewport()
            return
        }
        if isMenuVisible {
            hideMenu()
        } else {
            close()
        }
    }

    private func close() {
        guard !isClosing, let request = onCloseStarted() else { return }
        isClosing = true
        menuVisible = false
        focus = nil
        viewportSettings.close()
        onContinuousDisplayChanged(false)
        closeTask = Task { @MainActor in
            let stopped = await controller.stopBeforeClosing()
            guard !Task.isCancelled else { onClose(request, false); return }
#if DEBUG
            print("RingonomiMirakurunClose: stopped=\(stopped)")
#endif
            if !stopped {
                isClosing = false
                closeFailure = "再生の終了を確認できませんでした。もう一度閉じてください。"
            }
            onClose(request, stopped)
            if !stopped { onMiniPlayerChanged(false) }
            closeTask = nil
        }
    }

    private func openViewport() {
        guard acceptsInlineInput, !isLoading, failure == nil else { return }
        viewportSettings.open()
        focus = nil
    }

    private func closeViewport() {
        viewportSettings.close()
        guard !isLoading, failure == nil else { return }
        if menuVisible {
            focus = .viewport
        }
    }

    private func updateContinuousDisplay() {
        onContinuousDisplayChanged(hasAppeared && needsContinuousDisplay)
    }

    private func suspendPlaybackForBackground() {
        guard hasAppeared, !isClosing else { return }
        viewportSettings.close()
        controller.suspendForBackground()
    }

    private func resumePlaybackFromBackground() {
#if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
#endif
        guard hasAppeared, !isClosing else { return }
        controller.resumeFromBackground()
    }
#else
    private func updateContinuousDisplay() {}
    private func suspendPlaybackForBackground() {}
    private func resumePlaybackFromBackground() {}
    private func close() {
        guard let request = onCloseStarted() else { return }
        onClose(request, true)
    }
    private func handleExitCommand() { close() }
#endif
}
