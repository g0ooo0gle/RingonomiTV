import Foundation

/// A bearer token returned by KonomiTV's account endpoint.
///
/// The raw value is intentionally not included in textual descriptions.  The
/// application may persist `rawValue` in its own secure store, but the core
/// client never logs or serializes it implicitly.
public struct BackendAccessToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let token: String
    public let tokenType: String

    public init(rawValue: String) throws {
        try self.init(token: rawValue, tokenType: "bearer")
    }

    public init(token: String, tokenType: String = "bearer") throws {
        guard Self.isValidToken(token), tokenType.caseInsensitiveCompare("bearer") == .orderedSame else {
            throw ConnectionError.invalidToken
        }
        self.token = token
        self.tokenType = "bearer"
    }

    public var rawValue: String { token }

    public var description: String {
        "BackendAccessToken(<redacted>)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: ["<redacted>", tokenType])
    }

    public var authorizationValue: String {
        "Bearer \(token)"
    }

    private static func isValidToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard !bytes.isEmpty, bytes.count <= 16 * 1024 else { return false }
        // Bearer values are deliberately restricted to visible ASCII.  This
        // also rejects whitespace, CR/LF, and non-ASCII values before they can
        // become an HTTP header.
        return bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }
}

public struct BackendUser: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let isAdmin: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, isAdmin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(Int.self, forKey: .id)
        guard id > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "user id must be positive"
            )
        }
        self.id = id
        let name = try container.decode(String.self, forKey: .name)
        guard !name.isEmpty, name.utf8.count <= 256 else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "user name must be 1...256 bytes"
            )
        }
        self.name = name
        self.isAdmin = try container.decode(Bool.self, forKey: .isAdmin)
    }
}

/// URL invariants shared by the client initializer and the authenticated
/// request/redirect policy.  Keeping this logic in Core prevents a URL that
/// is visually similar to the configured server from receiving credentials.
internal enum BackendURLRules {
    static func normalize(_ address: String) throws -> URL {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty,
              let url = URL(string: input),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ConnectionError.invalidAddress
        }
        guard isSafePercentEncodedPath(components.percentEncodedPath) else {
            throw ConnectionError.invalidAddress
        }

        var normalized = components
        normalized.scheme = scheme
        normalized.percentEncodedPath = browserBasePath(components.percentEncodedPath)
        normalized.query = nil
        normalized.fragment = nil
        guard let result = normalized.url else { throw ConnectionError.invalidAddress }
        return result
    }

    static func canonicalBasePath(_ original: String) -> String {
        var path = original
        if path.isEmpty { path = "/" }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty || path == "/" { return "/" }
        if !path.hasPrefix("/") { path = "/" + path }
        return path + "/"
    }

    /// Remove one browser `/tv` suffix from the configured address.  This is
    /// intentionally separate from canonicalization: applying the browser
    /// normalization again to a base URL must not turn `/proxy/tv/tv/` into
    /// `/proxy/`.
    static func browserBasePath(_ original: String) -> String {
        var path = canonicalBasePath(original)
        if path == "/tv/" {
            return "/"
        }
        if path.hasSuffix("/tv/") {
            path.removeLast(4)
            return canonicalBasePath(path)
        }
        return path
    }

    static func isSafeRequestURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return isSafePercentEncodedPath(url.path(percentEncoded: true))
    }

    /// Reject ambiguous path syntax before URLSession can normalize it.  In
    /// particular, encoded separators/dots and encoded percent signs could
    /// become a different path after a proxy performs another decode pass.
    static func isSafePercentEncodedPath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C { return false } // backslash
            if byte == 0x25 { // percent escape
                guard index + 2 < bytes.count,
                      let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2]) else {
                    return false
                }
                let decoded = (high << 4) | low
                if decoded == 0x2E || decoded == 0x2F || decoded == 0x5C || decoded == 0x25 {
                    return false
                }
                index += 3
                continue
            }
            index += 1
        }

        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component == "." || component == ".." { return false }
        }
        return true
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    static func accountKey(for baseURL: URL) -> String {
        let scheme = baseURL.scheme?.lowercased() ?? ""
        let rawHost = baseURL.host?.lowercased() ?? ""
        let host: String
        if rawHost.hasPrefix("[") {
            host = rawHost
        } else if rawHost.contains(":") {
            host = "[\(rawHost)]"
        } else {
            host = rawHost
        }
        let port = effectivePort(for: baseURL)
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let portPart: String
        if let port, port != defaultPort {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }
        let path = canonicalBasePath(baseURL.path(percentEncoded: true))
        return "\(scheme)://\(host)\(portPart)\(path)"
    }

    static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased(),
              effectivePort(for: lhs) == effectivePort(for: rhs) else {
            return false
        }
        return true
    }

    static func isAPIURL(_ url: URL, relativeTo baseURL: URL) -> Bool {
        guard isSafeRequestURL(url), sameOrigin(url, baseURL) else { return false }
        let basePath = canonicalBasePath(baseURL.path(percentEncoded: true))
        let apiRoot = basePath + "api"
        let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        return path == apiRoot || path.hasPrefix(apiRoot + "/")
    }
}

private struct BackendTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
}

private enum BackendRedirectMode {
    case deny
    case api
}

private enum BackendTransportSession {
    static let secureShared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

private final class BackendRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let mode: BackendRedirectMode
    private let authorizationValue: String?
    private let lock = NSLock()
    private var didRejectRedirect = false

    init(baseURL: URL, mode: BackendRedirectMode, authorizationValue: String?) {
        self.baseURL = baseURL
        self.mode = mode
        self.authorizationValue = authorizationValue
    }

    var rejected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRejectRedirect
    }

    private func markRejected() {
        lock.lock()
        didRejectRedirect = true
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard mode == .api,
              let url = request.url,
              BackendURLRules.isAPIURL(url, relativeTo: baseURL) else {
            markRejected()
            completionHandler(nil)
            task.cancel()
            return
        }

        var permittedRequest = request
        permittedRequest.httpShouldHandleCookies = false
        permittedRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        if let authorizationValue {
            permittedRequest.setValue(authorizationValue, forHTTPHeaderField: "Authorization")
        }
        completionHandler(permittedRequest)
    }
}

public extension RingonomiClient {
    /// A stable, credential-free account identity used by the app's secure
    /// persistence layer.  The configured reverse-proxy path is retained.
    var accountKeyString: String {
        BackendURLRules.accountKey(for: baseURL)
    }

    /// Apply the configured bearer token only to this server's `/api` routes.
    /// This internal entry point is intentionally available to `@testable`
    /// tests and to Core extensions, while callers should normally use
    /// `backendData`/`backendBytes`.
    internal func backendAuthorizedRequest(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url else { throw ConnectionError.invalidAddress }
        guard BackendURLRules.isSafeRequestURL(url) else { throw ConnectionError.invalidAddress }
        if let httpBasicScope, let httpBasicCredential {
            return try httpBasicScope.authorizing(request, credential: httpBasicCredential)
        }
        var authorized = request
        // The account API is bearer-token based.  Do not let a caller's
        // session cookie or credential store silently become another auth
        // channel for this request.
        authorized.httpShouldHandleCookies = false
        authorized.setValue(nil, forHTTPHeaderField: "Cookie")
        if let accessToken {
            guard baseURL.scheme?.lowercased() == "https",
                  url.scheme?.lowercased() == "https",
                  BackendURLRules.isAPIURL(url, relativeTo: baseURL) else {
                throw ConnectionError.tokenScopeViolation
            }
            authorized.setValue(accessToken.authorizationValue, forHTTPHeaderField: "Authorization")
        } else {
            authorized.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return authorized
    }

    /// Perform an API request with bounded redirect and credential scope.
    func backendData(
        for request: URLRequest,
        using urlSession: URLSession = .shared
    ) async throws -> (Data, URLResponse) {
        try await performBackendData(request, using: urlSession, redirectMode: .api)
    }

    /// Streaming counterpart to `backendData`.  The response is validated
    /// before the bytes are returned, while the body remains a live stream.
    func backendBytes(
        for request: URLRequest,
        using urlSession: URLSession = .shared
    ) async throws -> (BackendResponseStream, URLResponse) {
        try await performBackendBytes(request, using: urlSession, redirectMode: .api)
    }

    /// Log in through the HTTPS-only account endpoint.  A client that already
    /// contains a token cannot send a password through the same instance.
    func login(
        username: String,
        password: String,
        using urlSession: URLSession = .shared
    ) async throws -> BackendAccessToken {
        guard httpBasicCredential == nil else { throw HTTPBasicAuthenticationError.conflictingAuthorization }
        guard accessToken == nil else { throw ConnectionError.authenticationAlreadyConfigured }
        guard !username.isEmpty,
              username.utf8.count <= 1024,
              !password.isEmpty,
              password.utf8.count <= 16 * 1024 else {
            throw ConnectionError.invalidCredentials
        }
        guard baseURL.scheme?.lowercased() == "https" else {
            throw ConnectionError.insecureAuthentication
        }

        var request = URLRequest(url: endpoint(["api", "users", "token"]))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded([
            ("grant_type", "password"),
            ("username", username),
            ("password", password)
        ])

        let (bytes, response) = try await performBackendBytes(request, using: urlSession, redirectMode: .deny)
        do {
            try Self.validateSuccessResponse(response)
        } catch {
            bytes.cancel()
            throw error
        }
        let data = try await Self.readBounded(bytes, maximumBytes: 64 * 1024)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload: BackendTokenResponse
        do {
            payload = try decoder.decode(BackendTokenResponse.self, from: data)
        } catch {
            throw ConnectionError.invalidResponse
        }
        return try BackendAccessToken(token: payload.accessToken, tokenType: payload.tokenType)
    }

    func currentUser(using urlSession: URLSession = .shared) async throws -> BackendUser {
        guard accessToken != nil else { throw ConnectionError.notAuthenticated }
        var request = URLRequest(url: endpoint(["api", "users", "me"]))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await performBackendBytes(request, using: urlSession, redirectMode: .api)
        do {
            try Self.validateSuccessResponse(response)
        } catch {
            bytes.cancel()
            throw error
        }
        let data = try await Self.readBounded(bytes, maximumBytes: 64 * 1024)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(BackendUser.self, from: data)
        } catch {
            throw ConnectionError.invalidResponse
        }
    }

    private func performBackendData(
        _ request: URLRequest,
        using urlSession: URLSession,
        redirectMode: BackendRedirectMode
    ) async throws -> (Data, URLResponse) {
        if let transport = try basicTransport(using: urlSession) {
            // A full timetable contains more metadata than paginated lists.
            // Keep its allowance separate from playlists and ordinary APIs.
            let isTimetable = request.url?.path == endpoint(["api", "programs", "timetable"]).path
            let maximumBytes = isTimetable ? 32 * 1024 * 1024 : HTTPBasicTransport.maximumDataBytes
            return try await transport.apiData(for: request, maximumBytes: maximumBytes)
        }
        let prepared = try backendAuthorizedRequest(request)
        let delegate = BackendRedirectDelegate(
            baseURL: baseURL,
            mode: redirectMode,
            authorizationValue: accessToken?.authorizationValue
        )
        let session = Self.transportSession(for: urlSession)
        do {
            let (data, response) = try await session.data(for: prepared, delegate: delegate)
            if delegate.rejected { throw ConnectionError.redirectRejected }
            try Self.validateHTTPResponseType(response)
            return (data, response)
        } catch let error as ConnectionError {
            throw error
        } catch {
            if delegate.rejected { throw ConnectionError.redirectRejected }
            throw error
        }
    }

    private func performBackendBytes(
        _ request: URLRequest,
        using urlSession: URLSession,
        redirectMode: BackendRedirectMode
    ) async throws -> (BackendResponseStream, URLResponse) {
        if let transport = try basicTransport(using: urlSession) {
            let bytes = try await transport.apiBytes(for: request)
            return (BackendResponseStream(bytes), bytes.response)
        }
        let prepared = try backendAuthorizedRequest(request)
        let delegate = BackendRedirectDelegate(
            baseURL: baseURL,
            mode: redirectMode,
            authorizationValue: accessToken?.authorizationValue
        )
        let session = Self.transportSession(for: urlSession)
        do {
            let (bytes, response) = try await session.bytes(for: prepared, delegate: delegate)
            if delegate.rejected {
                bytes.task.cancel()
                throw ConnectionError.redirectRejected
            }
            guard response is HTTPURLResponse else {
                bytes.task.cancel()
                throw ConnectionError.http(0)
            }
            return (BackendResponseStream(bytes), response)
        } catch let error as ConnectionError {
            throw error
        } catch {
            if delegate.rejected { throw ConnectionError.redirectRejected }
            throw error
        }
    }

    private static func transportSession(for supplied: URLSession) -> URLSession {
        // Keep injected sessions intact so URLProtocol-based tests and host
        // applications retain their configuration.  The default shared
        // session is replaced with a reused credential-free session.
        guard supplied === URLSession.shared else { return supplied }
        return BackendTransportSession.secureShared
    }

    private static func validateHTTPResponseType(_ response: URLResponse) throws {
        guard response is HTTPURLResponse else { throw ConnectionError.http(0) }
    }

    internal static func validateSuccessResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.http(0) }
        guard (200..<300).contains(http.statusCode) else {
            throw ConnectionError.http(http.statusCode)
        }
    }

    private static func readBounded(
        _ bytes: BackendResponseStream,
        maximumBytes: Int
    ) async throws -> Data {
        defer { bytes.cancel() }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 16 * 1024))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw ConnectionError.invalidResponse }
            data.append(byte)
        }
        return data
    }

    private static func formEncoded(_ fields: [(String, String)]) -> Data {
        let body = fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func formEncode(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x20:
                result.append("+")
            case 0x2D, 0x2E, 0x30...0x39, 0x41...0x5A, 0x5F, 0x61...0x7A, 0x7E:
                result.unicodeScalars.append(UnicodeScalar(byte))
            default:
                result.append("%")
                result.unicodeScalars.append(UnicodeScalar(hex[Int(byte >> 4)]))
                result.unicodeScalars.append(UnicodeScalar(hex[Int(byte & 0x0F)]))
            }
        }
        return result
    }
}
