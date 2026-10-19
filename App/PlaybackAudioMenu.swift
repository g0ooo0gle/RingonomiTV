import RingonomiCore
import SwiftUI

/// Keeps the visible selection and its spoken value consistent across players.
struct PlaybackAudioMenu: View {
    let options: [PlaybackAudioOption]
    let selectedID: String?
    let isDisabled: Bool
    let onSelect: (String) -> Void

    private var selectedName: String {
        options.first(where: { $0.id == selectedID })?.name ?? "選択情報なし"
    }

    var body: some View {
        Menu("音声") {
            ForEach(options) { option in
                Button(option.id == selectedID ? "✓ \(option.name)" : option.name) {
                    onSelect(option.id)
                }
                .accessibilityLabel(option.name)
                .accessibilityValue(option.id == selectedID ? "選択中" : "未選択")
                .accessibilityIdentifier("playback.audio.option.\(option.id)")
            }
        }
        .disabled(isDisabled)
        .accessibilityLabel("音声を選択")
        .accessibilityValue(selectedName)
        .accessibilityIdentifier("playback.audio")
    }
}
