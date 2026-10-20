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
    let closeRequest: UUID?
    let restoreRequest: UUID?
    let togglePauseRequest: UUID?
    let onClose: (Bool) -> Void
    let onDetachedChanged: (Bool) -> Void
    let onPictureInPictureNoticeChanged: (String?) -> Void
    let onTransportChanged: (PlaybackTransportState) -> Void
    @State private var isClosing = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var quality: String
    @State private var session = UUID().uuidString
    @State private var maintenanceError: String?
    @State private var hasStarted = false
    @StateObject private var viewportSettings = VideoViewportSettings()
    @State private var visiblePanel: PlaybackPanel?
    @State private var isQualityOverlayPresented = false
    @State private var isSceneSearchPresented = false
    @State private var sceneSearchPosition = 0.0
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
         closeRequest: UUID?, restoreRequest: UUID?, togglePauseRequest: UUID?,
         onClose: @escaping (Bool) -> Void,
         onDetachedChanged: @escaping (Bool) -> Void,
         onPictureInPictureNoticeChanged: @escaping (String?) -> Void,
         onTransportChanged: @escaping (PlaybackTransportState) -> Void,
         onContinuousDisplayChanged: @escaping (Bool) -> Void) {
        self.item = item
        self.resumeStore = resumeStore
        self.closeRequest = closeRequest
        self.restoreRequest = restoreRequest
        self.togglePauseRequest = togglePauseRequest
        self.onClose = onClose
        self.onDetachedChanged = onDetachedChanged
        self.onPictureInPictureNoticeChanged = onPictureInPictureNoticeChanged
        self.onTransportChanged = onTransportChanged
        self.onContinuousDisplayChanged = onContinuousDisplayChanged
        _quality = State(initialValue: item.initialQuality)
    }
    private var commentDelay: Double { liveCommentDelay.isFinite ? min(10, max(0, liveCommentDelay)) : 2 }
    private var streamURL: URL { item.url(quality: quality, session: session) }
    private var qualityValues: [String] { ["1080p", "720p", "540p", "360p"] }
#if canImport(TVVLCKit)
    @StateObject private var controller = PlaybackController()
    @StateObject private var recordingController = RecordingPlaybackController()
    private var isRecording: Bool { item.recordingID != nil }
    private var isLoading: Bool { isRecording ? recordingController.isLoading : controller.isLoading }
    private var failure: String? { isRecording ? recordingController.failure : controller.failure }
    private var audioOptions: [PlaybackAudioOption] { isRecording ? recordingController.audioOptions : controller.audioOptions }
    private var selectedAudioID: String? { isRecording ? recordingController.selectedAudioID : controller.selectedAudioID }
    private var audioSelectionError: String? { isRecording ? recordingController.audioSelectionError : controller.audioSelectionError }
    private var acceptsInlineInput: Bool {
        !isClosing && !recordingController.pictureInPicture.isDetached && !recordingController.pictureInPicture.isTransitioning
    }
    private var readyFocus: PlaybackControlFocus { failure != nil ? .retry : (isLoading ? .close : .surface) }
    private var pictureInPictureNotice: String? {
        guard isRecording else { return nil }
        // The inline subtree is hidden during PiP. Keep connection and
        // buffering status visible in the library's playback banner too.
        return recordingController.pictureInPicture.notice ?? failure ?? maintenanceError
            ?? (recordingController.pictureInPicture.ownsPlayback && isLoading ? "録画を読み込んでいます…" : nil)
    }
    private var pictureInPictureTransport: PlaybackTransportState {
        PlaybackTransportState(isPaused: recordingController.isPaused,
                               canToggle: isRecording && !isClosing && recordingController.canControlPictureInPicture)
    }
    private var surfaceIsFocusable: Bool { acceptsInlineInput && visiblePanel == nil && !isLoading && failure == nil && !isSceneSearchPresented && !viewportSettings.isPresented }
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
        .environment(\.colorScheme, .dark)
        .tint(.cyan)
        .onAppear {
            if !hasStarted, item.savedPosition == nil { beginPlayback(at: 0) }
        }
        .onExitCommand { handleExitCommand() }
        .onChange(of: closeRequest, initial: true) { _, request in
            if request != nil { close() }
        }
#if canImport(TVVLCKit)
        .onChange(of: recordingController.pictureInPicture.isDetached) { _, detached in
            onDetachedChanged(detached)
            if detached {
                closeViewport(restoreFocus: false)
                finishSceneSearch(restoreFocus: false, preparePlayback: false)
                visiblePanel = nil
                playbackFocus = nil
            } else if !isClosing {
                playbackFocus = acceptsInlineInput ? readyFocus : nil
            }
        }
        .onChange(of: pictureInPictureNotice, initial: true) { _, notice in
            onPictureInPictureNoticeChanged(notice)
        }
        .onChange(of: recordingController.pictureInPicture.isTransitioning) { _, transitioning in
            playbackFocus = !transitioning && acceptsInlineInput ? readyFocus : nil
        }
        .onChange(of: pictureInPictureTransport, initial: true) { _, state in
            onTransportChanged(state)
        }
        .onChange(of: togglePauseRequest) { _, request in
            guard request != nil, isRecording, !isClosing else { return }
            recordingController.togglePictureInPicturePause()
        }
        .onChange(of: restoreRequest) { _, request in
            if request != nil { recordingController.pictureInPicture.returnToInline() }
        }
        .onChange(of: recordingController.pictureInPicture.endedWhileDetached) { _, ended in
            if ended != nil, failure == nil { close() }
        }
        .onChange(of: recordingController.pictureInPicture.ownsPlayback) { _, owned in
            if !owned, !isClosing {
                recordingController.captions.reset(for: recordingController.currentSeconds)
#if canImport(UIKit)
                if UIApplication.shared.applicationState != .active { recordingController.suspendForBackground() }
#endif
            }
        }
        .task(id: recordingController.pictureInPicture.restoreRequest) {
            guard let request = recordingController.pictureInPicture.restoreRequest else { return }
            // The subtree stays mounted. Allow the library's opacity/focus
            // update to commit, and wait for app activation after Home.
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
#if canImport(UIKit)
                if UIApplication.shared.applicationState == .active {
                    await Task.yield()
                    recordingController.pictureInPicture.completeRestore(true, request: request)
                    return
                }
#endif
                try? await Task.sleep(for: .milliseconds(50))
            }
            recordingController.pictureInPicture.completeRestore(false, request: request)
        }
#endif
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
        if item.recordingID != nil { recordingController.configureNowPlaying(title: item.title) }
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
        closeViewport(restoreFocus: false)
#if canImport(TVVLCKit)
        finishSceneSearch(restoreFocus: false, preparePlayback: false)
#endif
        isQualityOverlayPresented = false
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
        guard !isClosing else { return }
        isClosing = true
        closeViewport(restoreFocus: false)
        onContinuousDisplayChanged(false)
#if DEBUG
        print("RingonomiPlaybackClose: panel=\(visiblePanel.map { $0 == .top ? "top" : "bottom" } ?? "hidden")")
#endif
        flushPosition()
#if canImport(TVVLCKit)
        finishSceneSearch(restoreFocus: false, preparePlayback: false)
#endif
        visiblePanel = nil
        isQualityOverlayPresented = false
        isSeeking = false
#if canImport(TVVLCKit)
        if isRecording {
            recordingController.pictureInPicture.stopBeforeClosing { success in
                if success {
                    recordingController.flushPosition()
                    recordingController.stop()
                } else { isClosing = false }
                onClose(success)
            }
        } else {
            controller.stop()
            onClose(true)
        }
#else
        onClose(true)
#endif
    }

    private var playerBody: some View {
        ZStack {
#if canImport(TVVLCKit)
            VideoViewportMedia(crop: viewportSettings.crop,
                               videoRect: isRecording ? recordingController.videoRect : controller.videoRect) {
                ZStack {
                    if isRecording {
                        NativeRecordingVideo(url: streamURL, controller: recordingController)
                            .ignoresSafeArea()
                    } else {
                        VLCVideo(url: streamURL, controller: controller)
                            .ignoresSafeArea()
                    }
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
                }
            }
            .ignoresSafeArea()
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
            if isQualityOverlayPresented {
                QualityChoicesView(
                    currentQuality: quality,
                    values: qualityValues,
                    onSelect: finishQualitySelection,
                    onClose: { dismissQualityOverlay(restoreFocus: true) }
                )
                // Give the card the full player bounds so tvOS can calculate
                // its focus candidates from the actual screen-sized surface.
                .padding(.top, 64)
                .padding(.trailing, 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity)
                .zIndex(2)
            }
            if isSceneSearchPresented, let recordingID = item.recordingID {
                RecordingSceneSearchView(client: item.client, recordingID: recordingID,
                    fileID: item.recordedFileID, position: sceneSearchPosition,
                    onSelect: { finishSceneSearch(at: $0) },
                    onClose: { finishSceneSearch() })
                    .zIndex(3)
            }
            if viewportSettings.isPresented {
                VideoViewportSettingsView(settings: viewportSettings, onClose: { closeViewport() })
                    .zIndex(5)
            }
            if visiblePanel == nil, failure == nil, let maintenanceError {
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
        .disabled(recordingController.pictureInPicture.isTransitioning)
#endif
        .onExitCommand { handleExitCommand() }
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
            guard acceptsInlineInput else { playbackFocus = nil; return }
            if loading {
                closeViewport(restoreFocus: false)
                finishSceneSearch(restoreFocus: false)
                isQualityOverlayPresented = false
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
        .onChange(of: audioOptions) { _, options in
            // A stream can lose an alternate track without starting a new load.
            // Do not leave focus pointing at the audio menu that just vanished.
            guard options.count < 2 else { return }
            let audioLostFocus = playbackFocus == .audio
                || (playbackFocus == nil && lastReadyPlaybackFocus == .audio)
            if lastReadyPlaybackFocus == .audio {
                lastReadyPlaybackFocus = isRecording ? .captions : .comments
            }
            guard audioLostFocus, panelIsVisible(.top), !isQualityOverlayPresented else { return }
            playbackFocus = focusForPanel(.top)
        }
        .onChange(of: failure) { _, failure in
            updateLiveCommentClock()
            if failure != nil {
                if isRecording { recordingController.pictureInPicture.returnToInline() }
                closeViewport(restoreFocus: false)
                finishSceneSearch(restoreFocus: false)
                isQualityOverlayPresented = false
                panelBeforeLoading = nil
                visiblePanel = nil
                isSeeking = false
                playbackFocus = .retry
            }
        }
        .onChange(of: visiblePanel) { _, panel in
            guard acceptsInlineInput else { playbackFocus = nil; return }
#if DEBUG
            print("RingonomiPlaybackPanel: \(panel.map { $0 == .top ? "top" : "bottom" } ?? "hidden") uptime=\(ProcessInfo.processInfo.systemUptime)")
#endif
            if let panel {
                playbackFocus = focusForPanel(panel, preferring: lastReadyPlaybackFocus)
            } else {
                playbackFocus = failure == nil && !isLoading ? .surface : (failure == nil ? .close : .retry)
            }
        }
        .onChange(of: item.id) { _, _ in
            viewportSettings.close()
            viewportSettings.reset()
        }
        .onChange(of: viewportSettings.crop) { _, crop in
#if DEBUG
            print("RingonomiViewport: left=\(crop.left) top=\(crop.top) right=\(crop.right) bottom=\(crop.bottom)")
#endif
        }
        .onChange(of: liveCommentDelay) { _, _ in updateLiveCommentClock() }
        .task(id: recordingCaptionsEnabled) {
            recordingController.captions.setEnabled(recordingCaptionsEnabled)
        }
        .onPlayPauseCommand {
#if DEBUG
            print("RingonomiPlaybackCommand: playPause")
#endif
            guard acceptsInlineInput, !isSceneSearchPresented, !viewportSettings.isPresented else { return }
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
                if isRecording, let notice = recordingController.pictureInPicture.notice {
                    Text(notice).foregroundStyle(.orange)
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
                pictureInPictureSupported: isRecording && recordingController.pictureInPicture.isSupported,
                pictureInPicturePossible: recordingController.pictureInPicture.isPossible,
                pictureInPictureBusy: recordingController.pictureInPicture.isTransitioning,
                startPictureInPicture: {
                    guard isRecording, !isLoading, failure == nil else { return }
                    recordingController.pictureInPicture.start()
                },
                selectAudio: { id in
                    if isRecording { recordingController.selectAudioTrack(id: id) }
                    else { controller.selectAudioTrack(id: id) }
                },
                close: close,
                openViewport: presentViewport,
                focus: $playbackFocus,
                isQualityOverlayPresented: $isQualityOverlayPresented
            )
        }
        .padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.82))
        .disabled(isQualityOverlayPresented)
        .allowsHitTesting(!isQualityOverlayPresented)
        .accessibilityHidden(isQualityOverlayPresented)
        .onMoveCommand { direction in
            guard !isQualityOverlayPresented,
                  panelIsVisible(.top), let playbackFocus,
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
                        Button("シーンサーチ", action: presentSceneSearch)
                            .focused($playbackFocus, equals: .scenes)
                            .disabled(isLoading || failure != nil)
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
        visiblePanel == panel && !isLoading && failure == nil && !isSceneSearchPresented && !viewportSettings.isPresented
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
            case .captions, .comments, .quality, .viewport, .panelClose:
                return true
            case .pictureInPicture:
                return isRecording && recordingController.pictureInPicture.isSupported
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
            case .chapters, .scenes:
                return isRecording
            default:
                return false
            }
        }
    }

    private func presentViewport() {
        guard !isLoading, failure == nil, !isSceneSearchPresented else { return }
        isQualityOverlayPresented = false
        playbackFocus = nil
        viewportSettings.open()
    }

    private func closeViewport(restoreFocus: Bool = true) {
        guard viewportSettings.isPresented else { return }
        viewportSettings.close()
        if restoreFocus, panelIsVisible(.top) { playbackFocus = .viewport }
    }

    private func presentSceneSearch() {
        guard isRecording, !isLoading, failure == nil,
              recordingController.beginSceneSearch() else { return }
        sceneSearchPosition = recordingController.currentSeconds
        isSeeking = false
        isSceneSearchPresented = true
    }

    private func finishSceneSearch(at seconds: Double? = nil, restoreFocus: Bool = true,
                                   preparePlayback: Bool = true) {
        guard isSceneSearchPresented else { return }
        isSceneSearchPresented = false
        recordingController.endSceneSearch(at: seconds, preparePlayback: preparePlayback)
        if restoreFocus, failure == nil {
            lastReadyPlaybackFocus = .scenes
            if !isLoading { playbackFocus = .scenes }
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
        guard acceptsInlineInput else { return }
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
        guard acceptsInlineInput else { return }
        guard value != quality, !isLoading else { return }
        if isRecording { recordingController.prepareQualityChange() }
        else { controller.prepareQualityChange() }
        session = UUID().uuidString
        quality = value
    }

    private func dismissQualityOverlay(restoreFocus: Bool) {
        guard isQualityOverlayPresented else { return }
        isQualityOverlayPresented = false
#if DEBUG
        print("RingonomiQualityOverlay: dismissed active=\(panelIsVisible(.top))")
#endif
        if restoreFocus, panelIsVisible(.top) {
            playbackFocus = .quality
        }
    }

    private func finishQualitySelection(_ value: String) {
        guard panelIsVisible(.top) else {
            isQualityOverlayPresented = false
            return
        }
        isQualityOverlayPresented = false
        playbackFocus = .quality
#if DEBUG
        print("RingonomiQualityOverlay: selected value=\(value)")
#endif
        selectQuality(value)
    }
#endif

    private func handleExitCommand() {
#if DEBUG
        print("RingonomiPlaybackExit: card=\(isQualityOverlayPresented) panel=\(visiblePanel.map { $0 == .top ? "top" : "bottom" } ?? "hidden") focus=\(playbackFocus?.rawValue ?? "none")")
#endif
#if canImport(TVVLCKit)
        if viewportSettings.isPresented {
            closeViewport()
        } else if isSceneSearchPresented {
            finishSceneSearch()
        } else if isQualityOverlayPresented {
            dismissQualityOverlay(restoreFocus: true)
        } else if visiblePanel != nil {
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
