import Foundation
import XCTest
@testable import RingonomiCore

private final class EPGStationLiveURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
        let redirectURL: URL?

        init(
            status: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
            body: Data,
            redirectURL: URL? = nil
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.redirectURL = redirectURL
        }
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Stub)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler,
              let requestURL = request.url,
              let client else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: stub.headers
        ) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let redirectURL = stub.redirectURL {
            client.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: redirectURL),
                redirectResponse: response
            )
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client.urlProtocol(self, didLoad: stub.body)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class EPGStationLiveRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var all: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class EPGStationLiveBlockingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0

    static func reset() {
        lock.lock()
        requests = 0
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lock.unlock()
        guard let requestURL = request.url,
              let response = HTTPURLResponse(
                  url: requestURL,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Keep the response open so cancellation must reach the URLSession
        // task instead of being satisfied by a completed fixture.
    }

    override func stopLoading() {}
}

final class EPGStationLiveTests: XCTestCase {
    private func client(
        protocolClass: URLProtocol.Type = EPGStationLiveURLProtocol.self
    ) throws -> EPGStationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return try EPGStationClient(
            address: "http://example.invalid/proxy",
            sessionConfiguration: configuration
        )
    }

    private func queryItems(from request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return items.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    func testProfileListIsAuthoritativeAndInvalidNamesKeepContainerMode() async throws {
        let profileBody = Data(#"""
        {
          "streamProfiles": {"live": [
            {"container":"m2ts","name":"標準","isUnconverted":true},
            {"container":"m2ts","name":"bad\u0001","isUnconverted":false},
            {"container":"m2ts","name":"高画質","isUnconverted":false},
            {"container":"m2tsll","name":"低遅延"},
            {"container":"unknown","name":"無視"},
            {"container":"hls","name":"HLS"}
          ]},
          "streamConfig": {"live": {"ts": {"m2ts":{}}}}
        }
        """#.utf8)
        EPGStationLiveURLProtocol.handler = { _ in
            EPGStationLiveURLProtocol.Stub(body: profileBody)
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let qualities = try await client().liveQualities()

        XCTAssertEqual(qualities.map(\.id), ["m2ts:0", "m2ts:2", "m2tsll:0", "hls:0"])
        XCTAssertEqual(qualities[1].name, "高画質")
        XCTAssertTrue(qualities[0].isUnconverted)
    }

    func testEmptyOrUnsupportedProfileListDoesNotFallBackToLegacy() async throws {
        for profiles in ["[]", #"[{"container":"unknown","name":"x"}]"#] {
            EPGStationLiveURLProtocol.handler = { _ in
                EPGStationLiveURLProtocol.Stub(body: Data("""
                {"streamProfiles":{"live":\(profiles)},"streamConfig":{"live":{"ts":{"m2ts":[{"name":"legacy"}]}}}}
                """.utf8))
            }
            defer { EPGStationLiveURLProtocol.handler = nil }

            let qualities = try await client().liveQualities()
            XCTAssertTrue(qualities.isEmpty)
        }
    }

    func testMissingProfileFieldUsesLegacyConfigAndPreservesIndexes() async throws {
        let body = Data(#"""
        {
          "streamConfig": {"live": {"ts": {
            "m2ts":[{"name":"TS0"},{"name":"bad\u0001"},{"name":"TS2"}],
            "m2tsll":["低遅延"], "hls":["HLS"]
          }}}
        }
        """#.utf8)
        EPGStationLiveURLProtocol.handler = { _ in
            EPGStationLiveURLProtocol.Stub(body: body)
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let qualities = try await client().liveQualities()

        XCTAssertEqual(qualities.map(\.id), ["m2ts:0", "m2ts:2", "m2tsll:0", "hls:0"])
    }

    func testMalformedProfileFieldsAreIgnoredWithoutChangingModes() async throws {
        let body = Data(#"""
        {"streamProfiles":{"live":[
          {"container":"m2ts","name":"first","isUnconverted":true},
          {"container":"m2ts","name":"bad-bool","isUnconverted":"wrong"},
          {"container":"m2ts","name":"third","isUnconverted":false},
          {"container":"unknown","name":123,"isUnconverted":"wrong"},
          {"container":"unknown"}
        ]}}
        """#.utf8)
        EPGStationLiveURLProtocol.handler = { _ in
            EPGStationLiveURLProtocol.Stub(body: body)
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let qualities = try await client().liveQualities()

        XCTAssertEqual(qualities.map(\.id), ["m2ts:0", "m2ts:2"])
        XCTAssertTrue(qualities[0].isUnconverted)
        XCTAssertFalse(qualities[1].isUnconverted)
    }

    func testQualityNamesAndConfigurationAreBounded() async throws {
        XCTAssertThrowsError(try EPGStationLiveQuality(format: .m2ts, mode: 0, name: ""))
        XCTAssertThrowsError(try EPGStationLiveQuality(format: .m2ts, mode: 0, name: "   "))
        XCTAssertThrowsError(try EPGStationLiveQuality(format: .m2ts, mode: 256, name: "too-late"))

        let entries = Array(
            repeating: #"{"container":"m2ts","name":"x"}"#,
            count: 257
        ).joined(separator: ",")
        let body = Data(#"{"streamProfiles":{"live":[\#(entries)]}}"#.utf8)
        EPGStationLiveURLProtocol.handler = { _ in
            EPGStationLiveURLProtocol.Stub(body: body)
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        do {
            _ = try await client().liveQualities()
            XCTFail("oversized quality configuration must be rejected")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let legacyEntries = Array(repeating: "\"x\"", count: 257).joined(separator: ",")
        let legacyBody = Data(#"{"streamConfig":{"live":{"ts":{"m2tsll":[\#(legacyEntries)]}}}}"#.utf8)
        EPGStationLiveURLProtocol.handler = { _ in
            EPGStationLiveURLProtocol.Stub(body: legacyBody)
        }
        do {
            _ = try await client().liveQualities()
            XCTFail("oversized legacy quality configuration must be rejected")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testQualityValidationAndDirectURLs() throws {
        let m2ts = try EPGStationLiveQuality(format: .m2ts, mode: 2, name: "TS")
        let client = try client()
        let url = try client.liveURL(channelID: 42, quality: m2ts)

        XCTAssertEqual(url.path, "/proxy/api/streams/live/42/m2ts")
        XCTAssertEqual(queryItems(from: URLRequest(url: url))["mode"], "2")
        XCTAssertThrowsError(try EPGStationLiveQuality(format: .hls, mode: -1, name: "bad"))

        let hls = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        XCTAssertThrowsError(try client.liveURL(channelID: 42, quality: hls)) { error in
            XCTAssertEqual(error as? EPGStationError, .invalidRequest)
        }
        XCTAssertThrowsError(try client.liveURL(channelID: 0, quality: m2ts)) { error in
            XCTAssertEqual(error as? EPGStationError, .invalidIdentifier)
        }
    }

    func testStartHLSAcceptsZeroStreamIDAndKeepUsesPUT() async throws {
        let recorder = EPGStationLiveRequestRecorder()
        EPGStationLiveURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path == "/proxy/api/streams/live/42/hls" {
                return EPGStationLiveURLProtocol.Stub(body: Data(#"{"streamId":0}"#.utf8))
            }
            return EPGStationLiveURLProtocol.Stub(body: Data())
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let client = try client()
        let quality = try EPGStationLiveQuality(format: .hls, mode: 1, name: "HLS")
        let stream = try await client.startLiveStream(channelID: 42, quality: quality)
        try await client.keepLiveStream(id: 0)

        XCTAssertEqual(stream.streamID, 0)
        XCTAssertEqual(stream.url.path, "/proxy/streamfiles/stream0.m3u8")
        XCTAssertEqual(recorder.all.count, 2)
        XCTAssertEqual(recorder.all[0].httpMethod, "GET")
        XCTAssertEqual(queryItems(from: recorder.all[0])["mode"], "1")
        XCTAssertEqual(recorder.all[1].httpMethod, "PUT")
        XCTAssertEqual(recorder.all[1].url?.path, "/proxy/api/streams/0/keep")
        XCTAssertNil(recorder.all[1].httpBody)
    }

    func testTSStartDoesNotMakeARequestAndHLSResponseIsStrict() async throws {
        EPGStationLiveURLProtocol.handler = { _ in
            XCTFail("TS start should only build a URL")
            return EPGStationLiveURLProtocol.Stub(body: Data())
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let client = try client()
        let quality = try EPGStationLiveQuality(format: .m2tsll, mode: 0, name: "LL")
        let stream = try await client.startLiveStream(channelID: 7, quality: quality)
        XCTAssertNil(stream.streamID)
        XCTAssertEqual(stream.url.path, "/proxy/api/streams/live/7/m2tsll")

        EPGStationLiveURLProtocol.handler = { _ in
            EPGStationLiveURLProtocol.Stub(body: Data(#"{"streamId":-1}"#.utf8))
        }
        let hls = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        do {
            _ = try await client.startLiveStream(channelID: 7, quality: hls)
            XCTFail("negative stream IDs must be rejected")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testHTTPStatusMalformedAndRedirectRemainSafe() async throws {
        EPGStationLiveURLProtocol.handler = { _ in
            EPGStationLiveURLProtocol.Stub(status: 503, body: Data("private".utf8))
        }
        defer { EPGStationLiveURLProtocol.handler = nil }
        do {
            _ = try await client().liveQualities()
            XCTFail("expected HTTP error")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .httpStatus(503))
        }

        EPGStationLiveURLProtocol.handler = { _ in
            EPGStationLiveURLProtocol.Stub(body: Data(#"{"streamProfiles":{"live":}"#.utf8))
        }
        do {
            _ = try await client().liveQualities()
            XCTFail("expected malformed response")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }

        EPGStationLiveURLProtocol.handler = { request in
            EPGStationLiveURLProtocol.Stub(
                body: Data(),
                redirectURL: URL(string: "http://other.invalid/config")
            )
        }
        do {
            _ = try await client().liveQualities()
            XCTFail("expected redirect rejection")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .redirectRejected)
        }
    }

    func testInvalidIDsFailBeforeNetwork() async throws {
        EPGStationLiveURLProtocol.handler = { _ in
            XCTFail("invalid request reached the network")
            return EPGStationLiveURLProtocol.Stub(status: 500, body: Data())
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let client = try client()
        let quality = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        do {
            _ = try await client.startLiveStream(channelID: 0, quality: quality)
            XCTFail("expected invalid channel")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
        do {
            try await client.keepLiveStream(id: -1)
            XCTFail("expected invalid stream")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
    }

    func testCancellationStopsAnInFlightConfigRequest() async throws {
        EPGStationLiveBlockingURLProtocol.reset()
        defer { EPGStationLiveBlockingURLProtocol.reset() }
        let liveClient = try client(protocolClass: EPGStationLiveBlockingURLProtocol.self)
        let task = Task {
            try await liveClient.liveQualities()
        }
        for _ in 0..<100 {
            if EPGStationLiveBlockingURLProtocol.requestCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(EPGStationLiveBlockingURLProtocol.requestCount(), 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: the transport must not retry after cancellation.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
