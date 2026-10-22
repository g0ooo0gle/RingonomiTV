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

    func testPrepareHLSPollsThroughUnavailableAndEmptyPlaylist() async throws {
        let recorder = EPGStationLiveRequestRecorder()
        EPGStationLiveURLProtocol.handler = { request in
            recorder.append(request)
            let path = request.url?.path
            if path == "/proxy/api/streams/live/42/hls" {
                return EPGStationLiveURLProtocol.Stub(body: Data(#"{"streamId":0}"#.utf8))
            }
            if path == "/proxy/streamfiles/stream0.m3u8" {
                let playlistRequests = recorder.all.filter {
                    $0.url?.path == "/proxy/streamfiles/stream0.m3u8"
                }.count
                switch playlistRequests {
                case 1:
                    return EPGStationLiveURLProtocol.Stub(status: 503, body: Data())
                case 2:
                    return EPGStationLiveURLProtocol.Stub(
                        body: Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n".utf8)
                    )
                default:
                    return EPGStationLiveURLProtocol.Stub(
                        body: Data("#EXTM3U\n#EXTINF:1,\nsegment.ts\n".utf8)
                    )
                }
            }
            return EPGStationLiveURLProtocol.Stub(body: Data())
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let quality = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        let stream = try await client().prepareLiveStream(channelID: 42, quality: quality)

        XCTAssertEqual(stream.streamID, 0)
        XCTAssertEqual(stream.url.path, "/proxy/streamfiles/stream0.m3u8")
        XCTAssertGreaterThanOrEqual(
            recorder.all.filter { $0.url?.path == "/proxy/streamfiles/stream0.m3u8" }.count,
            3
        )
    }

    func testPrepareHLSPropagatesStartHTTPError() async throws {
        EPGStationLiveURLProtocol.handler = { request in
            if request.url?.path == "/proxy/api/streams/live/42/hls" {
                return EPGStationLiveURLProtocol.Stub(status: 401, body: Data())
            }
            XCTFail("preparation must stop after start error")
            return EPGStationLiveURLProtocol.Stub(body: Data())
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let quality = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        do {
            _ = try await client().prepareLiveStream(channelID: 42, quality: quality)
            XCTFail("expected start HTTP error")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .httpStatus(401))
        }
    }

    func testPrepareHLSRejectsMalformedPlaylist() async throws {
        EPGStationLiveURLProtocol.handler = { request in
            if request.url?.path == "/proxy/api/streams/live/42/hls" {
                return EPGStationLiveURLProtocol.Stub(body: Data(#"{"streamId":0}"#.utf8))
            }
            return EPGStationLiveURLProtocol.Stub(body: Data("not an HLS playlist".utf8))
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let quality = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        do {
            _ = try await client().prepareLiveStream(channelID: 42, quality: quality)
            XCTFail("expected malformed playlist")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testPrepareHLSCancellationStopsSlowRequest() async throws {
        EPGStationLiveBlockingURLProtocol.reset()
        defer { EPGStationLiveBlockingURLProtocol.reset() }

        let quality = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        let liveClient = try client(protocolClass: EPGStationLiveBlockingURLProtocol.self)
        let task = Task {
            try await liveClient.prepareLiveStream(channelID: 42, quality: quality)
        }
        for _ in 0..<100 {
            if EPGStationLiveBlockingURLProtocol.requestCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(EPGStationLiveBlockingURLProtocol.requestCount(), 0)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: start or playlist reads must be canceled promptly.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPrepareHLSTimesOutOnPersistentlyEmptyPlaylist() async throws {
        let recorder = EPGStationLiveRequestRecorder()
        EPGStationLiveURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path == "/proxy/api/streams/live/42/hls" {
                return EPGStationLiveURLProtocol.Stub(body: Data(#"{"streamId":0}"#.utf8))
            }
            if request.url?.path == "/proxy/streamfiles/stream0.m3u8" {
                return EPGStationLiveURLProtocol.Stub(
                    body: Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n".utf8)
                )
            }
            return EPGStationLiveURLProtocol.Stub(body: Data())
        }
        defer { EPGStationLiveURLProtocol.handler = nil }

        let quality = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        do {
            _ = try await client().prepareLiveStream(channelID: 42, quality: quality)
            XCTFail("expected preparation timeout")
        } catch let error as EPGStationLivePreparationError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertGreaterThanOrEqual(
            recorder.all.filter { $0.httpMethod == "PUT" }.count,
            1
        )
        // A URLProtocol callback already queued by URLSession can finish
        // after cancellation.  No further polling may continue afterward.
        try await Task.sleep(for: .milliseconds(300))
        let finishedRequestCount = recorder.all.count
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(recorder.all.count, finishedRequestCount)
    }

    func testPrepareHLSContinuesAfterTemporarilyBusyKeep() async throws {
        let recorder = EPGStationLiveRequestRecorder()
        EPGStationLiveURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path == "/proxy/api/streams/live/42/hls" {
                return EPGStationLiveURLProtocol.Stub(body: Data(#"{"streamId":0}"#.utf8))
            }
            if request.httpMethod == "PUT" {
                return EPGStationLiveURLProtocol.Stub(status: 503, body: Data())
            }
            let keepWasAttempted = recorder.all.contains { $0.httpMethod == "PUT" }
            let playlist = keepWasAttempted
                ? "#EXTM3U\n#EXTINF:2,\nsegment.ts\n"
                : "#EXTM3U\n#EXT-X-TARGETDURATION:2\n"
            return EPGStationLiveURLProtocol.Stub(body: Data(playlist.utf8))
        }
        defer { EPGStationLiveURLProtocol.handler = nil }
        let quality = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        let stream = try await client().prepareLiveStream(channelID: 42, quality: quality)
        XCTAssertEqual(stream.streamID, 0)
        XCTAssertEqual(recorder.all.filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testPlaylistReadinessAcceptsByteRangeMetadata() async throws {
        let recorder = EPGStationLiveRequestRecorder()
        EPGStationLiveURLProtocol.handler = { request in
            recorder.append(request)
            if request.url?.path == "/proxy/api/streams/live/42/hls" {
                return EPGStationLiveURLProtocol.Stub(body: Data(#"{"streamId":0}"#.utf8))
            }
            let count = recorder.all.filter { $0.url?.path.hasSuffix(".m3u8") == true }.count
            let playlist = "#EXTM3U\n#EXTINF:2,\n#EXT-X-BYTERANGE:1024@0\n" + (count > 1 ? "segment.ts\n" : "")
            return EPGStationLiveURLProtocol.Stub(body: Data(playlist.utf8))
        }
        defer { EPGStationLiveURLProtocol.handler = nil }
        let quality = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        let stream = try await client().prepareLiveStream(channelID: 42, quality: quality)
        XCTAssertEqual(stream.streamID, 0)
        XCTAssertEqual(recorder.all.filter { $0.url?.path.hasSuffix(".m3u8") == true }.count, 2)
    }

    func testPlaylistReadinessRejectsMissingSegmentBeforeNextSegment() async throws {
        EPGStationLiveURLProtocol.handler = { request in
            let response = request.url?.path == "/proxy/api/streams/live/42/hls"
                ? #"{"streamId":0}"#
                : "#EXTM3U\n#EXTINF:2,\n#EXTINF:2,\nsegment.ts\n"
            return EPGStationLiveURLProtocol.Stub(body: Data(response.utf8))
        }
        defer { EPGStationLiveURLProtocol.handler = nil }
        let quality = try EPGStationLiveQuality(format: .hls, mode: 0, name: "HLS")
        do {
            _ = try await client().prepareLiveStream(channelID: 42, quality: quality)
            XCTFail("expected missing segment error")
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
