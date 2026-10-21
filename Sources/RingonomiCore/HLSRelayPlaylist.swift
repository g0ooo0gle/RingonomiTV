import Foundation

public enum HLSRelayError: Error, LocalizedError, Equatable, Sendable {
    case invalidPlaylist
    case unsupportedPlaylist
    case playlistTooLarge
    case invalidRoute
    case stopped

    public var errorDescription: String? {
        switch self {
        case .invalidPlaylist: return "再生用プレイリストの形式が不正です。"
        case .unsupportedPlaylist: return "このプレイリストの拡張形式には認証付き再生が対応していません。"
        case .playlistTooLarge: return "再生用プレイリストが大きすぎます。"
        case .invalidRoute: return "再生用の接続先を確認できません。"
        case .stopped: return "再生用の接続は終了しています。"
        }
    }
}

public enum HTTPMediaResourceKind: UInt8, Sendable, Codable, Hashable {
    case playlist = 1
    case media = 2
}

public struct HLSRelayReference: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    public let kind: HTTPMediaResourceKind

    public var description: String { "HLSRelayReference(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: ["<redacted>"]) }
}

/// Parses the entire document before creating any relay URLs. Every URI is
/// resolved against this playlist, including child playlists and key/map URIs.
/// Steering, variables, and resource-bearing metadata need deeper protocols
/// and are rejected instead of leaving an unvalidated URL in player input.
public struct HLSRelayPlaylist: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public static let maximumInputBytes = 4 * 1024 * 1024
    public static let maximumOutputBytes = 8 * 1024 * 1024
    public static let maximumReferences = 20_000
    public let references: [HLSRelayReference]
    private let pieces: [Piece]

    private enum Piece: Sendable {
        case text(String)
        case reference(Int)
    }

    private struct Attribute {
        let name: String
        let value: String
        let quoted: Bool
        var rendered: String { name + "=" + (quoted ? "\"" + value + "\"" : value) }
    }

    private static let uriTags: [String: HTTPMediaResourceKind] = [
        "EXT-X-KEY": .media, "EXT-X-SESSION-KEY": .media, "EXT-X-MAP": .media,
        "EXT-X-MEDIA": .playlist, "EXT-X-I-FRAME-STREAM-INF": .playlist,
        "EXT-X-IMAGE-STREAM-INF": .playlist, "EXT-X-PART": .media,
        "EXT-X-PRELOAD-HINT": .media, "EXT-X-RENDITION-REPORT": .playlist
    ]
    private static let attributeTags: Set<String> = [
        "EXT-X-STREAM-INF", "EXT-X-START", "EXT-X-DATERANGE", "EXT-X-SESSION-DATA",
        "EXT-X-SERVER-CONTROL", "EXT-X-PART-INF", "EXT-X-SKIP", "EXT-X-TILES"
    ]
    private static let scalarTags: Set<String> = [
        "EXTINF", "EXT-X-VERSION", "EXT-X-TARGETDURATION", "EXT-X-MEDIA-SEQUENCE",
        "EXT-X-DISCONTINUITY-SEQUENCE", "EXT-X-ENDLIST", "EXT-X-PLAYLIST-TYPE",
        "EXT-X-I-FRAMES-ONLY", "EXT-X-INDEPENDENT-SEGMENTS", "EXT-X-DISCONTINUITY",
        "EXT-X-PROGRAM-DATE-TIME", "EXT-X-BYTERANGE", "EXT-X-GAP", "EXT-X-BITRATE",
        "EXT-X-IMAGES-ONLY"
    ]

    public init(data: Data, sourceURL: URL, scope: HTTPBasicAuthenticationScope) throws {
        guard data.count <= Self.maximumInputBytes else { throw HLSRelayError.playlistTooLarge }
        guard sourceURL.absoluteString.utf8.count <= 8192 else { throw HLSRelayError.playlistTooLarge }
        guard scope.contains(sourceURL) else { throw HTTPBasicAuthenticationError.outsideScope }
        guard let original = String(data: data, encoding: .utf8),
              !original.hasPrefix("\u{FEFF}"),
              original == original.precomposedStringWithCanonicalMapping else {
            throw HLSRelayError.invalidPlaylist
        }
        let text = original.replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.unicodeScalars.contains(where: {
            ($0.value < 0x20 && $0.value != 0x0A) || (0x7F...0x9F).contains($0.value)
        }) else { throw HLSRelayError.invalidPlaylist }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "#EXTM3U" else { throw HLSRelayError.invalidPlaylist }
        var pieces: [Piece] = [.text("#EXTM3U\n")]
        var references: [HLSRelayReference] = []
        var nextURIIsPlaylist = false
        var resolvedURIBytes = 0

        func appendReference(_ value: String, kind: HTTPMediaResourceKind) throws {
            guard references.count < Self.maximumReferences else { throw HLSRelayError.playlistTooLarge }
            let url = try Self.resolve(value, against: sourceURL, scope: scope)
            let count = url.absoluteString.utf8.count
            guard count <= Self.maximumInputBytes - resolvedURIBytes else { throw HLSRelayError.playlistTooLarge }
            resolvedURIBytes += count
            pieces.append(.reference(references.count))
            references.append(HLSRelayReference(url: url, kind: kind))
        }

        for line in lines.dropFirst() {
            guard line.utf8.count <= 16 * 1024 else { throw HLSRelayError.playlistTooLarge }
            if line.isEmpty { pieces.append(.text("\n")); continue }
            guard line != "#EXTM3U" else { throw HLSRelayError.invalidPlaylist }
            if !line.hasPrefix("#") {
                try appendReference(line, kind: nextURIIsPlaylist ? .playlist : .media)
                nextURIIsPlaylist = false
                pieces.append(.text("\n"))
                continue
            }
            if !line.hasPrefix("#EXT") { pieces.append(.text(line + "\n")); continue }
            let pair = line.dropFirst().split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let tag = String(pair[0])
            let payload = pair.count == 2 ? String(pair[1]) : nil
            if tag == "EXT-X-DEFINE" || tag == "EXT-X-CONTENT-STEERING" {
                throw HLSRelayError.unsupportedPlaylist
            }
            if let kind = Self.uriTags[tag] {
                guard let payload else { throw HLSRelayError.invalidPlaylist }
                let attributes = try Self.attributes(payload)
                let uri = attributes.first { $0.name == "URI" }
                // MEDIA with in-band captions/audio and KEY METHOD=NONE may
                // omit URI; all other resource tags require one.
                if uri == nil {
                    guard tag == "EXT-X-MEDIA" ||
                            (tag == "EXT-X-KEY" && attributes.contains(where: { $0.name == "METHOD" && $0.value == "NONE" })) else {
                        throw HLSRelayError.invalidPlaylist
                    }
                }
                pieces.append(.text("#" + tag + ":"))
                for (index, attribute) in attributes.enumerated() {
                    if index > 0 { pieces.append(.text(",")) }
                    if attribute.name == "URI" {
                        guard attribute.quoted else { throw HLSRelayError.invalidPlaylist }
                        pieces.append(.text("URI=\""))
                        try appendReference(attribute.value, kind: kind)
                        pieces.append(.text("\""))
                    } else {
                        guard !Self.isResourceAttribute(attribute.name) else { throw HLSRelayError.unsupportedPlaylist }
                        pieces.append(.text(attribute.rendered))
                    }
                }
                pieces.append(.text("\n"))
            } else if Self.attributeTags.contains(tag) {
                guard let payload else { throw HLSRelayError.invalidPlaylist }
                let attributes = try Self.attributes(payload)
                guard !attributes.contains(where: { Self.isResourceAttribute($0.name) }) else {
                    throw HLSRelayError.unsupportedPlaylist
                }
                if tag == "EXT-X-STREAM-INF" {
                    guard !nextURIIsPlaylist else { throw HLSRelayError.invalidPlaylist }
                    nextURIIsPlaylist = true
                }
                pieces.append(.text("#" + tag + ":" + attributes.map(\.rendered).joined(separator: ",") + "\n"))
            } else if Self.scalarTags.contains(tag) {
                pieces.append(.text(line + "\n"))
            } else {
                // Unknown tags may gain URI semantics in a future player.
                // Retain plain comments, but do not guess an extension grammar.
                throw HLSRelayError.unsupportedPlaylist
            }
        }
        guard !nextURIIsPlaylist else { throw HLSRelayError.invalidPlaylist }
        self.references = references
        self.pieces = pieces
    }

    public func rewritten(using routes: HTTPMediaRelayRoutes) throws -> Data {
        // The complete document is validated before any bytes are returned.
        var result = Data()
        for piece in pieces {
            let text: String
            switch piece {
            case .text(let value): text = value
            case .reference(let index):
                let reference = references[index]
                text = try routes.localURL(for: reference.url, kind: reference.kind).absoluteString
            }
            guard text.utf8.count <= Self.maximumOutputBytes - result.count else {
                throw HLSRelayError.playlistTooLarge
            }
            result.append(contentsOf: text.utf8)
        }
        return result
    }

    private static func isResourceAttribute(_ name: String) -> Bool {
        name == "URI" || name.hasSuffix("-URI") || name.hasSuffix("-URL") || name == "X-ASSET-LIST"
    }

    private static func resolve(_ value: String, against source: URL, scope: HTTPBasicAuthenticationScope) throws -> URL {
        guard !value.isEmpty, value.utf8.count <= 8192,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("\\"), !value.contains("{$"),
              let raw = URLComponents(string: value),
              raw.user == nil, raw.password == nil, raw.fragment == nil else {
            throw HLSRelayError.invalidPlaylist
        }
        // Literal parent components are normal in HLS. Reject ambiguous
        // encodings before resolving those components against the source.
        let checkedPath = raw.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .map { ($0 == "." || $0 == "..") ? "_" : String($0) }.joined(separator: "/")
        guard BackendURLRules.isSafePercentEncodedPath(checkedPath),
              let relative = URL(string: value, relativeTo: source) else {
            throw HLSRelayError.invalidPlaylist
        }
        let url = relative.absoluteURL.standardized
        guard scope.contains(url) else { throw HTTPBasicAuthenticationError.outsideScope }
        return url
    }

    private static func attributes(_ text: String) throws -> [Attribute] {
        let bytes = Array(text.utf8)
        var index = 0
        var result: [Attribute] = []
        var names: Set<String> = []
        while index < bytes.count {
            while index < bytes.count && bytes[index] == 0x20 { index += 1 }
            let start = index
            while index < bytes.count && ((0x41...0x5A).contains(bytes[index]) ||
                (0x30...0x39).contains(bytes[index]) || bytes[index] == 0x2D) { index += 1 }
            guard index > start, index < bytes.count, bytes[index] == 0x3D else { throw HLSRelayError.invalidPlaylist }
            let name = String(decoding: bytes[start..<index], as: UTF8.self)
            guard names.insert(name).inserted else { throw HLSRelayError.invalidPlaylist }
            index += 1
            let quoted = index < bytes.count && bytes[index] == 0x22
            if quoted { index += 1 }
            let valueStart = index
            if quoted {
                while index < bytes.count && bytes[index] != 0x22 {
                    guard bytes[index] != 0x5C else { throw HLSRelayError.invalidPlaylist }
                    index += 1
                }
                guard index < bytes.count else { throw HLSRelayError.invalidPlaylist }
            } else {
                while index < bytes.count && bytes[index] != 0x2C { index += 1 }
                guard index > valueStart else { throw HLSRelayError.invalidPlaylist }
            }
            let value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
            if !quoted {
                guard !value.contains("\""), !value.contains(" "), !value.contains("\\") else { throw HLSRelayError.invalidPlaylist }
            }
            result.append(Attribute(name: name, value: value, quoted: quoted))
            if quoted { index += 1 }
            while index < bytes.count && bytes[index] == 0x20 { index += 1 }
            if index == bytes.count { break }
            guard bytes[index] == 0x2C, index + 1 < bytes.count else { throw HLSRelayError.invalidPlaylist }
            index += 1
        }
        guard !result.isEmpty else { throw HLSRelayError.invalidPlaylist }
        return result
    }

    public var description: String { "HLSRelayPlaylist(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: ["<redacted>"]) }
}
