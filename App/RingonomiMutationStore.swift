import Foundation
import Combine
import RingonomiCore

protocol ReservationMutationJournalStorage: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

enum ReservationMutationJournalStorageError: Error, LocalizedError, Equatable {
    case keychainReadFailed
    case keychainWriteFailed
    case keychainRemoveFailed
    case legacyCorrupt
    case legacyConflict
    case legacyMigrationFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .keychainReadFailed:
            return "予約操作の記録を端末の安全な保存領域から読み込めませんでした。"
        case .keychainWriteFailed:
            return "予約操作の記録を端末の安全な保存領域へ保存できませんでした。送信は行われていません。"
        case .keychainRemoveFailed:
            return "予約操作の記録を端末の安全な保存領域から解除できません。記録を残したまま停止しています。"
        case .legacyCorrupt:
            return "以前の予約操作の記録を読み込めませんでした。内容を確認してから復旧してください。"
        case .legacyConflict:
            return "予約操作の記録が複数の保存先で一致しません。内容を確認してから復旧してください。"
        case .legacyMigrationFailed:
            return "以前の予約操作の記録を安全に移行できません。記録を残したまま停止しています。"
        case .cleanupFailed:
            return "予約操作の記録を解除できません。予約一覧を確認してから再試行してください。"
        }
    }
}

/// Serializes KonomiTV reservation writes and keeps an unresolved write across
/// launches. Normal reservations and keyword reservations intentionally share
/// this store so that two screens cannot submit concurrent mutations.
@MainActor
final class RingonomiMutationStore: ObservableObject {
    static let shared = RingonomiMutationStore(storage: KeychainReservationMutationStorage())

    @Published private(set) var busy = false
    @Published private(set) var pending: ReservationMutationIntent?
    @Published private(set) var journalUnreadable = false
    @Published private(set) var journalError: String?

    private let storage: ReservationMutationJournalStorage

    init(storage: ReservationMutationJournalStorage) {
        self.storage = storage
        do {
            guard let data = try storage.read() else { return }
            pending = try JSONDecoder().decode(ReservationMutationIntent.self, from: data)
        } catch {
            // Keep a visible recovery marker. Deleting malformed data here
            // could discard evidence that a server accepted a write.
            journalUnreadable = true
            journalError = Self.journalErrorMessage(for: error)
            pending = .recoveryEntry()
        }
    }

    /// Runs read-only preflight, persists the intent, sends exactly one
    /// mutation, and clears the intent only after the caller's authoritative
    /// readback verification succeeds. Preflight errors never create a journal
    /// entry. Verification errors always retain it, including HTTP 4xx.
    @discardableResult
    func perform<Value: Sendable, Result: Sendable>(
        address: String,
        target: ReservationMutationTarget,
        action: ReservationMutationAction,
        title: String,
        subjectID: Int? = nil,
        prepare: @MainActor () async throws -> Value,
        validate: @MainActor () throws -> Void,
        send: @MainActor (Value) async throws -> Result,
        verify: @MainActor (Result) async throws -> Void
    ) async throws -> Result {
        guard !busy, pending == nil else {
            throw ReservationUIError("前の操作結果を一覧で確認してから、操作を再開してください。")
        }
        busy = true
        defer { busy = false }

        let value = try await prepare()
        try Task.checkCancellation()
        // The async preflight may have yielded while the selected connection
        // was replaced. Validate that generation synchronously immediately
        // before persisting the journal and sending the mutation.
        try validate()
        let normalizedAddress = try RingonomiClient(address: address).baseURL.absoluteString
        let intent = ReservationMutationIntent(
            address: normalizedAddress,
            target: target,
            action: action,
            subjectID: subjectID,
            title: title
        )
        let data = try JSONEncoder().encode(intent)
        // A storage error here aborts before any request can be sent.
        try storage.write(data)
        pending = intent
        journalUnreadable = false
        journalError = nil

        let result: Result
        do {
            result = try await send(value)
        } catch {
            // Only the mutation request's own explicit 4xx refusal clears the
            // journal. All other send errors are safe-side outcome-unknown.
            if ReservationMutationFailureClassifier.disposition(for: error) == .explicitRejection {
                _ = clearPending()
            }
            throw error
        }

        // This is deliberately a separate phase. A verification GET can
        // return 4xx after the mutation was accepted; it must retain pending.
        try await verify(result)
        guard clearPending() else {
            throw ReservationMutationJournalStorageError.cleanupFailed
        }
        return result
    }

    func canAcknowledge(
        address: String,
        readAt: Date?,
        readAddress: String,
        target: ReservationMutationTarget
    ) -> Bool {
        guard !busy, let pending, let readAt, readAt >= pending.startedAt else { return false }
        if journalUnreadable || pending.isRecoveryEntry { return false }
        guard pending.target == target,
              let normalized = try? RingonomiClient(address: address).baseURL.absoluteString,
              let normalizedRead = try? RingonomiClient(address: readAddress).baseURL.absoluteString else {
            return false
        }
        return normalized == pending.address && normalizedRead == pending.address
    }

    /// A corrupt or unreadable journal has no trustworthy target/address. It
    /// can be removed only from the combined reservation screen after both
    /// list reads have succeeded on the current connection.
    func canRecoverCorruptJournal(
        address: String,
        reservationReadAt: Date?,
        keywordReadAt: Date?,
        reservationReadAddress: String?,
        keywordReadAddress: String?
    ) -> Bool {
        guard !busy, journalUnreadable || pending?.isRecoveryEntry == true,
              let pending,
              let reservationReadAt,
              let keywordReadAt,
              let reservationReadAddress,
              let keywordReadAddress,
              reservationReadAt >= pending.startedAt,
              keywordReadAt >= pending.startedAt,
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let normalized = try? RingonomiClient(address: address).baseURL.absoluteString,
              let normalizedReservation = try? RingonomiClient(address: reservationReadAddress).baseURL.absoluteString,
              let normalizedKeyword = try? RingonomiClient(address: keywordReadAddress).baseURL.absoluteString else {
            return false
        }
        return normalized == normalizedReservation && normalized == normalizedKeyword
    }

    @discardableResult
    func recoverCorruptJournalAfterReview(
        address: String,
        reservationReadAt: Date?,
        keywordReadAt: Date?,
        reservationReadAddress: String?,
        keywordReadAddress: String?
    ) -> Bool {
        guard canRecoverCorruptJournal(
            address: address,
            reservationReadAt: reservationReadAt,
            keywordReadAt: keywordReadAt,
            reservationReadAddress: reservationReadAddress,
            keywordReadAddress: keywordReadAddress
        ) else { return false }
        return clearPending()
    }

    @discardableResult
    func acknowledgeAfterReview(
        address: String,
        readAt: Date?,
        readAddress: String,
        target: ReservationMutationTarget
    ) -> Bool {
        guard canAcknowledge(address: address, readAt: readAt, readAddress: readAddress, target: target) else { return false }
        return clearPending()
    }

    @discardableResult
    private func clearPending() -> Bool {
        do {
            try storage.remove()
        } catch {
            journalError = Self.journalErrorMessage(for: error)
            return false
        }
        pending = nil
        journalUnreadable = false
        journalError = nil
        return true
    }

    private static func journalErrorMessage(for error: Error) -> String {
        if let storageError = error as? ReservationMutationJournalStorageError,
           let message = storageError.errorDescription {
            return message
        }
        return "予約操作の記録を読み込めませんでした。内容を確認してから復旧してください。"
    }
}
