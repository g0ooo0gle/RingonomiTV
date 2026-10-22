import Foundation
@preconcurrency import Network
import XCTest
@testable import RingonomiCore

private final class LiveCaptionRelayFixtureProtocol: URLProtocol {
    struct Stub {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var hold = false
        var holdHeaders = false
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
        if stub.holdHeaders { return }
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

/// Uses an actual TCP close rather than relying on URLSession's buffered
/// AsyncBytes cancellation, so the fixture matches a decoder abandoning GET.
private final class LiveCaptionLoopbackClient: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data

    init(_ url: URL) throws {
        guard let host = url.host, let port = url.port,
              let endpoint = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw URLError(.badURL)
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: .tcp)
        request = Data("GET \(url.path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n".utf8)
        connection.start(queue: DispatchQueue(label: "fixture.live-caption-client"))
    }

    deinit { connection.cancel() }
    func cancel() { connection.cancel() }

    func responseStatus() async -> Int? {
        let deadline = Task { [connection] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            connection.cancel()
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                }
                var header = Data()
                while header.count < 4096 {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume(returning: data ?? Data()) }
                        }
                    }
                    guard !data.isEmpty else { return nil }
                    header.append(data)
                    if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                        guard let text = String(data: header[..<end.lowerBound], encoding: .ascii),
                              let first = text.components(separatedBy: "\r\n").first else { return nil }
                        let fields = first.split(separator: " ")
                        return fields.count >= 2 ? Int(fields[1]) : nil
                    }
                }
            } catch { }
            return nil
        } onCancel: { self.connection.cancel() }
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

    private func startRelay(usingStandardTransport: Bool = false) async throws -> (LiveCaptionRelay, URL) {
        let relay: LiveCaptionRelay
        if usingStandardTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LiveCaptionRelayFixtureProtocol.self]
            configuration.connectionProxyDictionary = [:]
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            relay = LiveCaptionRelay(client: try RingonomiClient(address: "https://fixture.test/"),
                                     session: session) { _ in await Task.yield() }
            addTeardownBlock { session.invalidateAndCancel() }
        } else {
            relay = LiveCaptionRelay(client: try client()) { _ in await Task.yield() }
        }
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

    private func waitForStartupProgress(_ relay: LiveCaptionRelay,
                                        phase: PlaybackStartupPhase,
                                        attempt: UInt64) async -> Bool {
        for _ in 0..<200 {
            if let progress = await relay.startupProgress,
               progress.phase == phase, progress.attempt == attempt {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
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
        let failure = await waitForFailure(relay)
        XCTAssertEqual(failure, .connection, "a finite upstream body is an unexpected EOF for a live TS")
    }

    func testStartupProgressTracksDecoderAttemptsAndStop() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(body: Data(repeating: 0x47, count: 32 * 1024),
                  headers: ["Content-Type": "video/mp2t"], hold: true)
        }
        let (relay, local) = try await startRelay()
        let initialProgress = await relay.startupProgress
        XCTAssertEqual(initialProgress,
                       PlaybackStartupProgress(phase: .waitingForRequest, attempt: 0))

        let first = try LiveCaptionLoopbackClient(local)
        let firstStatus = await first.responseStatus()
        XCTAssertEqual(firstStatus, 200)
        let firstDecoding = await waitForStartupProgress(relay, phase: .decoding, attempt: 1)
        XCTAssertTrue(firstDecoding)
        first.cancel()
        let firstReady = await waitForStartupProgress(relay, phase: .waitingForRequest, attempt: 1)
        XCTAssertTrue(firstReady)

        // The replacement request gets a new attempt number even if the old
        // GET's cancellation completion is still draining asynchronously.
        let second = try LiveCaptionLoopbackClient(local)
        let secondStatus = await second.responseStatus()
        XCTAssertEqual(secondStatus, 200)
        let secondDecoding = await waitForStartupProgress(relay, phase: .decoding, attempt: 2)
        XCTAssertTrue(secondDecoding)
        second.cancel()
        await relay.stop()
        let stoppedProgress = await relay.startupProgress
        XCTAssertNil(stoppedProgress)
    }

    func testValidatedHeadersWithoutBodyRemainWaitingForData() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(headers: ["Content-Type": "video/mp2t"], hold: true)
        }
        let (relay, local) = try await startRelay()
        let decoder = try LiveCaptionLoopbackClient(local)
        defer { decoder.cancel() }
        let status = await decoder.responseStatus()
        XCTAssertEqual(status, 200)
        let waiting = await waitForStartupProgress(relay, phase: .waitingForData, attempt: 1)
        XCTAssertTrue(waiting)
        decoder.cancel()
        let released = await waitForStartupProgress(relay, phase: .waitingForRequest, attempt: 1)
        XCTAssertTrue(released)
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

    func testMalformedLoopbackRequestDoesNotRecordUpstreamFailure() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(body: Data([0x01]), headers: ["Content-Type": "video/mp2t"])
        }
        let (relay, local) = try await startRelay()
        let session = playerSession()
        defer { session.invalidateAndCancel() }

        var components = URLComponents(url: local, resolvingAgainstBaseURL: false)!
        components.path = "/wrong-route"
        let (data, response) = try await session.data(from: components.url!)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        try await Task.sleep(for: .milliseconds(20))
        let failure = await relay.lastFailure
        XCTAssertNil(failure)
    }

    func testOldGETFailureCannotOverwriteReplacementGET() async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            LiveCaptionRelayFixtureProtocol.requests.count == 1
                ? .init(body: Data([0x01]), headers: ["Content-Type": "video/mp2t"])
                : .init(body: Data([0x02]), headers: ["Content-Type": "video/mp2t"], hold: true)
        }
        let (relay, local) = try await startRelay()
        let first = try LiveCaptionLoopbackClient(local)
        defer { first.cancel() }
        let firstStatus = await first.responseStatus()
        XCTAssertEqual(firstStatus, 200)
        let oldFailure = await waitForFailure(relay)
        XCTAssertEqual(oldFailure, .connection)

        let second = try LiveCaptionLoopbackClient(local)
        defer { second.cancel() }
        let secondStatus = await second.responseStatus()
        XCTAssertEqual(secondStatus, 200)
        let replacementFailure = await relay.lastFailure
        XCTAssertNil(replacementFailure)
    }

    func testLocalClientCancellationCanBeReplacedWithoutFailure() async throws {
        try await assertLocalCancellationReleasesBody(usingStandardTransport: false)
    }

    func testStandardTransportLocalCancellationReleasesBodyAndLease() async throws {
        try await assertLocalCancellationReleasesBody(usingStandardTransport: true)
    }

    private func assertLocalCancellationReleasesBody(usingStandardTransport: Bool) async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            .init(body: Data([0x01]), headers: ["Content-Type": "video/mp2t"], hold: true)
        }
        let (relay, local) = try await startRelay(usingStandardTransport: usingStandardTransport)
        let first = try LiveCaptionLoopbackClient(local)
        let firstStatus = await first.responseStatus()
        XCTAssertEqual(firstStatus, 200)
        first.cancel()
        try await waitForStopCount(1)
        XCTAssertGreaterThanOrEqual(LiveCaptionRelayFixtureProtocol.stopCount, 1)
        let firstFailure = await relay.lastFailure
        XCTAssertNil(firstFailure)
        try await assertNewGETSucceedsWithoutFailure(relay, local: local)
    }

    func testLocalCancellationBeforeUpstreamHeadersReleasesLease() async throws {
        try await assertLocalCancellationReleasesHeaders(usingStandardTransport: false)
    }

    func testStandardTransportLocalCancellationBeforeHeadersReleasesLease() async throws {
        try await assertLocalCancellationReleasesHeaders(usingStandardTransport: true)
    }

    private func assertLocalCancellationReleasesHeaders(usingStandardTransport: Bool) async throws {
        LiveCaptionRelayFixtureProtocol.reset { _ in
            LiveCaptionRelayFixtureProtocol.requests.count == 1
                ? .init(headers: ["Content-Type": "video/mp2t"], holdHeaders: true)
                : .init(body: Data([0x01]), headers: ["Content-Type": "video/mp2t"], hold: true)
        }
        let (relay, local) = try await startRelay(usingStandardTransport: usingStandardTransport)
        let first = try LiveCaptionLoopbackClient(local)
        let pending = Task { await first.responseStatus() }
        try await waitForRequestCount(1)
        XCTAssertEqual(LiveCaptionRelayFixtureProtocol.requests.count, 1)
        let waiting = await waitForStartupProgress(relay, phase: .waitingForResponse, attempt: 1)
        XCTAssertTrue(waiting)
        first.cancel()
        _ = await pending.value
        try await waitForStopCount(1)
        XCTAssertGreaterThanOrEqual(LiveCaptionRelayFixtureProtocol.stopCount, 1)
        let firstFailure = await relay.lastFailure
        XCTAssertNil(firstFailure)
        try await assertNewGETSucceedsWithoutFailure(relay, local: local)
    }

    private func assertNewGETSucceedsWithoutFailure(_ relay: LiveCaptionRelay, local: URL) async throws {
        // The actor must release the abandoned GET, not keep returning 503.
        for _ in 0..<100 {
            let retry = try LiveCaptionLoopbackClient(local)
            let status = await retry.responseStatus()
            if status == 200 {
                let failure = await relay.lastFailure
                XCTAssertNil(failure)
                retry.cancel()
                return
            }
            retry.cancel()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Replacement GET never received an upstream response")
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
