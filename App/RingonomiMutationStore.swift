import Foundation
import Combine
import RingonomiCore

protocol ReservationMutationJournalStorage: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

enum ReservationMutationJournalStorageError: Error, LocalizedError, Equatable {
    case applicationSupportUnavailable
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "予約操作の保存場所を準備できません。"
        case .cleanupFailed:
            return "予約操作の記録を解除できません。予約一覧を確認してから再試行してください。"
        }
    }
}

/// A small durable file in Application Support. The temporary file is written
/// and synchronized before replacement, so a failed write is reported before
/// the network mutation is started.
final class ApplicationSupportReservationMutationStorage: ReservationMutationJournalStorage {
    private let fileManager: FileManager
    private let fileURL: URL
    private let defaults: UserDefaults
    private let legacyKey: String

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        legacyKey: String = "ringonomiPendingReservationWrite.v1",
        fileURL: URL? = nil
    ) throws {
        self.fileManager = fileManager
        self.defaults = defaults
        self.legacyKey = legacyKey
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ReservationMutationJournalStorageError.applicationSupportUnavailable
        }
        self.fileURL = support
            .appendingPathComponent("RingonomiTV", isDirectory: true)
            .appendingPathComponent("reservation-write-journal.json", isDirectory: false)
    }

    func read() throws -> Data? {
        if fileManager.fileExists(atPath: fileURL.path) {
            return try Data(contentsOf: fileURL)
        }
        guard let legacy = defaults.object(forKey: legacyKey) else { return nil }
        guard let data = legacy as? Data else {
            // A previous build may have left a string/dictionary or another
            // value under the old Defaults key. Preserve it as a recovery
            // condition rather than treating it as an empty journal.
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    func write(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".reservation-write-journal-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporary) }

        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: fileURL)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    func remove() throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        defaults.removeObject(forKey: legacyKey)
    }
}

/// Serializes KonomiTV reservation writes and keeps an unresolved write across
/// launches. Normal reservations and keyword reservations intentionally share
/// this store so that two screens cannot submit concurrent mutations.
@MainActor
final class RingonomiMutationStore: ObservableObject {
    static let shared: RingonomiMutationStore = {
        do {
            return try RingonomiMutationStore(storage: ApplicationSupportReservationMutationStorage())
        } catch {
            return RingonomiMutationStore(storage: UnavailableReservationMutationStorage(error: error))
        }
    }()

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
            journalError = error.localizedDescription
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
            journalError = error.localizedDescription
            return false
        }
        pending = nil
        journalUnreadable = false
        journalError = nil
        return true
    }
}

/// Keeps a startup recovery marker visible if Application Support itself is
/// unavailable. No write can proceed because `write` throws before send.
private final class UnavailableReservationMutationStorage: ReservationMutationJournalStorage {
    private let error: Error

    init(error: Error) { self.error = error }
    func read() throws -> Data? { throw error }
    func write(_ data: Data) throws { throw error }
    func remove() throws { throw error }
}
