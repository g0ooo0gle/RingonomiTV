import CryptoKit
import Foundation

/// Errors raised while validating the local SMB resume archive.
public enum SMBResumeArchiveError: Error, LocalizedError, Equatable, Sendable {
    case invalidKey
    case invalidBookmark
    case invalidArchive
    case unsupportedVersion
    case archiveTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "SMB再生位置の識別子が不正です。"
        case .invalidBookmark:
            return "SMB再生位置が不正です。"
        case .invalidArchive:
            return "SMB再生位置の保存データが不正です。"
        case .unsupportedVersion:
            return "SMB再生位置の保存形式に対応していません。"
        case .archiveTooLarge:
            return "SMB再生位置の保存データが大きすぎます。"
        }
    }
}

/// Opaque identity for one SMB file on one normalized connection.
///
/// The raw server, share, base path, filename, and endpoint never appear in
/// the stored value. They are only included in a length-prefixed hash input so
/// a display-name rename cannot move a bookmark and two shares cannot collide.
public struct SMBResumeID: Codable, Equatable, Hashable, Sendable {
    public let storageKey: String

    public init(connection: SMBConnection, entry: SMBLibraryEntry) {
        var input = Data()
        Self.append("ringonomi.smb.identity.v1", to: &input)
        Self.append(connection.id.uuidString.lowercased(), to: &input)
        Self.append(connection.server.lowercased(), to: &input)
        Self.append(UInt64(connection.port), to: &input)
        Self.append(connection.share, to: &input)
        Self.append(connection.baseDirectory.components, to: &input)
        Self.append(entry.path.components, to: &input)
        Self.append(entry.size, to: &input)
        Self.append(entry.modifiedDate, to: &input)
        let digest = SHA256.hash(data: input)
        self.storageKey = "ringonomi.smb.resume.v1." + digest
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public init(storageKey: String) throws {
        guard Self.isValidStorageKey(storageKey) else {
            throw SMBResumeArchiveError.invalidKey
        }
        self.storageKey = storageKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(storageKey: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }

    static let storagePrefix = "ringonomi.smb.resume.v1."

    static func isValidStorageKey(_ value: String) -> Bool {
        guard value.hasPrefix(storagePrefix) else { return false }
        let digest = value.dropFirst(storagePrefix.count)
        guard digest.count == 64 else { return false }
        return digest.allSatisfy { character in
            switch character {
            case "0"..."9", "a"..."f": return true
            default: return false
            }
        }
    }

    private static func append(_ value: String, to data: inout Data) {
        append(UInt64(value.utf8.count), to: &data)
        data.append(contentsOf: value.utf8)
    }

    private static func append(_ values: [String], to data: inout Data) {
        append(UInt64(values.count), to: &data)
        for value in values { append(value, to: &data) }
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: Int64?, to data: inout Data) {
        data.append(value == nil ? 0 : 1)
        if let value {
            append(UInt64(bitPattern: value), to: &data)
        }
    }

    private static func append(_ value: Date?, to data: inout Data) {
        data.append(value == nil ? 0 : 1)
        if let value {
            append(value.timeIntervalSinceReferenceDate.bitPattern, to: &data)
        }
    }
}

/// A validated candidate is kept with its duration so a later playback load
/// can reject a changed file length instead of clamping into a wrong file.
public struct SMBResumeBookmark: Codable, Equatable, Sendable {
    public let seconds: Double
    public let duration: Double
    public let updatedAt: Date

    public init(seconds: Double, duration: Double, updatedAt: Date = Date()) {
        self.seconds = seconds
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

public enum SMBResumePolicy {
    public static let minimumResumeSeconds = 5.0
    public static let endMargin = 0.25

    public static func validatedBookmark(
        seconds: Double,
        duration: Double,
        updatedAt: Date
    ) -> SMBResumeBookmark? {
        guard seconds.isFinite, seconds >= 0,
              duration.isFinite, duration > 0,
              seconds < duration - endMargin,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }
        return SMBResumeBookmark(seconds: seconds, duration: duration, updatedAt: updatedAt)
    }

    /// Returns a position only when it is useful as a resume candidate. Near
    /// the end is retained when it is valid; this method never clears it just
    /// because it is close to the end.
    public static func candidate(bookmark: SMBResumeBookmark) -> Double? {
        guard validatedBookmark(
            seconds: bookmark.seconds,
            duration: bookmark.duration,
            updatedAt: bookmark.updatedAt
        ) != nil,
        bookmark.seconds >= minimumResumeSeconds else {
            return nil
        }
        return bookmark.seconds
    }

    /// Restore only when the current file length still matches the bookmark.
    /// A mismatch is rejected rather than clamped, preventing a position from
    /// moving to an unrelated point after a changed recording.
    public static func restoredPosition(
        bookmark: SMBResumeBookmark,
        currentDuration: Double
    ) -> Double? {
        guard currentDuration.isFinite, currentDuration > 0,
              validatedBookmark(
                  seconds: bookmark.seconds,
                  duration: bookmark.duration,
                  updatedAt: bookmark.updatedAt
              ) != nil,
              abs(currentDuration - bookmark.duration) <= durationTolerance(
                  currentDuration: currentDuration
              ),
              bookmark.seconds < currentDuration - endMargin else {
            return nil
        }
        return bookmark.seconds
    }

    private static func durationTolerance(currentDuration: Double) -> Double {
        max(0.75, min(2.0, currentDuration * 0.001))
    }
}

/// A bounded, per-entry-tolerant archive for local SMB resume positions.
public struct SMBResumeArchive: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumEntries = 200
    public static let maximumDataBytes = 256 * 1024

    public private(set) var entries: [String: SMBResumeBookmark]

    public init() {
        entries = [:]
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumDataBytes else {
            throw SMBResumeArchiveError.archiveTooLarge
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch let error as SMBResumeArchiveError {
            throw error
        } catch {
            throw SMBResumeArchiveError.invalidArchive
        }
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(self)
        } catch {
            throw SMBResumeArchiveError.invalidArchive
        }
        guard data.count <= Self.maximumDataBytes else {
            throw SMBResumeArchiveError.archiveTooLarge
        }
        return data
    }

    public func entry(for id: SMBResumeID) -> SMBResumeBookmark? {
        entries[id.storageKey]
    }

    public func entry(for storageKey: String) -> SMBResumeBookmark? {
        guard SMBResumeID.isValidStorageKey(storageKey) else { return nil }
        return entries[storageKey]
    }

    public mutating func set(
        _ bookmark: SMBResumeBookmark,
        for id: SMBResumeID
    ) throws {
        try set(bookmark, for: id.storageKey)
    }

    public mutating func set(
        _ bookmark: SMBResumeBookmark,
        for storageKey: String
    ) throws {
        guard SMBResumeID.isValidStorageKey(storageKey) else {
            throw SMBResumeArchiveError.invalidKey
        }
        guard SMBResumePolicy.validatedBookmark(
            seconds: bookmark.seconds,
            duration: bookmark.duration,
            updatedAt: bookmark.updatedAt
        ) != nil else {
            throw SMBResumeArchiveError.invalidBookmark
        }
        entries[storageKey] = bookmark
        trimToNewestEntries()
    }

    public mutating func remove(for id: SMBResumeID) {
        entries.removeValue(forKey: id.storageKey)
    }

    public mutating func remove(for storageKey: String) throws {
        guard SMBResumeID.isValidStorageKey(storageKey) else {
            throw SMBResumeArchiveError.invalidKey
        }
        entries.removeValue(forKey: storageKey)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case entries
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys>
        do {
            container = try decoder.container(keyedBy: CodingKeys.self)
        } catch {
            throw SMBResumeArchiveError.invalidArchive
        }
        guard let version = try? container.decode(Int.self, forKey: .version) else {
            throw SMBResumeArchiveError.invalidArchive
        }
        guard version == Self.schemaVersion else {
            throw SMBResumeArchiveError.unsupportedVersion
        }
        guard let entriesContainer = try? container.nestedContainer(
            keyedBy: DynamicCodingKey.self, forKey: .entries
        ) else {
            throw SMBResumeArchiveError.invalidArchive
        }

        var decoded: [String: SMBResumeBookmark] = [:]
        for key in entriesContainer.allKeys {
            let storageKey = key.stringValue
            guard SMBResumeID.isValidStorageKey(storageKey) else { continue }
            guard let bookmark = try? entriesContainer.decode(
                SMBResumeBookmark.self, forKey: key
            ) else { continue }
            guard SMBResumePolicy.validatedBookmark(
                seconds: bookmark.seconds,
                duration: bookmark.duration,
                updatedAt: bookmark.updatedAt
            ) != nil else { continue }
            decoded[storageKey] = bookmark
        }
        entries = Self.newestEntries(decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .version)
        try container.encode(entries, forKey: .entries)
    }

    private mutating func trimToNewestEntries() {
        entries = Self.newestEntries(entries)
    }

    private static func newestEntries(
        _ source: [String: SMBResumeBookmark]
    ) -> [String: SMBResumeBookmark] {
        let newest = source.sorted { lhs, rhs in
            if lhs.value.updatedAt != rhs.value.updatedAt {
                return lhs.value.updatedAt > rhs.value.updatedAt
            }
            return lhs.key < rhs.key
        }.prefix(Self.maximumEntries)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}
