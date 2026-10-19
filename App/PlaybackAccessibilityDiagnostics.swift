#if DEBUG
import UIKit

/// Opt-in device diagnostics for the playback controls, using public UIKit APIs.
/// Input fields and unrelated screens are deliberately excluded.
@MainActor
enum PlaybackAccessibilityDiagnostics {
    private static var observers: [NSObjectProtocol] = []

    static func start(arguments: [String]) {
        guard arguments.contains("--validate-accessibility"), observers.isEmpty else { return }
        reportStatus()
        observers.append(NotificationCenter.default.addObserver(
            forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { reportStatus() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { reportFocus() }
        })
    }

    private static func reportStatus() {
        print("RingonomiAccessibilityStatus: voiceOver=\(UIAccessibility.isVoiceOverRunning)")
    }

    private static func reportFocus() {
        guard UIAccessibility.isVoiceOverRunning,
              let element = UIAccessibility.focusedElement(using: .notificationVoiceOver) as? NSObject,
              let identifier = (element as? any UIAccessibilityIdentification)?.accessibilityIdentifier,
              identifier.hasPrefix("playback.") || identifier == "guide.grid" else { return }
        let label = element.accessibilityLabel ?? ""
        let value = element.accessibilityValue ?? ""
        let record = [
            "identifier": String(identifier.prefix(100)),
            "label": identifier == "guide.grid" ? "番組表" : String(label.prefix(240)),
            "labelCharacters": String(label.count),
            "value": String(value.prefix(240))
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print("RingonomiAccessibilityFocus: \(text)")
    }
}
#endif
