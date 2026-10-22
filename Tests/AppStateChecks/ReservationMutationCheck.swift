import Foundation
import RingonomiCore

/// Minimal application-side error used when this probe compiles the real
/// RingonomiMutationStore without the rest of the SwiftUI application target.
struct ReservationUIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ProbeStorage: ReservationMutationJournalStorage {
    var data: Data?
    var failWrite = false
    var failRemove = false
    var writes = 0
    var removes = 0

    func read() throws -> Data? { data }

    func write(_ data: Data) throws {
        guard !failWrite else { throw ProbeFailure.storageWrite }
        writes += 1
        self.data = data
    }

    func remove() throws {
        guard !failRemove else { throw ProbeFailure.storageRemove }
        removes += 1
        data = nil
    }
}

@MainActor
private final class ProbeCounter {
    var sends = 0
}

@MainActor
private final class ProbeGate {
    private var resumed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if resumed { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}

private enum ProbeFailure: Error {
    case storageWrite
    case storageRemove
    case message(String)
}

@main
struct ReservationMutationCheck {
    private static let address = "https://example.invalid/tv"

    @MainActor
    private static var checks = 0

    @MainActor
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure.message(message) }
        checks += 1
    }

    @MainActor
    private static func run(
        _ store: RingonomiMutationStore,
        send: @escaping @MainActor (String) async throws -> Int,
        verify: @escaping @MainActor (Int) async throws -> Void = { _ in }
    ) async throws -> Int {
        try await store.perform(
            address: address,
            target: .reservation,
            action: .add,
            title: "probe",
            prepare: { "prepared" },
            validate: {},
            send: send,
            verify: verify
        )
    }

    @MainActor
    static func main() async throws {
        // A failed read-only preflight never creates a journal or calls send.
        do {
            let storage = ProbeStorage()
            let counter = ProbeCounter()
            let store = RingonomiMutationStore(storage: storage)
            do {
                _ = try await store.perform(
                    address: address,
                    target: .reservation,
                    action: .add,
                    title: "preflight",
                    prepare: { () async throws -> String in throw ReservationError.invalidResponse },
                    validate: {},
                    send: { (_: String) async throws -> Int in counter.sends += 1; return 1 },
                    verify: { (_: Int) async throws -> Void in }
                )
                throw ProbeFailure.message("preflight unexpectedly succeeded")
            } catch is ReservationError {
                // expected
            }
            try expect(storage.writes == 0 && storage.data == nil && counter.sends == 0,
                       "preflight failure must not persist or send")
        }

        // A connection-generation validation failure immediately before the
        // journal write is equally safe and cannot reach the network.
        do {
            let storage = ProbeStorage()
            let counter = ProbeCounter()
            let store = RingonomiMutationStore(storage: storage)
            do {
                _ = try await store.perform(
                    address: address,
                    target: .reservation,
                    action: .add,
                    title: "validation",
                    prepare: { "prepared" },
                    validate: { throw ReservationUIError("stale connection") },
                    send: { (_: String) async throws -> Int in counter.sends += 1; return 1 },
                    verify: { (_: Int) async throws -> Void in }
                )
                throw ProbeFailure.message("validation unexpectedly succeeded")
            } catch is ReservationUIError {
                // expected
            }
            try expect(storage.writes == 0 && storage.data == nil && counter.sends == 0,
                       "validation failure must not persist or send")
        }

        // A durable-write failure is reported before a network mutation.
        do {
            let storage = ProbeStorage()
            storage.failWrite = true
            let counter = ProbeCounter()
            let store = RingonomiMutationStore(storage: storage)
            do {
                _ = try await run(store, send: { _ in counter.sends += 1; return 1 })
                throw ProbeFailure.message("write failure unexpectedly succeeded")
            } catch is ProbeFailure {
                // expected
            }
            try expect(counter.sends == 0 && store.pending == nil,
                       "storage write failure must prevent send")
        }

        // An explicit mutation 4xx is a known rejection and clears the entry.
        do {
            let storage = ProbeStorage()
            let store = RingonomiMutationStore(storage: storage)
            do {
                _ = try await run(store, send: { _ in
                    throw ReservationError.http(status: 403, detail: nil)
                })
                throw ProbeFailure.message("explicit rejection unexpectedly succeeded")
            } catch let error as ReservationError {
                try expect(error == .http(status: 403, detail: nil), "wrong explicit rejection")
            }
            try expect(store.pending == nil && storage.data == nil,
                       "explicit send rejection must clear journal")
        }

        // A verification 4xx is not evidence that the original write failed.
        do {
            let storage = ProbeStorage()
            let counter = ProbeCounter()
            let store = RingonomiMutationStore(storage: storage)
            do {
                _ = try await run(store, send: { _ in counter.sends += 1; return 1 }, verify: { _ in
                    throw ReservationError.http(status: 404, detail: nil)
                })
                throw ProbeFailure.message("verification rejection unexpectedly succeeded")
            } catch let error as ReservationError {
                try expect(error == .http(status: 404, detail: nil), "wrong verification error")
            }
            try expect(store.pending != nil && storage.data != nil,
                       "verification failure must retain journal")
            do {
                _ = try await run(store, send: { _ in counter.sends += 1; return 1 })
                throw ProbeFailure.message("pending mutation was allowed to retry")
            } catch is ReservationUIError {
                // expected
            }
            try expect(counter.sends == 1, "pending verification failure allowed a second send")
        }

        // A cancellation after preflight but before persistence is safe; the
        // cancellation gate also makes this check deterministic.
        do {
            let storage = ProbeStorage()
            let counter = ProbeCounter()
            let gate = ProbeGate()
            let store = RingonomiMutationStore(storage: storage)
            let task = Task { @MainActor in
                try await store.perform(
                    address: address,
                    target: .reservation,
                    action: .add,
                    title: "cancel",
                    prepare: { await gate.wait(); return "prepared" },
                    validate: {},
                    send: { (_: String) async throws -> Int in counter.sends += 1; return 1 },
                    verify: { (_: Int) async throws -> Void in }
                )
            }
            for _ in 0..<20 { await Task.yield() }
            task.cancel()
            gate.resume()
            do {
                _ = try await task.value
                throw ProbeFailure.message("cancelled operation unexpectedly succeeded")
            } catch is CancellationError {
                // expected
            }
            try expect(storage.data == nil && store.pending == nil && counter.sends == 0,
                       "pre-send cancellation must not persist or send")
        }

        // A successful send is cleared only after the separate verification
        // callback returns successfully.
        do {
            let storage = ProbeStorage()
            let counter = ProbeCounter()
            let store = RingonomiMutationStore(storage: storage)
            let value = try await run(store, send: { _ in counter.sends += 1; return 7 }, verify: { value in
                guard value == 7 else { throw ReservationError.invalidResponse }
            })
            try expect(value == 7 && counter.sends == 1 && store.pending == nil && storage.data == nil,
                       "verified send must clear journal")
        }

        // A successful write response with a readback mismatch remains
        // unresolved; the caller's verify phase is authoritative.
        do {
            let storage = ProbeStorage()
            let counter = ProbeCounter()
            let store = RingonomiMutationStore(storage: storage)
            do {
                _ = try await run(store, send: { _ in counter.sends += 1; return 1 }, verify: { _ in
                    throw ReservationError.invalidResponse
                })
                throw ProbeFailure.message("readback mismatch unexpectedly succeeded")
            } catch let error as ReservationError {
                try expect(error == .invalidResponse, "wrong readback mismatch error")
            }
            try expect(store.pending != nil && storage.data != nil && counter.sends == 1,
                       "readback mismatch must retain journal")
        }

        // Relaunching with a persisted unknown result restores the same block.
        do {
            let storage = ProbeStorage()
            let first = RingonomiMutationStore(storage: storage)
            do {
                _ = try await run(first, send: { _ in throw ReservationError.outcomeUnknown })
            } catch is ReservationError {
                // expected
            }
            guard let intent = first.pending else { throw ProbeFailure.message("unknown result was not retained") }
            let relaunched = RingonomiMutationStore(storage: storage)
            try expect(relaunched.pending == intent && relaunched.canAcknowledge(
                address: address,
                readAt: Date(timeIntervalSinceNow: 1),
                readAddress: address,
                target: .reservation
            ), "relaunch must restore a reviewable pending entry")
            try expect(!relaunched.canAcknowledge(
                address: "https://other.invalid/tv",
                readAt: Date(timeIntervalSinceNow: 1),
                readAddress: "https://other.invalid/tv",
                target: .reservation
            ), "wrong address must not acknowledge")
            try expect(!relaunched.canAcknowledge(
                address: address,
                readAt: Date(timeIntervalSinceNow: 1),
                readAddress: address,
                target: .keywordReservation
            ), "wrong target must not acknowledge")
            try expect(!relaunched.canAcknowledge(
                address: address,
                readAt: intent.startedAt.addingTimeInterval(-0.001),
                readAddress: address,
                target: .reservation
            ), "old read must not acknowledge")
            try expect(!relaunched.canAcknowledge(
                address: address,
                readAt: Date(timeIntervalSinceNow: 1),
                readAddress: "https://other.invalid/tv",
                target: .reservation
            ), "read from another connection must not acknowledge")
            try expect(relaunched.acknowledgeAfterReview(
                address: address,
                readAt: Date(timeIntervalSinceNow: 1),
                readAddress: address,
                target: .reservation
            ), "matching review should acknowledge")
        }

        // A malformed journal is visible and cannot be acknowledged against an
        // arbitrary target. Recovery requires both current list timestamps.
        do {
            let storage = ProbeStorage()
            storage.data = Data("not-json".utf8)
            let corrupt = RingonomiMutationStore(storage: storage)
            try expect(corrupt.journalUnreadable && corrupt.pending?.isRecoveryEntry == true,
                       "malformed journal must be visible")
            try expect(!corrupt.canAcknowledge(
                address: address,
                readAt: Date(timeIntervalSinceNow: 1),
                readAddress: address,
                target: .reservation
            ), "corrupt journal must not use normal acknowledgement")
            guard let marker = corrupt.pending else { throw ProbeFailure.message("missing recovery marker") }
            try expect(!corrupt.canRecoverCorruptJournal(
                address: address,
                reservationReadAt: Date(timeIntervalSinceNow: 1),
                keywordReadAt: nil,
                reservationReadAddress: address,
                keywordReadAddress: address
            ), "one list is insufficient for corrupt recovery")
            try expect(corrupt.canRecoverCorruptJournal(
                address: address,
                reservationReadAt: marker.startedAt.addingTimeInterval(1),
                keywordReadAt: marker.startedAt.addingTimeInterval(1),
                reservationReadAddress: address,
                keywordReadAddress: address
            ), "both current lists should allow explicit corrupt recovery")
            try expect(corrupt.recoverCorruptJournalAfterReview(
                address: address,
                reservationReadAt: marker.startedAt.addingTimeInterval(1),
                keywordReadAt: marker.startedAt.addingTimeInterval(1),
                reservationReadAddress: address,
                keywordReadAddress: address
            ), "corrupt recovery should clear after review")
            try expect(corrupt.pending == nil && storage.data == nil,
                       "corrupt recovery must remove durable marker")
        }

        // The file-backed adapter treats an old non-Data Defaults value and
        // an unreadable path as recovery conditions, and removes the legacy
        // value only after explicit recovery.
        do {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("ringonomi-mutation-probe-\(UUID().uuidString)", isDirectory: true)
            let fileURL = root.appendingPathComponent("journal.json", isDirectory: false)
            let legacyKey = "legacy-\(UUID().uuidString)"
            let defaultsSuite = "ringonomi-probe-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
                throw ProbeFailure.message("could not create isolated defaults suite")
            }
            defer {
                defaults.removePersistentDomain(forName: defaultsSuite)
                try? fileManager.removeItem(at: root)
            }
            defaults.set("old string value", forKey: legacyKey)
            let legacyStorage = try ApplicationSupportReservationMutationStorage(
                fileManager: fileManager,
                defaults: defaults,
                legacyKey: legacyKey,
                fileURL: fileURL
            )
            let legacyCorrupt = RingonomiMutationStore(storage: legacyStorage)
            try expect(legacyCorrupt.journalUnreadable && legacyCorrupt.pending?.isRecoveryEntry == true,
                       "legacy non-Data value must be visible as corruption")
            guard let legacyMarker = legacyCorrupt.pending else {
                throw ProbeFailure.message("missing legacy recovery marker")
            }
            try expect(legacyCorrupt.recoverCorruptJournalAfterReview(
                address: address,
                reservationReadAt: legacyMarker.startedAt.addingTimeInterval(1),
                keywordReadAt: legacyMarker.startedAt.addingTimeInterval(1),
                reservationReadAddress: address,
                keywordReadAddress: address
            ), "legacy corruption recovery should succeed")
            try expect(defaults.object(forKey: legacyKey) == nil,
                       "legacy Defaults value must be removed only during recovery")

            try fileManager.createDirectory(at: fileURL, withIntermediateDirectories: true)
            let unreadableStorage = try ApplicationSupportReservationMutationStorage(
                fileManager: fileManager,
                defaults: defaults,
                legacyKey: legacyKey,
                fileURL: fileURL
            )
            let unreadable = RingonomiMutationStore(storage: unreadableStorage)
            try expect(unreadable.journalUnreadable && unreadable.pending?.isRecoveryEntry == true,
                       "unreadable journal path must be visible as corruption")
        }

        // Cleanup failure retains the intent and continues to block retry.
        do {
            let storage = ProbeStorage()
            storage.failRemove = true
            let counter = ProbeCounter()
            let store = RingonomiMutationStore(storage: storage)
            do {
                _ = try await run(store, send: { _ in counter.sends += 1; return 1 })
                throw ProbeFailure.message("cleanup failure unexpectedly succeeded")
            } catch is ReservationMutationJournalStorageError {
                // expected
            }
            try expect(store.pending != nil && storage.data != nil && counter.sends == 1,
                       "cleanup failure must retain pending and prevent retry")
        }

        print("PASS: \(checks) reservation mutation checks")
    }
}
