import SwiftUI

/// A focus-stable card for recorded and live comment settings.
///
/// The parent owns the comment stores and closes this card before performing
/// a callback. Keeping the input state in the parent prevents a stale card
/// from changing a different playback item after a request has started.
struct PlaybackCommentChoicesView: View {
    private enum Choice: Hashable {
        case toggle
        case delay(Int)
        case reload
        case reconnect
        case close

        var identifier: String {
            switch self {
            case .toggle: return "toggle"
            case .delay(let seconds): return "delay.\(seconds)"
            case .reload: return "reload"
            case .reconnect: return "reconnect"
            case .close: return "close"
            }
        }
    }

    private struct ContentRevision: Equatable {
        let rows: [Choice]
        let isRecording: Bool
        let enabled: Bool
        let loading: Bool
        let status: String?
    }

    private let liveDelayValues = [0, 1, 2, 3, 5, 10]

    let isRecording: Bool
    let enabled: Bool
    let delay: Double
    let loading: Bool
    let status: String?
    let onSetEnabled: (Bool) -> Void
    let onSetDelay: (Double) -> Void
    let onReload: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedChoice: Choice?
    @State private var didSetInitialFocus = false

    private var title: String {
        isRecording ? "録画の実況" : "ライブの実況"
    }

    private var toggleTitle: String {
        enabled ? "実況を非表示にする" : "実況を表示する"
    }

    private var selectedDelay: Int {
        let safeDelay = delay.isFinite ? min(10, max(0, delay)) : 2
        return liveDelayValues.min(by: { abs(Double($0) - safeDelay) < abs(Double($1) - safeDelay) }) ?? 2
    }

    private var disabledAction: Choice {
        isRecording ? .reload : .reconnect
    }

    private var rowIDs: [Choice] {
        var rows: [Choice] = [.toggle]
        if enabled {
            if isRecording {
                rows.append(.reload)
            } else {
                rows += liveDelayValues.map { .delay($0) }
                rows.append(.reconnect)
            }
        }
        rows.append(.close)
        return rows
    }

    private var contentRevision: ContentRevision {
        ContentRevision(rows: rowIDs, isRecording: isRecording, enabled: enabled,
                        loading: loading, status: status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .accessibilityAddTraits(.isHeader)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        actionButton(
                            toggleTitle,
                            choice: .toggle,
                            selected: enabled,
                            action: { onSetEnabled(!enabled) }
                        )

                        if let status {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 6)
                        }

                        if enabled {
                            Divider()
                            if isRecording {
                                actionButton(
                                    "過去ログを再取得",
                                    choice: .reload,
                                    disabled: loading,
                                    action: onReload
                                )
                            } else {
                                Text("表示の遅延")
                                    .font(.headline)
                                    .padding(.horizontal, 24)
                                    .padding(.top, 4)

                                ForEach(liveDelayValues, id: \.self) { seconds in
                                    actionButton(
                                        "\(seconds)秒",
                                        choice: .delay(seconds),
                                        selected: selectedDelay == seconds,
                                        action: { onSetDelay(Double(seconds)) }
                                    )
                                }

                                actionButton(
                                    "実況に再接続",
                                    choice: .reconnect,
                                    disabled: loading,
                                    action: onReload
                                )
                            }
                        }

                        Divider()
                        actionButton("戻る", choice: .close, action: onClose)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
                }
                .frame(height: scrollHeight)
                .task {
                    guard !didSetInitialFocus else { return }
                    didSetInitialFocus = true
                    focusedChoice = .toggle
                    scroll(to: .toggle, using: proxy)
                }
                .task(id: contentRevision) {
                    // Loading and status changes alter the card height. Wait
                    // for that layout pass before keeping the current row in
                    // view.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll(to: focusedChoice, using: proxy)
                }
                .onChange(of: focusedChoice) { _, newChoice in
                    scroll(to: newChoice, using: proxy)
#if DEBUG
                    print("RingonomiCommentCardFocus: \(newChoice?.identifier ?? "none")")
#endif
                }
                .onChange(of: rowIDs) { _, updatedIDs in
                    guard let focusedChoice,
                          !updatedIDs.contains(focusedChoice) else { return }
                    self.focusedChoice = .toggle
                    scroll(to: .toggle, using: proxy)
                }
                .onChange(of: loading) { _, isLoading in
                    guard isLoading, focusedChoice == disabledAction else { return }
                    focusedChoice = .close
                    scroll(to: .close, using: proxy)
                }
            }
        }
        .padding(40)
        .frame(width: 680)
        .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .focusSection()
        .defaultFocus($focusedChoice, .toggle)
        .onExitCommand(perform: onClose)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: enabled)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: selectedDelay)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        choice: Choice,
        selected: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard !disabled else { return }
            action()
        } label: {
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
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "選択中" : disabled ? "利用不可" : "利用可能")
        .accessibilityIdentifier("playback.commentChoice.\(choice.identifier)")
        .id(choice)
    }

    private var scrollHeight: CGFloat {
        let rows = CGFloat(max(4, rowIDs.count))
        return min(480, max(300, rows * 72))
    }

    private func scroll(to choice: Choice?, using proxy: ScrollViewProxy) {
        guard let choice else { return }
        if reduceMotion {
            proxy.scrollTo(choice, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                proxy.scrollTo(choice, anchor: .center)
            }
        }
    }
}
