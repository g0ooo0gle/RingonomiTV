import Combine
import Foundation
import RingonomiCore

private enum MirakurunGuideLoadError: Error, LocalizedError {
    case timedOut
    var errorDescription: String? {
        "番組表の取得が完了しませんでした。接続先を確認して再試行してください。"
    }
}

private struct MirakurunGuidePrograms: Sendable {
    var programs: [MirakurunProgram] = []
    var failures = 0
    var firstError: MirakurunError?
}

private enum MirakurunServicePrograms: Sendable {
    case success([MirakurunProgram])
    case failure(MirakurunError)
}

enum MirakurunGuideBroadcast: String, CaseIterable, Identifiable, Sendable {
    case terrestrial = "GR", bs = "BS", cs = "CS", sky = "SKY", all = ""

    var id: String { rawValue }
    var title: String {
        switch self {
        case .terrestrial: return "地デジ"
        case .bs: return "BS"
        case .cs: return "CS"
        case .sky: return "SKY"
        case .all: return "すべて"
        }
    }
}

/// Fetch each selected service separately so the guide never needs to retain
/// a server's entire multi-day catalog in one large response.
@MainActor
final class MirakurunProgramGuideStore: ObservableObject {
    @Published private(set) var snapshot: MirakurunGuideSnapshot?
    @Published private(set) var loadedRequestKey: String?
    @Published private(set) var loading = false
    @Published private(set) var cancelled = false
    @Published private(set) var error: String?
    @Published private(set) var warning: String?
    @Published private(set) var completedServices = 0
    @Published private(set) var totalServices = 0

    private var request: Task<Void, Never>?
    private var generation = UUID()

    deinit { request?.cancel() }

    func load(requestKey: String, address: String, startDate: Date, endDate: Date,
              broadcast: MirakurunGuideBroadcast) {
        request?.cancel()
        let expected = UUID()
        generation = expected
        snapshot = nil
        loadedRequestKey = nil
        error = nil
        warning = nil
        cancelled = false
        completedServices = 0
        totalServices = 0
        loading = true

        request = Task { @MainActor [weak self] in
            do {
                let client = try MirakurunClient(address: address)
                let services = try await client.services().filter {
                    broadcast == .all || $0.channel?.type == broadcast.rawValue
                }
                try Task.checkCancellation()
                guard services.count <= 256 else { throw MirakurunError.responseTooLarge }
                guard let self, generation == expected else { return }
                self.totalServices = services.count
                let programs = try await Self.readPrograms(
                    client: client, services: services, startDate: startDate, endDate: endDate
                ) { [weak self] completed in
                    guard let self, self.generation == expected else { return }
                    self.completedServices = completed
                }
                try Task.checkCancellation()
                if programs.failures == services.count, let error = programs.firstError { throw error }
                let next = try await Self.makeSnapshot(services: services, programs: programs.programs,
                                                       startDate: startDate, endDate: endDate)
                try Task.checkCancellation()
                guard generation == expected else { return }
                snapshot = next
                if programs.failures > 0 {
                    warning = "\(programs.failures) / \(services.count) チャンネルの番組を取得できませんでした。更新して再試行してください。"
                }
                loadedRequestKey = requestKey
                loading = false
#if DEBUG
                print("RingonomiMirakurunGuideReady: channels=\(next.response.channels.count)")
#endif
            } catch is CancellationError {
                guard let self, self.generation == expected else { return }
                self.loading = false
                self.cancelled = true
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.loading = false
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
            warning = nil
            cancelled = false
            completedServices = 0
            totalServices = 0
        } else if wasLoading {
            cancelled = true
        }
    }

    private static func readPrograms(
        client: MirakurunClient, services: [MirakurunService],
        startDate: Date, endDate: Date,
        progress: @escaping @MainActor @Sendable (Int) -> Void
    ) async throws -> MirakurunGuidePrograms {
        try await withThrowingTaskGroup(of: MirakurunGuidePrograms.self) { group in
            group.addTask {
                try await fetchPrograms(client: client, services: services,
                                        startDate: startDate, endDate: endDate, progress: progress)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw MirakurunGuideLoadError.timedOut
            }
            defer { group.cancelAll() }
            guard let programs = try await group.next() else { throw CancellationError() }
            return programs
        }
    }

    private static func fetchPrograms(
        client: MirakurunClient, services: [MirakurunService],
        startDate: Date, endDate: Date,
        progress: @MainActor (Int) -> Void
    ) async throws -> MirakurunGuidePrograms {
        try await withThrowingTaskGroup(of: MirakurunServicePrograms.self) { group in
            var nextIndex = 0
            var completed = 0
            var result = MirakurunGuidePrograms()
            var retainedBytes = 0
            // Three small service responses can be in flight at once.  Only
            // the selected day is retained after each response is decoded.
            func enqueue(_ service: MirakurunService) {
                group.addTask {
                    do {
                        let programs = try await client.programs(for: service.key)
                        try Task.checkCancellation()
                        return .success(programs.filter {
                            $0.duration > 0 &&
                            $0.startAt < endDate.timeIntervalSince1970 * 1000 &&
                            $0.endAt > startDate.timeIntervalSince1970 * 1000
                        })
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as MirakurunError {
                        try Task.checkCancellation()
                        return .failure(error)
                    } catch {
                        try Task.checkCancellation()
                        return .failure(.transport)
                    }
                }
            }
            while nextIndex < min(3, services.count) {
                enqueue(services[nextIndex])
                nextIndex += 1
            }
            while let response = try await group.next() {
                try Task.checkCancellation()
                switch response {
                case .success(let programs):
                    retainedBytes += programs.reduce(0) { $0 + estimatedBytes($1) }
                    guard retainedBytes <= 16 * 1024 * 1024,
                          result.programs.count + programs.count <= 20_000 else {
                        throw MirakurunError.responseTooLarge
                    }
                    result.programs.append(contentsOf: programs)
                case .failure(let error):
                    result.failures += 1
                    if result.firstError == nil { result.firstError = error }
                }
                completed += 1
                progress(completed)
                if nextIndex < services.count {
                    enqueue(services[nextIndex])
                    nextIndex += 1
                }
            }
            return result
        }
    }

    private nonisolated static func estimatedBytes(_ program: MirakurunProgram) -> Int {
        let extended = program.extended?.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } ?? 0
        return 512 + (program.name?.utf8.count ?? 0) + (program.description?.utf8.count ?? 0) + extended
    }

    private nonisolated static func makeSnapshot(
        services: [MirakurunService], programs: [MirakurunProgram], startDate: Date, endDate: Date
    ) async throws -> MirakurunGuideSnapshot {
        // The display conversion can visit many events.  Keep it off the
        // main actor so cancel and navigation remain responsive.
        try Task.checkCancellation()
        let snapshot = try MirakurunGuideSnapshot(services: services, programs: programs,
                                                 startDate: startDate, endDate: endDate)
        try Task.checkCancellation()
        return snapshot
    }
}
