import Foundation
import Combine
import RingonomiCore

/// Serializes EPGStation writes and remembers an interrupted submission across launches.
@MainActor
final class EPGStationMutationStore: ObservableObject {
    static let shared = EPGStationMutationStore()

    struct Pending: Codable, Equatable {
        let address: String
        let title: String
        let action: String
        let startedAt: Date
        let reservationID: Int?
        let schedule: String?
        let target: String?
        let ruleID: Int?

        init(address: String, title: String, action: String, startedAt: Date, reservationID: Int?, schedule: String?, target: String? = nil, ruleID: Int? = nil) {
            self.address = address
            self.title = title
            self.action = action
            self.startedAt = startedAt
            self.reservationID = reservationID
            self.schedule = schedule
            self.target = target
            self.ruleID = ruleID
        }
    }

    @Published private(set) var busy = false
    @Published private(set) var pending: Pending?
    @Published private(set) var journalUnreadable = false
    private let defaults: UserDefaults
    private let journalKey = "epgstationPendingReservationWrite"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: journalKey) {
            do { pending = try JSONDecoder().decode(Pending.self, from: data) }
            catch {
                journalUnreadable = true
                pending = Pending(address: "", title: "前の操作情報を読み込めませんでした", action: "予約一覧の確認が必要です", startedAt: Date(), reservationID: nil, schedule: nil)
            }
        }
    }

    /// Preflight is read-only. Once submission begins, cancellation cannot prove it was rejected.
    func perform<Value: Sendable>(
        address: String, title: String, action: String, reservationID: Int? = nil, schedule: String? = nil,
        target: String? = nil, ruleID: Int? = nil,
        prepare: @MainActor () async throws -> Value,
        send: @MainActor (Value) async throws -> Void
    ) async throws {
        guard !busy, pending == nil else {
            throw ReservationUIError("前の操作結果を一覧で確認してから、操作を再開してください。")
        }
        busy = true
        defer { busy = false }
        let value = try await prepare()
        try Task.checkCancellation()
        let normalizedAddress = try EPGStationClient(address: address).baseURL.absoluteString
        let intent = Pending(address: normalizedAddress, title: title, action: action, startedAt: Date(), reservationID: reservationID, schedule: schedule, target: target, ruleID: ruleID)
        let data = try JSONEncoder().encode(intent)
        defaults.set(data, forKey: journalKey)
        pending = intent
        do {
            try await send(value)
            clearPending()
        } catch {
            // Retain the journal unless the transport can prove the write was rejected.
            // The client classifies failures; callers must never automatically resubmit.
            if let error = error as? EPGStationWriteError, !error.isOutcomeUnknown {
                clearPending()
            } else {
                let unresolved = Pending(address: intent.address, title: intent.title, action: intent.action, startedAt: Date(), reservationID: intent.reservationID, schedule: intent.schedule, target: intent.target, ruleID: intent.ruleID)
                pending = unresolved
                if let data = try? JSONEncoder().encode(unresolved) { defaults.set(data, forKey: journalKey) }
            }
            throw error
        }
    }

    func canAcknowledge(address: String, readAt: Date?, target: String? = nil) -> Bool {
        guard !busy, let pending, let readAt, readAt >= pending.startedAt,
              let normalized = try? EPGStationClient(address: address).baseURL.absoluteString else { return false }
        return journalUnreadable || (normalized == pending.address && pending.target == target)
    }

    func acknowledgeAfterReview(address: String, readAt: Date?, target: String? = nil) {
        guard canAcknowledge(address: address, readAt: readAt, target: target) else { return }
        clearPending()
    }

    private func clearPending() {
        defaults.removeObject(forKey: journalKey)
        pending = nil
        journalUnreadable = false
    }
}
