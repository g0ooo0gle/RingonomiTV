import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

private enum FilePlaybackFocus: Hashable {
    case surface
    case seek
    case backward
    case forward
    case playPause
    case audio
    case topClose
    case retry
    case loadingClose
    case failureClose
}

private enum FilePlaybackPanel: Equatable {
    case top
    case bottom
}

/// A tvOS playback screen for a direct file/HTTP media resource.
struct FilePlaybackView: View {
    let item: FilePlaybackSelection
    let onContinuousDisplayChanged: (Bool) -> Void
    let onProgress: (Double, Double?, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var visiblePanel: FilePlaybackPanel?
    @State private var isSeeking = false
    @State private var seekDraft = 0.0
    @FocusState private var playbackFocus: FilePlaybackFocus?

#if canImport(TVVLCKit)
    @StateObject private var controller: VLCFilePlaybackController
#endif

    init(
        item: FilePlaybackSelection,
        onContinuousDisplayChanged: @escaping (Bool) -> Void = { _ in },
        onProgress: @escaping (Double, Double?, Bool) -> Void = { _, _, _ in }
    ) {
        self.item = item
        self.onContinuousDisplayChanged = onContinuousDisplayChanged
        self.onProgress = onProgress
#if canImport(TVVLCKit)
        _controller = StateObject(wrappedValue: VLCFilePlaybackController())
#endif
    }

    var body: some View {
#if canImport(TVVLCKit)
        playerBody
            .onAppear {
                hasAppeared = true
                startPlayback()
            }
#if canImport(UIKit)
            // UIApplication notifications are the primary lifecycle boundary
            // on tvOS. scenePhase remains a fallback because it can lag during
            // a Home transition on some Apple TV releases.
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
            .onChange(of: item) { _, newItem in
                controller.start(
                    item: newItem,
                    onContinuousDisplayChanged: onContinuousDisplayChanged,
                    onProgress: onProgress
                )
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
#if canImport(UIKit)
                    // Ignore a delayed scene update after UIKit already
                    // reported that the application became active.
                    guard UIApplication.shared.applicationState != .active else { return }
#endif
                    suspendPlaybackForBackground()
                } else {
                    resumePlaybackFromBackground()
                }
            }
            .onDisappear {
                hasAppeared = false
                onContinuousDisplayChanged(false)
                controller.stop()
            }
#else
        VStack(spacing: 20) {
            Text("ファイル再生にはTVVLCKitが必要です")
            Text(item.title).lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
#endif
    }

#if canImport(TVVLCKit)
    private var playerBody: some View {
        ZStack {
            NativeFilePlaybackVideo(url: item.url, controller: controller)
                .ignoresSafeArea()

            // The surface is a focus target only while the controls are
            // hidden and playback is ready.  It is not a full-screen Button;
            // this keeps Select/arrow routing separate from the panels.
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .focusable(surfaceIsFocusable, interactions: .activate)
                .focusEffectDisabled(true)
                .focused($playbackFocus, equals: .surface)
                .allowsHitTesting(surfaceIsFocusable)
                .onMoveCommand {
#if DEBUG
                    print("RingonomiFileSurfaceMove: direction=\(String(describing: $0)) focus=\(String(describing: playbackFocus)) panel=\(String(describing: visiblePanel)) loading=\(controller.isLoading) failure=\(controller.failure != nil)")
#endif
                    handleSurfaceMove($0)
                }
                .onTapGesture {
#if DEBUG
                    print("RingonomiFileSurfaceSelect: focus=\(String(describing: playbackFocus)) panel=\(String(describing: visiblePanel)) focusable=\(surfaceIsFocusable) loading=\(controller.isLoading) failure=\(controller.failure != nil)")
#endif
                    revealBottomPanel()
                }
                .accessibilityLabel("再生メニュー")
                .accessibilityHidden(!surfaceIsFocusable)

            if controller.isLoading || controller.failure != nil {
                loadingOrFailureOverlay
            }

            topPanel
                .offset(y: panelIsVisible(.top) || reduceMotion ? 0 : -320)
                .opacity(panelIsVisible(.top) ? 1 : 0)
                .disabled(!panelIsVisible(.top))
                .allowsHitTesting(panelIsVisible(.top))
                .accessibilityHidden(!panelIsVisible(.top))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            bottomPanel
                .offset(y: panelIsVisible(.bottom) || reduceMotion ? 0 : 320)
                .opacity(panelIsVisible(.bottom) ? 1 : 0)
                .disabled(!panelIsVisible(.bottom))
                .allowsHitTesting(panelIsVisible(.bottom))
                .accessibilityHidden(!panelIsVisible(.bottom))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .defaultFocus($playbackFocus, .surface)
        .onExitCommand {
#if DEBUG
            print("RingonomiFileExit: focus=\(String(describing: playbackFocus)) panel=\(String(describing: visiblePanel)) loading=\(controller.isLoading) failure=\(controller.failure != nil)")
#endif
            handleExitCommand()
        }
        .onPlayPauseCommand { controller.togglePause() }
        .onChange(of: controller.isLoading, initial: true) { _, loading in
            if loading {
                isSeeking = false
                visiblePanel = nil
                playbackFocus = controller.failure == nil ? .loadingClose : .retry
            } else if controller.failure == nil {
                if controller.isEnded {
                    isSeeking = false
                    setPanel(.bottom)
                    playbackFocus = .playPause
                } else if visiblePanel == nil {
                    playbackFocus = .surface
                }
            }
        }
        .onChange(of: controller.failure, initial: true) { _, failure in
            if failure != nil {
                isSeeking = false
                visiblePanel = nil
                playbackFocus = .retry
            } else if !controller.isLoading, visiblePanel == nil {
                playbackFocus = .surface
            }
        }
        .onChange(of: controller.isEnded, initial: true) { _, ended in
            guard ended, !controller.isLoading, controller.failure == nil else { return }
            isSeeking = false
            setPanel(.bottom)
            playbackFocus = .playPause
        }
        .onChange(of: visiblePanel) { _, panel in
#if DEBUG
            print("RingonomiFilePanel: panel=\(String(describing: panel)) focus=\(String(describing: playbackFocus)) loading=\(controller.isLoading) failure=\(controller.failure != nil)")
#endif
            guard let panel, !controller.isLoading, controller.failure == nil else { return }
            playbackFocus = focusForPanel(panel)
        }
        .onChange(of: playbackFocus) { _, focus in
#if DEBUG
            print("RingonomiFileFocus: focus=\(String(describing: focus)) panel=\(String(describing: visiblePanel)) loading=\(controller.isLoading) failure=\(controller.failure != nil)")
#endif
        }
        .onChange(of: controller.durationSeconds) { _, duration in
            guard isSeeking, let duration, duration.isFinite, duration > 0 else { return }
            seekDraft = min(max(0, seekDraft), max(0, duration - 0.1))
        }
    }

    private var surfaceIsFocusable: Bool {
        visiblePanel == nil && !controller.isLoading && controller.failure == nil
    }

    private var loadingOrFailureOverlay: some View {
        VStack(spacing: 24) {
            if controller.isLoading {
                ProgressView().scaleEffect(1.5)
                Text("映像と音声を準備しています…")
            }
            if let failure = controller.failure {
                Text(failure)
                    .multilineTextAlignment(.center)
                HStack(spacing: 24) {
                    Button("再試行") { controller.retry() }
                        .focused($playbackFocus, equals: .retry)
                    Button("閉じる", action: close)
                        .focused($playbackFocus, equals: .failureClose)
                }
            } else {
                Button("閉じる", action: close)
                    .focused($playbackFocus, equals: .loadingClose)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .zIndex(2)
    }

    private var topPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 18) {
                Text(controller.status)
                    .font(.caption)
                if controller.audioOptions.count > 1 {
                    Menu("音声") {
                        ForEach(controller.audioOptions) { option in
                            Button(option.id == controller.selectedAudioID ? "✓ \(option.name)" : option.name) {
                                controller.selectAudioTrack(id: option.id)
                            }
                        }
                    }
                    .focused($playbackFocus, equals: .audio)
                    .disabled(controller.isLoading || controller.failure != nil)
                }
                Button("閉じる", action: close)
                    .focused($playbackFocus, equals: .topClose)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.86))
        .focusSection()
        .onMoveCommand { direction in
#if DEBUG
            print("RingonomiFileTopMove: direction=\(String(describing: direction)) focus=\(String(describing: playbackFocus)) panel=\(String(describing: visiblePanel))")
#endif
            guard panelIsVisible(.top) else { return }
            if direction == .down { revealBottomPanel() }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 16) {
            if let duration = controller.durationSeconds, duration > 0, controller.isSeekable {
                Button(action: toggleSeekEditing) {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: displayedSeekPosition, total: duration)
                        Text("\(timestamp(displayedSeekPosition)) / \(timestamp(duration))\(isSeeking ? "  （左右で移動、選択で確定）" : "")")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focused($playbackFocus, equals: .seek)
                .disabled(controller.isLoading || controller.failure != nil)
                .onMoveCommand { direction in
#if DEBUG
                    print("RingonomiFileSeekMove: direction=\(String(describing: direction)) focus=\(String(describing: playbackFocus)) panel=\(String(describing: visiblePanel)) seeking=\(isSeeking) canSeek=\(controller.canSeek)")
#endif
                    guard controller.canSeek else { return }
                    switch direction {
                    case .left:
                        if !isSeeking {
                            seekDraft = controller.currentSeconds
                            isSeeking = true
                        }
                        adjustSeek(-10)
                    case .right:
                        if !isSeeking {
                            seekDraft = controller.currentSeconds
                            isSeeking = true
                        }
                        adjustSeek(10)
                    case .up:
                        revealTopPanel()
                    case .down:
                        isSeeking = false
                        playbackFocus = .backward
                    default:
                        break
                    }
                }
            } else if controller.durationSeconds != nil {
                Text("このファイルはシークに対応していません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("再生時間を取得しています…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            bottomOperationRow
        }
        .padding(36)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.86))
        .focusSection()
    }

    private var bottomOperationRow: some View {
        HStack(spacing: 22) {
            Button("1分戻る") { controller.seek(seconds: -60) }
                .focused($playbackFocus, equals: .backward)
                .disabled(!controller.canSeek)
            Button("3分進む") { controller.seek(seconds: 180) }
                .focused($playbackFocus, equals: .forward)
                .disabled(!controller.canSeek)
            Button(controller.isEnded ? "最初から再生" : (controller.isPaused ? "再生" : "一時停止")) {
                controller.togglePause()
            }
            .focused($playbackFocus, equals: .playPause)
            .disabled(controller.failure != nil)
        }
        .onMoveCommand { direction in
#if DEBUG
            print("RingonomiFileBottomMove: direction=\(String(describing: direction)) focus=\(String(describing: playbackFocus)) panel=\(String(describing: visiblePanel)) seeking=\(isSeeking) canSeek=\(controller.canSeek)")
#endif
            guard panelIsVisible(.bottom),
                  playbackFocus == .backward
                    || playbackFocus == .forward
                    || playbackFocus == .playPause else { return }
            switch direction {
            case .up:
                if controller.canSeek {
                    playbackFocus = .seek
                } else {
                    revealTopPanel()
                }
            case .down:
                hidePanel()
            default: break
            }
        }
    }

    private var displayedSeekPosition: Double {
        isSeeking ? seekDraft : controller.currentSeconds
    }

    private func startPlayback() {
        controller.start(
            item: item,
            onContinuousDisplayChanged: onContinuousDisplayChanged,
            onProgress: onProgress
        )
    }

    private func suspendPlaybackForBackground() {
        guard hasAppeared else { return }
        controller.suspendForBackground()
    }

    private func resumePlaybackFromBackground() {
#if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
#endif
        guard hasAppeared else { return }
        controller.resumeFromBackground()
    }

    private func focusForPanel(_ panel: FilePlaybackPanel) -> FilePlaybackFocus {
        switch panel {
        case .top:
            return controller.audioOptions.count > 1 ? .audio : .topClose
        case .bottom:
            if controller.isEnded { return .playPause }
            return controller.canSeek ? .seek : .playPause
        }
    }

    private func panelIsVisible(_ panel: FilePlaybackPanel) -> Bool {
        visiblePanel == panel && !controller.isLoading && controller.failure == nil
    }

    private func revealTopPanel() {
        setPanel(.top)
    }

    private func revealBottomPanel() {
        setPanel(.bottom)
    }

    private func setPanel(_ panel: FilePlaybackPanel) {
        isSeeking = false
        if reduceMotion {
            visiblePanel = panel
        } else {
            withAnimation(.easeOut(duration: 0.2)) { visiblePanel = panel }
        }
    }

    private func hidePanel() {
        isSeeking = false
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { visiblePanel = nil }
        if !controller.isLoading, controller.failure == nil {
            playbackFocus = .surface
        }
    }

    private func handleSurfaceMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .up: revealTopPanel()
        case .down: revealBottomPanel()
        default: break
        }
    }

    private func handleExitCommand() {
        if visiblePanel != nil {
            hidePanel()
        } else {
            close()
        }
    }

    private func toggleSeekEditing() {
        guard controller.canSeek else { return }
        guard isSeeking else { return }
        controller.seek(to: seekDraft)
        isSeeking = false
    }

    private func adjustSeek(_ delta: Double) {
        guard let duration = controller.durationSeconds else { return }
        seekDraft = min(max(0, seekDraft + delta), max(0, duration - 0.1))
    }

    private func close() {
        onContinuousDisplayChanged(false)
        visiblePanel = nil
        isSeeking = false
        controller.stop()
        dismiss()
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, min(seconds.isFinite ? seconds : 0, 100_000_000)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
#endif
}
