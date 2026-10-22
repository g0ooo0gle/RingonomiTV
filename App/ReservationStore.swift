import Foundation
import Combine
import RingonomiCore

private enum ReservationWriteOperation: Sendable {
    case add(programID: String, settings: RecordSettings)
    case update(id: Int, settings: RecordSettings)
    case delete(id: Int)
}

private enum ReservationWriteResult: Sendable {
    case reservation(Reservation, expectedProgramID: String, expectedSettings: RecordSettings)
    case deleted
}

/// One shared list keeps guide details and the reservations tab consistent.
@MainActor final class ReservationStore: ObservableObject {
    @Published private(set) var items: [Reservation] = []
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    /// The timestamp of the latest successful list read. A pending mutation
    /// can be acknowledged only after a read performed after its journal entry.
    @Published private(set) var lastReadAt: Date?
    /// Address associated with `lastReadAt`; stale reads from another
    /// connection must never unlock a pending mutation.
    @Published private(set) var lastReadAddress: String?

    private var address = ""
    private var generation = UUID()
    private let mutation = RingonomiMutationStore.shared

    func reservation(for programID: String) -> Reservation? {
        items.first { $0.program.id == programID }
    }

    func invalidateConnection() {
        generation = UUID()
        items = []
        loading = false
        saving = false
        error = nil
        lastReadAt = nil
        lastReadAddress = nil
    }

    func refresh(address next: String) async {
        if address != next {
            address = next
            generation = UUID()
            items = []
            error = nil
            loading = false
            saving = false
            lastReadAt = nil
            lastReadAddress = nil
        }
        guard !loading, !saving, !next.isEmpty else { return }
        let expected = generation
        loading = true
        error = nil
        lastReadAt = nil
        lastReadAddress = nil
        defer { if generation == expected { loading = false } }
        do {
            let client = try RingonomiClient.connected(to: next)
            let readStartedAt = Date()
            let result = try await client.reservations()
            guard !Task.isCancelled, generation == expected else { return }
            items = sorted(result.reservations)
            lastReadAt = readStartedAt
            lastReadAddress = client.baseURL.absoluteString
#if DEBUG
            print("RingonomiReservationsReady: count=\(items.count)")
#endif
        } catch {
            guard !Task.isCancelled, generation == expected else { return }
            self.error = "予約一覧を読み込めませんでした。\(error.localizedDescription)"
        }
    }

    /// Patch only fields changed by this editor onto a freshly retrieved
    /// record. All read-only preflight happens before the shared mutation
    /// journal is persisted; a preflight failure therefore never blocks a
    /// later operation.
    func save(address requested: String, program: GuideProgram, original: Reservation?, settings: RecordSettings) async throws {
        guard !saving, !loading, requested == address else {
            throw ReservationUIError("一覧の読み込み後にもう一度お試しください。")
        }
        let expected = generation
        let client = try RingonomiClient.connected(to: requested)
        saving = true
        error = nil
        defer { if generation == expected { saving = false } }

        do {
            try await mutation.perform(
                address: requested,
                target: .reservation,
                action: original == nil ? .add : .update,
                title: original?.program.title ?? program.title,
                subjectID: original?.id,
                prepare: {
                    if let original {
                        let latest = try await client.reservation(id: original.id)
                        try self.requireCurrent(expected)
                        guard latest.program.id == original.program.id else {
                            throw ReservationUIError("予約の番組が変更されています。画面を閉じて開き直してください。")
                        }
                        let values = try mergingEditedSettings(
                            original: original.recordSettings.rawValues,
                            edited: settings.rawValues,
                            latest: latest.recordSettings.rawValues
                        )
                        return ReservationWriteOperation.update(
                            id: original.id,
                            settings: RecordSettings(rawValues: values)
                        )
                    }

                    guard (program.endDate ?? .distantPast) > Date(), !program.id.isEmpty else {
                        throw ReservationUIError("終了した番組は予約できません。番組表を更新してください。")
                    }
                    let current = try await client.reservations()
                    try self.requireCurrent(expected)
                    self.items = self.sorted(current.reservations)
                    guard !current.reservations.contains(where: { $0.program.id == program.id }) else {
                        throw ReservationUIError("この番組はすでに予約されています。画面を閉じて予約を開き直してください。")
                    }
                    return ReservationWriteOperation.add(programID: program.id, settings: settings)
                },
                validate: {
                    try self.requireCurrent(expected)
                },
                send: { operation -> ReservationWriteResult in
                    switch operation {
                    case .add(let programID, let settings):
                        let added = try await client.addReservation(programID: programID, settings: settings)
                        guard added.program.id == programID, added.id > 0 else { throw ReservationError.invalidResponse }
                        return .reservation(added, expectedProgramID: programID, expectedSettings: settings)
                    case .update(let id, let settings):
                        let updated = try await client.updateReservation(id: id, settings: settings)
                        guard updated.id == id,
                              updated.program.id == (original?.program.id ?? program.id) else {
                            throw ReservationError.invalidResponse
                        }
                        return .reservation(
                            updated,
                            expectedProgramID: original?.program.id ?? program.id,
                            expectedSettings: settings
                        )
                    case .delete:
                        throw ReservationError.invalidResponse
                    }
                },
                verify: { result in
                    try await self.readBack(client: client, expected: expected)
                    guard case .reservation(let written, let expectedProgramID, let expectedSettings) = result,
                          self.items.contains(where: {
                              $0.id == written.id &&
                              $0.program.id == expectedProgramID &&
                              preservesRequestedFields(actual: $0.recordSettings, expected: expectedSettings)
                          }) else {
                        throw ReservationError.invalidResponse
                    }
                }
            )
        } catch {
            if generation == expected { self.error = error.localizedDescription }
            throw error
        }
    }

    func delete(address requested: String, reservation: Reservation) async throws {
        guard !saving, !loading, requested == address else {
            throw ReservationUIError("一覧の読み込み後にもう一度お試しください。")
        }
        let expected = generation
        let client = try RingonomiClient.connected(to: requested)
        saving = true
        error = nil
        defer { if generation == expected { saving = false } }

        do {
            try await mutation.perform(
                address: requested,
                target: .reservation,
                action: .delete,
                title: reservation.program.title,
                subjectID: reservation.id,
                prepare: {
                    let latest = try await client.reservation(id: reservation.id)
                    try self.requireCurrent(expected)
                    guard latest.program.id == reservation.program.id else {
                        throw ReservationUIError("予約の内容が変更されています。画面を開き直してください。")
                    }
                    guard !latest.isRecordingInProgress || reservation.isRecordingInProgress else {
                        throw ReservationUIError("この予約は録画を開始しました。一覧を更新してから削除を確認してください。")
                    }
                    return ReservationWriteOperation.delete(id: reservation.id)
                },
                validate: {
                    try self.requireCurrent(expected)
                },
                send: { operation -> ReservationWriteResult in
                    guard case .delete(let id) = operation else { throw ReservationError.invalidResponse }
                    try await client.deleteReservation(id: id)
                    return .deleted
                },
                verify: { result in
                    try await self.readBack(client: client, expected: expected)
                    guard case .deleted = result,
                          !self.items.contains(where: { $0.id == reservation.id }) else {
                        throw ReservationError.invalidResponse
                    }
                }
            )
        } catch {
            if generation == expected { self.error = error.localizedDescription }
            throw error
        }
    }

    private func readBack(client: RingonomiClient, expected: UUID) async throws {
        try requireCurrent(expected)
        let readStartedAt = Date()
        let verified = try await client.reservations()
        try requireCurrent(expected)
        items = sorted(verified.reservations)
        lastReadAt = readStartedAt
        lastReadAddress = client.baseURL.absoluteString
    }

    private func requireCurrent(_ expected: UUID) throws {
        guard generation == expected else {
            throw ReservationUIError("接続先が変更されました。画面を開き直してください。")
        }
    }

    private func sorted(_ values: [Reservation]) -> [Reservation] {
        values.sorted { ($0.program.startDate ?? .distantFuture) < ($1.program.startDate ?? .distantFuture) }
    }
}

struct ReservationUIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func preservesRequestedFields(actual: RecordSettings, expected: RecordSettings) -> Bool {
    expected.rawValues.allSatisfy { key, value in actual.rawValues[key] == value }
}
