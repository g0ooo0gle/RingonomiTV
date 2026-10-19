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
    let onContinuousDisplayChanged: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focus: MirakurunPlaybackFocus?
    @State private var menuVisible = false
    @State private var hasAppeared = false
    @StateObject private var viewportSettings = VideoViewportSettings()
#if canImport(TVVLCKit)
    @StateObject private var controller = PlaybackController()
#endif

#if canImport(TVVLCKit)
    private var isLoading: Bool { controller.isLoading }
    private var failure: String? { controller.failure }
    private var needsContinuousDisplay: Bool {
        failure == nil && !controller.isPaused
    }
#else
    private var isLoading: Bool { true }
    private var failure: String? { nil }
    private var needsContinuousDisplay: Bool { false }
#endif

    private var isMenuVisible: Bool {
        menuVisible && !isLoading && failure == nil
            && !viewportSettings.isPresented
    }

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
            if isLoading {
                loadingOverlay
            } else if let failure {
                failureOverlay(message: failure)
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
        .onAppear {
            hasAppeared = true
            updateContinuousDisplay()
        }
        .onDisappear {
            hasAppeared = false
            viewportSettings.close()
            onContinuousDisplayChanged(false)
        }
        .onExitCommand(perform: handleExitCommand)
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
                focus = .loadingClose
            } else if failure == nil {
                focus = .surface
            }
            updateContinuousDisplay()
        }
        .onChange(of: controller.failure) { _, newFailure in
            if newFailure != nil {
                viewportSettings.close()
            }
            menuVisible = false
            focus = newFailure == nil ? .surface : .retry
            updateContinuousDisplay()
        }
        .onChange(of: controller.isPaused) { _, _ in
            updateContinuousDisplay()
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
            guard failure == nil, !viewportSettings.isPresented else { return }
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
                !isLoading && failure == nil && !isMenuVisible && !viewportSettings.isPresented,
                interactions: .activate
            )
            .focusEffectDisabled()
            .focused($focus, equals: .surface)
            .allowsHitTesting(
                !isLoading && failure == nil && !isMenuVisible && !viewportSettings.isPresented
            )
            .accessibilityHidden(
                isLoading || failure != nil || isMenuVisible || viewportSettings.isPresented
            )
            .accessibilityLabel("Mirakurun再生メニュー")
            .onMoveCommand { direction in
                guard !isLoading, failure == nil, !viewportSettings.isPresented else { return }
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
                    controller.retry()
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
        guard !isLoading, failure == nil, !viewportSettings.isPresented else { return }
        menuVisible = true
        focus = .playPause
    }

    private func hideMenu() {
        menuVisible = false
        focus = .surface
    }

    private func handleExitCommand() {
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
        viewportSettings.close()
        onContinuousDisplayChanged(false)
        dismiss()
    }

    private func openViewport() {
        guard !isLoading, failure == nil else { return }
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
        guard hasAppeared else { return }
        viewportSettings.close()
        controller.suspendForBackground()
    }

    private func resumePlaybackFromBackground() {
#if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
#endif
        guard hasAppeared else { return }
        controller.resumeFromBackground()
    }
#else
    private func updateContinuousDisplay() {}
    private func suspendPlaybackForBackground() {}
    private func resumePlaybackFromBackground() {}
    private func handleExitCommand() { dismiss() }
#endif
}
