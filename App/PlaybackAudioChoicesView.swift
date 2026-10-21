import RingonomiCore
import SwiftUI

/// A focus-stable audio track picker for the playback overlay.
struct PlaybackAudioChoicesView: View {
    private enum Choice: Hashable {
        case option(String)
        case close
    }

    let options: [PlaybackAudioOption]
    let selectedID: String?
    let isEnabled: Bool
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedChoice: Choice?

    private var optionIDs: [String] {
        options.map(\.id)
    }

    private var initialChoice: Choice {
        initialChoice(for: options)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音声を選択")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(options) { option in
                            optionButton(option)
                                .id(option.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: optionsHeight)
                .task {
                    if focusedChoice == nil {
                        focusedChoice = initialChoice
                    }
                    scroll(to: focusedChoice ?? initialChoice, using: proxy)
                }
                .onChange(of: focusedChoice) { _, newChoice in
                    scroll(to: newChoice, using: proxy)
                }
                .onChange(of: optionIDs) { _, updatedIDs in
                    guard case .option(let focusedID) = focusedChoice,
                          !updatedIDs.contains(focusedID) else { return }
                    let nextChoice = initialChoice(for: options)
                    focusedChoice = nextChoice
                    scroll(to: nextChoice, using: proxy)
                }
            }

            Button("戻る", action: onClose)
                .focused($focusedChoice, equals: .close)
                .accessibilityLabel("戻る")
                .accessibilityIdentifier("playback.audioChoice.close")
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
        .onExitCommand(perform: onClose)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: selectedID)
    }

    @ViewBuilder
    private func optionButton(_ option: PlaybackAudioOption) -> some View {
        let selected = option.id == selectedID
        Button {
            guard isEnabled, options.contains(where: { $0.id == option.id }) else { return }
            onSelect(option.id)
        } label: {
            HStack(alignment: .top, spacing: 16) {
                Text(option.name)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .layoutPriority(1)
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
        .focused($focusedChoice, equals: .option(option.id))
        .disabled(!isEnabled)
        .accessibilityLabel(option.name)
        .accessibilityValue(selected ? "選択中" : "未選択")
        .accessibilityIdentifier("playback.audio.option.\(option.id)")
    }

    private var optionsHeight: CGFloat {
        let rowHeight: CGFloat = 108
        let rowSpacing: CGFloat = 10
        let count = CGFloat(options.count)
        let spacing = CGFloat(max(0, options.count - 1)) * rowSpacing
        return min(360, max(56, count * rowHeight + spacing))
    }

    private func scroll(to choice: Choice?, using proxy: ScrollViewProxy) {
        guard case .option(let id) = choice else { return }
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func initialChoice(for currentOptions: [PlaybackAudioOption]) -> Choice {
        if let selectedID,
           currentOptions.contains(where: { $0.id == selectedID }) {
            return .option(selectedID)
        }
        if let first = currentOptions.first {
            return .option(first.id)
        }
        return .close
    }
}
