import SwiftUI

/// A focus-friendly caption picker for the live playback panel.
///
/// Native `Menu` controls can make the video surface lose too much time while
/// the menu is open on older Apple TV hardware. Keeping the choices in an
/// opaque card also gives the remote a stable focus section to navigate.
struct PlaybackCaptionChoicesView: View {
    private enum Choice: Hashable {
        case show
        case hide
        case reload
        case close
    }

    let enabled: Bool
    let canReload: Bool
    let onSelect: (Bool) -> Void
    let onReload: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedChoice: Choice?

    private var initialChoice: Choice {
        enabled ? .show : .hide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("字幕表示")
                .font(.title2)

            choiceButton("表示", choice: .show, selected: enabled) {
                onSelect(true)
            }

            choiceButton("非表示", choice: .hide, selected: !enabled) {
                onSelect(false)
            }

            Button("映像と字幕を再読み込み", action: onReload)
                .focused($focusedChoice, equals: .reload)
                .disabled(!canReload)
                .accessibilityLabel("映像と字幕を再読み込み")
                .accessibilityValue(canReload ? "利用可能" : "利用不可")
                .accessibilityIdentifier("playback.captionChoice.reload")
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

            Button("戻る", action: onClose)
                .focused($focusedChoice, equals: .close)
                .accessibilityIdentifier("playback.captionChoice.close")
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .padding(40)
        .frame(width: 680)
        .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .focusSection()
        .defaultFocus($focusedChoice, initialChoice)
        .task {
            focusedChoice = initialChoice
        }
        .onExitCommand(perform: onClose)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: enabled)
    }

    @ViewBuilder
    private func choiceButton(
        _ title: String,
        choice: Choice,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Text("✓")
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .focused($focusedChoice, equals: choice)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "選択中" : "未選択")
        .accessibilityIdentifier(
            choice == .show
                ? "playback.captionChoice.show"
                : "playback.captionChoice.hide"
        )
    }
}
