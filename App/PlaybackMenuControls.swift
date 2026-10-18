import SwiftUI
import RingonomiCore

/// Focus targets used by the two playback panels and the video surface.
enum PlaybackControlFocus: String, Hashable {
    case resume
    case startOver
    case surface
    case seek
    case backward
    case forward
    case chapters
    case playPause
    case captions
    case comments
    case audio
    case quality
    case close
    case panelClose
    case retry
}

enum PlaybackPanel: Equatable {
    case top
    case bottom
}

/// The controls that are shown in the upper playback panel.
struct PlaybackTopControls: View {
    let isRecording: Bool
    @Binding var recordingCaptionsEnabled: Bool
    @Binding var recordingCommentsEnabled: Bool
    @Binding var liveCommentsEnabled: Bool
    @Binding var liveCommentDelay: Double
    let commentStoreLoading: Bool
    let commentReload: () -> Void
    let liveCommentReload: () -> Void
    let quality: String
    let isActive: Bool
    let isLoading: Bool
    let failure: String?
    let audioOptions: [PlaybackAudioOption]
    let selectedAudioID: String?
    let selectAudio: (String) -> Void
    let selectQuality: (String) -> Void
    let close: () -> Void
    @FocusState.Binding var focus: PlaybackControlFocus?
    @State private var isQualityOverlayPresented = false

    private let qualityValues = ["1080p", "720p", "540p", "360p"]

    var body: some View {
        HStack(spacing: 24) {
            if isRecording {
                Menu(recordingCaptionsEnabled ? "字幕：表示" : "字幕：非表示") {
                    Button(recordingCaptionsEnabled ? "字幕を非表示にする" : "字幕を表示する") {
                        recordingCaptionsEnabled.toggle()
                    }
                }
                .focused($focus, equals: .captions)
                .accessibilityLabel("録画の字幕を設定")

                Menu(recordingCommentsEnabled ? "実況：表示" : "実況：非表示") {
                    Button(recordingCommentsEnabled ? "実況を非表示にする" : "実況を表示する") {
                        recordingCommentsEnabled.toggle()
                    }
                    if recordingCommentsEnabled {
                        Button("過去ログを再取得") { commentReload() }
                            .disabled(commentStoreLoading)
                    }
                }
                .focused($focus, equals: .comments)
                .accessibilityLabel("録画の実況を設定")
            } else {
                Menu(liveCommentsEnabled ? "実況：表示" : "実況：非表示") {
                    Button(liveCommentsEnabled ? "実況を非表示にする" : "実況を表示する") {
                        liveCommentsEnabled.toggle()
                    }
                    if liveCommentsEnabled {
                        Menu("表示の遅延：\(Int(safeDelay))秒") {
                            ForEach([0, 1, 2, 3, 5, 10], id: \.self) { value in
                                Button(value == Int(safeDelay) ? "✓ \(value)秒" : "\(value)秒") {
                                    liveCommentDelay = Double(value)
                                }
                            }
                        }
                        Button("実況に再接続") { liveCommentReload() }
                    }
                }
                .focused($focus, equals: .comments)
                .accessibilityLabel("ライブの実況を設定")
            }

            if audioOptions.count > 1 {
                Menu("音声") {
                    ForEach(audioOptions) { option in
                        Button(option.id == selectedAudioID ? "✓ \(option.name)" : option.name) {
                            selectAudio(option.id)
                        }
                    }
                }
                .focused($focus, equals: .audio)
                .disabled(isLoading || failure != nil)
                .accessibilityLabel("音声を選択")
            }

            Button("画質：\(quality)") {
                // Clear the parent focus before adding the child focus section.
                // This prevents the top panel's Down handler from receiving a
                // command while the quality card is taking over the remote.
                focus = nil
                isQualityOverlayPresented = true
            }
            .focused($focus, equals: .quality)
            .disabled(isLoading)

            Button("閉じる", action: close)
                .focused($focus, equals: .panelClose)
        }
        .frame(maxWidth: .infinity)
        // Keep this card in the current playback view hierarchy.  An overlay
        // does not replace the native video view or change the panel's layout
        // size, unlike a presentation sheet.
        .disabled(isQualityOverlayPresented)
        .allowsHitTesting(!isQualityOverlayPresented)
        .accessibilityHidden(isQualityOverlayPresented)
        .overlay(alignment: .topTrailing) {
            if isQualityOverlayPresented {
                QualityChoicesView(
                    currentQuality: quality,
                    values: qualityValues,
                    onSelect: finishQualitySelection,
                    onClose: { dismissQualityOverlay(restoreFocus: true) }
                )
                // The controls above are disabled while the card is open, but
                // the card itself must remain interactive and focusable.
                .disabled(false)
                .padding(.top, 20)
                .padding(.trailing, 20)
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .focusSection()
        .onChange(of: isActive) { _, active in
            // Loading and failure states remove the top panel's active focus.
            // Close the card without trying to focus a disabled quality button.
            if !active { dismissQualityOverlay(restoreFocus: false) }
        }
    }

    private var safeDelay: Double {
        liveCommentDelay.isFinite ? min(10, max(0, liveCommentDelay)) : 2
    }

    private func dismissQualityOverlay(restoreFocus: Bool) {
        guard isQualityOverlayPresented else { return }
        isQualityOverlayPresented = false
        if restoreFocus, isActive {
            focus = .quality
        }
    }

    private func finishQualitySelection(_ value: String) {
        isQualityOverlayPresented = false
        if isActive {
            focus = .quality
        }
        selectQuality(value)
    }
}

private struct QualityChoicesView: View {
    private enum FocusTarget: Hashable {
        case option(String)
        case close
    }

    let currentQuality: String
    let values: [String]
    let onSelect: (String) -> Void
    let onClose: () -> Void
    @FocusState private var focusedTarget: FocusTarget?

    private var initialFocus: FocusTarget {
        if let current = values.first(where: { $0 == currentQuality }) {
            return .option(current)
        }
        if let first = values.first {
            return .option(first)
        }
        return .close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("画質を選択")
                .font(.title2)
            ForEach(values, id: \.self) { value in
                Button {
                    onSelect(value)
                } label: {
                    HStack(spacing: 16) {
                        Text(value)
                        Spacer()
                        if value == currentQuality {
                            Text("✓")
                                .accessibilityLabel("現在の画質")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                }
                .focused($focusedTarget, equals: .option(value))
            }
            Button("戻る", action: onClose)
                .focused($focusedTarget, equals: .close)
        }
        .padding(40)
        .frame(width: 680)
        .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .focusSection()
        .defaultFocus($focusedTarget, initialFocus)
        .onAppear { focusedTarget = initialFocus }
        .onExitCommand(perform: onClose)
    }
}
