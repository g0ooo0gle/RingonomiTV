import Foundation
import Combine
import RingonomiCore

@MainActor
final class EPGStationRuleStore: ObservableObject {
    @Published private(set) var items: [EPGStationRule] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var cancelled = false
    @Published private(set) var error: String?
    @Published private(set) var lastReadAt: Date?
    private var request: Task<Void, Never>?
    private var generation = UUID()

    func load(address: String, offset: Int, keyword: String) {
        cancel(clear: true)
        let expected = generation
        loading = true
        request = Task { @MainActor [weak self] in
            do {
                let page = try await EPGStationClient(address: address).rules(offset: offset, limit: 30, filter: .all, keyword: keyword)
                try Task.checkCancellation()
                guard let self, generation == expected else { return }
                items = page.rules
                total = page.total
                lastReadAt = Date()
                loading = false
#if DEBUG
                print("RingonomiEPGStationRules: count=\(items.count) total=\(total) offset=\(offset)")
#endif
            } catch {
                guard let self, generation == expected, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    func cancel(clear: Bool = false) {
        let interrupted = loading
        generation = UUID()
        request?.cancel()
        request = nil
        loading = false
        if clear {
            items = []
            total = 0
            error = nil
            lastReadAt = nil
            cancelled = false
        } else if interrupted { cancelled = true }
    }
}

@MainActor
final class EPGStationRuleDetailStore: ObservableObject {
    @Published private(set) var item: EPGStationRule?
    @Published private(set) var reservations: [EPGStationReservation] = []
    @Published private(set) var reservationTotal = 0
    @Published private(set) var reservationError: String?
    @Published private(set) var loading = false
    @Published private(set) var cancelled = false
    @Published private(set) var error: String?
    private var request: Task<Void, Never>?
    private var generation = UUID()

    func load(address: String, id: Int) {
        cancel()
        let expected = generation
        item = nil
        reservations = []
        reservationTotal = 0
        reservationError = nil
        error = nil
        cancelled = false
        loading = true
        request = Task { @MainActor [weak self] in
            do {
                let client = try EPGStationClient(address: address)
                let rule = try await client.rule(id: id)
                try Task.checkCancellation()
                guard let self, generation == expected else { return }
                item = rule
                do {
                    let page = try await client.reservations(limit: 30, ruleID: id)
                    try Task.checkCancellation()
                    guard generation == expected else { return }
                    reservations = page.reservations
                    reservationTotal = page.total
                } catch {
                    guard generation == expected, !Task.isCancelled else { return }
                    reservationError = error.localizedDescription
                }
                loading = false
#if DEBUG
                print("RingonomiEPGStationRuleDetail: ready")
#endif
            } catch {
                guard let self, generation == expected, !Task.isCancelled else { return }
                self.error = error as? EPGStationError == .httpStatus(404)
                    ? "このルールは見つかりません。一覧を更新してください。" : error.localizedDescription
                loading = false
            }
        }
    }

    func cancel() {
        generation = UUID()
        request?.cancel()
        request = nil
        if loading { cancelled = true }
        loading = false
    }
}

@MainActor
final class EPGStationRuleEditorStore: ObservableObject {
    @Published private(set) var channels: [EPGStationChannel] = []
    @Published private(set) var directories: [String] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var preview: [EPGStationScheduleProgram] = []
    @Published private(set) var previewing = false
    @Published private(set) var previewError: String?
    @Published private(set) var previewedSearch: [String: RawJSONValue]?
    private var request: Task<Void, Never>?
    private var previewRequest: Task<Void, Never>?
    private var generation = UUID()
    private var previewGeneration = UUID()

    func load(address: String) {
        request?.cancel()
        let expected = UUID()
        generation = expected
        channels = []
        directories = []
        error = nil
        loading = true
        request = Task { @MainActor [weak self] in
            do {
                let client = try EPGStationClient(address: address)
                async let values = client.channels()
                async let configuration = client.config()
                let (channels, config) = try await (values, configuration)
                try Task.checkCancellation()
                guard let self, generation == expected else { return }
                self.channels = channels
                directories = config.recordedDirectories
                loading = false
#if DEBUG
                print("RingonomiEPGStationRuleEditor: ready")
#endif
            } catch {
                guard let self, generation == expected, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    func search(address: String, values: [String: RawJSONValue]) {
        invalidatePreview()
        let expected = previewGeneration
        previewing = true
        previewRequest = Task { @MainActor [weak self] in
            do {
                let programs = try await EPGStationClient(address: address).previewRule(searchValues: values, limit: 30)
                try Task.checkCancellation()
                guard let self, previewGeneration == expected else { return }
                preview = programs
                previewedSearch = values
                previewing = false
#if DEBUG
                print("RingonomiEPGStationRulePreview: count=\(programs.count)")
#endif
            } catch {
                guard let self, previewGeneration == expected, !Task.isCancelled else { return }
                previewError = error.localizedDescription
                previewing = false
            }
        }
    }

    func invalidatePreview() {
        previewGeneration = UUID()
        previewRequest?.cancel()
        previewRequest = nil
        preview = []
        previewedSearch = nil
        previewError = nil
        previewing = false
    }

    func cancel() {
        generation = UUID()
        request?.cancel()
        request = nil
        loading = false
        invalidatePreview()
    }
}
