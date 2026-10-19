#if DEBUG
import UIKit

/// Opt-in device diagnostics for the playback controls, using public UIKit APIs.
/// Input fields and unrelated screens are deliberately excluded.
@MainActor
enum PlaybackAccessibilityDiagnostics {
    private static var observers: [NSObjectProtocol] = []
    private static var timer: Timer?
    private static var previousRecord: String?
    private static var previousInspection: String?

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
        ) { notification in
            // Delivery and consumption are synchronous on the main queue. The
            // UIKit element must not be transferred to a task or another queue.
            nonisolated(unsafe) let element = notification.userInfo?[UIAccessibility.focusedElementUserInfoKey]
            MainActor.assumeIsolated {
                reportFocus(element)
            }
        })
        // Some tvOS controls change the UIKit focus without posting this notification.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { reportFocus() }
        }
    }

    private static func reportStatus() {
        print("RingonomiAccessibilityStatus: voiceOver=\(UIAccessibility.isVoiceOverRunning)")
    }

    private static func reportFocus(_ notifiedElement: Any? = nil) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let element = (notifiedElement
            ?? UIAccessibility.focusedElement(using: .notificationVoiceOver)) as? NSObject
        let identifier = element.flatMap { accessibilityIdentifier(of: $0) }
        let inspection = "element=\(element != nil) identifier=\(identifier != nil)"
        if inspection != previousInspection {
            previousInspection = inspection
            print("RingonomiAccessibilityInspection: \(inspection)")
        }
        guard let element, let identifier,
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
              let text = String(data: data, encoding: .utf8),
              text != previousRecord else { return }
        previousRecord = text
        print("RingonomiAccessibilityFocus: \(text)")
    }

    private static func accessibilityIdentifier(of element: NSObject) -> String? {
        if let identified = element as? any UIAccessibilityIdentification {
            return identified.accessibilityIdentifier
        }
        // SwiftUI accessibility elements can implement the public getter without
        // declaring UIAccessibilityIdentification conformance.
        let selector = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }
}
#endif
