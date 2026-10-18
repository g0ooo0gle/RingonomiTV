import SwiftUI
import RingonomiCore
#if canImport(UIKit)
import UIKit
#endif

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
    let onContinuousDisplayChanged: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var quality: String
    @State private var session = UUID().uuidString
    @State private var maintenanceError: String?
    @State private var hasStarted = false
    @State private var visiblePanel: PlaybackPanel?
    @State private var panelBeforeLoading: PlaybackPanel?
    @State private var isSeeking = false
    @State private var didSetInitialPlaybackFocus = false
    @State private var lastReadyPlaybackFocus: PlaybackControlFocus?
    @FocusState private var playbackFocus: PlaybackControlFocus?
    @AppStorage("recordingCaptionsEnabled") private var recordingCaptionsEnabled = true
    @AppStorage("recordingCommentsEnabled") private var recordingCommentsEnabled = false
    @AppStorage("liveCommentsEnabled") private var liveCommentsEnabled = false
    @AppStorage("liveCommentDelay") private var liveCommentDelay = 2.0
    @State private var liveCommentReload = 0
    @StateObject private var liveCommentStore = LiveCommentStore()
    @State private var commentReload = 0
    @StateObject private var commentStore = RecordingCommentStore()
    init(item: Playback, resumeStore: RecordingResumeStore,
         onContinuousDisplayChanged: @escaping (Bool) -> Void) {
        self.item = item
        self.resumeStore = resumeStore
        self.onContinuousDisplayChanged = onContinuousDisplayChanged
        _quality = State(initialValue: item.initialQuality)
    }
    private var commentDelay: Double { liveCommentDelay.isFinite ? min(10, max(0, liveCommentDelay)) : 2 }
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
    private var surfaceIsFocusable: Bool { visiblePanel == nil && !isLoading && failure == nil }
#endif
    private var needsContinuousDisplay: Bool {
#if canImport(TVVLCKit)
        hasStarted && failure == nil && !(isRecording ? recordingController.isPaused : controller.isPaused)
#else
        false
#endif
    }
    var body: some View {
        Group {
            if hasStarted {
                playerBody
            } else if let position = item.savedPosition {
                VStack(spacing: 30) {
                    Text(item.title).font(.title2).multilineTextAlignment(.center)
                    Text("前回は \(Playback.timestamp(position)) まで再生しました。")
                    Button("続きから再生") { beginPlayback(at: position) }
                        .focused($playbackFocus, equals: .resume)
                    Button("最初から再生") { beginPlayback(at: 0) }
                        .focused($playbackFocus, equals: .startOver)
                    Button("閉じる") { close() }
                        .focused($playbackFocus, equals: .close)
                }.padding(80).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                    .focusSection()
                    .defaultFocus($playbackFocus, .resume)
                    .onAppear {
                        playbackFocus = .resume
#if DEBUG
                        print("RingonomiResumePrompt: shown")
#endif
                    }
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            if !hasStarted, item.savedPosition == nil { beginPlayback(at: 0) }
        }
        .onExitCommand { handleExitCommand() }
#if canImport(UIKit)
        // UIApplication notifications are the primary lifecycle boundary on
        // tvOS.  scenePhase remains a fallback because it can lag during a
        // Home transition on some Apple TV releases.
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
        .onChange(of: needsContinuousDisplay, initial: true) { _, needsDisplay in
            onContinuousDisplayChanged(needsDisplay)
        }
        .onDisappear {
#if DEBUG
            print("RingonomiPlaybackDismissed")
#endif
            flushPosition()
            commentStore.cancel()
            liveCommentStore.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                flushPosition()
#if canImport(UIKit)
                // Ignore a delayed scene update after the app has already
                // become active. UIKit notifications are the primary source.
                guard UIApplication.shared.applicationState != .active else { return }
#endif
                suspendPlaybackForBackground()
            } else {
                resumePlaybackFromBackground()
            }
        }
    }

    private func beginPlayback(at seconds: Double) {
#if DEBUG
        print("RingonomiPlaybackBegin: target=\(seconds)")
#endif
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

    private func suspendPlaybackForBackground() {
        guard hasStarted else { return }
#if canImport(TVVLCKit)
        if isRecording {
            recordingController.suspendForBackground()
        } else {
            controller.suspendForBackground()
        }
#endif
    }

    private func resumePlaybackFromBackground() {
#if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
#endif
        guard hasStarted else { return }
#if canImport(TVVLCKit)
        if isRecording {
            recordingController.resumeFromBackground()
        } else {
            controller.resumeFromBackground()
        }
#endif
    }

    private func close() {
        onContinuousDisplayChanged(false)
#if DEBUG
        print("RingonomiPlaybackClose: panel=\(visiblePanel.map { $0 == .top ? "top" : "bottom" } ?? "hidden")")
#endif
        flushPosition()
        visiblePanel = nil
        isSeeking = false
        dismiss()
    }

    private var playerBody: some View {
        ZStack {
#if canImport(TVVLCKit)
            if isRecording {
                NativeRecordingVideo(url: streamURL, controller: recordingController)
                    .ignoresSafeArea()
            } else {
                VLCVideo(url: streamURL, controller: controller)
                    .ignoresSafeArea()
            }
            // Keep focus effects and remote input away from the native video
            // layer. Returning from a panel must not refocus AVPlayer/VLC views.
            Color.clear
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .focusable(surfaceIsFocusable, interactions: .activate)
                .focusEffectDisabled()
                .focused($playbackFocus, equals: .surface)
                .allowsHitTesting(surfaceIsFocusable)
                .onMoveCommand { handleMoveCommand($0) }
                .onTapGesture { revealBottomPanel() }
                .accessibilityLabel("再生メニュー")
                .accessibilityHidden(!surfaceIsFocusable)
            if isRecording, recordingCommentsEnabled {
                PlaybackCommentOverlay(comments: commentStore.comments,
                                        clock: { recordingController.currentSeconds },
                                        videoRect: recordingController.videoRect,
                                        isPaused: recordingController.isPaused,
                                        isVisible: !isLoading && failure == nil, topReservedSpace: 480)
                    .ignoresSafeArea()
            }
            if !isRecording, liveCommentsEnabled {
                PlaybackCommentOverlay(comments: liveCommentStore.comments,
                                       clock: { liveCommentStore.currentSeconds },
                                       videoRect: controller.videoRect,
                                       isPaused: controller.isPaused || isLoading,
                                       isVisible: !isLoading && failure == nil)
                    .ignoresSafeArea()
            }
            if isRecording, recordingCaptionsEnabled {
                RecordingCaptionOverlay(controller: recordingController.captions,
                                        videoRect: recordingController.videoRect,
                                        isVisible: !isLoading && failure == nil)
                    .ignoresSafeArea()
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
                        HStack(spacing: 24) {
                            Button("再試行") {
                                if isRecording { recordingController.retry() } else { controller.retry() }
                            }.focused($playbackFocus, equals: .retry)
                            Button("閉じる", action: close)
                                .focused($playbackFocus, equals: .close)
                        }
                    } else {
                        Button("閉じる", action: close)
                            .focused($playbackFocus, equals: .close)
                    }
                }.padding(60).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Preserve the controls' identity while handing focus back to the
            // remote surface. Removing a focused panel during a transition can
            // leave tvOS updating focus against a disappearing view hierarchy.
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
            if visiblePanel == nil, let maintenanceError {
                Text(maintenanceError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
#else
            VStack(spacing: 30) {
                Text("TS再生ライブラリが必要です")
                Text("READMEの手順でTVVLCKitを導入してビルドしてください。")
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
#endif
        }
#if canImport(TVVLCKit)
        .task(id: LiveCommentRequestID(channel: item.channelID, enabled: liveCommentsEnabled,
                                      active: scenePhase == .active && failure == nil, reload: liveCommentReload)) {
            guard !isRecording, let channel = item.channelID else {
                liveCommentStore.disable()
                return
            }
            guard liveCommentsEnabled, scenePhase == .active, failure == nil else {
                liveCommentStore.disable()
                return
            }
            updateLiveCommentClock()
            await liveCommentStore.run(client: item.client, channelID: channel)
        }
        .defaultFocus($playbackFocus, .surface)
        .onChange(of: isLoading, initial: true) { _, loading in
            updateLiveCommentClock()
            if loading {
                if panelBeforeLoading == nil, let visiblePanel {
                    panelBeforeLoading = visiblePanel
                }
                if visiblePanel != nil {
                    visiblePanel = nil
                    isSeeking = false
                }
                playbackFocus = .close
            } else if !loading, failure == nil, let panel = panelBeforeLoading {
                panelBeforeLoading = nil
                setPanel(panel)
            } else if !loading, failure == nil, !didSetInitialPlaybackFocus {
                didSetInitialPlaybackFocus = true
                playbackFocus = .surface
            } else if !loading, failure == nil, visiblePanel == nil {
                // A failed retry or a hidden-panel rebuffer must return to the
                // video surface; a panel focus would point at a view that is
                // no longer in the hierarchy.
                playbackFocus = .surface
            } else if !loading, failure == nil, let previous = lastReadyPlaybackFocus {
                // Disabled controls temporarily lose focus during seek/preroll.
                // Return to the user's control when the ready gate opens.
                playbackFocus = previous == .audio && audioOptions.count < 2
                    ? fallbackFocus : previous
            }
        }
        .onChange(of: playbackFocus) { _, focus in
            if !isLoading, failure == nil, let focus, focus != .retry { lastReadyPlaybackFocus = focus }
#if DEBUG
            print("RingonomiPlaybackFocus: \(focus?.rawValue ?? "none") uptime=\(ProcessInfo.processInfo.systemUptime)")
#endif
        }
        .onChange(of: controller.isPaused) { _, _ in updateLiveCommentClock() }
        .onChange(of: failure) { _, failure in
            updateLiveCommentClock()
            if failure != nil {
                panelBeforeLoading = nil
                visiblePanel = nil
                isSeeking = false
                playbackFocus = .retry
            }
        }
        .onChange(of: visiblePanel) { _, panel in
#if DEBUG
            print("RingonomiPlaybackPanel: \(panel.map { $0 == .top ? "top" : "bottom" } ?? "hidden") uptime=\(ProcessInfo.processInfo.systemUptime)")
#endif
            if let panel {
                playbackFocus = focusForPanel(panel, preferring: lastReadyPlaybackFocus)
            } else {
                playbackFocus = failure == nil && !isLoading ? .surface : (failure == nil ? .close : .retry)
            }
        }
        .onChange(of: liveCommentDelay) { _, _ in updateLiveCommentClock() }
        .task(id: recordingCaptionsEnabled) {
            recordingController.captions.setEnabled(recordingCaptionsEnabled)
        }
        .onPlayPauseCommand {
#if DEBUG
            print("RingonomiPlaybackCommand: playPause")
#endif
            if isRecording { recordingController.togglePause() } else { controller.togglePause() }
        }
        .task(id: CommentRequestID(server: item.client.baseURL, recordingID: item.recordingID,
                                   enabled: recordingCommentsEnabled, reload: commentReload)) {
            guard let recordingID = item.recordingID else { return }
            if recordingCommentsEnabled {
                await commentStore.load(client: item.client, recordingID: recordingID)
            } else {
                commentStore.disable()
            }
        }
        .task(id: streamURL) {
            guard let recordingID = item.recordingID else { return }
            let requestURL = streamURL
            let currentSession = session
            let currentQuality = quality
            while !Task.isCancelled {
                do {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(4))
                    if failure != nil { continue }
                    try Task.checkCancellation()
                    guard streamURL == requestURL,
                          session == currentSession,
                          quality == currentQuality else { break }
                    try await item.client.keepRecordingAlive(id: recordingID, session: currentSession, quality: currentQuality)
                    try Task.checkCancellation()
                    guard streamURL == requestURL,
                          session == currentSession,
                          quality == currentQuality else { break }
                    if failure != nil { continue }
                    maintenanceError = nil
#if DEBUG
                    print("RingonomiTVRecording: keep-alive OK quality=\(currentQuality)")
#endif
                } catch is CancellationError { break }
                catch {
                    if Task.isCancelled { break }
                    guard streamURL == requestURL,
                          session == currentSession,
                          quality == currentQuality else { break }
                    if failure != nil { continue }
                    maintenanceError = "接続の維持に失敗しました。再試行しています。"
                }
            }
        }
#endif
    }
#if canImport(TVVLCKit)
    private func updateLiveCommentClock() {
        liveCommentStore.updatePlaybackState(playing: !isRecording && !isLoading && failure == nil && !controller.isPaused,
                                             delay: commentDelay)
    }

    private var topPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 16) {
                Text(isRecording ? recordingController.status : controller.status)
                    .font(.caption)
                if let maintenanceError {
                    Text(maintenanceError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if isRecording, let notice = recordingController.commercialSkipNotice {
                    Text(notice).font(.caption)
                }
                if let audioSelectionError {
                    Text(audioSelectionError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if isRecording, recordingCaptionsEnabled,
                   let captionStatus = recordingController.captions.status {
                    Text(captionStatus).font(.caption)
                }
                if isRecording, recordingCommentsEnabled, let status = commentStore.status {
                    Text(status).font(.caption)
                }
                if !isRecording, liveCommentsEnabled, let status = liveCommentStore.status {
                    Text(status).font(.caption)
                }
            }
            PlaybackTopControls(
                isRecording: isRecording,
                recordingCaptionsEnabled: $recordingCaptionsEnabled,
                recordingCommentsEnabled: $recordingCommentsEnabled,
                liveCommentsEnabled: $liveCommentsEnabled,
                liveCommentDelay: $liveCommentDelay,
                commentStoreLoading: commentStore.loading,
                commentReload: { commentReload &+= 1 },
                liveCommentReload: { liveCommentReload &+= 1 },
                quality: quality,
                isActive: panelIsVisible(.top),
                isLoading: isLoading,
                failure: failure,
                audioOptions: audioOptions,
                selectedAudioID: selectedAudioID,
                selectAudio: { id in
                    if isRecording { recordingController.selectAudioTrack(id: id) }
                    else { controller.selectAudioTrack(id: id) }
                },
                selectQuality: selectQuality,
                close: close,
                focus: $playbackFocus
            )
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.82))
        .onMoveCommand { direction in
            guard panelIsVisible(.top), let playbackFocus,
                  focusBelongs(playbackFocus, to: .top) else { return }
            switch direction {
            case .down: revealBottomPanel()
            default: break
            }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 16) {
            if isRecording {
                if let duration = recordingController.durationSeconds, duration > 0 {
                    PlaybackSeekControl(
                        position: recordingController.currentSeconds,
                        duration: duration,
                        isEnabled: !isLoading && failure == nil,
                        focus: $playbackFocus,
                        isEditing: $isSeeking,
                        onCommit: { recordingController.seek(to: $0) },
                        onMoveCommand: handleMoveCommand
                    )
                } else {
                    Text("再生時間：\(recordingController.playbackTime)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("シークバーは総時間を取得すると表示されます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    Button("10秒戻る") { recordingController.seek(seconds: -10) }
                        .focused($playbackFocus, equals: .backward)
                        .disabled(isLoading || failure != nil)
                    Button("30秒進む") { recordingController.seek(seconds: 30) }
                        .focused($playbackFocus, equals: .forward)
                        .disabled(isLoading || failure != nil)
                    Button(recordingController.isPaused ? "再生" : "一時停止") {
                        recordingController.togglePause()
                    }
                    .focused($playbackFocus, equals: .playPause)
                    .disabled(isLoading || failure != nil)
                    if let recordingID = item.recordingID {
                        RecordingChapterControls(client: item.client, recordingID: recordingID,
                                                 fileID: item.recordedFileID, controller: recordingController)
                            .focused($playbackFocus, equals: .chapters)
                    }
                }
                .onMoveCommand { direction in
                    guard panelIsVisible(.bottom), let focus = playbackFocus,
                          focusBelongs(focus, to: .bottom) else { return }
                    switch direction {
                    case .up:
                        if recordingController.durationSeconds != nil { playbackFocus = .seek }
                        else { revealTopPanel() }
                    case .down: hidePanel()
                    default: break
                    }
                }
            } else {
                HStack(spacing: 24) {
                    Text(controller.status).font(.caption)
                    Button(controller.isPaused ? "再生" : "一時停止") {
                        controller.togglePause()
                    }
                    .focused($playbackFocus, equals: .playPause)
                    .disabled(failure != nil)
                }
                .onMoveCommand { direction in
                    guard panelIsVisible(.bottom), let focus = playbackFocus,
                          focusBelongs(focus, to: .bottom) else { return }
                    switch direction {
                    case .up: revealTopPanel()
                    case .down: hidePanel()
                    default: break
                    }
                }
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.82))
        .focusSection()
    }

    private var fallbackFocus: PlaybackControlFocus {
        guard let visiblePanel else { return .surface }
        return focusForPanel(visiblePanel)
    }

    private func panelIsVisible(_ panel: PlaybackPanel) -> Bool {
        visiblePanel == panel && !isLoading && failure == nil
    }

    private func focusForPanel(_ panel: PlaybackPanel,
                               preferring previous: PlaybackControlFocus? = nil) -> PlaybackControlFocus {
        if let previous, focusBelongs(previous, to: panel) {
            return previous
        }
        switch panel {
        case .top:
            return isRecording ? .captions : .comments
        case .bottom:
            if isRecording {
                return recordingController.durationSeconds.map { _ in .seek } ?? .backward
            }
            return .playPause
        }
    }

    private func focusBelongs(_ focus: PlaybackControlFocus, to panel: PlaybackPanel) -> Bool {
        switch panel {
        case .top:
            switch focus {
            case .captions, .comments, .quality, .panelClose:
                return true
            case .audio:
                return audioOptions.count > 1
            default:
                return false
            }
        case .bottom:
            switch focus {
            case .seek:
                return isRecording && recordingController.durationSeconds != nil
            case .backward, .forward, .playPause:
                return true
            case .chapters:
                return isRecording
            default:
                return false
            }
        }
    }

    private func revealTopPanel() {
        setPanel(.top)
    }

    private func revealBottomPanel() {
        setPanel(.bottom)
    }

    private func setPanel(_ panel: PlaybackPanel) {
        isSeeking = false
        if reduceMotion {
            visiblePanel = panel
        } else {
            withAnimation(.easeOut(duration: 0.2)) { visiblePanel = panel }
        }
    }

    private func hidePanel() {
        isSeeking = false
        // Complete the focus handoff without keeping the old controls in an
        // animated removal/update transaction.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visiblePanel = nil
        }
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .up: revealTopPanel()
        case .down:
            if visiblePanel == .bottom {
                playbackFocus = isRecording ? .backward : .playPause
            } else {
                revealBottomPanel()
            }
        default: break
        }
    }

    private func selectQuality(_ value: String) {
        guard value != quality, !isLoading else { return }
        if isRecording { recordingController.prepareQualityChange() }
        else { controller.prepareQualityChange() }
        session = UUID().uuidString
        quality = value
    }
#endif

    private func handleExitCommand() {
#if canImport(TVVLCKit)
        if visiblePanel != nil {
            hidePanel()
        } else {
            close()
        }
#else
        close()
#endif
    }
}

private struct LiveCommentRequestID: Hashable {
    let channel: String?
    let enabled: Bool
    let active: Bool
    let reload: Int
}

private struct CommentRequestID: Hashable {
    let server: URL
    let recordingID: Int?
    let enabled: Bool
    let reload: Int
}
