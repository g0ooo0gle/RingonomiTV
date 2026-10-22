import Foundation
import XCTest
@testable import RingonomiCore

private final class KonomiBasicFixture: URLProtocol {
    struct Stub { var status = 200; var text = "{}"; var redirect: URL?; var hold = false }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest) -> Stub)?
        var requests: [URLRequest] = []
        func reset(_ handler: ((URLRequest) -> Stub)?) {
            lock.lock(); defer { lock.unlock() }; self.handler = handler; requests = []
        }
        func handle(_ request: URLRequest) -> Stub {
            lock.lock(); requests.append(request); let handler = handler; lock.unlock()
            return handler?(request) ?? Stub(status: 404)
        }
        func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }
    private static let state = State()
    static func reset(_ handler: ((URLRequest) -> Stub)? = nil) { state.reset(handler) }
    static var requests: [URLRequest] { state.snapshot() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.state.handle(request)
        if let redirect = stub.redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
        } else {
            let data = Data(stub.text.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            if !stub.hold { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() {}
}

final class KonomiHTTPBasicTests: XCTestCase, @unchecked Sendable {
    override func tearDown() { KonomiBasicFixture.reset(); super.tearDown() }
    private func credential() throws -> HTTPBasicCredential {
        try HTTPBasicCredential(username: "fixture-user", password: "fixture-password")
    }
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KonomiBasicFixture.self]
        return configuration
    }
    private func client() throws -> RingonomiClient {
        try RingonomiClient(address: "https://example.test/proxy/tv/", httpBasicCredential: credential(), sessionConfiguration: configuration())
    }
    private var authorization: String { "Basic Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzc3dvcmQ=" }

    func testBearerConflictAndInsecureConnectionFailBeforeNetwork() throws {
        XCTAssertThrowsError(try RingonomiClient(address: "https://example.test/", accessToken: BackendAccessToken(rawValue: "fixture-token"), httpBasicCredential: credential())) {
            XCTAssertEqual($0 as? HTTPBasicAuthenticationError, .conflictingAuthorization)
        }
        XCTAssertThrowsError(try RingonomiClient(address: "http://example.test/", httpBasicCredential: credential())) {
            XCTAssertEqual($0 as? HTTPBasicAuthenticationError, .insecureConnection)
        }
        XCTAssertTrue(KonomiBasicFixture.requests.isEmpty)
    }

    func testBrowserAddressIsNormalizedOnceBeforeCreatingCredentialScope() throws {
        let client = try RingonomiClient(address: "https://example.test/proxy/tv/tv/", httpBasicCredential: credential())
        XCTAssertEqual(client.httpBasicScope?.storageIdentity, "https://example.test/proxy/tv/")
        let allowed = URLRequest(url: URL(string: "https://example.test/proxy/tv/api/channels")!)
        XCTAssertEqual(try client.backendAuthorizedRequest(allowed).value(forHTTPHeaderField: "Authorization"), authorization)
        XCTAssertThrowsError(try client.backendAuthorizedRequest(URLRequest(url: URL(string: "https://example.test/proxy/api/channels")!)))
    }

    func testGenericAPIAndKeepAliveUseBasicWithoutCookieOrSharedHeaders() async throws {
        KonomiBasicFixture.reset { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), self.authorization)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return .init()
        }
        let client = try client()
        let result = try await client.fetch(["api", "version"], as: [String: String].self)
        XCTAssertTrue(result.isEmpty)
        try await client.keepRecordingAlive(id: 1, session: "fixture-session", quality: "720p")
        XCTAssertEqual(KonomiBasicFixture.requests.count, 2)
        XCTAssertEqual(KonomiBasicFixture.requests[1].httpMethod, "PUT")
        XCTAssertEqual(KonomiBasicFixture.requests[1].url?.path, "/proxy/api/streams/video/1/720p/keep-alive")
    }

    func testChannelListUsesAuthenticatedStreamingDecoder() async throws {
        KonomiBasicFixture.reset { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), self.authorization)
            return .init(text: #"{"GR":[{"id":"gr011","display_channel_id":"gr011","name":"Fixture","is_watchable":true,"is_display":true}]}"#)
        }
        let channels = try await client().channels()
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first?.displayChannelId, "gr011")
    }

    func testExplicitSessionConfigurationIsCopiedAndHardened() async throws {
        KonomiBasicFixture.reset { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), self.authorization)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Proxy-Authorization"))
            return .init()
        }
        let configuration = configuration()
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer injected", "Proxy-Authorization": "Basic injected", "Cookie": "fixture=cookie"]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = try RingonomiClient(address: "https://example.test/proxy/", httpBasicCredential: credential())
        _ = try await client.fetch(["api", "version"], as: [String: String].self, using: session)
        XCTAssertEqual(KonomiBasicFixture.requests.count, 1)
    }

    func testErrorStatusAndBodyRemainAvailableToTypedAPIClients() async throws {
        KonomiBasicFixture.reset { _ in .init(status: 409, text: #"{"detail":"fixture conflict"}"#) }
        let client = try client()
        var request = URLRequest(url: client.endpoint(["api", "reservations"]))
        request.httpMethod = "POST"
        let (data, response) = try await client.backendData(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"detail":"fixture conflict"}"#)
        XCTAssertEqual(KonomiBasicFixture.requests.count, 1)
    }

    func testAuthenticationFailureIsNotReplayedOrExposedAsBody() async throws {
        KonomiBasicFixture.reset { _ in .init(status: 401, text: "private response body") }
        let client = try client()
        var request = URLRequest(url: client.endpoint(["api", "reservations"]))
        request.httpMethod = "POST"
        do { _ = try await client.backendData(for: request); XCTFail("Expected authentication error") }
        catch { XCTAssertEqual(error as? HTTPBasicTransportError, .authenticationRequired) }
        XCTAssertEqual(KonomiBasicFixture.requests.count, 1)
    }

    func testRedirectAndOutOfScopeRequestsNeverReachOtherOrigins() async throws {
        KonomiBasicFixture.reset { _ in .init(status: 302, redirect: URL(string: "https://other.test/proxy/api/channels")!) }
        let client = try client()
        do { _ = try await client.channels(); XCTFail("Expected redirect refusal") }
        catch { XCTAssertEqual(error as? HTTPBasicTransportError, .redirectRejected) }
        XCTAssertEqual(KonomiBasicFixture.requests.count, 1)
        for address in ["https://other.test/proxy/api/version", "https://example.test/proxy2/api/version"] {
            do { _ = try await client.backendData(for: URLRequest(url: URL(string: address)!)); XCTFail("Expected scope error") }
            catch { XCTAssertEqual(error as? HTTPBasicAuthenticationError, .outsideScope) }
        }
        XCTAssertEqual(KonomiBasicFixture.requests.count, 1)
    }

    func testStreamRetainsConnectionAndExplicitCancellationIsPreserved() async throws {
        KonomiBasicFixture.reset { _ in .init(text: "fixture-body") }
        var client: RingonomiClient? = try self.client()
        let request = URLRequest(url: client!.endpoint(["api", "version"]))
        let (bytes, _) = try await client!.backendBytes(for: request)
        client = nil
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "fixture-body")
        bytes.cancel()
        var iterator = bytes.makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let description = [String(describing: bytes), String(reflecting: iterator),
                           Mirror(reflecting: bytes).children.map { String(reflecting: $0.value) }.joined()].joined()
        XCTAssertFalse(description.contains("example.test"))
        XCTAssertFalse(description.contains("fixture-password"))
    }

    func testAccountLoginCannotSilentlyCombineBasicAndBearer() async throws {
        do { _ = try await client().login(username: "fixture-user", password: "fixture-password"); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? HTTPBasicAuthenticationError, .conflictingAuthorization) }
        XCTAssertTrue(KonomiBasicFixture.requests.isEmpty)
    }

    func testShortAPIDeadlineIsRespectedWithoutReplay() async throws {
        KonomiBasicFixture.reset { request in
            XCTAssertEqual(request.timeoutInterval, 0.05, accuracy: 0.001)
            return .init(hold: true)
        }
        let client = try client()
        var request = URLRequest(url: client.endpoint(["api", "version"]))
        request.timeoutInterval = 0.05
        let started = Date()
        do { _ = try await client.backendData(for: request); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? HTTPBasicTransportError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(KonomiBasicFixture.requests.count, 1)
    }

    func testTimetableCanExceedPlaylistLimitWhileOrdinaryAPIStaysBounded() async throws {
        let large = "{\"channels\":[],\"padding\":\"" + String(repeating: "x", count: HTTPBasicTransport.maximumDataBytes) + "\"}"
        KonomiBasicFixture.reset { _ in .init(text: large) }
        let client = try client()
        let guide = try await client.programGuide()
        XCTAssertTrue(guide.channels.isEmpty)
        do {
            _ = try await client.backendData(for: URLRequest(url: client.endpoint(["api", "version"])))
            XCTFail("Expected ordinary response limit")
        } catch { XCTAssertEqual(error as? HTTPBasicTransportError, .responseTooLarge) }
    }

    func testMediaRelayRetainsTheConnectionsInjectedTransportConfiguration() async throws {
        KonomiBasicFixture.reset { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), self.authorization)
            return .init(text: "#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n")
        }
        let client = try client()
        let relay = try XCTUnwrap(client.makeAuthenticatedMediaRelay())
        let local = try await relay.start(source: client.endpoint(["api", "streams", "playlist"]), kind: .playlist)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        do {
            let (data, response) = try await session.data(from: local)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("127.0.0.1"))
            XCTAssertEqual(KonomiBasicFixture.requests.count, 1)
        } catch { await relay.stop(); session.invalidateAndCancel(); throw error }
        await relay.stop(); session.invalidateAndCancel()
    }

    func testOnlyBasicConnectionCreatesMediaRelayWithoutStartingNetwork() async throws {
        let anonymous = try RingonomiClient(address: "https://example.test/")
        XCTAssertNil(try anonymous.makeAuthenticatedMediaRelay())
        let relay = try XCTUnwrap(client().makeAuthenticatedMediaRelay())
        await relay.stop()
        XCTAssertTrue(KonomiBasicFixture.requests.isEmpty)
    }
}
