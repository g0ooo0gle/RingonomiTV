import Foundation
import Security

/// The small journal payload is kept in a device-only Generic Password item.
/// This protocol keeps the store testable without writing to the host
/// Keychain during state probes.
protocol ReservationMutationJournalKeychain: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

/// Synchronous Security.framework adapter for the reservation mutation journal.
/// The service and account are app-specific names and do not depend on a
/// bundle identifier, signing team, or user-provided server address.
final class SecurityReservationMutationKeychain: ReservationMutationJournalKeychain {
    private static let lock = NSRecursiveLock()
    private static let service = "ringonomi.reservation-mutation-journal"
    private static let account = "pending-v1"

    func read() throws -> Data? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try readUnlocked()
    }

    func write(_ data: Data) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let query = itemQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                guard SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                    throw ReservationMutationJournalStorageError.keychainWriteFailed
                }
            } else if addStatus != errSecSuccess {
                throw ReservationMutationJournalStorageError.keychainWriteFailed
            }
        } else if updateStatus != errSecSuccess {
            throw ReservationMutationJournalStorageError.keychainWriteFailed
        }

        // Do not consider the pre-send persistence complete until the
        // synchronous readback exactly matches the bytes that were written.
        guard try readUnlocked() == data else {
            throw ReservationMutationJournalStorageError.keychainWriteFailed
        }
    }

    func remove() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let status = SecItemDelete(itemQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReservationMutationJournalStorageError.keychainRemoveFailed
        }
    }

    private func readUnlocked() throws -> Data? {
        var query = itemQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ReservationMutationJournalStorageError.keychainReadFailed
        }
        return data
    }

    private func itemQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

/// Keychain-backed journal with one-way compatibility for the former
/// UserDefaults key. The legacy value is removed only after a successful
/// Keychain write and byte-for-byte readback.
final class KeychainReservationMutationStorage: ReservationMutationJournalStorage {
    private let keychain: ReservationMutationJournalKeychain
    private let defaults: UserDefaults
    private let legacyKey: String

    init(
        keychain: ReservationMutationJournalKeychain = SecurityReservationMutationKeychain(),
        defaults: UserDefaults = .standard,
        legacyKey: String = "ringonomiPendingReservationWrite.v1"
    ) {
        self.keychain = keychain
        self.defaults = defaults
        self.legacyKey = legacyKey
    }

    func read() throws -> Data? {
        let legacy = try readLegacy()
        let current: Data?
        do {
            current = try keychain.read()
        } catch let error as ReservationMutationJournalStorageError {
            // A pre-Keychain install may still have a usable legacy intent
            // while the device is temporarily unable to read Keychain (for
            // example before the first unlock). Keep that intent reviewable;
            // any new write still fails closed in write(_:).
            if error == .keychainReadFailed, let legacy {
                return legacy
            }
            throw error
        }

        if let current {
            guard let legacy else { return current }
            guard legacy == current else {
                throw ReservationMutationJournalStorageError.legacyConflict
            }
            try removeLegacy()
            return current
        }

        guard let legacy else { return nil }
        // A valid legacy value is migrated only after the Keychain adapter
        // confirms that the same bytes can be read back.
        try keychain.write(legacy)
        guard try keychain.read() == legacy else {
            throw ReservationMutationJournalStorageError.keychainWriteFailed
        }
        try removeLegacy()
        return legacy
    }

    func write(_ data: Data) throws {
        let legacy = try readLegacy()
        if let legacy, legacy != data {
            // A second write must never overwrite a legacy intent whose
            // migration has not completed.
            throw ReservationMutationJournalStorageError.legacyConflict
        }
        try keychain.write(data)
        guard try keychain.read() == data else {
            throw ReservationMutationJournalStorageError.keychainWriteFailed
        }
        if legacy != nil {
            try removeLegacy()
        }
    }

    func remove() throws {
        // Keep the legacy value if the Keychain deletion fails. This lets the
        // next launch recover the unresolved operation instead of retrying it.
        try keychain.remove()
        try removeLegacy()
    }

    private func readLegacy() throws -> Data? {
        guard let value = defaults.object(forKey: legacyKey) else { return nil }
        guard let data = value as? Data else {
            throw ReservationMutationJournalStorageError.legacyCorrupt
        }
        return data
    }

    private func removeLegacy() throws {
        guard defaults.object(forKey: legacyKey) != nil else { return }
        defaults.removeObject(forKey: legacyKey)
        guard defaults.object(forKey: legacyKey) == nil else {
            throw ReservationMutationJournalStorageError.legacyMigrationFailed
        }
    }
}
