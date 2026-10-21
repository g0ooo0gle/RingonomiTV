import Foundation
import XCTest
@testable import RingonomiCore

private final class LiveCaptionRelayFixtureProtocol: URLProtocol {
    struct Stub {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var hold = false
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest) -> Stub)?
        var requests: [URLRequest] = []
        var stopCount = 0

        func reset(_ handler: ((URLRequest) -> Stub)? = nil) {
            lock.lock()
            defer { lock.unlock() }
            self.handler = handler
            requests = []
            stopCount = 0
        }

        func response(for request: URLRequest) -> Stub {
            lock.lock()
            requests.append(request)
            let handler = handler
            lock.unlock()
            return handler?(request) ?? Stub(status: 404)
        }

        func snapshotRequests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func stopped() {
            lock.lock()
            stopCount += 1
            lock.unlock()
        }

        func snapshotStopCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return stopCount
        }
    }

    private static let state = State()

    static func reset(_ handler: @escaping (URLRequest) -> Stub) {
        state.reset(handler)
    }

    static func clear() {
        state.reset()
    }

    static var requests: [URLRequest] { state.snapshotRequests() }
    static var stopCount: Int { state.snapshotStopCount() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.state.response(for: request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status,
                                             httpVersion: "HTTP/1.1", headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        if !stub.hold { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        Self.state.stopped()
    }
}

final class LiveCaptionRelayTests: XCTestCase, @unchecked Sendable {
    override func tearDown() {
        LiveCaptionRelayFixtureProtocol.clear()
        super.tearDown()
    }

    private var liveSource: URL {
        URL(string: "https://fixture.test/api/streams/live/fixture-channel/720p/mpegts")!
    }

    private func client() throws -> RingonomiClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveCaptionRelayFixtureProtocol.self]
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let credential = try HTTPBasicCredential(username: "fixture-user", password: "fixture-password")
        return try RingonomiClient(address: "https://fixture.test/",
                                   httpBasicCredential: credential,
                                   sessionConfiguration: configuration)
    }

    private func playerSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private func startRelay() async throws -> (LiveCaptionRelay, URL) {
        let relay = LiveCaptionRelay(client: try client()) { _ in await Task.yield() }
        addTeardownBlock { await relay.stop() }
        return (relay, try await relay.start(source: liveSource))
    }

    private func waitForRequestCount(_ count: Int) async throws {
        for _ in 0..<100 {
            if LiveCaptionRelayFixtureProtocol.requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForStopCount(_ count: Int) async throws {
        for _ in 0..<100 {
            if LiveCaptionRelayFixtureProtocol.stopCount >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForFailure(_ relay: LiveCaptionRelay) async -> HTTPMediaRelayFailure? {
        for _ in 0..<100 {
            let failure = await relay.lastFailure
            if failure != nil { return failure }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await relay.lastFailure
    }

    func testBatchCarriesParserGenerationAndClockState() {
        let id = UUID()
        let caption = MPEGTSARIBCaption(payload: Data([0x80, 0xFF, 0x01]),
                                        presentationTicks: 90_000,
                                        discontinuitySequence: 2)
        let batch = LiveCaptionBatch(streamID: id, captions: [caption], firstVideoTicks: 45_000,
                                     firstClockTicks: 40_000, currentClockTicks: 90_000,
                                     discontinuitySequence: 2)
        XCTAssertEqual(batch.streamID, id)
        XCTAssertEqual(batch.captions.first?.presentationTicks, 90_000)
        XCTAssertEqual(batch.firstClockTicks, 40_000)
        XCTAssertEqual(batch.currentClockTicks, 90_000)
        XCTAssertTrue(batch.isSynchronized)
    }

    func testGETForwardsExactBytesFromAuthenticatedUpstream() async throws {
        let body = Data((0..<70_003).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) })
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(body: body, headers: ["Content-Type": "video/mp2t"])
        }
        let (relay, local) = try await startRelay()
        let session = playerSession()
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(from: local)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, body)

        let requests = LiveCaptionRelayFixtureProtocol.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.url?.path, liveSource.path)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept"), "video/mp2t")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
        let failure = await relay.lastFailure
        XCTAssertNil(failure)
    }

    func testHEADDoesNotOpenAuthenticatedUpstream() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(headers: ["Content-Type": "video/mp2t"])
        }
        let (_, local) = try await startRelay()
        let session = playerSession()
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: local)
        request.httpMethod = "HEAD"
        let (data, response) = try await session.data(for: request)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(LiveCaptionRelayFixtureProtocol.requests.count, 0)
    }

    func testNonzeroRangeReturns416WithoutOpeningAuthenticatedUpstream() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(headers: ["Content-Type": "video/mp2t"])
        }
        let (_, local) = try await startRelay()
        let session = playerSession()
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: local)
        request.setValue("bytes=1-2", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 416)
        XCTAssertEqual(LiveCaptionRelayFixtureProtocol.requests.count, 0)
    }

    func testNonMPEGTSResponseReturns502AndRecordsConnectionFailure() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(body: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                  headers: ["Content-Type": "application/octet-stream"])
        }
        let (relay, local) = try await startRelay()
        let session = playerSession()
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(from: local)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertEqual(LiveCaptionRelayFixtureProtocol.requests.count, 1)
        let failure = await waitForFailure(relay)
        XCTAssertEqual(failure, .connection)
    }

    func testStopCancelsPendingAuthenticatedStream() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(headers: ["Content-Type": "video/mp2t"], hold: true)
        }
        let (relay, local) = try await startRelay()
        let session = playerSession()
        defer { session.invalidateAndCancel() }

        let reading = Task { try await session.data(from: local) }
        try await waitForRequestCount(1)
        XCTAssertEqual(LiveCaptionRelayFixtureProtocol.requests.count, 1)

        await relay.stop()
        reading.cancel()
        let result = await reading.result
        if case .success = result { XCTFail("stopped stream unexpectedly completed") }
        try await waitForStopCount(1)
        XCTAssertGreaterThanOrEqual(LiveCaptionRelayFixtureProtocol.stopCount, 1)
    }

    func testOnlyOneGETUsesAuthenticatedUpstreamAtATime() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(headers: ["Content-Type": "video/mp2t"], hold: true)
        }
        let (relay, local) = try await startRelay()
        let session = playerSession()
        defer { session.invalidateAndCancel() }

        let first = Task { try await session.data(from: local) }
        try await waitForRequestCount(1)
        let (secondData, secondResponse) = try await session.data(from: local)
        XCTAssertTrue(secondData.isEmpty)
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(LiveCaptionRelayFixtureProtocol.requests.count, 1)

        await relay.stop()
        first.cancel()
        _ = await first.result
    }

    func testWrongLoopbackRouteReturns502WithoutOpeningUpstream() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(body: Data([0x00]), headers: ["Content-Type": "video/mp2t"])
        }
        let (_, local) = try await startRelay()
        let session = playerSession()
        defer { session.invalidateAndCancel() }

        var components = URLComponents(url: local, resolvingAgainstBaseURL: false)!
        components.path = "/wrong-route"
        let (data, response) = try await session.data(from: components.url!)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertEqual(LiveCaptionRelayFixtureProtocol.requests.count, 0)
    }

    func testSourceOutsideConfiguredOriginIsRejectedBeforeListenerOrUpstream() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in .init() }
        let relay = LiveCaptionRelay(client: try client()) { _ in await Task.yield() }
        addTeardownBlock { await relay.stop() }
        let foreignSource = URL(string: "https://outside.test/api/streams/live/fixture-channel/720p/mpegts")!

        do {
            _ = try await relay.start(source: foreignSource)
            XCTFail("source outside the configured origin should be rejected")
        } catch let error as HLSRelayError {
            XCTAssertEqual(error, .invalidRoute)
        }
        XCTAssertTrue(LiveCaptionRelayFixtureProtocol.requests.isEmpty)
    }

    func testPlaylistKindIsRejectedBeforeOpeningListener() async throws {
        let client = try RingonomiClient(address: "https://example.test/")
        let relay = LiveCaptionRelay(client: client) { _ in await Task.yield() }
        let source = URL(string: "https://example.test/api/streams/live/channel/720p/mpegts")!
        do {
            _ = try await relay.start(source: source, kind: .playlist)
            XCTFail("playlist relay should be rejected")
        } catch let error as HLSRelayError {
            XCTAssertEqual(error, .invalidRoute)
        }
    }

    func testQueryIsRejectedWithoutStartingNetworkListener() async throws {
        let client = try RingonomiClient(address: "https://example.test/")
        let relay = LiveCaptionRelay(client: client) { _ in await Task.yield() }
        let source = URL(string: "https://example.test/api/streams/live/channel/720p/mpegts?x=1")!
        do {
            _ = try await relay.start(source: source)
            XCTFail("query-bearing live source should be rejected")
        } catch let error as HLSRelayError {
            XCTAssertEqual(error, .invalidRoute)
        }
    }
}
