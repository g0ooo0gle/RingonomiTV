import Foundation
import CryptoKit
import Security
import RingonomiCore

/// The password is never persisted. Each server path has its own keychain item.
struct AccountKeychain: BackendCredentialStorage {
    private static let lock = NSRecursiveLock()
    // A reinstall gets a new namespace, so an item left by an interrupted
    // deletion cannot silently restore an older installation's session.
    private static let service: String = {
        let defaults = UserDefaults.standard
        let key = "account.installationID"
        let identifier = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(identifier.uuidString, forKey: key)
        return "app.ringonomitv.server-account." + identifier.uuidString
    }()

    func load(for account: String) throws -> BackendAccessToken? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if isRemovalPending(for: account) {
            try? remove(for: account)
            return nil
        }
        var query = itemQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AccountStorageError.read }
        do { return try BackendAccessToken(rawValue: value) }
        catch { throw AccountStorageError.read }
    }

    func save(_ token: BackendAccessToken, for account: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let query = itemQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.rawValue.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AccountStorageError.write }
        } else if status != errSecSuccess { throw AccountStorageError.write }
        UserDefaults.standard.removeObject(forKey: retiredKey(account))
    }

    func remove(for account: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        // Even when Keychain is temporarily unavailable, a requested logout
        // must not silently reuse its old item on the next request or launch.
        // Only a hash of the server identity is stored here, never the token.
        UserDefaults.standard.set(true, forKey: retiredKey(account))
        let status = SecItemDelete(itemQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountStorageError.remove }
        UserDefaults.standard.removeObject(forKey: retiredKey(account))
    }

    func isRemovalPending(for account: String) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return UserDefaults.standard.bool(forKey: retiredKey(account))
    }

    private func retiredKey(_ account: String) -> String {
        let identity = Self.service + "\n" + account
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "account.retired." + digest
    }

    private func itemQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

#if DEBUG
    /// A separate fictional identity tests the signed app's Keychain access
    /// across two launches without reading or changing a user's account item.
    static func checkStorage(arguments: [String]) {
        let write = arguments.contains("--test-account-storage-write")
        let read = arguments.contains("--test-account-storage-read")
        guard write || read else { return }
        let storage = AccountKeychain()
        let account = "https://storage-check.example.invalid/"
        do {
            if write {
                let token = try BackendAccessToken(rawValue: UUID().uuidString)
                try storage.save(token, for: account)
                let matches = try AccountKeychain().load(for: account) == token
                print("RingonomiAccountStorage: wrote=true readBack=\(matches)")
            } else {
                let persisted = try storage.load(for: account) != nil
                try storage.remove(for: account)
                let status = SecItemCopyMatching(storage.itemQuery(account) as CFDictionary, nil)
                let remaining = try storage.load(for: account)
                let cleared = status == errSecItemNotFound && remaining == nil
                UserDefaults.standard.removeObject(forKey: storage.retiredKey(account))
                print("RingonomiAccountStorage: persisted=\(persisted) cleared=\(cleared)")
            }
        } catch {
            print("RingonomiAccountStorage: checkFailed=true")
        }
    }
#endif
}

private enum AccountStorageError: LocalizedError {
    case read, write, remove
    var errorDescription: String? {
        switch self {
        case .read: return "保存したログイン情報を読み込めませんでした。時間をおいて再試行してください。"
        case .write: return "ログイン情報を保存できませんでした。もう一度ログインしてください。"
        case .remove: return "ログイン情報を削除できませんでした。もう一度ログアウトしてください。"
        }
    }
}

extension RingonomiClient {
    static func connected(to address: String) throws -> RingonomiClient {
        let anonymous = try RingonomiClient(address: address)
        let token = try AccountKeychain().load(for: anonymous.accountKeyString)
        return try RingonomiClient(address: address, accessToken: token)
    }
}
