import Foundation
import CryptoKit
import Security
import RingonomiCore

/// Credentials kept in memory while an SMB connection is being used.
///
/// This type deliberately does not conform to Codable.  Only the private
/// Keychain payload below is serialised.
struct SMBCredentials: Equatable, Sendable {
    let username: String
    let password: String
    let domain: String

    init(username: String, password: String, domain: String = "") {
        self.username = username
        self.password = password
        self.domain = domain
    }
}

/// Stores SMB credentials in a device-only Keychain item bound to one
/// connection identity and endpoint.
struct SMBCredentialsKeychain: Sendable {
    private static let lock = NSRecursiveLock()
    private static let installationKey = "smb.credentials.installationID"
    private static let service: String = {
        let defaults = UserDefaults.standard
        let identifier = defaults.string(forKey: installationKey)
            .flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(identifier.uuidString, forKey: installationKey)
        return "app.ringonomitv.smb-credentials." + identifier.uuidString.lowercased()
    }()

    private static let usernameMaximumBytes = 512
    private static let passwordMaximumBytes = 4_096
    private static let domainMaximumBytes = 255

    /// Guest access is represented by nil.  A pending deletion also returns
    /// nil so a stale Keychain item can never be reused implicitly.
    func load(for connection: SMBConnection) throws -> SMBCredentials? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        if isRemovalPendingUnlocked(for: connection) {
            _ = try? removeUnlocked(for: connection)
            return nil
        }

        var query = itemQuery(for: connection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SMBCredentialsKeychainError.read
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            try Self.validate(payload)
            return SMBCredentials(
                username: payload.username,
                password: payload.password,
                domain: payload.domain
            )
        } catch is SMBCredentialsKeychainError {
            throw SMBCredentialsKeychainError.read
        } catch {
            throw SMBCredentialsKeychainError.read
        }
    }

    /// Passing nil removes the saved credentials and represents guest access.
    func save(_ credentials: SMBCredentials?, for connection: SMBConnection) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        guard let credentials else {
            try removeUnlocked(for: connection)
            return
        }
        do {
            try Self.validate(credentials)
        } catch {
            throw SMBCredentialsKeychainError.invalidCredentials
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(
                Payload(
                    username: credentials.username,
                    password: credentials.password,
                    domain: credentials.domain
                )
            )
        } catch {
            throw SMBCredentialsKeychainError.write
        }

        let query = itemQuery(for: connection)
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
                    throw SMBCredentialsKeychainError.write
                }
            } else if addStatus != errSecSuccess {
                throw SMBCredentialsKeychainError.write
            }
        } else if updateStatus != errSecSuccess {
            throw SMBCredentialsKeychainError.write
        }
        UserDefaults.standard.removeObject(forKey: retiredKey(for: connection))
    }

    func remove(for connection: SMBConnection) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try removeUnlocked(for: connection)
    }

    /// True means an earlier explicit removal failed.  Callers must treat the
    /// connection as guest until a later explicit save succeeds.
    func isRemovalPending(for connection: SMBConnection) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return isRemovalPendingUnlocked(for: connection)
    }

    private func removeUnlocked(for connection: SMBConnection) throws {
        let retired = retiredKey(for: connection)
        UserDefaults.standard.set(true, forKey: retired)
        try deleteItemUnlocked(for: connection)
        UserDefaults.standard.removeObject(forKey: retired)
    }

    private func deleteItemUnlocked(for connection: SMBConnection) throws {
        let status = SecItemDelete(itemQuery(for: connection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SMBCredentialsKeychainError.remove
        }
    }

    private func isRemovalPendingUnlocked(for connection: SMBConnection) -> Bool {
        UserDefaults.standard.bool(forKey: retiredKey(for: connection))
    }

    private func itemQuery(for connection: SMBConnection) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: endpointAccount(for: connection),
            kSecAttrSynchronizable as String: false
        ]
    }

    private func retiredKey(for connection: SMBConnection) -> String {
        let identity = Self.service + "\n" + endpointAccount(for: connection)
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "smb.credentials.retired." + digest
    }

    /// The endpoint is part of the account key so a reused connection UUID or
    /// an edited share cannot silently recover another share's password.
    private func endpointAccount(for connection: SMBConnection) -> String {
        let endpoint = [
            "id=" + connection.id.uuidString.lowercased(),
            "host=" + connection.server.lowercased(),
            "port=" + String(connection.port),
            "share=" + connection.share,
            "base=" + connection.baseDirectory.stableKey
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(endpoint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "endpoint." + digest
    }

    private struct Payload: Codable {
        let username: String
        let password: String
        let domain: String
    }

    private static func validate(_ payload: Payload) throws {
        try validate(username: payload.username, password: payload.password, domain: payload.domain)
    }

    private static func validate(_ credentials: SMBCredentials) throws {
        try validate(
            username: credentials.username,
            password: credentials.password,
            domain: credentials.domain
        )
    }

    private static func validate(username: String, password: String, domain: String) throws {
        guard validField(username, minimumBytes: 1, maximumBytes: usernameMaximumBytes),
              validField(password, minimumBytes: 0, maximumBytes: passwordMaximumBytes),
              validField(domain, minimumBytes: 0, maximumBytes: domainMaximumBytes) else {
            throw SMBCredentialsKeychainError.invalidCredentials
        }
    }

    private static func validField(_ value: String, minimumBytes: Int, maximumBytes: Int) -> Bool {
        let byteCount = value.utf8.count
        guard (minimumBytes...maximumBytes).contains(byteCount) else { return false }
        return !value.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F
        }
    }
}

private enum SMBCredentialsKeychainError: LocalizedError, Equatable, Sendable {
    case invalidCredentials
    case read
    case write
    case remove

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "SMBの認証情報が不正です。"
        case .read:
            return "SMBの認証情報を読み込めませんでした。"
        case .write:
            return "SMBの認証情報を保存できませんでした。"
        case .remove:
            return "SMBの認証情報を削除できませんでした。"
        }
    }
}
