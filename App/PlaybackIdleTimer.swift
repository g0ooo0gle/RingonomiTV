import Combine
import UIKit

/// Keep video visible without changing the system's normal sleep settings.
@MainActor
final class PlaybackIdleTimer: ObservableObject {
    private var needsContinuousDisplay = false
    private var applicationIsActive = UIApplication.shared.applicationState == .active
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        observe(UIApplication.didBecomeActiveNotification, active: true)
        observe(UIApplication.willResignActiveNotification, active: false)
        observe(UIApplication.didEnterBackgroundNotification, active: false)
    }

    func setNeedsContinuousDisplay(_ needed: Bool) {
        needsContinuousDisplay = needed
        applicationIsActive = UIApplication.shared.applicationState == .active
        updateTimer()
    }

    private func observe(_ name: Notification.Name, active: Bool) {
        NotificationCenter.default.publisher(for: name)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applicationIsActive = active
                self?.updateTimer()
            }
            .store(in: &subscriptions)
    }

    private func updateTimer() {
        let preventsSleep = needsContinuousDisplay && applicationIsActive
        UIApplication.shared.isIdleTimerDisabled = preventsSleep
#if DEBUG
        print("RingonomiIdleTimer: disabled=\(UIApplication.shared.isIdleTimerDisabled) needsDisplay=\(needsContinuousDisplay) applicationActive=\(applicationIsActive)")
#endif
    }
}
