import Foundation
import XCTest
@testable import RingonomiCore

private final class LiveChannelClientURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: Data
        let contentLength: String?

        init(status: Int = 200, body: Data, contentLength: String? = nil) {
            self.status = status
            self.body = body
            self.contentLength = contentLength
        }
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Stub)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.requests.append(request)
        let stub = handler(request)
        var headers = ["Content-Type": "application/json"]
        if let contentLength = stub.contentLength {
            headers["Content-Length"] = contentLength
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.status,
                  httpVersion: nil,
                  headerFields: headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LiveChannelClientTests: XCTestCase {
    func testChannelsUsesGETAndRetainsOptionalBroadcastMetadata() async throws {
        let payload = Data(
            #"{"GR":[{"id":"one","display_channel_id":"gr011","name":"地上波","type":"GR","channel_number":"011","is_watchable":true,"is_display":true}],"BS":[{"id":"two","display_channel_id":"bs101","name":"衛星","is_watchable":true,"is_display":true}],"UNKNOWN":[{"id":"ignored","display_channel_id":"other","name":"未使用","is_watchable":true,"is_display":true}]}"#.utf8
        )
        LiveChannelClientURLProtocol.requests = []
        LiveChannelClientURLProtocol.handler = { _ in LiveChannelClientURLProtocol.Stub(body: payload) }
        defer { LiveChannelClientURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveChannelClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = try RingonomiClient(address: "http://example.invalid/proxy")
        let channels = try await client.channels(using: session)

        XCTAssertEqual(channels.map(\.displayChannelId), ["gr011", "bs101"])
        XCTAssertEqual(channels[0].type, "GR")
        XCTAssertEqual(channels[0].channelNumber, "011")
        XCTAssertNil(channels[1].type)
        XCTAssertNil(channels[1].channelNumber)
        let request = try XCTUnwrap(LiveChannelClientURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/proxy/api/channels")
        XCTAssertNil(request.url?.query)
    }

    func testChannelsRejectsTooManyDecodedEntriesInsteadOfTruncating() async throws {
        let channel: [String: Any] = [
            "id": "one", "display_channel_id": "gr011", "name": "地上波",
            "is_watchable": true, "is_display": true
        ]
        let groups: [String: Any] = ["GR": Array(repeating: channel, count: 4097)]
        let payload = try JSONSerialization.data(withJSONObject: groups)
        LiveChannelClientURLProtocol.handler = { _ in LiveChannelClientURLProtocol.Stub(body: payload) }
        defer { LiveChannelClientURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveChannelClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = try RingonomiClient(address: "http://example.invalid/proxy")

        do {
            _ = try await client.channels(using: session)
            XCTFail("the bounded response must be rejected")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testChannelsRequireHTTP200AndMapServerErrors() async throws {
        let payload = Data(#"{"GR":[]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveChannelClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = try RingonomiClient(address: "http://example.invalid/proxy")
        defer { LiveChannelClientURLProtocol.handler = nil }

        LiveChannelClientURLProtocol.handler = { _ in
            LiveChannelClientURLProtocol.Stub(status: 206, body: payload)
        }
        do {
            _ = try await client.channels(using: session)
            XCTFail("partial content must not be accepted as a channel list")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }

        LiveChannelClientURLProtocol.handler = { _ in
            LiveChannelClientURLProtocol.Stub(status: 503, body: Data())
        }
        do {
            _ = try await client.channels(using: session)
            XCTFail("server errors must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .http(503))
        }
    }

    func testChannelsRejectsDeclaredAndStreamedOversizeResponses() async throws {
        let small = Data(#"{"GR":[]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveChannelClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = try RingonomiClient(address: "http://example.invalid/proxy")
        defer { LiveChannelClientURLProtocol.handler = nil }

        LiveChannelClientURLProtocol.handler = { _ in
            LiveChannelClientURLProtocol.Stub(
                body: small,
                contentLength: String(4 * 1024 * 1024 + 1)
            )
        }
        do {
            _ = try await client.channels(using: session)
            XCTFail("declared oversized response must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let oversized = Data(repeating: 0x20, count: 4 * 1024 * 1024 + 1)
        LiveChannelClientURLProtocol.handler = { _ in
            // No Content-Length header: the streaming byte bound must still
            // reject the response rather than truncating it.
            LiveChannelClientURLProtocol.Stub(body: oversized)
        }
        do {
            _ = try await client.channels(using: session)
            XCTFail("streamed oversized response must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testChannelsMapsMalformedJSONToInvalidResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveChannelClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = try RingonomiClient(address: "http://example.invalid/proxy")
        defer { LiveChannelClientURLProtocol.handler = nil }
        LiveChannelClientURLProtocol.handler = { _ in
            LiveChannelClientURLProtocol.Stub(body: Data(#"{"GR":}"#.utf8))
        }

        do {
            _ = try await client.channels(using: session)
            XCTFail("malformed JSON must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testChannelsRejectsIdentifiersThatCannotBePlayedOrSaved() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveChannelClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); LiveChannelClientURLProtocol.handler = nil }
        let client = try RingonomiClient(address: "http://example.invalid/")
        for identifier in ["", " gr011", "gr011 ", "gr/011", String(repeating: "a", count: 129)] {
            let payload = try JSONSerialization.data(withJSONObject: ["GR": [[
                "id": "sample", "display_channel_id": identifier, "name": "テスト",
                "is_watchable": true, "is_display": true
            ]]])
            LiveChannelClientURLProtocol.handler = { _ in
                LiveChannelClientURLProtocol.Stub(body: payload)
            }
            do {
                _ = try await client.channels(using: session)
                XCTFail("invalid display identifier must fail before playback or persistence")
            } catch let error as ConnectionError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }
}
