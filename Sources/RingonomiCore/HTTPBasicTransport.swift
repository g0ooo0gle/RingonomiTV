import Foundation

public enum HTTPBasicTransportError: Error, LocalizedError, Equatable, Sendable {
    case authenticationRequired
    case redirectRejected
    case invalidResponse
    case unsupportedConfiguration
    case invalidLimit
    case invalidTimeout
    case timedOut
    case responseTooLarge
    case httpStatus(Int)
    case transport

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "接続先の認証を確認してください。自動再送は行いません。"
        case .redirectRejected:
            return "認証付き通信のリダイレクトは許可されていません。"
        case .invalidResponse:
            return "接続先の応答形式が不正です。"
        case .unsupportedConfiguration:
            return "認証付き通信にバックグラウンドセッションは使用できません。"
        case .invalidLimit:
            return "応答サイズの上限が不正です。"
        case .invalidTimeout:
            return "応答の待ち時間が不正です。"
        case .timedOut:
            return "接続先の応答が時間内に完了しませんでした。自動再送は行いません。"
        case .responseTooLarge:
            return "接続先の応答が大きすぎます。"
        case .httpStatus(let status):
            return "接続先への通信に失敗しました（HTTP \(status)）。"
        case .transport:
            return "認証付きの接続に失敗しました。"
        }
    }
}

/// A per-connection transport for API data and a future media relay.
///
/// Each instance owns an isolated session. Credentials are applied to one
/// validated request, never to shared session settings or URLCredentialStorage.
/// No request, including a mutation, is replayed on a 401 or redirect.
/// AVPlayer and VLC do not use this transport automatically.
public final class HTTPBasicTransport: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public static let maximumDataBytes = 4 * 1024 * 1024
    private let scope: HTTPBasicAuthenticationScope
    private let credential: HTTPBasicCredential
    private let session: URLSession
    private let cancellation = HTTPBasicCancellationState()

    public init(
        scope: HTTPBasicAuthenticationScope,
        credential: HTTPBasicCredential,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard sessionConfiguration?.identifier == nil else {
            // Background sessions follow redirects without the task delegate.
            throw HTTPBasicTransportError.unsupportedConfiguration
        }
        self.scope = scope
        self.credential = credential
        let configuration = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        if var headers = configuration.httpAdditionalHeaders {
            for key in Array(headers.keys) {
                guard let name = key as? String else { continue }
                if ["Authorization", "Proxy-Authorization", "Cookie"].contains(where: {
                    name.caseInsensitiveCompare($0) == .orderedSame
                }) {
                    headers.removeValue(forKey: key)
                }
            }
            configuration.httpAdditionalHeaders = headers
        }
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    fileprivate var isInvalidated: Bool { cancellation.isCancelled }

    /// Cancels all outstanding work when this connection is replaced or its
    /// credentials are removed. The caller must create a fresh transport.
    public func invalidate() {
        cancellation.cancel()
        session.invalidateAndCancel()
    }

    /// The stream retains this connection until reading ends. Cancel it when
    /// playback stops, a generation changes, or the body is no longer needed.
    public func bytes(for request: URLRequest) async throws -> HTTPBasicResponseStream {
        try Task.checkCancellation()
        if isInvalidated { throw CancellationError() }
        var authorized = try scope.authorizing(request, credential: credential)
        authorized.cachePolicy = .reloadIgnoringLocalCacheData
        authorized.timeoutInterval = 20
        let delegate = HTTPBasicTaskDelegate()
        do {
            let (bytes, response) = try await session.bytes(for: authorized, delegate: delegate)
            do {
                try Task.checkCancellation()
                if isInvalidated { throw CancellationError() }
                if delegate.rejectedRedirect { throw HTTPBasicTransportError.redirectRejected }
                if delegate.rejectedAuthentication { throw HTTPBasicTransportError.authenticationRequired }
                guard let http = response as? HTTPURLResponse else {
                    throw HTTPBasicTransportError.invalidResponse
                }
                guard http.url == authorized.url, let url = http.url, scope.contains(url) else {
                    throw HTTPBasicTransportError.redirectRejected
                }
                if (300..<400).contains(http.statusCode) {
                    throw HTTPBasicTransportError.redirectRejected
                }
                if http.statusCode == 401 || http.statusCode == 407 {
                    throw HTTPBasicTransportError.authenticationRequired
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw HTTPBasicTransportError.httpStatus(http.statusCode)
                }
                return HTTPBasicResponseStream(bytes: bytes, response: http, owner: self)
            } catch {
                bytes.task.cancel()
                throw error
            }
        } catch let error as HTTPBasicTransportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || isInvalidated { throw CancellationError() }
            if delegate.rejectedRedirect { throw HTTPBasicTransportError.redirectRejected }
            if delegate.rejectedAuthentication { throw HTTPBasicTransportError.authenticationRequired }
            // URLError may contain a private URL. Keep it out of UI/log errors.
            throw HTTPBasicTransportError.transport
        }
    }

    /// API/playlist reads have a total deadline in addition to the stream's
    /// inactivity timeout. Continuous live bodies use bytes(for:) instead.
    public func data(
        for request: URLRequest,
        maximumBytes: Int = HTTPBasicTransport.maximumDataBytes,
        maximumDuration: Duration = .seconds(30)
    ) async throws -> (Data, HTTPURLResponse) {
        guard (1...Self.maximumDataBytes).contains(maximumBytes) else {
            throw HTTPBasicTransportError.invalidLimit
        }
        guard maximumDuration > .zero, maximumDuration <= .seconds(120) else {
            throw HTTPBasicTransportError.invalidTimeout
        }
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await self.readData(for: request, maximumBytes: maximumBytes) }
            group.addTask {
                try await Task.sleep(for: maximumDuration)
                throw HTTPBasicTransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func readData(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let stream = try await bytes(for: request)
        let response = stream.response
        defer { stream.cancel() }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw HTTPBasicTransportError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 32 * 1024))
        do {
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < maximumBytes else {
                    throw HTTPBasicTransportError.responseTooLarge
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            if isInvalidated { throw CancellationError() }
            return (data, response)
        } catch let error as HTTPBasicTransportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || isInvalidated { throw CancellationError() }
            throw HTTPBasicTransportError.transport
        }
    }

    public var description: String { "HTTPBasicTransport(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, unlabeledChildren: ["<redacted>"])
    }
}

/// A single-consumer response body that retains its owning connection and
/// sanitizes errors raised after the response headers have been received.
public final class HTTPBasicResponseStream: Sendable, AsyncSequence,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public typealias Element = UInt8
    public let response: HTTPURLResponse
    private let bytes: URLSession.AsyncBytes
    private let owner: HTTPBasicTransport
    private let cancellation = HTTPBasicCancellationState()

    private var isCancelled: Bool { cancellation.isCancelled || owner.isInvalidated }

    fileprivate init(bytes: URLSession.AsyncBytes, response: HTTPURLResponse, owner: HTTPBasicTransport) {
        self.bytes = bytes
        self.response = response
        self.owner = owner
    }

    deinit { bytes.task.cancel() }
    public func cancel() {
        cancellation.cancel()
        bytes.task.cancel()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: bytes.makeAsyncIterator(), stream: self)
    }

    public struct AsyncIterator: AsyncIteratorProtocol, CustomStringConvertible,
        CustomDebugStringConvertible, CustomReflectable {
        fileprivate var base: URLSession.AsyncBytes.AsyncIterator
        fileprivate let stream: HTTPBasicResponseStream

        public mutating func next() async throws -> UInt8? {
            // Keep stream -> owner -> session alive across every suspension.
            defer { withExtendedLifetime(stream) {} }
            do {
                try Task.checkCancellation()
                if stream.isCancelled { throw CancellationError() }
                return try await base.next()
            } catch is CancellationError {
                stream.cancel()
                throw CancellationError()
            } catch {
                let wasCancelled = Task.isCancelled || stream.isCancelled
                stream.cancel()
                if wasCancelled { throw CancellationError() }
                throw HTTPBasicTransportError.transport
            }
        }

        public var description: String { "HTTPBasicResponseStream.AsyncIterator(<redacted>)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, unlabeledChildren: ["<redacted>"]) }
    }

    public var description: String { "HTTPBasicResponseStream(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: ["<redacted>"]) }
}

private final class HTTPBasicCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class HTTPBasicTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirect = false
    private var authentication = false

    var rejectedRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return redirect
    }

    var rejectedAuthentication: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authentication
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirect = true
        lock.unlock()
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            // Preserve platform TLS validation. Never install a trust bypass.
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Credentials were already applied explicitly. Do not answer a
            // challenge with cached, proposed, proxy, or alternate credentials.
            lock.lock()
            authentication = true
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
