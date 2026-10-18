import SwiftUI
import RingonomiCore

/// Focus targets used by the two playback panels and the video surface.
enum PlaybackControlFocus: String, Hashable {
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
    let isLoading: Bool
    let failure: String?
    let audioOptions: [PlaybackAudioOption]
    let selectedAudioID: String?
    let selectAudio: (String) -> Void
    let selectQuality: (String) -> Void
    let close: () -> Void
    @FocusState.Binding var focus: PlaybackControlFocus?

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

            Menu("画質：\(quality)") {
                ForEach(qualityValues, id: \.self) { value in
                    Button(value == quality ? "✓ \(value)" : value) {
                        guard value != quality else { return }
                        selectQuality(value)
                    }
                }
            }
            .focused($focus, equals: .quality)
            .disabled(isLoading)

            Button("閉じる", action: close)
                .focused($focus, equals: .close)
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }

    private var safeDelay: Double {
        liveCommentDelay.isFinite ? min(10, max(0, liveCommentDelay)) : 2
    }
}
