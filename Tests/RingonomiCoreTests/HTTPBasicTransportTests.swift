import Foundation
import XCTest
@testable import RingonomiCore

private final class HTTPBasicTransportURLProtocol: URLProtocol, URLAuthenticationChallengeSender, @unchecked Sendable {
    struct Stub {
        var status = 200
        var body = Data("fixture-response".utf8)
        var headers: [String: String] = [:]
        var redirect: URL?
        var responseURL: URL?
        var error: Error?
        var challengeMethod: String?
        var deferredBodyFailure = false
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((URLRequest) -> Stub)?
        private var requests: [URLRequest] = []
        private var authenticationActions: [String] = []
        private var pendingFailure: (() -> Void)?

        func reset(_ handler: ((URLRequest) -> Stub)? = nil) {
            lock.lock()
            defer { lock.unlock() }
            self.handler = handler
            requests = []
            authenticationActions = []
            pendingFailure = nil
        }

        func response(for request: URLRequest) -> Stub {
            lock.lock()
            requests.append(request)
            let handler = self.handler
            lock.unlock()
            return handler?(request) ?? Stub()
        }

        func recordAuthentication(_ action: String) {
            lock.lock()
            defer { lock.unlock() }
            authenticationActions.append(action)
        }

        func authenticationSnapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return authenticationActions
        }

        func deferFailure(_ body: @escaping () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            pendingFailure = body
        }

        var hasPendingFailure: Bool {
            lock.lock()
            defer { lock.unlock() }
            return pendingFailure != nil
        }

        func failPendingBody() {
            lock.lock()
            let body = pendingFailure
            pendingFailure = nil
            lock.unlock()
            body?()
        }

        func snapshot() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private static let state = State()
    static func reset(_ handler: ((URLRequest) -> Stub)? = nil) { state.reset(handler) }
    static var requests: [URLRequest] { state.snapshot() }
    static var authenticationActions: [String] { state.authenticationSnapshot() }
    static func failPendingBody() { state.failPendingBody() }
    static var hasPendingFailure: Bool { state.hasPendingFailure }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.state.response(for: request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let method = stub.challengeMethod {
            let url = request.url!
            let space = URLProtectionSpace(host: url.host!, port: url.port ?? 443,
                                           protocol: url.scheme, realm: "fixture", authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(
                protectionSpace: space,
                proposedCredential: URLCredential(user: "unrelated-fixture", password: "unrelated-fixture", persistence: .none),
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: self
            )
            client?.urlProtocol(self, didReceive: challenge)
            return
        }
        var headers = stub.headers
        if let target = stub.redirect { headers["Location"] = target.absoluteString }
        let response = HTTPURLResponse(url: stub.responseURL ?? request.url!, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        if let target = stub.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if stub.deferredBodyFailure {
            Self.state.deferFailure { [self] in
                let error = URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: request.url!])
                client?.urlProtocol(self, didFailWithError: error)
            }
            client?.urlProtocol(self, didLoad: Data("prefix".utf8))
            return
        }
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func finishChallenge(_ action: String) {
        Self.state.recordAuthentication(action)
        client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { finishChallenge("use") }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { finishChallenge("continue") }
    func cancel(_ challenge: URLAuthenticationChallenge) { finishChallenge("cancel") }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { finishChallenge("default") }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { finishChallenge("reject") }
}

final class HTTPBasicTransportTests: XCTestCase, @unchecked Sendable {
    override func tearDown() {
        HTTPBasicTransportURLProtocol.reset()
        super.tearDown()
    }

    private func transport(headers: [String: String] = [:]) throws -> HTTPBasicTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPBasicTransportURLProtocol.self]
        configuration.httpAdditionalHeaders = headers
        return try HTTPBasicTransport(
            scope: try HTTPBasicAuthenticationScope(address: "https://example.test/proxy/"),
            credential: try HTTPBasicCredential(username: "fixture-user", password: "fixture-password"),
            sessionConfiguration: configuration
        )
    }

    private func request(_ address: String = "https://example.test/proxy/api/videos") -> URLRequest {
        URLRequest(url: URL(string: address)!)
    }

    func testSuccessfulRequestAndRangeStreaming() async throws {
        HTTPBasicTransportURLProtocol.reset { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ=")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return .init(status: 206, body: Data("segment".utf8), headers: ["Content-Range": "bytes 0-6/7"])
        }
        let client = try transport()
        var source = request("https://example.test/proxy/hls/segment.ts")
        source.setValue("bytes=0-6", forHTTPHeaderField: "Range")
        let stream = try await client.bytes(for: source)
        defer { stream.cancel() }
        var body = Data()
        for try await byte in stream { body.append(byte) }
        XCTAssertEqual(stream.response.statusCode, 206)
        XCTAssertEqual(body, Data("segment".utf8))
        XCTAssertEqual(HTTPBasicTransportURLProtocol.requests.count, 1)
        XCTAssertEqual(HTTPBasicTransportURLProtocol.requests[0].value(forHTTPHeaderField: "Range"), "bytes=0-6")
    }

    func testSessionWideCredentialsAndCookiesCannotReplaceScopedBasic() async throws {
        HTTPBasicTransportURLProtocol.reset { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ=")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Proxy-Authorization"))
            return .init()
        }
        let client = try transport(headers: ["authorization": "Bearer unrelated", "COOKIE": "session=unrelated",
                                             "proxy-authorization": "Basic unrelated"])
        _ = try await client.data(for: request())
        XCTAssertEqual(HTTPBasicTransportURLProtocol.requests.count, 1)
    }

    func testOutOfScopeResourcesNeverReachNetwork() async throws {
        HTTPBasicTransportURLProtocol.reset()
        let client = try transport()
        for address in ["https://other.test/proxy/hls/key.bin", "https://example.test:444/proxy/api/videos",
                        "http://example.test/proxy/hls/playlist.m3u8", "https://example.test/proxy2/api/videos"] {
            do {
                _ = try await client.data(for: request(address))
                XCTFail("Expected scope rejection")
            } catch {
                XCTAssertEqual(error as? HTTPBasicAuthenticationError, .outsideScope)
            }
        }
        XCTAssertTrue(HTTPBasicTransportURLProtocol.requests.isEmpty)
    }

    func testBearerConflictNeverReachesNetwork() async throws {
        HTTPBasicTransportURLProtocol.reset()
        let client = try transport()
        var source = request()
        source.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        do {
            _ = try await client.data(for: source)
            XCTFail("Expected conflicting authorization")
        } catch {
            XCTAssertEqual(error as? HTTPBasicAuthenticationError, .conflictingAuthorization)
        }
        XCTAssertTrue(HTTPBasicTransportURLProtocol.requests.isEmpty)
    }

    func test401And407DoNotReplayMutation() async throws {
        for status in [401, 407] {
            HTTPBasicTransportURLProtocol.reset { _ in
                .init(status: status, body: Data("private remote response".utf8), headers: ["WWW-Authenticate": "Basic realm=\"fixture\""])
            }
            let client = try transport()
            var source = request("https://example.test/proxy/api/reserves")
            source.httpMethod = "POST"
            source.httpBody = Data("{}".utf8)
            do {
                _ = try await client.data(for: source)
                XCTFail("Expected authentication failure")
            } catch {
                XCTAssertEqual(error as? HTTPBasicTransportError, .authenticationRequired)
                XCTAssertFalse(error.localizedDescription.contains("private remote"))
            }
            XCTAssertEqual(HTTPBasicTransportURLProtocol.requests.count, 1)
            XCTAssertEqual(HTTPBasicTransportURLProtocol.requests[0].httpMethod, "POST")
        }
    }

    func testRedirectsNeverIssueASecondRequest() async throws {
        for status in [301, 302, 303, 307, 308] {
            for target in ["https://other.test/proxy/api", "http://example.test/proxy/api",
                           "https://example.test/proxy/other", "https://example.test/proxy2/api"] {
                HTTPBasicTransportURLProtocol.reset { _ in
                    .init(status: status, redirect: URL(string: target)!)
                }
                let client = try transport()
                var source = request()
                source.httpMethod = "POST"
                source.httpBody = Data("{}".utf8)
                do {
                    _ = try await client.data(for: source)
                    XCTFail("Expected redirect rejection")
                } catch {
                    XCTAssertEqual(error as? HTTPBasicTransportError, .redirectRejected)
                }
                XCTAssertEqual(HTTPBasicTransportURLProtocol.requests.count, 1)
            }
        }
    }

    func testRedirectStatusWithoutLocationIsAlsoRejected() async throws {
        HTTPBasicTransportURLProtocol.reset { _ in .init(status: 302) }
        let client = try transport()
        do {
            _ = try await client.data(for: request())
            XCTFail("Expected redirect rejection")
        } catch {
            XCTAssertEqual(error as? HTTPBasicTransportError, .redirectRejected)
        }
        XCTAssertEqual(HTTPBasicTransportURLProtocol.requests.count, 1)
    }

    func testUnexplainedResponseURLChangeIsRejected() async throws {
        HTTPBasicTransportURLProtocol.reset { _ in .init(responseURL: URL(string: "https://other.test/proxy/api")!) }
        let client = try transport()
        do {
            _ = try await client.data(for: request())
            XCTFail("Expected response URL rejection")
        } catch {
            XCTAssertEqual(error as? HTTPBasicTransportError, .redirectRejected)
        }
    }

    func testBodyLimitWorksWithAndWithoutContentLength() async throws {
        for headers in [["Content-Length": "5"], [:]] {
            HTTPBasicTransportURLProtocol.reset { _ in .init(body: Data("12345".utf8), headers: headers) }
            let client = try transport()
            do {
                _ = try await client.data(for: request(), maximumBytes: 4)
                XCTFail("Expected bounded response failure")
            } catch {
                XCTAssertEqual(error as? HTTPBasicTransportError, .responseTooLarge)
            }
        }
        HTTPBasicTransportURLProtocol.reset { _ in .init(body: Data("1234".utf8)) }
        let client = try transport()
        let (data, _) = try await client.data(for: request(), maximumBytes: 4)
        XCTAssertEqual(data, Data("1234".utf8))
    }

    func testInvalidLimitIsRejectedBeforeNetwork() async throws {
        HTTPBasicTransportURLProtocol.reset()
        let client = try transport()
        for limit in [0, -1, HTTPBasicTransport.maximumDataBytes + 1, Int.max] {
            do {
                _ = try await client.data(for: request(), maximumBytes: limit)
                XCTFail("Expected invalid limit")
            } catch {
                XCTAssertEqual(error as? HTTPBasicTransportError, .invalidLimit)
            }
        }
        XCTAssertTrue(HTTPBasicTransportURLProtocol.requests.isEmpty)
    }

    func testRemoteFailureDoesNotExposeBodyOrURL() async throws {
        HTTPBasicTransportURLProtocol.reset { _ in .init(status: 500, body: Data("private remote detail".utf8)) }
        let client = try transport()
        do {
            _ = try await client.data(for: request())
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? HTTPBasicTransportError, .httpStatus(500))
            XCTAssertFalse(error.localizedDescription.contains("example.test"))
            XCTAssertFalse(error.localizedDescription.contains("private remote"))
        }
        HTTPBasicTransportURLProtocol.reset { request in
            .init(error: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: request.url!]))
        }
        do {
            _ = try await client.data(for: request())
            XCTFail("Expected sanitized transport error")
        } catch {
            XCTAssertEqual(error as? HTTPBasicTransportError, .transport)
            XCTAssertFalse(String(reflecting: error).contains("example.test"))
        }
    }

    func testAuthenticationChallengeCancelsWithoutUsingProposedCredentials() async throws {
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest] {
            HTTPBasicTransportURLProtocol.reset { _ in .init(challengeMethod: method) }
            let client = try transport()
            do {
                _ = try await client.data(for: request())
                XCTFail("Expected challenge rejection")
            } catch {
                XCTAssertEqual(error as? HTTPBasicTransportError, .authenticationRequired)
            }
            XCTAssertFalse(HTTPBasicTransportURLProtocol.authenticationActions.contains("use"))
            XCTAssertFalse(HTTPBasicTransportURLProtocol.authenticationActions.contains("default"))
            XCTAssertEqual(HTTPBasicTransportURLProtocol.requests.count, 1)
        }
    }

    func testResponseBodyFailureDoesNotExposeRequestURL() async throws {
        HTTPBasicTransportURLProtocol.reset { _ in .init(deferredBodyFailure: true) }
        let client = try transport()
        let reading = Task { try await client.data(for: request(), maximumDuration: .seconds(1)) }
        defer { reading.cancel() }
        // URLProtocol can buffer a response until the first body read. Inject
        // failure from outside that read instead of waiting for it to return.
        for _ in 0..<100 {
            if HTTPBasicTransportURLProtocol.hasPendingFailure { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(HTTPBasicTransportURLProtocol.hasPendingFailure)
        HTTPBasicTransportURLProtocol.failPendingBody()
        do {
            _ = try await reading.value
            XCTFail("Expected body failure")
        } catch {
            XCTAssertEqual(error as? HTTPBasicTransportError, .transport)
            XCTAssertFalse(String(reflecting: error).contains("example.test"))
        }
    }

    func testBackgroundConfigurationIsRejectedBeforeSessionCreation() throws {
        HTTPBasicTransportURLProtocol.reset()
        let configuration = URLSessionConfiguration.background(withIdentifier: "fixture.basic-auth")
        XCTAssertThrowsError(try HTTPBasicTransport(
            scope: HTTPBasicAuthenticationScope(address: "https://example.test/proxy/"),
            credential: HTTPBasicCredential(username: "fixture", password: "fixture"),
            sessionConfiguration: configuration
        )) {
            XCTAssertEqual($0 as? HTTPBasicTransportError, .unsupportedConfiguration)
        }
        XCTAssertTrue(HTTPBasicTransportURLProtocol.requests.isEmpty)
    }

    func testStreamRetainsConnectionAndReleasesItOnCompletion() async throws {
        HTTPBasicTransportURLProtocol.reset()
        var client: HTTPBasicTransport? = try transport()
        weak var owner = client
        var stream: HTTPBasicResponseStream? = try await client!.bytes(for: request())
        client = nil
        XCTAssertNotNil(owner)
        var body = Data()
        for try await byte in stream! { body.append(byte) }
        XCTAssertEqual(body, Data("fixture-response".utf8))
        stream!.cancel()
        stream = nil
        XCTAssertNil(owner)
    }

    func testExplicitStreamCancelIsCancellationRatherThanNetworkFailure() async throws {
        HTTPBasicTransportURLProtocol.reset()
        let client = try transport()
        let stream = try await client.bytes(for: request())
        stream.cancel()
        stream.cancel()
        do {
            for try await _ in stream {}
            XCTFail("Expected explicit cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testInvalidatingConnectionCancelsItsStreamAndPreventsNewRequests() async throws {
        HTTPBasicTransportURLProtocol.reset()
        let client = try transport()
        let stream = try await client.bytes(for: request())
        client.invalidate()
        client.invalidate()
        do {
            for try await _ in stream {}
            XCTFail("Expected connection cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await client.data(for: request())
            XCTFail("Expected invalidated connection rejection")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(HTTPBasicTransportURLProtocol.requests.count, 1)
    }

    func testInvalidatingDuringBodyWaitCancelsWithoutReplay() async throws {
        HTTPBasicTransportURLProtocol.reset { _ in .init(deferredBodyFailure: true) }
        let client = try transport()
        let reading = Task { try await client.data(for: request(), maximumDuration: .seconds(1)) }
        defer { reading.cancel() }
        for _ in 0..<100 {
            if HTTPBasicTransportURLProtocol.hasPendingFailure { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(HTTPBasicTransportURLProtocol.hasPendingFailure)
        client.invalidate()
        do {
            _ = try await reading.value
            XCTFail("Expected cancellation during response body")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(HTTPBasicTransportURLProtocol.requests.count, 1)
    }

    func testTotalDataDeadlineCancelsIncompleteResponseWithoutReplay() async throws {
        HTTPBasicTransportURLProtocol.reset { _ in .init(deferredBodyFailure: true) }
        let client = try transport()
        do {
            _ = try await client.data(for: request(), maximumDuration: .milliseconds(50))
            XCTFail("Expected total deadline")
        } catch { XCTAssertEqual(error as? HTTPBasicTransportError, .timedOut) }
        XCTAssertEqual(HTTPBasicTransportURLProtocol.requests.count, 1)
    }

    func testInvalidDeadlineIsRejectedBeforeNetwork() async throws {
        HTTPBasicTransportURLProtocol.reset()
        let client = try transport()
        for duration in [Duration.zero, .seconds(-1), .seconds(121)] {
            do {
                _ = try await client.data(for: request(), maximumDuration: duration)
                XCTFail("Expected invalid deadline")
            } catch { XCTAssertEqual(error as? HTTPBasicTransportError, .invalidTimeout) }
        }
        XCTAssertTrue(HTTPBasicTransportURLProtocol.requests.isEmpty)
    }

    func testChunkReadsPreserveBytesAndHonorExplicitCancellation() async throws {
        let body = Data((0..<10_000).map { UInt8($0 % 251) })
        HTTPBasicTransportURLProtocol.reset { _ in .init(body: body) }
        let client = try transport()
        let stream = try await client.bytes(for: request())
        var iterator = stream.makeAsyncIterator()
        var result = Data()
        while let chunk = try await iterator.nextChunk(maximumBytes: 1024) {
            XCTAssertLessThanOrEqual(chunk.count, 1024)
            result.append(chunk)
        }
        XCTAssertEqual(result, body)
        stream.cancel()
        do { _ = try await iterator.nextChunk(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTransportDescriptionsAreRedacted() throws {
        let client = try transport()
        let output = [client.description, client.debugDescription, String(reflecting: client),
                      Mirror(reflecting: client).children.map { String(reflecting: $0.value) }.joined()].joined()
        for value in ["example.test", "fixture-user", "fixture-password", "Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ="] {
            XCTAssertFalse(output.contains(value))
        }
    }
}
