import Foundation
import Combine
import RingonomiCore

@MainActor
final class EPGStationReservationStore: ObservableObject {
    @Published private(set) var items: [EPGStationReservation] = []
    @Published private(set) var total = 0
    @Published private(set) var channelNames: [Int: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var cancelled = false
    @Published private(set) var error: String?
    private var request: Task<Void, Never>?
    private var channelRequest: Task<Void, Never>?
    private var generation = UUID()

    func load(address: String, offset: Int, filter: EPGStationReservationFilter) {
        request?.cancel()
        channelRequest?.cancel()
        let expected = UUID()
        generation = expected
        items = []
        total = 0
        channelNames = [:]
        loading = true
        cancelled = false
        error = nil
        let client: EPGStationClient
        do { client = try EPGStationClient(address: address) }
        catch {
            self.error = error.localizedDescription
            loading = false
            return
        }
        channelRequest = Task { @MainActor [weak self] in
            let channels = try? await client.channels()
            guard let self, generation == expected, !Task.isCancelled else { return }
            channelNames = epgStationChannelNames(channels ?? [])
            channelRequest = nil
        }
        request = Task { @MainActor [weak self] in
            do {
                let page = try await client.reservations(
                    offset: offset, limit: 30, filter: filter
                )
                try Task.checkCancellation()
                guard let self, generation == expected else { return }
                items = page.reservations
                total = page.total
                loading = false
#if DEBUG
                print("RingonomiEPGStationReservations: count=\(items.count) total=\(total) offset=\(offset)")
#endif
                request = nil
            } catch {
                guard let self, generation == expected, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
                request = nil
                channelRequest?.cancel()
                channelRequest = nil
            }
        }
    }

    func cancel(clear: Bool = false) {
        let wasLoading = loading
        generation = UUID()
        request?.cancel()
        channelRequest?.cancel()
        request = nil
        channelRequest = nil
        loading = false
        if clear {
            items = []
            total = 0
            channelNames = [:]
            error = nil
            cancelled = false
        } else if wasLoading {
            cancelled = true
        }
    }
}

@MainActor
final class EPGStationReservationDetailStore: ObservableObject {
    @Published private(set) var item: EPGStationReservation?
    @Published private(set) var channelNames: [Int: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var cancelled = false
    @Published private(set) var error: String?
    private var request: Task<Void, Never>?
    private var channelRequest: Task<Void, Never>?
    private var generation = UUID()

    func load(address: String, id: Int) {
        request?.cancel()
        channelRequest?.cancel()
        let expected = UUID()
        generation = expected
        item = nil
        channelNames = [:]
        loading = true
        cancelled = false
        error = nil
        let client: EPGStationClient
        do { client = try EPGStationClient(address: address) }
        catch {
            self.error = error.localizedDescription
            loading = false
            return
        }
        channelRequest = Task { @MainActor [weak self] in
            let channels = try? await client.channels()
            guard let self, generation == expected, !Task.isCancelled else { return }
            channelNames = epgStationChannelNames(channels ?? [])
            channelRequest = nil
        }
        request = Task { @MainActor [weak self] in
            do {
                let current = try await client.reservation(id: id)
                try Task.checkCancellation()
                guard let self, generation == expected else { return }
                item = current
                loading = false
#if DEBUG
                print("RingonomiEPGStationReservationDetail: ready")
#endif
                request = nil
            } catch {
                guard let self, generation == expected, !Task.isCancelled else { return }
                if error as? EPGStationError == .httpStatus(404) {
                    self.error = "この予約は見つかりません。一覧を更新して確認してください。"
                } else {
                    self.error = error.localizedDescription
                }
                loading = false
                request = nil
                channelRequest?.cancel()
                channelRequest = nil
            }
        }
    }

    func cancel() {
        let wasLoading = loading
        generation = UUID()
        request?.cancel()
        channelRequest?.cancel()
        request = nil
        channelRequest = nil
        loading = false
        if wasLoading { cancelled = true }
    }
}

private func epgStationChannelNames(_ channels: [EPGStationChannel]) -> [Int: String] {
    Dictionary(channels.map {
        let shortName = $0.halfWidthName.flatMap { $0.isEmpty ? nil : $0 }
        return ($0.id, shortName ?? $0.name)
    }, uniquingKeysWith: { first, _ in first })
}
