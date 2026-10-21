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
    case scenes
    case playPause
    case captions
    case comments
    case audio
    case quality
    case viewport
    case pictureInPicture
    case miniPlayer
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
    @Binding var liveCaptionsEnabled: Bool
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
    let pictureInPictureSupported: Bool
    let pictureInPicturePossible: Bool
    let pictureInPictureBusy: Bool
    let startPictureInPicture: () -> Void
    let startMiniPlayer: () -> Void
    let close: () -> Void
    let openViewport: () -> Void
    @FocusState.Binding var focus: PlaybackControlFocus?
    @Binding var isAudioOverlayPresented: Bool
    @Binding var isCaptionOverlayPresented: Bool
    @Binding var isQualityOverlayPresented: Bool

    private var captionsEnabled: Bool { isRecording ? recordingCaptionsEnabled : liveCaptionsEnabled }
    private var isChoicePresented: Bool { isAudioOverlayPresented || isCaptionOverlayPresented || isQualityOverlayPresented }

    var body: some View {
        HStack(spacing: 24) {
            if isRecording {
                Menu(captionsEnabled ? "字幕：表示" : "字幕：非表示") {
                    Button(captionsEnabled ? "字幕を非表示にする" : "字幕を表示する") {
                        recordingCaptionsEnabled.toggle()
                    }
                }
                .focused($focus, equals: .captions)
                .accessibilityLabel("録画の字幕")
                .accessibilityValue(captionsEnabled ? "表示" : "非表示")
                .accessibilityIdentifier("playback.captions")
            } else {
                Button(captionsEnabled ? "字幕：表示" : "字幕：非表示") {
                    focus = nil
                    isCaptionOverlayPresented = true
                }
                .focused($focus, equals: .captions)
                .accessibilityLabel("ライブの字幕")
                .accessibilityValue(captionsEnabled ? "表示" : "非表示")
                .accessibilityIdentifier("playback.captions")
            }

            if isRecording {
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
                .accessibilityLabel("録画の実況")
                .accessibilityValue(recordingCommentsEnabled ? "表示" : "非表示")
                .accessibilityIdentifier("playback.comments")
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
                                .accessibilityLabel("\(value)秒")
                                .accessibilityValue(value == Int(safeDelay) ? "選択中" : "未選択")
                                .accessibilityIdentifier("playback.commentDelay.\(value)")
                            }
                        }
                        .accessibilityLabel("実況表示の遅延")
                        .accessibilityValue("\(Int(safeDelay))秒")
                        .accessibilityIdentifier("playback.commentDelay")
                        Button("実況に再接続") { liveCommentReload() }
                    }
                }
                .focused($focus, equals: .comments)
                .accessibilityLabel("ライブの実況")
                .accessibilityValue(liveCommentsEnabled ? "表示" : "非表示")
                .accessibilityIdentifier("playback.comments")
            }

            if audioOptions.count > 1 {
                Button("音声") {
                    focus = nil
                    isAudioOverlayPresented = true
#if DEBUG
                    print("RingonomiAudioOverlay: opened")
#endif
                }
                .focused($focus, equals: .audio)
                .accessibilityLabel("音声を選択")
                .accessibilityValue(audioOptions.first(where: { $0.id == selectedAudioID })?.name ?? "選択情報なし")
                .accessibilityIdentifier("playback.audio")
            }

            Button("画質：\(quality)") {
                // Clear the parent focus before adding the child focus section.
                // This prevents the top panel's Down handler from receiving a
                // command while the quality card is taking over the remote.
                focus = nil
                isQualityOverlayPresented = true
#if DEBUG
                print("RingonomiQualityOverlay: opened current=\(quality)")
#endif
            }
            .focused($focus, equals: .quality)
            .disabled(isLoading)
            .accessibilityLabel("画質")
            .accessibilityValue(quality)
            .accessibilityIdentifier("playback.quality")

            Button("小窓", action: startMiniPlayer)
                .focused($focus, equals: .miniPlayer)
                .disabled(isLoading || failure != nil || pictureInPictureBusy)
                .accessibilityLabel("アプリ内小窓で表示")
                .accessibilityHint("再生を続けながら一覧を操作します")
                .accessibilityIdentifier("playback.miniPlayer")

            if pictureInPictureSupported {
                Button("PiP", action: startPictureInPicture)
                    .focused($focus, equals: .pictureInPicture)
                    .disabled(isLoading || failure != nil || !pictureInPicturePossible || pictureInPictureBusy)
                    .accessibilityLabel("録画を小窓で表示")
                    .accessibilityHint("小窓には映像と音声を表示します")
                    .accessibilityIdentifier("playback.pictureInPicture")
            }

            Button("画面", action: openViewport)
                .focused($focus, equals: .viewport)
                .disabled(isLoading || failure != nil)
                .accessibilityLabel("映像のクロップを調整")

            Button("閉じる", action: close)
                .focused($focus, equals: .panelClose)
        }
        .frame(maxWidth: .infinity)
        // Keep the top controls in the current playback view hierarchy while
        // a selection card is hosted by the full-screen player ZStack.
        .disabled(isChoicePresented)
        .allowsHitTesting(!isChoicePresented)
        .accessibilityHidden(isChoicePresented)
        .focusSection()
        .onChange(of: isActive) { _, active in
            // Loading and failure states remove the top panel's active focus.
            // Close the card without trying to focus a disabled selection button.
            if !active {
                isQualityOverlayPresented = false
                isCaptionOverlayPresented = false
                isAudioOverlayPresented = false
            }
        }
    }

    private var safeDelay: Double {
        liveCommentDelay.isFinite ? min(10, max(0, liveCommentDelay)) : 2
    }
}

struct QualityChoicesView: View {
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
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                }
                .focused($focusedTarget, equals: .option(value))
                .accessibilityLabel("画質 \(value)")
                .accessibilityValue(value == currentQuality ? "選択中" : "未選択")
                .accessibilityIdentifier("playback.quality.\(value)")
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
    }
}
