import CryptoKit
import Foundation

/// Errors raised while validating the small local live-channel preference
/// archive. Error values never carry a URL, server name, or channel content.
public enum LiveChannelFavoritesError: Error, LocalizedError, Equatable, Sendable {
    case invalidArchive
    case unsupportedVersion
    case archiveTooLarge
    case invalidServerAddress
    case invalidServerKey
    case invalidChannelID
    case serverLimitExceeded
    case favoriteLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "ライブチャンネルのお気に入りデータが不正です。"
        case .unsupportedVersion: return "ライブチャンネルのお気に入りデータの版が対応していません。"
        case .archiveTooLarge: return "ライブチャンネルのお気に入りデータが大きすぎます。"
        case .invalidServerAddress: return "お気に入りを保存する接続先が不正です。"
        case .invalidServerKey: return "お気に入りの接続先識別子が不正です。"
        case .invalidChannelID: return "お気に入りのチャンネル識別子が不正です。"
        case .serverLimitExceeded: return "お気に入りを保存できる接続先数の上限に達しました。"
        case .favoriteLimitExceeded: return "この接続先のお気に入り数の上限に達しました。"
        }
    }
}

/// A bounded, versioned archive for per-server live-channel favorites.
///
/// Only SHA-256 server keys and channel IDs are serialized. The server URL is
/// used transiently to derive a key and is never retained by this type.
public struct LiveChannelFavoritesArchive: Sendable {
    public static let version = 1
    public static let maximumServers = 16
    public static let maximumFavoritesPerServer = 256
    public static let maximumArchiveBytes = 256 * 1024
    public static let maximumChannelIDBytes = 128

    private var favoritesByServer: [String: Set<String>]

    private struct Payload: Codable {
        let version: Int
        let servers: [String: [String]]
    }

    public init() {
        favoritesByServer = [:]
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumArchiveBytes else {
            throw LiveChannelFavoritesError.archiveTooLarge
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw LiveChannelFavoritesError.invalidArchive
        }
        guard payload.version == Self.version else {
            throw LiveChannelFavoritesError.unsupportedVersion
        }
        guard payload.servers.count <= Self.maximumServers else {
            throw LiveChannelFavoritesError.serverLimitExceeded
        }

        var decoded: [String: Set<String>] = [:]
        decoded.reserveCapacity(payload.servers.count)
        for (rawKey, ids) in payload.servers {
            let key = rawKey.lowercased()
            guard Self.isValidServerKey(key) else { throw LiveChannelFavoritesError.invalidServerKey }
            guard decoded[key] == nil else { throw LiveChannelFavoritesError.invalidServerKey }
            guard ids.count <= Self.maximumFavoritesPerServer else {
                throw LiveChannelFavoritesError.favoriteLimitExceeded
            }
            var set = Set<String>(minimumCapacity: ids.count)
            for id in ids {
                guard Self.isValidChannelID(id), set.insert(id).inserted else {
                    throw LiveChannelFavoritesError.invalidChannelID
                }
            }
            decoded[key] = set
        }
        favoritesByServer = decoded
    }

    public func data() throws -> Data {
        do {
            return try Self.encode(favoritesByServer)
        } catch let error as LiveChannelFavoritesError {
            throw error
        } catch {
            throw LiveChannelFavoritesError.invalidArchive
        }
    }

    public func favoriteIDs(serverKey: String) -> Set<String> {
        favoritesByServer[serverKey.lowercased()] ?? []
    }

    public mutating func setFavorite(
        _ channelID: String,
        isFavorite: Bool,
        serverKey: String
    ) throws {
        let key = serverKey.lowercased()
        guard Self.isValidServerKey(key) else { throw LiveChannelFavoritesError.invalidServerKey }
        guard Self.isValidChannelID(channelID) else { throw LiveChannelFavoritesError.invalidChannelID }

        var ids = favoritesByServer[key] ?? []
        if isFavorite {
            if ids.contains(channelID) { return }
            guard ids.count < Self.maximumFavoritesPerServer else {
                throw LiveChannelFavoritesError.favoriteLimitExceeded
            }
            if favoritesByServer[key] == nil, favoritesByServer.count >= Self.maximumServers {
                throw LiveChannelFavoritesError.serverLimitExceeded
            }
            ids.insert(channelID)
            var candidate = favoritesByServer
            candidate[key] = ids
            _ = try Self.encode(candidate)
            favoritesByServer = candidate
        } else {
            var candidate = favoritesByServer
            ids.remove(channelID)
            if ids.isEmpty {
                candidate.removeValue(forKey: key)
            } else {
                candidate[key] = ids
            }
            // Validate the candidate before publishing the mutation. This
            // keeps a failed archive-size check from partially changing the
            // in-memory preferences.
            _ = try Self.encode(candidate)
            favoritesByServer = candidate
        }
    }

    /// Derive a non-reversible, stable key from the same normalized server
    /// identity used by account storage. Query, fragment, and credentials are
    /// rejected or excluded by the shared backend URL rules.
    public static func serverKey(address: String) throws -> String {
        let normalized: URL
        do {
            normalized = try BackendURLRules.normalize(address)
        } catch {
            throw LiveChannelFavoritesError.invalidServerAddress
        }
        let identity = BackendURLRules.accountKey(for: normalized)
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isValidServerKey(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }

    private static func isValidChannelID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumChannelIDBytes else { return false }
        return bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) ||
            (0x41...0x5A).contains(byte) ||
            (0x61...0x7A).contains(byte) ||
            byte == 0x2D || byte == 0x5F
        }
    }

    private static func encode(_ source: [String: Set<String>]) throws -> Data {
        guard source.count <= Self.maximumServers else {
            throw LiveChannelFavoritesError.serverLimitExceeded
        }
        var servers: [String: [String]] = [:]
        servers.reserveCapacity(source.count)
        for (key, ids) in source {
            guard Self.isValidServerKey(key), ids.count <= Self.maximumFavoritesPerServer else {
                throw LiveChannelFavoritesError.invalidArchive
            }
            guard ids.allSatisfy(Self.isValidChannelID) else {
                throw LiveChannelFavoritesError.invalidArchive
            }
            servers[key] = ids.sorted()
        }
        let payload = Payload(version: Self.version, servers: servers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let encoded = try encoder.encode(payload)
            guard encoded.count <= Self.maximumArchiveBytes else {
                throw LiveChannelFavoritesError.archiveTooLarge
            }
            return encoded
        } catch let error as LiveChannelFavoritesError {
            throw error
        } catch {
            throw LiveChannelFavoritesError.invalidArchive
        }
    }
}
