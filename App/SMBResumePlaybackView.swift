import RingonomiCore
import SwiftUI

/// The choice and decoder occupy the same shared session. A choice with no
/// decoder can acknowledge a handoff immediately; an active file waits for stop.
struct SMBResumePlaybackView: View {
    let item: FilePlaybackSelection
    let closeRequest: UUID?
    let restoreRequest: UUID?
    let togglePauseRequest: UInt64
    let isMiniPlayer: Bool
    let onMiniPlayerChanged: (Bool) -> Void
    let onCloseStarted: () -> UUID?
    let onClose: (UUID, Bool) -> Void
    let onNoticeChanged: (String?) -> Void
    let onTransportChanged: (PlaybackTransportState) -> Void
    let onBeginning: () -> Void
    let onContinuousDisplayChanged: (Bool) -> Void
    let onProgress: (Double, Double?, Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedItem: FilePlaybackSelection?
    @FocusState private var resumeFocused: Bool

    init(item: FilePlaybackSelection, closeRequest: UUID?, restoreRequest: UUID?,
         togglePauseRequest: UInt64, isMiniPlayer: Bool,
         onMiniPlayerChanged: @escaping (Bool) -> Void,
         onCloseStarted: @escaping () -> UUID?, onClose: @escaping (UUID, Bool) -> Void,
         onNoticeChanged: @escaping (String?) -> Void,
         onTransportChanged: @escaping (PlaybackTransportState) -> Void,
         onBeginning: @escaping () -> Void,
         onContinuousDisplayChanged: @escaping (Bool) -> Void,
         onProgress: @escaping (Double, Double?, Bool) -> Void) {
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
        self.onBeginning = onBeginning
        self.onContinuousDisplayChanged = onContinuousDisplayChanged
        self.onProgress = onProgress
        _selectedItem = State(initialValue: item.smbResumeBookmark == nil ? item : nil)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let selectedItem {
                FilePlaybackView(item: selectedItem,
                    closeRequest: closeRequest, restoreRequest: restoreRequest,
                    togglePauseRequest: togglePauseRequest, isMiniPlayer: isMiniPlayer,
                    onMiniPlayerChanged: onMiniPlayerChanged,
                    onCloseStarted: onCloseStarted, onClose: onClose,
                    onNoticeChanged: onNoticeChanged, onTransportChanged: onTransportChanged,
                    onContinuousDisplayChanged: onContinuousDisplayChanged,
                    onProgress: onProgress)
            } else {
                resumeChoice
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { closeChoiceIfRequested() }
        .onChange(of: closeRequest) { _, _ in closeChoiceIfRequested() }
    }

    private var resumeChoice: some View {
        VStack(spacing: 26) {
            Text("続きから再生しますか？")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(item.title)
                .font(.title3).lineLimit(2).truncationMode(.middle)
            Text("前回の位置 \(resumeTime)")
                .foregroundStyle(.secondary).monospacedDigit()
            Button("続きから再生") {
                guard closeRequest == nil else { return }
                selectedItem = item
            }
                .focused($resumeFocused)
            Button("先頭から再生") {
                guard closeRequest == nil else { return }
                onBeginning()
                // Construct the new selection once. Recomputing it in body
                // would change its UUID and restart the decoder on updates.
                selectedItem = FilePlaybackSelection(url: item.url, title: item.title,
                    identity: item.identity, smbConnection: item.smbConnection)
            }
            Button("キャンセル", role: .cancel) { cancelChoice() }
        }
        .padding(60)
        .frame(maxWidth: 900)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .defaultFocus($resumeFocused, true)
        .task(id: scenePhase) {
            guard scenePhase == .active else { resumeFocused = false; return }
            // The shared overlay does not create a new focus environment as
            // a modal did. Wait until it is mounted, then choose its first action.
            await Task.yield()
            guard !Task.isCancelled, selectedItem == nil, closeRequest == nil else { return }
            resumeFocused = true
        }
        .disabled(closeRequest != nil)
        .onExitCommand { cancelChoice() }
    }

    private func closeChoiceIfRequested() {
        guard selectedItem == nil, let closeRequest else { return }
        onClose(closeRequest, true)
    }

    private func cancelChoice() {
        guard selectedItem == nil, let request = onCloseStarted() else { return }
        onClose(request, true)
    }

    private var resumeTime: String {
        guard let seconds = item.smbResumeBookmark?.seconds,
              let whole = Int(exactly: seconds.rounded(.down)), whole >= 0 else { return "保存位置" }
        return String(format: "%02lld:%02lld:%02lld", Int64(whole / 3600),
                      Int64((whole / 60) % 60), Int64(whole % 60))
    }
}
