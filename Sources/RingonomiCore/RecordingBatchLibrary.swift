import CryptoKit
import Foundation

/// Errors raised while validating the local post-recording batch archive.
public enum RecordingBatchArchiveError: Error, LocalizedError, Equatable, Sendable {
    case invalidArchive
    case unsupportedVersion
    case archiveTooLarge
    case invalidServerAddress
    case invalidServerKey
    case invalidNamespace
    case invalidName
    case invalidPath
    case duplicateID
    case serverLimitExceeded
    case batchLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "録画後実行バッチ登録の保存データが不正です。"
        case .unsupportedVersion: return "録画後実行バッチ登録の版に対応していません。"
        case .archiveTooLarge: return "録画後実行バッチ登録の保存データが大きすぎます。"
        case .invalidServerAddress: return "録画後実行バッチ登録の接続先が不正です。"
        case .invalidServerKey: return "録画後実行バッチ登録の接続先識別子が不正です。"
        case .invalidNamespace: return "録画後実行バッチ登録の接続先識別子が重複または不正です。"
        case .invalidName: return "録画後実行バッチ名が不正です。"
        case .invalidPath: return "録画後実行バッチのパスが不正です。"
        case .duplicateID: return "録画後実行バッチの識別子が重複しています。"
        case .serverLimitExceeded: return "録画後実行バッチを保存できる接続先数の上限に達しました。"
        case .batchLimitExceeded: return "この接続先に保存できる録画後実行バッチ数の上限に達しました。"
        }
    }
}

/// A registered batch command invoked by the recording server after recording.
///
/// The path points to the batch command on the recording server. This value
/// type only stores the registration; it never executes or sends the command.
public struct RegisteredRecordingBatch: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String

    public init(id: UUID = UUID(), name: String, path: String) throws {
        guard Self.isValidName(name) else { throw RecordingBatchArchiveError.invalidName }
        guard Self.isValidPath(path) else { throw RecordingBatchArchiveError.invalidPath }
        self.id = id
        self.name = name
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let path = try container.decode(String.self, forKey: .path)
        try self.init(id: id, name: name, path: path)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
    }

    private static func isValidName(_ value: String) -> Bool {
        isValidText(value, maximumUTF8Bytes: RecordingBatchArchive.maximumNameBytes)
    }

    private static func isValidPath(_ value: String) -> Bool {
        isValidText(value, maximumUTF8Bytes: RecordingBatchArchive.maximumPathBytes)
    }

    private static func isValidText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumUTF8Bytes else {
            return false
        }
        // Spaces, percent signs, backslashes, and non-ASCII text are valid
        // batch names/paths. Reject only Unicode C0/C1 controls and DEL.
        return !value.unicodeScalars.contains { scalar in
            let number = scalar.value
            return number <= 0x1F || (0x7F...0x9F).contains(number)
        }
    }
}

/// A bounded, versioned archive of post-recording batch registrations grouped
/// by server.
///
/// Server URLs are normalized and hashed before they become archive keys.
/// Neither the raw URL nor credentials are encoded in the archive.
public struct RecordingBatchArchive: Equatable, Sendable {
    public static let version = 1
    public static let maximumServers = 32
    public static let maximumEntriesPerServer = 64
    public static let maximumArchiveBytes = 256 * 1024
    public static let maximumNameBytes = 128
    public static let maximumPathBytes = 4096

    private struct ServerEntries: Equatable, Sendable {
        let key: String
        var entries: [RegisteredRecordingBatch]
    }

    private struct Payload: Codable {
        let version: Int
        let servers: [ServerPayload]
    }

    private struct ServerPayload: Codable {
        let key: String
        let entries: [RegisteredRecordingBatch]
    }

    private var servers: [ServerEntries]

    public init() {
        servers = []
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumArchiveBytes else {
            throw RecordingBatchArchiveError.archiveTooLarge
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch let error as RecordingBatchArchiveError {
            throw error
        } catch {
            throw RecordingBatchArchiveError.invalidArchive
        }

        guard payload.version == Self.version else {
            throw RecordingBatchArchiveError.unsupportedVersion
        }
        guard payload.servers.count <= Self.maximumServers else {
            throw RecordingBatchArchiveError.serverLimitExceeded
        }

        var decoded: [ServerEntries] = []
        decoded.reserveCapacity(payload.servers.count)
        var namespaces = Set<String>()
        for server in payload.servers {
            let key = server.key.lowercased()
            guard Self.isValidServerKey(key) else {
                throw RecordingBatchArchiveError.invalidServerKey
            }
            guard namespaces.insert(key).inserted else {
                throw RecordingBatchArchiveError.invalidNamespace
            }
            guard server.entries.count <= Self.maximumEntriesPerServer else {
                throw RecordingBatchArchiveError.batchLimitExceeded
            }

            var IDs = Set<UUID>()
            IDs.reserveCapacity(server.entries.count)
            for entry in server.entries {
                guard IDs.insert(entry.id).inserted else {
                    throw RecordingBatchArchiveError.duplicateID
                }
            }
            decoded.append(ServerEntries(key: key, entries: server.entries))
        }
        servers = decoded
    }

    /// Returns the entries in their saved order. Invalid keys produce no
    /// entries, keeping this read-only lookup non-throwing for UI callers.
    public func entries(serverKey: String) -> [RegisteredRecordingBatch] {
        let key = serverKey.lowercased()
        guard Self.isValidServerKey(key) else { return [] }
        return servers.first(where: { $0.key == key })?.entries ?? []
    }

    /// Adds an entry or replaces the entry with the same ID, preserving order.
    public mutating func upsert(
        _ entry: RegisteredRecordingBatch,
        serverKey: String
    ) throws {
        let key = try Self.validatedServerKey(serverKey)
        guard let serverIndex = servers.firstIndex(where: { $0.key == key }) else {
            guard servers.count < Self.maximumServers else {
                throw RecordingBatchArchiveError.serverLimitExceeded
            }
            var candidate = servers
            candidate.append(ServerEntries(key: key, entries: [entry]))
            _ = try Self.encode(candidate)
            servers = candidate
            return
        }

        var candidate = servers
        if let entryIndex = candidate[serverIndex].entries.firstIndex(where: { $0.id == entry.id }) {
            candidate[serverIndex].entries[entryIndex] = entry
        } else {
            guard candidate[serverIndex].entries.count < Self.maximumEntriesPerServer else {
                throw RecordingBatchArchiveError.batchLimitExceeded
            }
            candidate[serverIndex].entries.append(entry)
        }
        _ = try Self.encode(candidate)
        servers = candidate
    }

    /// Removes an entry and reports whether it was present.
    @discardableResult
    public mutating func remove(
        id: UUID,
        serverKey: String
    ) throws -> Bool {
        let key = try Self.validatedServerKey(serverKey)
        guard let serverIndex = servers.firstIndex(where: { $0.key == key }) else {
            return false
        }
        guard let entryIndex = servers[serverIndex].entries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        var candidate = servers
        candidate[serverIndex].entries.remove(at: entryIndex)
        if candidate[serverIndex].entries.isEmpty {
            candidate.remove(at: serverIndex)
        }
        _ = try Self.encode(candidate)
        servers = candidate
        return true
    }

    /// Encodes the archive without modifying it. Server and entry order is
    /// preserved, so a UI list remains stable across a save/load round trip.
    public func data() throws -> Data {
        try Self.encode(servers)
    }

    /// Derives the same opaque per-server namespace used by live favorites.
    public static func serverKey(address: String) throws -> String {
        let normalized: URL
        do {
            normalized = try BackendURLRules.normalize(address)
        } catch {
            throw RecordingBatchArchiveError.invalidServerAddress
        }
        let identity = BackendURLRules.accountKey(for: normalized)
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func validatedServerKey(_ value: String) throws -> String {
        let key = value.lowercased()
        guard isValidServerKey(key) else {
            throw RecordingBatchArchiveError.invalidServerKey
        }
        return key
    }

    private static func isValidServerKey(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) ||
            (0x41...0x46).contains(byte) ||
            (0x61...0x66).contains(byte)
        }
    }

    private static func encode(_ source: [ServerEntries]) throws -> Data {
        guard source.count <= Self.maximumServers else {
            throw RecordingBatchArchiveError.serverLimitExceeded
        }

        var namespaces = Set<String>()
        var payloadServers: [ServerPayload] = []
        payloadServers.reserveCapacity(source.count)
        for server in source {
            let key = server.key.lowercased()
            guard isValidServerKey(key), namespaces.insert(key).inserted else {
                throw RecordingBatchArchiveError.invalidNamespace
            }
            guard server.entries.count <= Self.maximumEntriesPerServer else {
                throw RecordingBatchArchiveError.batchLimitExceeded
            }

            var IDs = Set<UUID>()
            IDs.reserveCapacity(server.entries.count)
            for entry in server.entries {
                guard IDs.insert(entry.id).inserted else {
                    throw RecordingBatchArchiveError.duplicateID
                }
            }
            payloadServers.append(ServerPayload(key: key, entries: server.entries))
        }

        let payload = Payload(version: Self.version, servers: payloadServers)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(payload)
            guard encoded.count <= Self.maximumArchiveBytes else {
                throw RecordingBatchArchiveError.archiveTooLarge
            }
            return encoded
        } catch let error as RecordingBatchArchiveError {
            throw error
        } catch {
            throw RecordingBatchArchiveError.invalidArchive
        }
    }
}
