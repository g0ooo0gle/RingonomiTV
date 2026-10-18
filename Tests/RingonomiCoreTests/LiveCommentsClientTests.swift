import Foundation
import XCTest
@testable import RingonomiCore

final class LiveCommentsClientTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveCommentsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testBackendPrefixAndExplicitResponseKeys() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); LiveCommentsURLProtocol.handler = nil }
        let token = try BackendAccessToken(rawValue: "test-token")
        let client = try RingonomiClient(address: "https://example.invalid/proxy/tv/", accessToken: token)
        var authorization: String?
        LiveCommentsURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/proxy/api/channels/gr011/jikkyo")
            XCTAssertEqual(request.httpMethod, "GET")
            authorization = request.value(forHTTPHeaderField: "Authorization")
            return (200, [:], Data(#"{"watch_session_url":"wss://example.invalid/watch","comment_session_url":"wss://example.invalid/comment","is_nxjikkyo_exclusive":false}"#.utf8))
        }
        let info = try await client.liveComments(channelID: "gr011", using: session)
        XCTAssertEqual(authorization, "Bearer test-token")
        XCTAssertEqual(info.watchSessionURL?.path, "/watch")
        XCTAssertEqual(info.commentSessionURL?.path, "/comment")
        XCTAssertFalse(info.isNXJikkyoExclusive)
    }

    func testUnsupportedChannelAndHTTPFailureRemainDistinct() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); LiveCommentsURLProtocol.handler = nil }
        let client = try RingonomiClient(address: "https://example.invalid")
        LiveCommentsURLProtocol.handler = { _ in
            (200, [:], Data(#"{"watch_session_url":null,"comment_session_url":null,"is_nxjikkyo_exclusive":false}"#.utf8))
        }
        let info = try await client.liveComments(channelID: "gr011", using: session)
        XCTAssertNil(info.watchSessionURL)
        LiveCommentsURLProtocol.handler = { _ in (503, [:], Data()) }
        do {
            _ = try await client.liveComments(channelID: "gr011", using: session)
            XCTFail("HTTP failures must remain retryable")
        } catch ConnectionError.http(503) { }
    }

    func testBoundsBothDeclaredAndChunkedResponse() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); LiveCommentsURLProtocol.handler = nil }
        let client = try RingonomiClient(address: "https://example.invalid")
        for declaredLength in [true, false] {
            LiveCommentsURLProtocol.handler = { _ in
                (200, declaredLength ? ["Content-Length": "65537"] : [:],
                 declaredLength ? Data() : Data(repeating: 32, count: 65537))
            }
            do {
                _ = try await client.liveComments(channelID: "gr011", using: session)
                XCTFail("oversized replies must stop before decoding")
            } catch LiveCommentsRequestError.responseTooLarge { }
        }
    }

    func testRejectsInvalidChannelBeforeNetwork() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); LiveCommentsURLProtocol.handler = nil }
        LiveCommentsURLProtocol.handler = { _ in XCTFail("invalid channel sent to server"); return (500, [:], Data()) }
        let client = try RingonomiClient(address: "https://example.invalid")
        for id in ["", "../other", "gr011?token=example", String(repeating: "x", count: 129)] {
            do {
                _ = try await client.liveComments(channelID: id, using: session)
                XCTFail("invalid channel accepted")
            } catch LiveCommentsRequestError.invalidChannel { }
        }
    }
}

private final class LiveCommentsURLProtocol: URLProtocol, @unchecked Sendable {
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
