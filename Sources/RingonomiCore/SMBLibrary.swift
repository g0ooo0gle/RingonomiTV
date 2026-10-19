import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors for SMB value models and URI boundary checks.
///
/// These errors intentionally carry no URL, path, username, password, or
/// server response. A caller can show the localized description without
/// accidentally putting credentials or private NAS details in a log.
public enum SMBError: Error, LocalizedError, Equatable, Sendable {
    case invalidConnection
    case invalidPath
    case invalidEntry
    case unsafeExternalURL

    public var errorDescription: String? {
        switch self {
        case .invalidConnection:
            return "SMB接続情報が不正です。"
        case .invalidPath:
            return "SMBパスが不正です。"
        case .invalidEntry:
            return "SMBファイル情報が不正です。"
        case .unsafeExternalURL:
            return "SMB外部URLは接続先の共有範囲外です。"
        }
    }
}

/// A path relative to an SMB share or to the configured connection base
/// directory, depending on the API that carries it.
///
/// Components are kept as decoded values. A literal percent sign is just a
/// filename character here; URL encoding is performed exactly once when a
/// connection creates an SMB URL.
public struct SMBRelativePath: Codable, Hashable, Sendable, Equatable,
    CustomStringConvertible {
    public static let maximumDepth = 64
    public static let maximumComponentBytes = 255
    public static let maximumTotalBytes = 4_096

    public let components: [String]

    public static var root: SMBRelativePath {
        SMBRelativePath(uncheckedComponents: [])
    }

    public var isRoot: Bool { components.isEmpty }

    public var description: String {
        components.joined(separator: "/")
    }

    public init(components: [String]) throws {
        guard components.count <= Self.maximumDepth else {
            throw SMBError.invalidPath
        }
        var totalBytes = 0
        for component in components {
            guard Self.isValidComponent(component) else {
                throw SMBError.invalidPath
            }
            totalBytes += component.utf8.count
            guard totalBytes <= Self.maximumTotalBytes else {
                throw SMBError.invalidPath
            }
        }
        self.components = components
    }

    /// Parse a slash-separated relative path. Backslashes are never treated
    /// as separators because accepting both spellings makes traversal and
    /// double-normalization bugs easy to introduce.
    public init(string: String) throws {
        if string.isEmpty {
            self = .root
            return
        }
        guard !string.hasPrefix("/"),
              !string.hasSuffix("/"),
              !string.contains("\\") else {
            throw SMBError.invalidPath
        }
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: \.isEmpty) else {
            throw SMBError.invalidPath
        }
        try self.init(components: parts.map(String.init))
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.singleValueContainer()
            let components = try container.decode([String].self)
            try self.init(components: components)
        } catch let error as SMBError {
            throw error
        } catch {
            throw SMBError.invalidPath
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(components)
    }

    /// Add one literal entry name. The name is never URL-decoded here.
    public func child(_ name: String) throws -> SMBRelativePath {
        try SMBRelativePath(components: components + [name])
    }

    /// Return the parent path, or nil when this path is already the share/base
    /// root.
    public func parent() -> SMBRelativePath? {
        guard !components.isEmpty else { return nil }
        return SMBRelativePath(uncheckedComponents: Array(components.dropLast()))
    }

    /// A length-prefixed key avoids collisions such as ["a/b"] versus
    /// ["a", "b"] and keeps literal percent signs literal.
    public var stableKey: String {
        components.map { "\($0.utf8.count):\($0)" }.joined(separator: "/")
    }

    fileprivate static func isValidComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= maximumComponentBytes else {
            return false
        }
        guard !value.contains("/"), !value.contains("\\") else { return false }
        return !value.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F
        }
    }

    fileprivate init(uncheckedComponents: [String]) {
        self.components = uncheckedComponents
    }
}

/// A saved SMB share and the directory from which its library is browsed.
///
/// baseDirectory is relative to share. Methods accepting an
/// SMBRelativePath (such as url(for:)) treat that argument as relative to
/// this base directory. The URL initializer accepts a full smb:// URL and
/// splits its first path component into share.
public struct SMBConnection: Identifiable, Codable, Equatable, Sendable {
    /// Bound both the decoded and percent-encoded path forms. The latter is
    /// relevant to native URL consumers because non-ASCII and reserved bytes
    /// can expand to three ASCII bytes each.
    private static let maximumEncodedPathBytes =
        (SMBRelativePath.maximumTotalBytes + SMBRelativePath.maximumComponentBytes) * 3 +
        SMBRelativePath.maximumDepth + 1
    private static let maximumAddressBytes = maximumEncodedPathBytes + 512

    public let id: UUID
    public let displayName: String
    /// Host without IPv6 brackets. DNS names are stored lowercase.
    public let server: String
    /// The effective SMB port. The default is normalized to 445.
    public let port: Int
    public let share: String
    public let baseDirectory: SMBRelativePath

    private enum CodingKeys: String, CodingKey {
        case id, displayName, server, port, share, baseDirectory
    }

    /// Create a connection from a full SMB URL such as
    /// smb://nas.example/recordings/tv.
    public init(
        address: String,
        id: UUID = UUID(),
        displayName: String? = nil
    ) throws {
        let parsed = try Self.parseAddress(address)
        try self.init(
            id: id,
            displayName: displayName ?? "\(parsed.server)/\(parsed.share)",
            server: parsed.server,
            port: parsed.port,
            share: parsed.share,
            baseDirectory: parsed.baseDirectory
        )
    }

    public init(
        address: URL,
        id: UUID = UUID(),
        displayName: String? = nil
    ) throws {
        try self.init(address: address.absoluteString, id: id, displayName: displayName)
    }

    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        server: String,
        port: Int = 445,
        share: String,
        baseDirectory: SMBRelativePath = .root
    ) throws {
        let normalizedServer = try Self.normalizeServer(server)
        let normalizedShare = try Self.normalizeShare(share)
        guard (1...65_535).contains(port) else {
            throw SMBError.invalidConnection
        }
        let resolvedName = displayName ?? "\(normalizedServer)/\(normalizedShare)"
        guard Self.isValidDisplayName(resolvedName) else {
            throw SMBError.invalidConnection
        }
        self.id = id
        self.displayName = resolvedName
        self.server = normalizedServer
        self.port = port
        self.share = normalizedShare
        self.baseDirectory = baseDirectory
    }

    public init(
        server: String,
        share: String,
        port: Int = 445,
        baseDirectory: SMBRelativePath = .root,
        id: UUID = UUID(),
        displayName: String? = nil
    ) throws {
        try self.init(
            id: id,
            displayName: displayName,
            server: server,
            port: port,
            share: share,
            baseDirectory: baseDirectory
        )
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(UUID.self, forKey: .id)
            let displayName = try container.decode(String.self, forKey: .displayName)
            let server = try container.decode(String.self, forKey: .server)
            let port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 445
            let share = try container.decode(String.self, forKey: .share)
            let baseDirectory = try container.decodeIfPresent(
                SMBRelativePath.self,
                forKey: .baseDirectory
            ) ?? .root
            try self.init(
                id: id,
                displayName: displayName,
                server: server,
                port: port,
                share: share,
                baseDirectory: baseDirectory
            )
        } catch {
            throw SMBError.invalidConnection
        }
    }

    /// URL for a path relative to baseDirectory.
    public func url(for relativePath: SMBRelativePath = .root) throws -> URL {
        try makeURL(for: relativePath)
    }

    /// Validate a VLC/native-player subitem URL and return its path relative
    /// to this connection's base directory.
    public func relativePath(for externalURL: URL) throws -> SMBRelativePath {
        guard let components = URLComponents(
            url: externalURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw SMBError.unsafeExternalURL
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.scheme?.lowercased() == "smb",
              let host = components.host,
              Self.normalizeServerIfValid(host) == server,
              (components.port ?? 445) == port else {
            throw SMBError.unsafeExternalURL
        }

        let pathComponents: [String]
        do {
            pathComponents = try Self.decodePathComponents(
                components.percentEncodedPath
            )
        } catch {
            throw SMBError.unsafeExternalURL
        }
        guard let externalShare = pathComponents.first,
              Self.compareShare(externalShare, share) else {
            throw SMBError.unsafeExternalURL
        }
        let shareRelative = Array(pathComponents.dropFirst())
        guard shareRelative.starts(with: baseDirectory.components) else {
            throw SMBError.unsafeExternalURL
        }
        do {
            let relativeComponents = Array(
                shareRelative.dropFirst(baseDirectory.components.count)
            )
            _ = try SMBRelativePath(
                components: baseDirectory.components + relativeComponents
            )
            guard Self.encodedPath(for: [share] + baseDirectory.components + relativeComponents)
                    .utf8.count <= Self.maximumEncodedPathBytes else {
                throw SMBError.unsafeExternalURL
            }
            return try SMBRelativePath(components: relativeComponents)
        } catch {
            throw SMBError.unsafeExternalURL
        }
    }

    /// A stable, non-secret key suitable for pins and resume bookmarks.
    /// The connection UUID prevents the same path on two shares from
    /// colliding.
    public func stableKey(for relativePath: SMBRelativePath = .root) -> String {
        "smb:\(id.uuidString.lowercased()):\(relativePath.stableKey)"
    }

    private func makeURL(for relativePath: SMBRelativePath) throws -> URL {
        let combinedPath = try SMBRelativePath(
            components: baseDirectory.components + relativePath.components
        )
        let path = [share] + combinedPath.components
        let encodedPath = Self.encodedPath(for: path)
        guard encodedPath.utf8.count <= Self.maximumEncodedPathBytes else {
            throw SMBError.invalidPath
        }
        var components = URLComponents()
        components.scheme = "smb"
        // Darwin URLComponents requires brackets when assigning an IPv6
        // literal. The stored server value intentionally remains unbracketed
        // for Codable and host comparisons.
        components.host = server.contains(":") ? "[\(server)]" : server
        if port != 445 { components.port = port }
        components.percentEncodedPath = encodedPath
        guard let url = components.url else {
            throw SMBError.invalidConnection
        }
        return url
    }

    private struct ParsedAddress {
        let server: String
        let port: Int
        let share: String
        let baseDirectory: SMBRelativePath
    }

    private static func parseAddress(_ address: String) throws -> ParsedAddress {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= maximumAddressBytes,
              let schemeSeparator = input.range(of: "://"),
              String(input[..<schemeSeparator.lowerBound]).caseInsensitiveCompare("smb") == .orderedSame else {
            throw SMBError.invalidConnection
        }

        // Validate the caller's spelling before Foundation can repair an
        // invalid escape (for example `%ZZ` -> `%25ZZ`) or encode a mixed
        // Unicode/raw-percent path a second time.
        try validateRawPercentEscapes(input)

        let authorityAndPath = input[schemeSeparator.upperBound...]
        guard let firstPathCharacter = authorityAndPath.firstIndex(of: "/") else {
            throw SMBError.invalidConnection
        }
        let rawAuthority = String(authorityAndPath[..<firstPathCharacter])
        let rawPath = String(authorityAndPath[firstPathCharacter...])
        guard !rawAuthority.isEmpty,
              !rawAuthority.contains("?"),
              !rawAuthority.contains("#"),
              !rawAuthority.contains("%"),
              !rawPath.contains("?"),
              !rawPath.contains("#") else {
            throw SMBError.invalidConnection
        }

        // Parse only the authority with Foundation. The path is decoded from
        // the original string below, so URLComponents cannot double-escape it.
        guard let authority = URLComponents(string: "smb://" + rawAuthority),
              authority.user == nil,
              authority.password == nil,
              authority.query == nil,
              authority.fragment == nil,
              let host = authority.host,
              let server = normalizeServerIfValid(host) else {
            throw SMBError.invalidConnection
        }
        let port = authority.port ?? 445
        guard (1...65_535).contains(port) else {
            throw SMBError.invalidConnection
        }

        let pathComponents: [String]
        do {
            pathComponents = try decodePathComponents(rawPath)
        } catch {
            throw SMBError.invalidConnection
        }
        guard let share = pathComponents.first,
              let normalizedShare = try? normalizeShare(share) else {
            throw SMBError.invalidConnection
        }
        do {
            let baseDirectory = try SMBRelativePath(
                components: Array(pathComponents.dropFirst())
            )
            guard encodedPath(for: pathComponents).utf8.count <= maximumEncodedPathBytes else {
                throw SMBError.invalidConnection
            }
            return ParsedAddress(
                server: server,
                port: port,
                share: normalizedShare,
                baseDirectory: baseDirectory
            )
        } catch {
            throw SMBError.invalidConnection
        }
    }

    private static func normalizeServer(_ value: String) throws -> String {
        guard let normalized = normalizeServerIfValid(value) else {
            throw SMBError.invalidConnection
        }
        return normalized
    }

    private static func normalizeServerIfValid(_ value: String) -> String? {
        var server = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if server.hasPrefix("[") || server.hasSuffix("]") {
            guard server.hasPrefix("["),
                  server.hasSuffix("]"),
                  server.count >= 2 else {
                return nil
            }
            server = String(server.dropFirst().dropLast())
        }
        guard !server.isEmpty,
              server.utf8.count <= 253,
              server.unicodeScalars.allSatisfy({ $0.value < 0x80 }),
              !server.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F ||
                  $0 == "/" || $0 == "\\" || $0 == "?" || $0 == "#" || $0 == "%"
              }) else {
            return nil
        }
        if server.hasSuffix(".") && !server.contains(":") {
            server.removeLast()
        }
        guard !server.isEmpty else { return nil }
        if server.contains(":") {
            guard isValidIPv6Literal(server) else {
                return nil
            }
            return server.lowercased()
        }
        guard !server.contains(" "),
              server.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }) else {
            return nil
        }
        return server.lowercased()
    }

    private static func isValidIPv6Literal(_ value: String) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return value.withCString { pointer in
            var address = in6_addr()
            return inet_pton(AF_INET6, pointer, &address) == 1
        }
        #else
        return false
        #endif
    }

    private static func normalizeShare(_ value: String) throws -> String {
        guard SMBRelativePath.isValidComponent(value) else {
            throw SMBError.invalidConnection
        }
        return value
    }

    private static func compareShare(_ lhs: String, _ rhs: String) -> Bool {
        // Host names are case-insensitive. Share and file names retain their
        // server-provided spelling so a case-sensitive backend cannot be
        // crossed accidentally.
        lhs == rhs
    }

    private static func isValidDisplayName(_ value: String) -> Bool {
        !value.isEmpty &&
        value.utf8.count <= 256 &&
        !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func decodePathComponents(_ encodedPath: String) throws -> [String] {
        guard encodedPath.hasPrefix("/"),
              encodedPath.utf8.count <= maximumEncodedPathBytes else {
            throw SMBError.invalidConnection
        }
        let rawComponents = encodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard rawComponents.first?.isEmpty == true else {
            throw SMBError.invalidConnection
        }
        let withoutLeadingSlash = rawComponents.dropFirst()
        let trimmed = withoutLeadingSlash.last?.isEmpty == true
            ? withoutLeadingSlash.dropLast()
            : withoutLeadingSlash[...]
        guard !trimmed.contains(where: \.isEmpty) else {
            throw SMBError.invalidConnection
        }
        return try trimmed.map { try decodePathComponent(String($0)) }
    }

    private static func decodePathComponent(_ raw: String) throws -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.utf8.count)
        let input = Array(raw.utf8)
        var index = 0
        while index < input.count {
            if input[index] == 0x25 {
                guard index + 2 < input.count,
                      let high = hexValue(input[index + 1]),
                      let low = hexValue(input[index + 2]) else {
                    throw SMBError.invalidConnection
                }
                let decoded = (high << 4) | low
                guard decoded >= 0x20,
                      decoded != 0x2E,
                      decoded != 0x2F,
                      decoded != 0x5C,
                      decoded != 0x7F else {
                    throw SMBError.invalidConnection
                }
                bytes.append(decoded)
                index += 3
            } else {
                guard input[index] >= 0x20,
                      input[index] != 0x7F,
                      input[index] != 0x5C else {
                    throw SMBError.invalidConnection
                }
                bytes.append(input[index])
                index += 1
            }
        }
        guard let value = String(bytes: bytes, encoding: .utf8),
              SMBRelativePath.isValidComponent(value) else {
            throw SMBError.invalidConnection
        }
        return value
    }

    private static func validateRawPercentEscapes(_ input: String) throws {
        let bytes = Array(input.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25 {
                guard index + 2 < bytes.count,
                      hexValue(bytes[index + 1]) != nil,
                      hexValue(bytes[index + 2]) != nil else {
                    throw SMBError.invalidConnection
                }
                index += 3
            } else {
                index += 1
            }
        }
    }

    private static func encodedPath(for components: [String]) -> String {
        "/" + components.map(percentEncodeComponent).joined(separator: "/")
    }

    private static func percentEncodeComponent(_ value: String) -> String {
        let allowed = Set("!$&'()*+,-.:;=@_~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
        return value.utf8.map { byte in
            if allowed.contains(byte) {
                return String(decoding: [byte], as: UTF8.self)
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

/// One SMB directory or file returned by a native/SMB browser.
public struct SMBLibraryEntry: Identifiable, Codable, Equatable, Sendable {
    public let name: String
    /// Path relative to the connection's configured base directory.
    public let path: SMBRelativePath
    public let isDirectory: Bool
    public let size: Int64?
    public let modifiedDate: Date?

    public var id: String { path.stableKey }

    public var fileExtension: String? {
        guard !isDirectory,
              let dot = name.lastIndex(of: "."),
              dot < name.index(before: name.endIndex) else {
            return nil
        }
        let suffix = name[name.index(after: dot)...]
        guard !suffix.isEmpty else { return nil }
        return String(suffix).lowercased()
    }

    public var isVideo: Bool {
        !isDirectory && fileExtension.map(Self.videoExtensions.contains) == true
    }

    public static let videoExtensions: Set<String> = [
        "ts", "m2ts", "mts", "mp4", "mkv", "mov", "m4v", "avi", "webm",
        "mpeg", "mpg", "mpe", "mpv", "3gp", "3g2", "wmv", "flv", "asf",
        "vob", "ogv"
    ]

    public init(
        name: String,
        path: SMBRelativePath,
        isDirectory: Bool,
        size: Int64? = nil,
        modifiedDate: Date? = nil
    ) throws {
        guard let last = path.components.last,
              last == name,
              size.map({ $0 >= 0 }) ?? true,
              modifiedDate.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            throw SMBError.invalidEntry
        }
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
    }

    public init(
        name: String,
        parent: SMBRelativePath = .root,
        isDirectory: Bool,
        size: Int64? = nil,
        modifiedDate: Date? = nil
    ) throws {
        try self.init(
            name: name,
            path: parent.child(name),
            isDirectory: isDirectory,
            size: size,
            modifiedDate: modifiedDate
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                name: container.decode(String.self, forKey: .name),
                path: container.decode(SMBRelativePath.self, forKey: .path),
                isDirectory: container.decode(Bool.self, forKey: .isDirectory),
                size: container.decodeIfPresent(Int64.self, forKey: .size),
                modifiedDate: container.decodeIfPresent(Date.self, forKey: .modifiedDate)
            )
        } catch {
            throw SMBError.invalidEntry
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(modifiedDate, forKey: .modifiedDate)
    }

    public func stableKey(for connection: SMBConnection) -> String {
        connection.stableKey(for: path)
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, isDirectory, size, modifiedDate
    }
}

public extension SMBLibraryEntry {
    /// Directory-first natural ordering with a deterministic path tie-breaker.
    static func sorted(_ entries: [SMBLibraryEntry]) -> [SMBLibraryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison = lhs.name.compare(
                rhs.name,
                options: [.numeric, .caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: nil,
                locale: Locale(identifier: "ja_JP")
            )
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.path.stableKey < rhs.path.stableKey
        }
    }

    /// Search names and relative paths locally. Whitespace-separated terms
    /// are ANDed; an empty query returns the normal directory-first order.
    static func search(
        _ query: String,
        in entries: [SMBLibraryEntry]
    ) -> [SMBLibraryEntry] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { normalizeSearchText(String($0)) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return sorted(entries) }
        return sorted(entries.filter { entry in
            let haystack = normalizeSearchText("\(entry.name) \(entry.path.description)")
            return terms.allSatisfy(haystack.contains)
        })
    }

    private static func normalizeSearchText(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }
}

