import Combine
import Foundation
import RingonomiCore

@MainActor
final class EPGStationProgramGuideStore: ObservableObject {
    @Published private(set) var snapshot: EPGStationGuideSnapshot?
    @Published private(set) var loadedRequestKey: String?
    @Published private(set) var loading = false
    @Published private(set) var cancelled = false
    @Published private(set) var error: String?

    private var request: Task<Void, Never>?
    private var generation = UUID()

    deinit {
        request?.cancel()
    }

    func load(
        requestKey: String,
        address: String,
        startAt: Double,
        endAt: Double,
        broadcast: EPGStationGuideBroadcast
    ) {
        request?.cancel()
        let expected = UUID()
        generation = expected
        snapshot = nil
        loadedRequestKey = nil
        error = nil
        cancelled = false
        loading = true

        request = Task { @MainActor [weak self] in
            do {
                let client = try EPGStationClient(address: address)
                let schedules = try await client.programGuide(
                    startAt: startAt,
                    endAt: endAt,
                    broadcast: broadcast
                )
                try Task.checkCancellation()
                let snapshot = try EPGStationGuideSnapshot(schedules: schedules)
                try Task.checkCancellation()
                guard let self, generation == expected else { return }
                self.snapshot = snapshot
                self.loadedRequestKey = requestKey
                loading = false
#if DEBUG
                print("RingonomiEPGStationGuideReady: channels=\(snapshot.response.channels.count)")
#endif
            } catch is CancellationError {
                guard let self, generation == expected else { return }
                loading = false
                cancelled = true
            } catch {
                guard let self, generation == expected, !Task.isCancelled else { return }
                snapshot = nil
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    func cancel(clear: Bool = false) {
        let wasLoading = loading
        generation = UUID()
        request?.cancel()
        request = nil
        loading = false
        if clear {
            snapshot = nil
            loadedRequestKey = nil
            error = nil
            cancelled = false
        } else if wasLoading {
            cancelled = true
        }
    }
}
