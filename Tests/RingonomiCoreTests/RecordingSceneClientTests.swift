import Foundation
import XCTest
@testable import RingonomiCore

final class RecordingSceneClientTests: XCTestCase {
    private let maximumImageBytes = 16 * 1024 * 1024

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingSceneURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client(withToken: Bool = false) throws -> RingonomiClient {
        if withToken {
            return try RingonomiClient(
                address: "https://example.invalid/proxy",
                accessToken: try BackendAccessToken(rawValue: "test-token")
            )
        }
        return try RingonomiClient(address: "https://example.invalid/proxy")
    }

    override func tearDown() {
        RecordingSceneURLProtocol.handler = nil
        RecordingSceneURLProtocol.requests = []
        RecordingSceneURLProtocol.stopCount = 0
        super.tearDown()
    }

    func testFetchesTiledImageThroughAuthenticatedBackendTransport() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try client(withToken: true)
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        RecordingSceneURLProtocol.handler = { request in
            RecordingSceneURLProtocol.Stub(
                headers: [
                    "Content-Type": " Image/PNG ; charset=binary ",
                    "Content-Length": String(image.count)
                ],
                body: image
            )
        }

        let result = try await client.recordingSceneImage(recordingID: 17, using: session)

        XCTAssertEqual(result, image)
        let request = try XCTUnwrap(RecordingSceneURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/proxy/api/videos/17/thumbnail/tiled")
        XCTAssertEqual(request.timeoutInterval, 20, accuracy: 0.001)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testSceneRecordingFetchesBoundedJSONMetadata() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try client(withToken: true)
        let payload = Data(
            #"{"id":17,"title":"番組","description":"説明","is_free":true,"recorded_video":{"id":42,"duration":75.5,"status":"Recorded"}}"#.utf8
        )
        RecordingSceneURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/proxy/api/videos/17")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return RecordingSceneURLProtocol.Stub(
                headers: ["Content-Type": " Application/JSON ; charset=utf-8 "],
                body: payload
            )
        }

        let recording = try await client.recordingSceneRecording(id: 17, using: session)

        XCTAssertEqual(recording.id, 17)
        XCTAssertEqual(recording.recordedVideo.id, 42)
        XCTAssertEqual(recording.recordedVideo.duration, 75.5, accuracy: 0.001)
        XCTAssertEqual(RecordingSceneURLProtocol.requests.count, 1)
    }

    func testSceneRecordingAcceptsMissingJSONContentTypeButRejectsWrongIDAndMalformedPayload() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try client()
        let payload = Data(
            #"{"id":8,"title":"番組","description":"説明","is_free":true,"recorded_video":{"id":42,"duration":10}}"#.utf8
        )
        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(headers: [:], body: payload)
        }
        do {
            _ = try await client.recordingSceneRecording(id: 7, using: session)
            XCTFail("a detail response for another recording must fail")
        } catch let error as RecordingLibraryError {
            XCTAssertEqual(error, .invalidResponse)
        }

        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(headers: [:], body: Data(#"{"id":7}"#.utf8))
        }
        do {
            _ = try await client.recordingSceneRecording(id: 7, using: session)
            XCTFail("malformed recording metadata must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testSceneRecordingRejectsDeclaredAndStreamedMetadataAboveFourMiB() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try client()

        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(
                headers: [
                    "Content-Type": "application/json",
                    "Content-Length": String(4 * 1024 * 1024 + 1)
                ],
                body: Data([1])
            )
        }
        do {
            _ = try await client.recordingSceneRecording(id: 7, using: session)
            XCTFail("declared oversized metadata was accepted")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let oversized = Data(repeating: 0x20, count: 4 * 1024 * 1024 + 1)
        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(
                headers: ["Content-Type": "application/json"],
                body: oversized
            )
        }
        do {
            _ = try await client.recordingSceneRecording(id: 7, using: session)
            XCTFail("streamed oversized metadata was accepted")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testRejectsNonPositiveRecordingIDBeforeNetwork() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try client()
        RecordingSceneURLProtocol.handler = { _ in
            XCTFail("invalid recording IDs must not send a request")
            return RecordingSceneURLProtocol.Stub(body: Data([1]))
        }

        for id in [0, -1] {
            do {
                _ = try await client.recordingSceneImage(recordingID: id, using: session)
                XCTFail("invalid recording ID was accepted")
            } catch let error as RecordingLibraryError {
                XCTAssertEqual(error, .invalidIdentifier)
            }
        }
        XCTAssertTrue(RecordingSceneURLProtocol.requests.isEmpty)
    }

    func testRequiresHTTP200AndSupportedNonEmptyImageContentType() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try client()

        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(status: 206, body: Data([1]))
        }
        do {
            _ = try await client.recordingSceneImage(recordingID: 7, using: session)
            XCTFail("partial content must not be accepted")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }

        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(status: 503, body: Data())
        }
        do {
            _ = try await client.recordingSceneImage(recordingID: 7, using: session)
            XCTFail("server errors must be reported")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .http(503))
        }

        for contentType in ["text/plain", "application/octet-stream", "image/gif"] {
            RecordingSceneURLProtocol.handler = { _ in
                RecordingSceneURLProtocol.Stub(
                    headers: ["Content-Type": contentType],
                    body: Data([1])
                )
            }
            do {
                _ = try await client.recordingSceneImage(recordingID: 7, using: session)
                XCTFail("unsupported content type was accepted: \(contentType)")
            } catch let error as ConnectionError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }

        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(
                headers: ["Content-Type": "image/jpeg"],
                body: Data()
            )
        }
        do {
            _ = try await client.recordingSceneImage(recordingID: 7, using: session)
            XCTFail("empty image was accepted")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testRejectsDeclaredAndStreamedImagesAboveSixteenMiB() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try client()

        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(
                headers: [
                    "Content-Type": "image/webp",
                    "Content-Length": String(self.maximumImageBytes + 1)
                ],
                body: Data([1])
            )
        }
        do {
            _ = try await client.recordingSceneImage(recordingID: 7, using: session)
            XCTFail("declared oversized image was accepted")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let oversized = Data(repeating: 0x01, count: maximumImageBytes + 1)
        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(
                headers: ["Content-Type": "image/png"],
                body: oversized
            )
        }
        do {
            _ = try await client.recordingSceneImage(recordingID: 7, using: session)
            XCTFail("streamed oversized image was accepted")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testCancellationDuringImageStreamIsPreserved() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try client()
        RecordingSceneURLProtocol.handler = { _ in
            RecordingSceneURLProtocol.Stub(
                headers: ["Content-Type": "image/png"],
                body: Data([1]),
                finishLoading: false
            )
        }

        let operation = Task {
            try await client.recordingSceneImage(recordingID: 7, using: session)
        }
        for _ in 0..<100 {
            if !RecordingSceneURLProtocol.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("cancelled image request must throw")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(RecordingSceneURLProtocol.requests.isEmpty)
    }

    func testAuthenticatedCrossOriginRedirectIsRejectedBeforeFollowing() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = try client(withToken: true)
        RecordingSceneURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return RecordingSceneURLProtocol.Stub(
                redirectURL: URL(string: "https://other.invalid/proxy/api/videos/7/thumbnail/tiled")!
            )
        }

        do {
            _ = try await client.recordingSceneImage(recordingID: 7, using: session)
            XCTFail("cross-origin redirect must be rejected")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .redirectRejected)
        }
        XCTAssertEqual(RecordingSceneURLProtocol.requests.count, 1)
    }
}

private final class RecordingSceneURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
        let redirectURL: URL?
        let finishLoading: Bool

        init(
            status: Int = 200,
            headers: [String: String] = ["Content-Type": "image/png"],
            body: Data,
            redirectURL: URL? = nil,
            finishLoading: Bool = true
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.redirectURL = redirectURL
            self.finishLoading = finishLoading
        }

        init(redirectURL: URL) {
            self.init(status: 302, headers: ["Location": redirectURL.absoluteString], body: Data(), redirectURL: redirectURL)
        }
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Stub)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var stopCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
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
        if stub.finishLoading {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.stopCount += 1
    }
}
