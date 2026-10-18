import Foundation
import Combine
import RingonomiCore

@MainActor
final class EPGStationReservationEditorStore: ObservableObject {
    @Published private(set) var channels: [EPGStationChannel] = []
    @Published private(set) var directories: [String] = []
    @Published private(set) var programs: [EPGStationScheduleProgram] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingPrograms = false
    @Published private(set) var error: String?
    @Published private(set) var programError: String?
    private var request: Task<Void, Never>?
    private var programRequest: Task<Void, Never>?
    private var generation = UUID()
    private var programGeneration = UUID()

    func load(address: String) {
        cancel()
        let expected = UUID()
        generation = expected
        loading = true
        error = nil
        channels = []
        directories = []
        request = Task { @MainActor [weak self] in
            do {
                let client = try EPGStationClient(address: address)
                async let fetchedChannels = client.channels()
                async let configuration = client.config()
                let (channels, config) = try await (fetchedChannels, configuration)
                try Task.checkCancellation()
                guard let self, generation == expected else { return }
                self.channels = channels
                directories = config.recordedDirectories
                loading = false
#if DEBUG
                print("RingonomiEPGStationEditor: ready")
#endif
            } catch {
                guard let self, generation == expected, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    func loadPrograms(address: String, channelID: Int, day: Date) {
        programRequest?.cancel()
        let expected = UUID()
        programGeneration = expected
        programs = []
        programError = nil
        loadingPrograms = true
        programRequest = Task { @MainActor [weak self] in
            do {
                let client = try EPGStationClient(address: address)
                let schedules = try await client.channelSchedule(channelID: channelID, startAt: day.timeIntervalSince1970 * 1000, days: 1)
                try Task.checkCancellation()
                guard let self, programGeneration == expected else { return }
                programs = schedules.flatMap(\.programs).filter { $0.endAt > Date().timeIntervalSince1970 * 1000 }
                loadingPrograms = false
            } catch {
                guard let self, programGeneration == expected, !Task.isCancelled else { return }
                programError = error.localizedDescription
                loadingPrograms = false
            }
        }
    }

    func cancel() {
        generation = UUID()
        programGeneration = UUID()
        request?.cancel()
        programRequest?.cancel()
        request = nil
        programRequest = nil
        loading = false
        loadingPrograms = false
    }
}
