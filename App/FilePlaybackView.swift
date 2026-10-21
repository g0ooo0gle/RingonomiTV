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
    case viewport
    case miniPlayer
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
    let closeRequest: UUID?
    let restoreRequest: UUID?
    let togglePauseRequest: UInt64
    let isMiniPlayer: Bool
    let onMiniPlayerChanged: ((Bool) -> Void)?
    let onCloseStarted: (() -> UUID?)?
    let onClose: ((UUID, Bool) -> Void)?
    let onNoticeChanged: (String?) -> Void
    let onTransportChanged: (PlaybackTransportState) -> Void
    let onContinuousDisplayChanged: (Bool) -> Void
    let onProgress: (Double, Double?, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var isClosing = false
    @State private var closeFailure: String?
    @State private var closeTask: Task<Void, Never>?
    @State private var visiblePanel: FilePlaybackPanel?
    @State private var isSeeking = false
    @State private var seekDraft = 0.0
    @StateObject private var viewportSettings = VideoViewportSettings()
    @FocusState private var playbackFocus: FilePlaybackFocus?

#if canImport(TVVLCKit)
    @StateObject private var controller: VLCFilePlaybackController
#endif

    init(
        item: FilePlaybackSelection,
        closeRequest: UUID? = nil,
        restoreRequest: UUID? = nil,
        togglePauseRequest: UInt64 = 0,
        isMiniPlayer: Bool = false,
        onMiniPlayerChanged: ((Bool) -> Void)? = nil,
        onCloseStarted: (() -> UUID?)? = nil,
        onClose: ((UUID, Bool) -> Void)? = nil,
        onNoticeChanged: @escaping (String?) -> Void = { _ in },
        onTransportChanged: @escaping (PlaybackTransportState) -> Void = { _ in },
        onContinuousDisplayChanged: @escaping (Bool) -> Void = { _ in },
        onProgress: @escaping (Double, Double?, Bool) -> Void = { _, _, _ in }
    ) {
        self.item = item
        self.closeRequest = closeRequest
        self.restoreRequest = restoreRequest
        self.togglePauseRequest = togglePauseRequest
        self.isMiniPlayer = isMiniPlayer
        self.onMiniPlayerChanged = onMiniPlayerChanged
        self.onCloseStarted = onCloseStarted
        self.onClose = onClose
        self.onNoticeChanged = onNoticeChanged
        self.onTransportChanged = onTransportChanged
        self.onContinuousDisplayChanged = onContinuousDisplayChanged
        self.onProgress = onProgress
#if canImport(TVVLCKit)
        _controller = StateObject(wrappedValue: VLCFilePlaybackController())
#endif
    }

    var body: some View {
#if canImport(TVVLCKit)
        playerBody
            .background(Color.black.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .tint(.cyan)
            .onAppear {
                hasAppeared = true
                // A cancelled close can outlive a temporary disappearance.
                // Recover only after the view is mounted, without restarting
                // its permanently closing decoder.
                if isClosing, closeTask == nil {
                    isClosing = false
                    closeFailure = "再生の終了を確認できませんでした。もう一度閉じてください。"
                    playbackFocus = .retry
                }
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
                guard !isClosing else { return }
                viewportSettings.reset()
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
                closeTask?.cancel()
                closeTask = nil
                viewportSettings.close()
                onContinuousDisplayChanged(false)
                controller.stop()
            }
#else
        VStack(spacing: 20) {
            Text("ファイル再生にはTVVLCKitが必要です")
            Text(item.title).lineLimit(2)
            Button("閉じる") {
                if let onCloseStarted, let request = onCloseStarted() { onClose?(request, true) }
                else { dismiss() }
            }
        }
        .onChange(of: closeRequest, initial: true) { _, request in
            if let request { onClose?(request, true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
#endif
    }

#if canImport(TVVLCKit)
    private var failure: String? { closeFailure ?? controller.failure }
    private var acceptsInlineInput: Bool { !isMiniPlayer && !isClosing }
    private var readyFocus: FilePlaybackFocus {
        failure != nil ? .retry : (controller.isLoading ? .loadingClose : .surface)
    }
    private var transport: PlaybackTransportState {
        PlaybackTransportState(isPaused: controller.isPaused || controller.isEnded,
            canToggle: hasAppeared && isMiniPlayer && !isClosing && !controller.isLoading && failure == nil)
    }
    private var playbackNotice: String? {
        isMiniPlayer ? failure ?? (controller.isLoading ? "映像と音声を準備しています…" : nil) : nil
    }

    private var playerBody: some View {
        ZStack {
            VideoViewportMedia(crop: viewportSettings.crop, videoRect: controller.videoRect) {
                NativeFilePlaybackVideo(url: item.url, controller: controller)
            }
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
                    print("RingonomiFileSurfaceMove: direction=\(String(describing: $0)) focus=\(String(describing: playbackFocus)) panel=\(String(describing: visiblePanel)) loading=\(controller.isLoading) failure=\(failure != nil)")
#endif
                    handleSurfaceMove($0)
                }
                .onTapGesture {
#if DEBUG
                    print("RingonomiFileSurfaceSelect: focus=\(String(describing: playbackFocus)) panel=\(String(describing: visiblePanel)) focusable=\(surfaceIsFocusable) loading=\(controller.isLoading) failure=\(failure != nil)")
#endif
                    revealBottomPanel()
                }
                .accessibilityLabel("再生メニュー")
                .accessibilityHidden(!surfaceIsFocusable)

            if isClosing {
                ProgressView("再生を終了しています…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .zIndex(3)
            } else if controller.isLoading || failure != nil {
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

            if viewportSettings.isPresented {
                VideoViewportSettingsView(
                    settings: viewportSettings,
                    onClose: closeViewport
                )
                .zIndex(5)
            }
        }
        .defaultFocus($playbackFocus, .surface)
        .onExitCommand {
#if DEBUG
            print("RingonomiFileExit: focus=\(String(describing: playbackFocus)) panel=\(String(describing: visiblePanel)) loading=\(controller.isLoading) failure=\(failure != nil)")
#endif
            handleExitCommand()
        }
        .onPlayPauseCommand {
            guard acceptsInlineInput, !viewportSettings.isPresented else { return }
            controller.togglePause()
        }
        .onChange(of: closeRequest, initial: true) { _, request in
            if request != nil { close() }
        }
        .onChange(of: isMiniPlayer) { _, mini in
            viewportSettings.close()
            isSeeking = false
            visiblePanel = nil
            playbackFocus = !mini && !isClosing ? readyFocus : nil
            if !mini, controller.isEnded, failure == nil, !isClosing {
                setPanel(.bottom)
                playbackFocus = .playPause
            }
#if DEBUG
            print("RingonomiFileMini: active=\(mini)")
#endif
        }
        .onChange(of: restoreRequest) { _, request in
            guard request != nil, closeRequest == nil, acceptsInlineInput else { return }
            playbackFocus = controller.isEnded ? .playPause : readyFocus
        }
        .onChange(of: transport, initial: true) { _, value in onTransportChanged(value) }
        .onChange(of: playbackNotice, initial: true) { _, value in onNoticeChanged(value) }
        .onChange(of: togglePauseRequest) { previous, current in
            guard isMiniPlayer, !isClosing, failure == nil,
                  !(current &- previous).isMultiple(of: 2) else { return }
            controller.togglePause()
        }
        .onChange(of: controller.isLoading, initial: true) { _, loading in
            if loading {
                viewportSettings.close()
                isSeeking = false
                visiblePanel = nil
                playbackFocus = acceptsInlineInput ? readyFocus : nil
            } else if failure == nil {
                if controller.isEnded, acceptsInlineInput {
                    isSeeking = false
                    setPanel(.bottom)
                    playbackFocus = .playPause
                } else if visiblePanel == nil {
                    playbackFocus = acceptsInlineInput ? .surface : nil
                }
            }
        }
        .onChange(of: failure, initial: true) { _, failure in
            if failure != nil {
                viewportSettings.close()
                isSeeking = false
                visiblePanel = nil
                if isMiniPlayer { onMiniPlayerChanged?(false) }
                playbackFocus = acceptsInlineInput ? .retry : nil
            } else if !controller.isLoading, visiblePanel == nil {
                playbackFocus = acceptsInlineInput ? .surface : nil
            }
        }
        .onChange(of: controller.isEnded, initial: true) { _, ended in
            guard ended,
                  !controller.isLoading, failure == nil else { return }
            viewportSettings.close()
            isSeeking = false
            if isMiniPlayer { onMiniPlayerChanged?(false) }
            if acceptsInlineInput {
                setPanel(.bottom)
                playbackFocus = .playPause
            }
        }
        .onChange(of: controller.audioOptions) { _, options in
            guard options.count < 2, panelIsVisible(.top),
                  playbackFocus == .audio || playbackFocus == nil else { return }
            playbackFocus = focusForPanel(.top)
        }
        .onChange(of: visiblePanel) { _, panel in
#if DEBUG
            print("RingonomiFilePanel: panel=\(String(describing: panel)) focus=\(String(describing: playbackFocus)) loading=\(controller.isLoading) failure=\(failure != nil)")
#endif
            guard acceptsInlineInput, let panel, !viewportSettings.isPresented,
                  !controller.isLoading, failure == nil else { return }
            playbackFocus = focusForPanel(panel)
        }
        .onChange(of: viewportSettings.isPresented) { _, isPresented in
            if isPresented {
                playbackFocus = nil
            } else {
                restoreFocusAfterViewport()
            }
        }
        .onChange(of: playbackFocus) { _, focus in
#if DEBUG
            print("RingonomiFileFocus: focus=\(String(describing: focus)) panel=\(String(describing: visiblePanel)) loading=\(controller.isLoading) failure=\(failure != nil)")
#endif
        }
        .onChange(of: controller.durationSeconds) { _, duration in
            guard isSeeking, let duration, duration.isFinite, duration > 0 else { return }
            seekDraft = min(max(0, seekDraft), max(0, duration - 0.1))
        }
    }

    private var surfaceIsFocusable: Bool {
        acceptsInlineInput && visiblePanel == nil && !viewportSettings.isPresented
            && !controller.isLoading && failure == nil
    }

    private var loadingOrFailureOverlay: some View {
        VStack(spacing: 24) {
            if controller.isLoading {
                ProgressView().scaleEffect(1.5)
                Text("映像と音声を準備しています…")
            }
            if let failure {
                Text(failure)
                    .multilineTextAlignment(.center)
                HStack(spacing: 24) {
                    Button(closeFailure == nil ? "再試行" : "もう一度閉じる") {
                        if closeFailure != nil { close() } else { controller.retry() }
                    }
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
                    PlaybackAudioMenu(options: controller.audioOptions,
                                      selectedID: controller.selectedAudioID,
                                      isDisabled: controller.isLoading || failure != nil,
                                      onSelect: { controller.selectAudioTrack(id: $0) })
                    .focused($playbackFocus, equals: .audio)
                }
                Button("画面調整", action: openViewport)
                    .focused($playbackFocus, equals: .viewport)
                    .disabled(controller.isLoading || failure != nil)
                if onMiniPlayerChanged != nil {
                    Button("小窓", action: beginMiniPlayer)
                        .focused($playbackFocus, equals: .miniPlayer)
                        .disabled(controller.isLoading || failure != nil || controller.isEnded)
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
                .disabled(controller.isLoading || failure != nil)
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
                Text("\(timestamp(controller.currentSeconds)) / 総時間不明")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !controller.canSeekRelative {
                    Text("再生時間を取得できないためシークできません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                .disabled(!controller.canSeekRelative)
            Button("3分進む") { controller.seek(seconds: 180) }
                .focused($playbackFocus, equals: .forward)
                .disabled(!controller.canSeekRelative)
            Button(controller.isEnded ? "最初から再生" : (controller.isPaused ? "再生" : "一時停止")) {
                controller.togglePause()
            }
            .focused($playbackFocus, equals: .playPause)
            .disabled(failure != nil)
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
        guard !isClosing, closeFailure == nil else { return }
        controller.start(
            item: item,
            onContinuousDisplayChanged: onContinuousDisplayChanged,
            onProgress: onProgress
        )
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
        acceptsInlineInput && visiblePanel == panel && !viewportSettings.isPresented
            && !controller.isLoading && failure == nil
    }

    private func revealTopPanel() {
        setPanel(.top)
    }

    private func revealBottomPanel() {
        setPanel(.bottom)
    }

    private func setPanel(_ panel: FilePlaybackPanel) {
        guard acceptsInlineInput else { return }
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
        if acceptsInlineInput, !controller.isLoading, failure == nil {
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
        guard acceptsInlineInput else { return }
        if viewportSettings.isPresented {
            closeViewport()
            return
        }
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

    private func beginMiniPlayer() {
        guard acceptsInlineInput, !controller.isLoading, !controller.isEnded, failure == nil else { return }
        viewportSettings.close()
        visiblePanel = nil
        isSeeking = false
        playbackFocus = nil
        onMiniPlayerChanged?(true)
    }

    private func close() {
        guard !isClosing else { return }
        let request: UUID
        if let onCloseStarted {
            guard let token = onCloseStarted() else { return }
            request = token
        } else {
            request = UUID()
        }
        isClosing = true
        closeFailure = nil
        viewportSettings.close()
        onContinuousDisplayChanged(false)
        visiblePanel = nil
        isSeeking = false
        playbackFocus = nil
        closeTask = Task { @MainActor in
            let success = await controller.stopBeforeClosing()
            guard !Task.isCancelled else { onClose?(request, false); return }
            closeTask = nil
#if DEBUG
            print("RingonomiFileClose: nativeStopped=\(success)")
#endif
            if success {
                if let onClose { onClose(request, true) }
                else { dismiss() }
            } else {
                isClosing = false
                closeFailure = "再生の終了を確認できませんでした。もう一度閉じてください。"
                onClose?(request, false)
                playbackFocus = acceptsInlineInput ? .retry : nil
            }
        }
    }

    private func openViewport() {
        guard acceptsInlineInput, !controller.isLoading, failure == nil else { return }
        viewportSettings.open()
        playbackFocus = nil
    }

    private func closeViewport() {
        viewportSettings.close()
        restoreFocusAfterViewport()
    }

    private func restoreFocusAfterViewport() {
        guard acceptsInlineInput, !controller.isLoading, failure == nil else { return }
        if controller.isEnded {
            isSeeking = false
            setPanel(.bottom)
            playbackFocus = .playPause
        } else if visiblePanel == .top {
            playbackFocus = .viewport
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, min(seconds.isFinite ? seconds : 0, 100_000_000)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
#endif
}
