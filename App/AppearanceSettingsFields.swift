import SwiftUI

struct AppearanceSettingsFields: View {
    @Binding var modeValue: String
    @Binding var styleValue: String

    var body: some View {
        Section("表示") {
            Picker("外観", selection: Binding(
                get: { AppAppearanceMode(rawValue: modeValue) ?? .system },
                set: { modeValue = $0.rawValue }
            )) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("settings.appearance.mode")

            Picker("配色", selection: Binding(
                get: { AppColorStyle(rawValue: styleValue) ?? .standard },
                set: { styleValue = $0.rawValue }
            )) {
                ForEach(AppColorStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .accessibilityIdentifier("settings.appearance.style")
        }
    }
}
