import Foundation
import RingonomiCore
import SwiftUI

/// An edge of the video frame that can be cropped while the player is open.
enum VideoViewportEdge: String, CaseIterable, Hashable, Sendable {
    case left
    case top
    case right
    case bottom

    var title: String {
        switch self {
        case .left: return "左"
        case .top: return "上"
        case .right: return "右"
        case .bottom: return "下"
        }
    }
}

/// In-memory L-shaped crop settings for the current player.
///
/// The setting is deliberately not persisted. A crop that is useful for one
/// broadcast should not silently affect the next program or channel.
@MainActor
final class VideoViewportSettings: ObservableObject {
    @Published private(set) var crop: VideoViewportCrop = .identity
    @Published private(set) var isPresented = false

    func open() {
        isPresented = true
    }

    func close() {
        isPresented = false
    }

    func reset() {
        crop = .identity
    }

    func applyPreset(_ preset: VideoViewportPreset) {
        crop = preset.crop
    }

    func value(for edge: VideoViewportEdge) -> Double {
        switch edge {
        case .left: return crop.left
        case .top: return crop.top
        case .right: return crop.right
        case .bottom: return crop.bottom
        }
    }

    /// Returns whether the requested one-step change can be applied.
    func canAdjust(edge: VideoViewportEdge, by delta: Double) -> Bool {
        guard let nextValue = boundedValue(for: edge, by: delta) else { return false }
        return nextValue != value(for: edge)
    }

    /// Adjusts one edge while preserving the Core crop invariants.
    ///
    /// The view uses 0.01 steps. The method accepts a finite delta so future
    /// direct-adjustment controls can use a larger step without bypassing the
    /// same bounds checks.
    func adjust(edge: VideoViewportEdge, by delta: Double) {
        guard let nextValue = boundedValue(for: edge, by: delta),
              nextValue != value(for: edge) else { return }

        var values = valuesByEdge
        values[edge] = nextValue
        guard let nextCrop = try? VideoViewportCrop(
            left: values[.left] ?? 0,
            top: values[.top] ?? 0,
            right: values[.right] ?? 0,
            bottom: values[.bottom] ?? 0
        ) else {
            return
        }
        crop = nextCrop
    }

    private var valuesByEdge: [VideoViewportEdge: Double] {
        [
            .left: crop.left,
            .top: crop.top,
            .right: crop.right,
            .bottom: crop.bottom
        ]
    }

    private func boundedValue(for edge: VideoViewportEdge, by delta: Double) -> Double? {
        guard delta.isFinite else { return nil }

        let current = value(for: edge)
        let otherEdge: Double
        switch edge {
        case .left: otherEdge = crop.right
        case .top: otherEdge = crop.bottom
        case .right: otherEdge = crop.left
        case .bottom: otherEdge = crop.top
        }

        let maximum = min(
            VideoViewportCrop.maximumEdge,
            max(0, 1 - VideoViewportCrop.minimumRemainingExtent - otherEdge)
        )
        return min(max(current + delta, 0), maximum)
    }
}

/// A tvOS-friendly editor for the current playback viewport.
struct VideoViewportSettingsView: View {
    @ObservedObject private var settings: VideoViewportSettings
    let onClose: () -> Void

    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case preset(String)
        case adjust(VideoViewportEdge, Int)
        case reset
        case close
    }

    init(settings: VideoViewportSettings, onClose: @escaping () -> Void) {
        _settings = ObservedObject(wrappedValue: settings)
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.48)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())

                panel
                    .frame(maxWidth: min(1_060, max(0, geometry.size.width - 96)))
                    .padding(.horizontal, 48)
                    .padding(.bottom, 42)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusSection()
        .defaultFocus($focusedAction, .preset("leftL"))
        .onAppear {
            if focusedAction == nil { focusedAction = .preset("leftL") }
        }
        .onExitCommand(perform: close)
        // Consume Play/Pause while this overlay owns the remote focus.
        .onPlayPauseCommand { }
        .accessibilityElement(children: .contain)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("映像のクロップ")
                        .font(.title3.weight(.semibold))
                    Text("放送画面の端を隠します。設定はこの視聴中だけ有効です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(cropSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("現在のクロップ")
                    .accessibilityValue(cropSummary)
            }

            HStack(spacing: 12) {
                presetButton("なし", preset: .identity, id: "identity")
                presetButton("左L", preset: .leftL, id: "leftL")
                presetButton("右L", preset: .rightL, id: "rightL")
                presetButton("下帯", preset: .bottomBar, id: "bottomBar")
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                ForEach(VideoViewportEdge.allCases, id: \.self) { edge in
                    edgeRow(edge)
                }
            }

            HStack(spacing: 12) {
                Spacer()
                actionButton(
                    title: "元に戻す",
                    action: .reset,
                    isDisabled: settings.crop == .identity,
                    accessibilityLabel: "クロップを元に戻す"
                ) {
                    settings.reset()
                }
                actionButton(
                    title: "閉じる",
                    action: .close,
                    accessibilityLabel: "クロップ設定を閉じる",
                    perform: close
                )
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.opacity(0.82))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func edgeRow(_ edge: VideoViewportEdge) -> some View {
        HStack(spacing: 12) {
            Text(edge.title)
                .frame(width: 40, alignment: .leading)
            Text(percent(for: edge))
                .font(.body.monospacedDigit())
                .frame(width: 62, alignment: .trailing)
                .accessibilityLabel("\(edge.title)側")
                .accessibilityValue(percent(for: edge))
            Spacer(minLength: 12)
            actionButton(
                title: "−1%",
                action: .adjust(edge, -1),
                isDisabled: !settings.canAdjust(edge: edge, by: -0.01),
                accessibilityLabel: "\(edge.title)側を1パーセント減らす"
            ) {
                settings.adjust(edge: edge, by: -0.01)
            }
            actionButton(
                title: "+1%",
                action: .adjust(edge, 1),
                isDisabled: !settings.canAdjust(edge: edge, by: 0.01),
                accessibilityLabel: "\(edge.title)側を1パーセント増やす"
            ) {
                settings.adjust(edge: edge, by: 0.01)
            }
        }
    }

    private func presetButton(
        _ title: String,
        preset: VideoViewportPreset,
        id: String
    ) -> some View {
        actionButton(
            title: settings.crop == preset.crop ? "\(title) ✓" : title,
            action: .preset(id),
            accessibilityLabel: "クロップ\(title)",
            accessibilityValue: settings.crop == preset.crop ? "選択中" : nil
        ) {
            settings.applyPreset(preset)
        }
    }

    private func actionButton(
        title: String,
        action: Action,
        isDisabled: Bool = false,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(focusedAction == action ? Color.black : Color.white)
                .frame(minWidth: 86, minHeight: 42)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(focusedAction == action ? Color.white : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedAction, equals: action)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
    }

    private var cropSummary: String {
        let total = settings.crop.left + settings.crop.top + settings.crop.right + settings.crop.bottom
        return total == 0 ? "クロップなし" : "合計 \(Int((total * 100).rounded()))%"
    }

    private func percent(for edge: VideoViewportEdge) -> String {
        "\(Int((settings.value(for: edge) * 100).rounded()))%"
    }

    private func close() {
        onClose()
    }
}
