import Foundation
import XCTest
@testable import RingonomiCore

final class RecordedCommentsClientTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordedCommentsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testUsesRecordedProgramIDAndDecodesFileRelativeTime() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); RecordedCommentsURLProtocol.handler = nil }
        let client = try RingonomiClient(address: "https://example.invalid/proxy/")
        RecordedCommentsURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/proxy/api/videos/7/jikkyo")
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], Data(##"{"is_success":true,"comments":[{"time":12.345678,"type":"right","size":"medium","color":"#FFEAEA","author":"example","text":"実況"}],"detail":"ok"}"##.utf8))
        }
        let response = try await client.recordedComments(recordingID: 7, using: session)
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.comments.count, 1)
        XCTAssertEqual(response.comments.first?.time ?? 0, 12.345678, accuracy: 0.000001)
    }

    func testUnavailableCommentsAreSeparateFromHTTPFailure() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); RecordedCommentsURLProtocol.handler = nil }
        let client = try RingonomiClient(address: "https://example.invalid")
        RecordedCommentsURLProtocol.handler = { _ in
            (200, [:], Data(##"{"is_success":false,"comments":[],"detail":"過去ログはまだありません"}"##.utf8))
        }
        let response = try await client.recordedComments(recordingID: 7, using: session)
        XCTAssertFalse(response.isSuccess)
        XCTAssertTrue(response.comments.isEmpty)

        RecordedCommentsURLProtocol.handler = { _ in (503, [:], Data()) }
        do {
            _ = try await client.recordedComments(recordingID: 7, using: session)
            XCTFail("HTTP failure must remain distinguishable from an empty log")
        } catch let error as ConnectionError {
            guard case .http(503) = error else { return XCTFail("unexpected HTTP error") }
        }
    }

    func testRejectsOversizedTransferBeforeDecodingAndInvalidIDsBeforeRequest() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); RecordedCommentsURLProtocol.handler = nil }
        let client = try RingonomiClient(address: "https://example.invalid")
        RecordedCommentsURLProtocol.handler = { _ in
            (200, ["Content-Length": "20971521"], Data())
        }
        do {
            _ = try await client.recordedComments(recordingID: 7, using: session)
            XCTFail("large replies must not be buffered")
        } catch let error as RecordedCommentsRequestError {
            XCTAssertEqual(error, .responseTooLarge)
        }
        RecordedCommentsURLProtocol.handler = { _ in
            XCTFail("invalid IDs must not send a request")
            return (500, [:], Data())
        }
        do {
            _ = try await client.recordedComments(recordingID: 0, using: session)
            XCTFail("invalid recording ID")
        } catch let error as RecordedCommentsRequestError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
    }
}

private final class RecordedCommentsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (code, headers, data) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
