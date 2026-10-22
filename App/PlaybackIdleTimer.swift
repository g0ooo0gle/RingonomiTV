import Combine
import UIKit
import RingonomiCore

/// Each screen owns only its request, never the process-wide timer setting.
@MainActor
final class PlaybackIdleTimer: ObservableObject {
    private let ownerID = UUID()

    func setNeedsContinuousDisplay(_ needed: Bool) {
        PlaybackIdleTimerCoordinator.shared.setNeedsContinuousDisplay(needed, for: ownerID)
    }

    deinit {
        let retiredOwner = ownerID
        Task { @MainActor in
            PlaybackIdleTimerCoordinator.shared.setNeedsContinuousDisplay(false, for: retiredOwner)
        }
    }
}

/// UIKit has one idle timer for the entire app. Observe its lifecycle once
/// and keep it disabled until the last active playback request is released.
@MainActor
private final class PlaybackIdleTimerCoordinator {
    static let shared = PlaybackIdleTimerCoordinator()
    private var policy = PlaybackIdlePolicy()
    private var applicationIsActive = UIApplication.shared.applicationState == .active
    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        observe(UIApplication.didBecomeActiveNotification, active: true)
        observe(UIApplication.willResignActiveNotification, active: false)
        observe(UIApplication.didEnterBackgroundNotification, active: false)
    }

    func setNeedsContinuousDisplay(_ needed: Bool, for owner: UUID) {
        policy.setNeedsContinuousDisplay(needed, for: owner)
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
        let preventsSleep = policy.preventsSleep(applicationIsActive: applicationIsActive)
        if UIApplication.shared.isIdleTimerDisabled != preventsSleep {
            UIApplication.shared.isIdleTimerDisabled = preventsSleep
        }
#if DEBUG
        print("RingonomiIdleTimer: disabled=\(UIApplication.shared.isIdleTimerDisabled) playbackOwners=\(policy.requestCount) applicationActive=\(applicationIsActive)")
#endif
    }
}
