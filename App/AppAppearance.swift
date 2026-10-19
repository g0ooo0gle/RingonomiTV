import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, dark, light

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "システム"
        case .dark: return "ダーク"
        case .light: return "ライト"
        }
    }
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

enum AppColorStyle: String, CaseIterable, Identifiable, Sendable {
    case standard, spring, summer, autumn, winter

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "標準"
        case .spring: return "春"
        case .summer: return "夏"
        case .autumn: return "秋"
        case .winter: return "冬"
        }
    }
    func palette(for colorScheme: ColorScheme) -> AppColorPalette {
        AppColorPalette(style: self, colorScheme: colorScheme)
    }
}

/// Colors for the library and guide. Video controls retain their dark appearance.
struct AppColorPalette {
    let background: Color
    let surface: Color
    let selection: Color
    let accent: Color
    private let isDark: Bool

    var primaryText: Color { isDark ? .white : .black }
    var secondaryText: Color { primaryText.opacity(isDark ? 0.74 : 0.68) }
    var inactiveSelection: Color { isDark ? .white.opacity(0.16) : Color(rgb: 0xD6DBE6) }
    var selectionOutline: Color { primaryText.opacity(isDark ? 0.50 : 0.35) }
    var gridLine: Color { primaryText.opacity(isDark ? 0.18 : 0.16) }
    var currentTime: Color { Color(rgb: isDark ? 0xFF665B : 0xB81212) }
    var reservation: Color { currentTime }

    fileprivate init(style: AppColorStyle, colorScheme: ColorScheme) {
        isDark = colorScheme == .dark
        switch style {
        case .standard:
            background = Color(rgb: isDark ? 0x0E1116 : 0xF5F7FA)
            surface = Color(rgb: isDark ? 0x1F242E : 0xE0E6ED)
            selection = Color(rgb: isDark ? 0x2E475C : 0xC7DEF5)
            accent = Color(rgb: isDark ? 0x00C7FF : 0x005DA8)
        case .spring:
            background = Color(rgb: isDark ? 0x0B1813 : 0xF2FAF0)
            surface = Color(rgb: isDark ? 0x1A2E24 : 0xDBF0DB)
            selection = Color(rgb: isDark ? 0x295738 : 0xC2E8C2)
            accent = Color(rgb: isDark ? 0x4DE68C : 0x147A33)
        case .summer:
            background = Color(rgb: isDark ? 0x09131F : 0xEDF7FF)
            surface = Color(rgb: isDark ? 0x14293D : 0xD6EBFA)
            selection = Color(rgb: isDark ? 0x1F476B : 0xBDDBFA)
            accent = Color(rgb: isDark ? 0x42C7FF : 0x0D59B3)
        case .autumn:
            background = Color(rgb: isDark ? 0x1F1109 : 0xFFF5E8)
            surface = Color(rgb: isDark ? 0x381F12 : 0xF5E0C7)
            selection = Color(rgb: isDark ? 0x66361A : 0xF5C794)
            accent = Color(rgb: isDark ? 0xFF942E : 0xB34008)
        case .winter:
            background = Color(rgb: isDark ? 0x0B1121 : 0xF0F5FF)
            surface = Color(rgb: isDark ? 0x1A2140 : 0xDBE6FA)
            selection = Color(rgb: isDark ? 0x29386B : 0xC2D1FA)
            accent = Color(rgb: isDark ? 0x80B8FF : 0x2E4DAD)
        }
    }

    // Genre colors stay consistent when the surrounding color family changes.
    func genreColor(for genre: String) -> Color {
        if genre.contains("ニュース") { return .blue }
        if genre.contains("スポーツ") { return .orange }
        if genre.contains("アニメ") { return .pink }
        if genre.contains("映画") { return .purple }
        if genre.contains("ドラマ") { return .teal }
        if genre.contains("音楽") { return .indigo }
        if genre.contains("ドキュメンタリー") { return .green }
        if genre.contains("バラエティ") { return .yellow }
        return isDark ? .gray : Color(rgb: 0x475059)
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

private struct AppColorStyleKey: EnvironmentKey {
    static let defaultValue = AppColorStyle.standard
}

extension EnvironmentValues {
    var appColorStyle: AppColorStyle {
        get { self[AppColorStyleKey.self] }
        set { self[AppColorStyleKey.self] = newValue }
    }
}
