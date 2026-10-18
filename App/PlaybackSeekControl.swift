import SwiftUI

/// A tvOS-friendly seek control.  It uses a focusable button instead of a
/// Slider so the Siri Remote can preview a position with left/right and
/// commit it with Select.
struct PlaybackSeekControl: View {
    let position: Double
    let duration: Double
    let isEnabled: Bool
    @FocusState.Binding var focus: PlaybackControlFocus?
    @Binding var isEditing: Bool
    let onCommit: (Double) -> Void
    let onMoveCommand: (MoveCommandDirection) -> Void

    @State private var draftPosition: Double

    init(position: Double, duration: Double, isEnabled: Bool,
         focus: FocusState<PlaybackControlFocus?>.Binding, isEditing: Binding<Bool>,
         onCommit: @escaping (Double) -> Void,
         onMoveCommand: @escaping (MoveCommandDirection) -> Void) {
        self.position = position
        self.duration = duration
        self.isEnabled = isEnabled
        _focus = focus
        _isEditing = isEditing
        self.onCommit = onCommit
        self.onMoveCommand = onMoveCommand
        _draftPosition = State(initialValue: Self.clamp(position, duration: duration))
    }

    private var shownPosition: Double {
        isEditing ? draftPosition : Self.clamp(position, duration: duration)
    }

    var body: some View {
        Button(action: commit) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(Playback.timestamp(shownPosition))
                        .monospacedDigit()
                    Spacer()
                    Text(Playback.timestamp(duration))
                        .monospacedDigit()
                }
                ProgressView(value: shownPosition, total: duration)
                    .tint(isEditing ? .white : .secondary)
                Text(isEditing ? "決定で移動・戻るで取り消し" : "左右で移動先を選択")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.white.opacity(focus == .seek ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .seek)
        .disabled(!isEnabled)
        .onMoveCommand { direction in
            guard isEnabled else { return }
            switch direction {
            case .left:
                adjust(by: -10)
            case .right:
                adjust(by: 10)
            default:
                onMoveCommand(direction)
            }
        }
        .onChange(of: focus) { _, newFocus in
            if newFocus == .seek {
                draftPosition = Self.clamp(position, duration: duration)
            } else if isEditing {
                draftPosition = Self.clamp(position, duration: duration)
                isEditing = false
            }
        }
        .onChange(of: position) { _, newPosition in
            if !isEditing { draftPosition = Self.clamp(newPosition, duration: duration) }
        }
        .onChange(of: duration) { _, newDuration in
            draftPosition = Self.clamp(draftPosition, duration: newDuration)
        }
        .accessibilityLabel("録画の再生位置")
        .accessibilityValue("\(Playback.timestamp(shownPosition)) / \(Playback.timestamp(duration))")
    }

    private func adjust(by seconds: Double) {
        let basePosition = isEditing ? draftPosition : position
        draftPosition = Self.clamp(basePosition + seconds, duration: duration)
        isEditing = true
#if DEBUG
        print("RingonomiSeekPreview: target=\(draftPosition)")
#endif
    }

    private func commit() {
        guard isEnabled, isEditing else { return }
        isEditing = false
#if DEBUG
        print("RingonomiSeekCommit: target=\(draftPosition)")
#endif
        onCommit(Self.clamp(draftPosition, duration: duration))
    }

    private static func clamp(_ value: Double, duration: Double) -> Double {
        guard value.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(0, value), max(0, duration - 0.1))
    }
}
