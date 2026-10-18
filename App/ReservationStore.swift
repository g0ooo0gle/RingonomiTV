import Foundation
import Combine
import RingonomiCore

/// One shared list keeps guide details and the reservations tab consistent.
@MainActor final class ReservationStore: ObservableObject {
    @Published private(set) var items: [Reservation] = []
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    private var address = ""
    private var generation = UUID()

    func reservation(for programID: String) -> Reservation? {
        items.first { $0.program.id == programID }
    }
    func refresh(address next: String) async {
        if address != next {
            address = next
            generation = UUID()
            items = []
            error = nil
            loading = false
            saving = false
        }
        guard !loading, !saving, !next.isEmpty else { return }
        let expected = generation
        loading = true
        error = nil
        defer { if generation == expected { loading = false } }
        do {
            let result = try await RingonomiClient(address: next).reservations()
            guard !Task.isCancelled, generation == expected else { return }
            items = sorted(result.reservations)
#if DEBUG
            print("RingonomiReservationsReady: count=\(items.count)")
#endif
        } catch {
            guard !Task.isCancelled, generation == expected else { return }
            self.error = "予約一覧を読み込めませんでした。\(error.localizedDescription)"
        }
    }

    /// Patch only fields changed by this editor onto a freshly retrieved record.
    /// This preserves server extensions and settings changed elsewhere.
    func save(address requested: String, program: GuideProgram, original: Reservation?, settings: RecordSettings) async throws {
        guard !saving, !loading, requested == address else { throw ReservationUIError("一覧の読み込み後にもう一度お試しください。") }
        let expected = generation
        let client = try RingonomiClient(address: requested)
        saving = true
        error = nil
        defer { if generation == expected { saving = false } }
        do {
            if let original {
                let latest = try await client.reservation(id: original.id)
                try requireCurrent(expected)
                guard latest.program.id == original.program.id else { throw ReservationUIError("予約の番組が変更されています。画面を閉じて開き直してください。") }
                var values = latest.recordSettings.rawValues
                for key in Set(settings.rawValues.keys).union(original.recordSettings.rawValues.keys) {
                    let before = original.recordSettings.rawValues[key]
                    let after = settings.rawValues[key]
                    guard before != after else { continue }
                    guard values[key] == before || values[key] == after else {
                        throw ReservationUIError("同じ設定が別の画面で変更されています。画面を閉じて開き直してください。")
                    }
                    values[key] = after
                }
                let updated = try await client.updateReservation(id: original.id, settings: RecordSettings(rawValues: values))
                guard updated.id == original.id, updated.program.id == original.program.id else { throw ReservationError.invalidResponse }
            } else {
                guard (program.endDate ?? .distantPast) > Date(), !program.id.isEmpty else {
                    throw ReservationUIError("終了した番組は予約できません。番組表を更新してください。")
                }
                let current = try await client.reservations()
                try requireCurrent(expected)
                items = sorted(current.reservations)
                guard !current.reservations.contains(where: { $0.program.id == program.id }) else {
                    throw ReservationUIError("この番組はすでに予約されています。画面を閉じて予約を開き直してください。")
                }
                let added = try await client.addReservation(programID: program.id, settings: settings)
                guard added.program.id == program.id else { throw ReservationError.invalidResponse }
            }
            try requireCurrent(expected)
            let verified = try await client.reservations()
            try requireCurrent(expected)
            items = sorted(verified.reservations)
        } catch {
            if generation == expected {
                // A timeout may happen after the server accepted the write. Never
                // retry a mutation automatically
                // Read back the authoritative list instead.
                if let current = try? await client.reservations(), generation == expected { items = sorted(current.reservations) }
                self.error = error.localizedDescription
            }
            throw error
        }
    }

    func delete(address requested: String, reservation: Reservation) async throws {
        guard !saving, !loading, requested == address else { throw ReservationUIError("一覧の読み込み後にもう一度お試しください。") }
        let expected = generation
        let client = try RingonomiClient(address: requested)
        saving = true
        error = nil
        defer { if generation == expected { saving = false } }
        do {
            let latest = try await client.reservation(id: reservation.id)
            try requireCurrent(expected)
            guard latest.program.id == reservation.program.id else { throw ReservationUIError("予約の内容が変更されています。画面を開き直してください。") }
            guard !latest.isRecordingInProgress || reservation.isRecordingInProgress else {
                throw ReservationUIError("この予約は録画を開始しました。一覧を更新してから削除を確認してください。")
            }
            try await client.deleteReservation(id: reservation.id)
            try requireCurrent(expected)
            let current = try await client.reservations()
            try requireCurrent(expected)
            items = sorted(current.reservations)
            guard !items.contains(where: { $0.id == reservation.id }) else { throw ReservationUIError("削除結果を確認できませんでした。一覧を確認してください。") }
        } catch {
            if generation == expected {
                if let current = try? await client.reservations(), generation == expected { items = sorted(current.reservations) }
                self.error = error.localizedDescription
            }
            throw error
        }
    }
    private func requireCurrent(_ expected: UUID) throws {
        guard generation == expected else { throw ReservationUIError("接続先が変更されました。画面を開き直してください。") }
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
