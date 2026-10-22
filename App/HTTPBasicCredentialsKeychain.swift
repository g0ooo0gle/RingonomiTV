import CryptoKit
import Foundation
import Security
import RingonomiCore

/// Basic credentials have their own installation namespace and a directory
/// scope. Bearer and SMB entries never participate in this lookup.
struct HTTPBasicCredentialsKeychain: Sendable {
    private static let lock = NSRecursiveLock()
    private static let service: String = {
        let defaults = UserDefaults.standard
        let key = "http-basic.installationID"
        let id = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(id.uuidString, forKey: key)
        return "app.ringonomitv.http-basic." + id.uuidString.lowercased()
    }()

    private static let maximumPayloadBytes = 64 * 1024

    /// KonomiTV accepts browser addresses ending in /tv/. Use the same
    /// normalization once for saving and loading, including nested /tv/tv/.
    static func konomiScope(address: String) throws -> HTTPBasicAuthenticationScope {
        let client = try RingonomiClient(address: address)
        return try HTTPBasicAuthenticationScope(address: client.baseURL.absoluteString)
    }

    private struct Payload: Codable {
        let username: String
        let password: String
    }

    func load(for scope: HTTPBasicAuthenticationScope) throws -> HTTPBasicCredential? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if isRemovalPending(for: scope) {
            try? remove(for: scope)
            return nil
        }
        var query = itemQuery(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= Self.maximumPayloadBytes else {
            throw HTTPBasicStorageError.read
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return try HTTPBasicCredential(username: payload.username, password: payload.password)
        } catch { throw HTTPBasicStorageError.read }
    }

    /// The interoperable ASCII encoding is persisted. UTF-8 credentials need
    /// an explicit server challenge workflow before enabling them in settings.
    func save(username: String, password: String, for scope: HTTPBasicAuthenticationScope) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        _ = try HTTPBasicCredential(username: username, password: password)
        let data: Data
        do { data = try JSONEncoder().encode(Payload(username: username, password: password)) }
        catch { throw HTTPBasicStorageError.write }
        guard data.count <= Self.maximumPayloadBytes else { throw HTTPBasicStorageError.write }
        let query = itemQuery(scope)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecDuplicateItem {
                guard SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                    throw HTTPBasicStorageError.write
                }
            } else if added != errSecSuccess { throw HTTPBasicStorageError.write }
        } else if status != errSecSuccess { throw HTTPBasicStorageError.write }
        UserDefaults.standard.removeObject(forKey: retiredKey(scope))
    }

    func remove(for scope: HTTPBasicAuthenticationScope) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        // A failed physical deletion must not resurrect an explicitly removed
        // credential. Only the scope hash is placed in preferences.
        UserDefaults.standard.set(true, forKey: retiredKey(scope))
        let status = SecItemDelete(itemQuery(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HTTPBasicStorageError.remove }
        UserDefaults.standard.removeObject(forKey: retiredKey(scope))
    }

    func isRemovalPending(for scope: HTTPBasicAuthenticationScope) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return UserDefaults.standard.bool(forKey: retiredKey(scope))
    }

    private func retiredKey(_ scope: HTTPBasicAuthenticationScope) -> String {
        "http-basic.retired." + account(scope)
    }

    private func account(_ scope: HTTPBasicAuthenticationScope) -> String {
        SHA256.hash(data: Data((Self.service + "\n" + scope.storageIdentity).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func itemQuery(_ scope: HTTPBasicAuthenticationScope) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account(scope),
         kSecAttrSynchronizable as String: false]
    }

#if DEBUG
    /// The two explicit launches inspect only a fictional identity, then clear
    /// it. They never read a configured server's item or log credential data.
    static func checkStorage(arguments: [String]) {
        let write = arguments.contains("--test-basic-storage-write")
        let read = arguments.contains("--test-basic-storage-read")
        guard write || read else { return }
        let storage = HTTPBasicCredentialsKeychain()
        do {
            let scope = try konomiScope(address: "https://basic-storage-check.example.invalid/proxy/tv/")
            if write {
                let password = UUID().uuidString
                try storage.save(username: "fixture-user", password: password, for: scope)
                let expected = try HTTPBasicCredential(username: "fixture-user", password: password)
                let equivalent = try konomiScope(address: "https://basic-storage-check.example.invalid/proxy/")
                let matches = try HTTPBasicCredentialsKeychain().load(for: equivalent) == expected
                let nested = try konomiScope(address: "https://basic-storage-check.example.invalid/proxy/tv/tv/")
                let nestedIsolated = try storage.load(for: nested) == nil
                let limits = try konomiScope(address: "https://basic-storage-check.example.invalid/payload-limits/")
                let longUsername = String(repeating: "\"", count: 1024)
                let longPassword = String(repeating: "\\", count: 16 * 1024)
                try storage.save(username: longUsername, password: longPassword, for: limits)
                let limitsMatch = try storage.load(for: limits) == HTTPBasicCredential(username: longUsername, password: longPassword)
                try storage.remove(for: limits)
                let sibling = try HTTPBasicAuthenticationScope(address: "https://basic-storage-check.example.invalid/proxy2/")
                let isolated = try storage.load(for: sibling) == nil
                print("RingonomiBasicStorage: wrote=true readBack=\(matches) scopeIsolated=\(isolated) nestedIsolated=\(nestedIsolated) limitsMatch=\(limitsMatch)")
            } else {
                let persisted = try storage.load(for: scope) != nil
                try storage.remove(for: scope)
                let status = SecItemCopyMatching(storage.itemQuery(scope) as CFDictionary, nil)
                let remaining = try storage.load(for: scope)
                let cleared = status == errSecItemNotFound && remaining == nil
                UserDefaults.standard.removeObject(forKey: storage.retiredKey(scope))
                print("RingonomiBasicStorage: persisted=\(persisted) cleared=\(cleared)")
            }
        } catch { print("RingonomiBasicStorage: checkFailed=true") }
    }
#endif
}

private enum HTTPBasicStorageError: LocalizedError {
    case read, write, remove
    var errorDescription: String? {
        switch self {
        case .read: return "保存したBasic認証情報を読み込めませんでした。時間をおいて再試行してください。"
        case .write: return "Basic認証情報を保存できませんでした。再試行してください。"
        case .remove: return "Basic認証情報を削除できませんでした。削除を再試行してください。"
        }
    }
}
