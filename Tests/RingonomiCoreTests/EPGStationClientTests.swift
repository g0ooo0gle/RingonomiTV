import Foundation
import XCTest
@testable import RingonomiCore

private final class EPGStationURLProtocol: URLProtocol {
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
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        guard let requestURL = request.url,
              let response = HTTPURLResponse(
                  url: requestURL,
                  statusCode: stub.status,
                  httpVersion: nil,
                  headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let redirectURL = stub.redirectURL {
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: redirectURL),
                redirectResponse: response
            )
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class EPGStationBlockingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stopped = false

    static func reset() {
        lock.lock()
        stopped = false
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
        // Keep the response open without occupying URLProtocol's callback
        // thread.  Cancellation calls stopLoading on the session's side.
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stopped = true
        Self.lock.unlock()
    }
}

private final class EPGStationRequestRecorder: @unchecked Sendable {
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

final class EPGStationClientTests: XCTestCase {
    private func client(
        address: String = "http://example.invalid/proxy",
        protocolClass: URLProtocol.Type = EPGStationURLProtocol.self,
        additionalHeaders: [String: String]? = nil
    ) throws -> EPGStationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        if let additionalHeaders {
            configuration.httpAdditionalHeaders = additionalHeaders.reduce(into: [AnyHashable: Any]()) {
                $0[AnyHashable($1.key)] = $1.value
            }
        }
        return try EPGStationClient(
            address: address,
            sessionConfiguration: configuration
        )
    }

    private func recordingObjectJSON() -> String {
        """
        {
          "id": 11,
          "channelId": 2,
          "startAt": 1700000000000,
          "endAt": 1700003600000,
          "name": "番組",
          "description": "詳細\\n次の行\\t項目",
          "extended": "拡張\\r\\n補足",
          "isRecording": false,
          "isEncoding": false,
          "isProtected": true,
          "videoFiles": [
            {"id": 101, "name": "TS", "filename": "record.ts", "type": "ts", "size": 123},
            {"id": 102, "name": "将来形式", "type": "future", "size": 0}
          ]
        }
        """
    }

    private func recordingPageJSON(
        records: String? = nil,
        total: Int = 3
    ) -> Data {
        let records = records ?? "[\(recordingObjectJSON())]"
        return Data("{\"records\":\(records),\"total\":\(total)}".utf8)
    }

    private func recordingDetailJSON() -> Data {
        Data(recordingObjectJSON().utf8)
    }

    func testRecordingsBuildExpectedQueryAndDecodeUnknownFileType() async throws {
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            return EPGStationURLProtocol.Stub(body: self.recordingPageJSON())
        }
        defer { EPGStationURLProtocol.handler = nil }

        let client = try client(
            additionalHeaders: [
                "Authorization": "secret-token",
                "Cookie": "secret-cookie",
                "X-Test": "kept"
            ]
        )
        let page = try await client.recordings(
            offset: 10,
            limit: 25,
            keyword: " ニュース ",
            isReverse: false
        )

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/proxy/api/recorded")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        let queryItems = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(query["isHalfWidth"], "true")
        XCTAssertEqual(query["offset"], "10")
        XCTAssertEqual(query["limit"], "25")
        XCTAssertEqual(query["keyword"], "ニュース")
        XCTAssertEqual(query["isReverse"], "false")

        let recording = try XCTUnwrap(page.records.first)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(recording.id, 11)
        XCTAssertEqual(recording.channelID, 2)
        XCTAssertEqual(recording.startAt, 1_700_000_000_000)
        XCTAssertEqual(recording.description, "詳細\n次の行\t項目")
        XCTAssertEqual(recording.extended, "拡張\r\n補足")
        XCTAssertEqual(recording.videoFiles.count, 2)
        XCTAssertEqual(recording.videoFiles[0].id, 101)
        XCTAssertEqual(recording.videoFiles[1].type, "future")
        XCTAssertNil(recording.videoFiles[1].filename)
    }

    func testRecordingDetailAndVideoEndpointsKeepIDsSeparate() async throws {
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            guard let path = request.url?.path else {
                return EPGStationURLProtocol.Stub(status: 500, body: Data())
            }
            if path.hasSuffix("/duration") {
                return EPGStationURLProtocol.Stub(body: Data(#"{"duration":321.5}"#.utf8))
            }
            return EPGStationURLProtocol.Stub(body: self.recordingDetailJSON())
        }
        defer { EPGStationURLProtocol.handler = nil }

        let client = try client()
        let recording = try await client.recording(id: 11)
        XCTAssertEqual(recording.id, 11)
        let videoURL = try client.videoURL(fileID: 101)
        XCTAssertEqual(videoURL.absoluteString, "http://example.invalid/proxy/api/videos/101")
        let duration = try await client.videoDuration(fileID: 101)
        XCTAssertEqual(duration, 321.5)

        let requests = recorder.all
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/proxy/api/recorded/11")
        XCTAssertEqual(requests[0].url?.query, "isHalfWidth=true")
        XCTAssertEqual(requests[1].url?.path, "/proxy/api/videos/101/duration")
        XCTAssertEqual(requests[1].url?.query, nil)
        XCTAssertNotEqual(recording.id, 101)
    }

    func testOptionalRecordingFieldsAndVideoFilesMayBeMissing() throws {
        let payload = Data(
            #"{"id":12,"channelId":2,"startAt":1700000000000,"endAt":1700000001000,"name":"最小","isRecording":false,"isEncoding":false,"isProtected":false}"#.utf8
        )
        let recording = try JSONDecoder().decode(EPGStationRecording.self, from: payload)
        XCTAssertNil(recording.description)
        XCTAssertNil(recording.extended)
        XCTAssertTrue(recording.videoFiles.isEmpty)
    }

    func testDescriptionRejectsNULWhileAllowingHumanLineBreaks() throws {
        let payload = Data(
            #"{"id":12,"channelId":2,"startAt":1700000000000,"endAt":1700000001000,"name":"最小","description":"不正\u0000文字","isRecording":false,"isEncoding":false,"isProtected":false}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(EPGStationRecording.self, from: payload)) { error in
            XCTAssertEqual(error as? EPGStationError, .invalidResponse)
        }
    }

    func testInitializerPreservesPathPrefixAndRejectsUnsafeAddressAndIDs() throws {
        let client = try EPGStationClient(address: "HTTPS://example.invalid/proxy///")
        XCTAssertEqual(client.baseURL.absoluteString, "https://example.invalid/proxy/")
        XCTAssertEqual(
            try client.videoURL(fileID: 101).absoluteString,
            "https://example.invalid/proxy/api/videos/101"
        )

        let invalidAddresses = [
            "ftp://example.invalid",
            "http://user:password@example.invalid",
            "http://example.invalid/proxy?token=secret",
            "http://example.invalid/proxy#fragment",
            "http://example.invalid/proxy/../api",
            "http://example.invalid/proxy/%2e%2e",
            "http://example.invalid/proxy/%252e%252e",
            "http://example.invalid/proxy/%2fescape",
            "http://example.invalid/proxy/%00",
            "http://example.invalid:0",
            "http://example.invalid:65536"
        ]
        for address in invalidAddresses {
            XCTAssertThrowsError(try EPGStationClient(address: address)) { error in
                XCTAssertEqual(error as? EPGStationError, .invalidAddress)
            }
        }

        XCTAssertThrowsError(try client.videoURL(fileID: 0)) { error in
            XCTAssertEqual(error as? EPGStationError, .invalidIdentifier)
        }
        XCTAssertThrowsError(try client.videoURL(fileID: -1)) { error in
            XCTAssertEqual(error as? EPGStationError, .invalidIdentifier)
        }
    }

    func testPaginationLimitsAndDuplicateIDsAreRejected() async throws {
        let client = try client()
        do {
            _ = try await client.recordings(offset: -1)
            XCTFail("negative offset must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidRequest)
        }
        do {
            _ = try await client.recordings(limit: 0)
            XCTFail("zero limit must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidRequest)
        }

        EPGStationURLProtocol.handler = { _ in
            let one = self.recordingObjectJSON()
            return EPGStationURLProtocol.Stub(
                body: Data("{\"records\":[\(one),\(one)],\"total\":2}".utf8)
            )
        }
        defer { EPGStationURLProtocol.handler = nil }

        do {
            _ = try await client.recordings(limit: 2)
            XCTFail("duplicate recording IDs must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }

        EPGStationURLProtocol.handler = { _ in
            let one = self.recordingObjectJSON()
            let two = one.replacingOccurrences(of: "\"id\": 11", with: "\"id\": 12")
            return EPGStationURLProtocol.Stub(
                body: Data("{\"records\":[\(one),\(two)],\"total\":2}".utf8)
            )
        }
        do {
            _ = try await client.recordings(limit: 1)
            XCTFail("a page larger than the requested limit must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testHTTPStatusMalformedAndOversizedResponsesMapToSafeErrors() async throws {
        let client = try client()
        defer { EPGStationURLProtocol.handler = nil }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(
                status: 503,
                body: Data(#"{"secret":"must not appear"}"#.utf8)
            )
        }
        do {
            _ = try await client.recordings()
            XCTFail("HTTP failure must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .httpStatus(503))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(body: Data(#"{"broken":}"#.utf8))
        }
        do {
            _ = try await client.recordings()
            XCTFail("malformed JSON must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(
                body: Data(repeating: 0x20, count: EPGStationClient.maximumResponseBytes + 1)
            )
        }
        do {
            _ = try await client.recordings()
            XCTFail("oversized response must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testRedirectIsRejectedWithoutFollowingIt() async throws {
        let client = try client()
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            return EPGStationURLProtocol.Stub(
                status: 302,
                headers: ["Location": "https://other.invalid/api/recorded"],
                body: Data(),
                redirectURL: URL(string: "https://other.invalid/api/recorded")
            )
        }
        defer { EPGStationURLProtocol.handler = nil }

        do {
            _ = try await client.recordings()
            XCTFail("redirect must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .redirectRejected)
        }
        XCTAssertEqual(recorder.all.count, 1)
    }

    func testCancellationStopsAnInFlightResponse() async throws {
        let client = try client(protocolClass: EPGStationBlockingURLProtocol.self)
        EPGStationBlockingURLProtocol.reset()
        defer { EPGStationBlockingURLProtocol.reset() }

        let task = Task { () -> Bool in
            do {
                _ = try await client.recordings()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
    }
}
