import CryptoKit
import Foundation

/// Generation-scoped opaque URLs for a loopback media relay.
///
/// Authenticated encryption keeps upstream addresses and query values out of
/// player URLs. A bounded cache reuses recent URLs, while older routes remain
/// decodable without retaining an unbounded live-segment registry. Destroying
/// the generation's key invalidates every route, including cache evictions.
public final class HTTPMediaRelayRoutes: @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let baseURL: URL
    private let scope: HTTPBasicAuthenticationScope
    private let lock = NSLock()
    private var key: SymmetricKey? = SymmetricKey(size: .bits256)
    private let authenticatedData: Data
    private static let cacheCapacity = 512
    private var cache: [HLSRelayReferenceKey: URL] = [:]
    private var ring: [HLSRelayReferenceKey?] = Array(repeating: nil, count: cacheCapacity)
    private var nextSlot = 0

    private struct HLSRelayReferenceKey: Hashable {
        let url: URL
        let kind: HTTPMediaResourceKind
    }
    private struct Payload: Codable {
        let version: Int
        let address: String
        let kind: HTTPMediaResourceKind
    }

    public init(loopbackOrigin: URL, scope: HTTPBasicAuthenticationScope) throws {
        guard loopbackOrigin.baseURL == nil,
              loopbackOrigin.scheme == "http", loopbackOrigin.host == "127.0.0.1",
              let port = loopbackOrigin.port, (1...65535).contains(port),
              loopbackOrigin.user == nil, loopbackOrigin.password == nil,
              loopbackOrigin.query == nil, loopbackOrigin.fragment == nil,
              loopbackOrigin.path.isEmpty || loopbackOrigin.path == "/" else {
            throw HLSRelayError.invalidRoute
        }
        self.scope = scope
        let generation = UUID().uuidString.lowercased()
        baseURL = loopbackOrigin.appendingPathComponent("media/" + generation + "/", isDirectory: true)
        authenticatedData = Data(("ringonomi.media.route.v1:" + baseURL.absoluteString).utf8)
    }

    public func localURL(for url: URL, kind: HTTPMediaResourceKind) throws -> URL {
        guard scope.contains(url), url.absoluteString.utf8.count <= 8192 else {
            throw HTTPBasicAuthenticationError.outsideScope
        }
        lock.lock()
        defer { lock.unlock() }
        guard let key else { throw HLSRelayError.stopped }
        let identity = HLSRelayReferenceKey(url: url, kind: kind)
        if let existing = cache[identity] { return existing }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let payload = try encoder.encode(Payload(version: 1, address: url.absoluteString, kind: kind))
            let box = try AES.GCM.seal(payload, using: key, authenticating: authenticatedData)
            guard let combined = box.combined else { throw HLSRelayError.invalidRoute }
            data = combined
        } catch { throw HLSRelayError.invalidRoute }
        let token = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let suffix = kind == .playlist ? ".m3u8" : ".bin"
        let result = baseURL.appendingPathComponent(token + suffix)
        if let expired = ring[nextSlot] { cache.removeValue(forKey: expired) }
        ring[nextSlot] = identity
        nextSlot = (nextSlot + 1) % Self.cacheCapacity
        cache[identity] = result
        return result
    }

    /// Resolve only routes minted for this relay generation. The sole query
    /// extension is the HLS player's bounded blocking-reload parameters.
    public func resolve(_ localURL: URL) throws -> HLSRelayReference {
        guard localURL.baseURL == nil, BackendURLRules.sameOrigin(localURL, baseURL),
              localURL.user == nil, localURL.password == nil, localURL.fragment == nil,
              localURL.path(percentEncoded: true).hasPrefix(baseURL.path(percentEncoded: true)) else {
            throw HLSRelayError.invalidRoute
        }
        let name = String(localURL.path(percentEncoded: true).dropFirst(baseURL.path(percentEncoded: true).count))
        let suffix: String
        if name.hasSuffix(".m3u8") { suffix = ".m3u8" }
        else if name.hasSuffix(".bin") { suffix = ".bin" }
        else { throw HLSRelayError.invalidRoute }
        let token = String(name.dropLast(suffix.count))
        guard !token.isEmpty, token.utf8.count <= 16 * 1024,
              token.utf8.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) ||
                  (0x30...0x39).contains($0) || $0 == 0x2D || $0 == 0x5F }) else {
            throw HLSRelayError.invalidRoute
        }
        var encoded = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded) else { throw HLSRelayError.invalidRoute }
        lock.lock()
        defer { lock.unlock() }
        guard let key else { throw HLSRelayError.stopped }
        let payload: Payload
        do {
            let box = try AES.GCM.SealedBox(combined: bytes)
            let data = try AES.GCM.open(box, using: key, authenticating: authenticatedData)
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch { throw HLSRelayError.invalidRoute }
        guard payload.version == 1, let upstream = URL(string: payload.address),
              scope.contains(upstream), (payload.kind == .playlist) == (suffix == ".m3u8") else {
            throw HLSRelayError.invalidRoute
        }
        let result = try addingReloadQuery(from: localURL, to: upstream, kind: payload.kind)
        guard scope.contains(result) else { throw HLSRelayError.invalidRoute }
        return HLSRelayReference(url: result, kind: payload.kind)
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        key = nil
        cache.removeAll()
        ring.removeAll()
    }

    private func addingReloadQuery(from local: URL, to upstream: URL, kind: HTTPMediaResourceKind) throws -> URL {
        guard let query = URLComponents(url: local, resolvingAgainstBaseURL: false)?.queryItems else { return upstream }
        guard kind == .playlist, !query.isEmpty, query.count <= 3 else { throw HLSRelayError.invalidRoute }
        var names: Set<String> = []
        for item in query {
            guard names.insert(item.name).inserted, let value = item.value else { throw HLSRelayError.invalidRoute }
            if item.name == "_HLS_msn" || item.name == "_HLS_part" {
                guard !value.isEmpty, value.utf8.count <= 19,
                      value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), Int64(value) != nil else {
                    throw HLSRelayError.invalidRoute
                }
            } else if item.name == "_HLS_skip" {
                guard value == "YES" || value == "v2" else { throw HLSRelayError.invalidRoute }
            } else { throw HLSRelayError.invalidRoute }
        }
        var result = URLComponents(url: upstream, resolvingAgainstBaseURL: false)!
        var items = (result.queryItems ?? []).filter { !names.contains($0.name) }
        items.append(contentsOf: query)
        result.queryItems = items
        guard let url = result.url else { throw HLSRelayError.invalidRoute }
        return url
    }

    public var description: String { "HTTPMediaRelayRoutes(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: ["<redacted>"]) }
}
