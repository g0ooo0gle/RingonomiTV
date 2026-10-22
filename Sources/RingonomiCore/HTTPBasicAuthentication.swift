import Foundation

public enum HTTPBasicAuthenticationError: Error, LocalizedError, Equatable, Sendable {
    case invalidCredentials
    case unsupportedEncoding
    case invalidAddress
    case insecureConnection
    case outsideScope
    case conflictingAuthorization

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Basic認証のユーザー名またはパスワードが不正です。"
        case .unsupportedEncoding:
            return "この認証方式では使用できない文字が含まれています。"
        case .invalidAddress:
            return "Basic認証の接続先URLが不正です。"
        case .insecureConnection:
            return "Basic認証にはHTTPS接続を使用してください。"
        case .outsideScope:
            return "設定した接続先の範囲外へ認証情報は送信できません。"
        case .conflictingAuthorization:
            return "別の認証方式が設定された通信にはBasic認証を追加できません。"
        }
    }
}

/// Transient credentials, separate from KonomiTV's account bearer token.
/// Do not put these values in a URL, UserDefaults, or a session-wide header.
public struct HTTPBasicCredential: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public enum CharacterEncoding: Sendable {
        /// The interoperable default when the server has not advertised UTF-8.
        case ascii
        /// Use only after a Basic challenge explicitly advertises UTF-8.
        case utf8
    }

    private let encodedUserPassword: String

    public init(
        username: String,
        password: String,
        encoding: CharacterEncoding = .ascii
    ) throws {
        // A colon in the username would be interpreted as part of the password.
        // Empty passwords are valid; whitespace is significant and not trimmed.
        guard !username.isEmpty, username.utf8.count <= 1024,
              password.utf8.count <= 16 * 1024, !username.contains(":"),
              !Self.containsControl(username), !Self.containsControl(password) else {
            throw HTTPBasicAuthenticationError.invalidCredentials
        }
        let userPassword: String
        switch encoding {
        case .ascii:
            guard username.unicodeScalars.allSatisfy({ $0.isASCII }),
                  password.unicodeScalars.allSatisfy({ $0.isASCII }) else {
                throw HTTPBasicAuthenticationError.unsupportedEncoding
            }
            userPassword = username + ":" + password
        case .utf8:
            // RFC 7617 specifies NFC when a server advertises charset=UTF-8.
            userPassword = username.precomposedStringWithCanonicalMapping + ":"
                + password.precomposedStringWithCanonicalMapping
        }
        encodedUserPassword = Data(userPassword.utf8).base64EncodedString()
    }

    internal var authorizationValue: String { "Basic " + encodedUserPassword }

    public var description: String { "HTTPBasicCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: ["<redacted>"])
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// An explicit credential boundary for both API and media HTTP requests.
///
/// The base path is a directory: `/proxy/` permits `/proxy/api` but not
/// `/proxy2/api`. Unlike a browser address, a trailing `/tv/` is significant.
/// This policy prepares one request; it does not configure AVPlayer or VLC,
/// follow redirects, persist credentials, or implement media authentication.
public struct HTTPBasicAuthenticationScope: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let baseURL: URL

    public init(address: String) throws {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty,
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              Self.isSafePath(components.percentEncodedPath) else {
            throw HTTPBasicAuthenticationError.invalidAddress
        }
        guard scheme == "https" else {
            throw HTTPBasicAuthenticationError.insecureConnection
        }
        components.scheme = scheme
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        components.percentEncodedPath = BackendURLRules.canonicalBasePath(components.percentEncodedPath)
        guard let url = components.url else {
            throw HTTPBasicAuthenticationError.invalidAddress
        }
        baseURL = url
    }

    /// A storage lookup identity without usernames or passwords. It still
    /// contains a private server address and must not be logged or published.
    public var storageIdentity: String { BackendURLRules.accountKey(for: baseURL) }

    public func contains(_ url: URL) -> Bool {
        guard url.baseURL == nil,
              BackendURLRules.sameOrigin(url, baseURL),
              url.user == nil, url.password == nil, url.fragment == nil,
              Self.isSafePath(url.path(percentEncoded: true)) else { return false }
        let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        let root = baseURL.path(percentEncoded: true)
        return path.hasPrefix(root)
    }

    /// Call after building each request, including each playlist, segment,
    /// or key request. Recheck redirects independently; do not let a player
    /// forward this header through an unvalidated redirect.
    public func authorizing(
        _ request: URLRequest,
        credential: HTTPBasicCredential
    ) throws -> URLRequest {
        guard let url = request.url, contains(url) else {
            throw HTTPBasicAuthenticationError.outsideScope
        }
        // Bearer and Basic occupy the same header and cannot be combined.
        // Even an existing Basic header may belong to a different connection.
        guard request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Proxy-Authorization") == nil else {
            throw HTTPBasicAuthenticationError.conflictingAuthorization
        }
        var authorized = request
        authorized.httpShouldHandleCookies = false
        authorized.setValue(nil, forHTTPHeaderField: "Cookie")
        authorized.setValue(credential.authorizationValue, forHTTPHeaderField: "Authorization")
        return authorized
    }

    public var description: String { "HTTPBasicAuthenticationScope(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: ["<redacted>"])
    }

    private static func isSafePath(_ path: String) -> Bool {
        guard !path.contains("//"), BackendURLRules.isSafePercentEncodedPath(path),
              let decoded = path.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        // Reverse proxies can discard path parameters before routing. Reject
        // this ambiguous syntax instead of broadening the configured scope.
        return !decoded.contains(";")
    }
}
