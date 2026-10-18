import Foundation
import XCTest
@testable import RingonomiCore

private final class RecordingLibraryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = handler(request)
        client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RecordingLibraryTests: XCTestCase {
    private func clientAndSession() throws -> (RingonomiClient, URLSession) {
        let client = try RingonomiClient(address: "https://example.invalid/proxy")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingLibraryURLProtocol.self]
        return (client, URLSession(configuration: configuration))
    }

    private func authenticatedClientAndSession() throws -> (RingonomiClient, URLSession) {
        let token = try BackendAccessToken(rawValue: "test-token")
        let client = try RingonomiClient(address: "https://example.invalid/proxy", accessToken: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingLibraryURLProtocol.self]
        return (client, URLSession(configuration: configuration))
    }

    private func jsonResponse(
        _ request: URLRequest,
        _ status: Int = 200,
        _ body: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            body
        )
    }

    private func recordingObjectJSON(id: Int = 7, videoID: Int = 42) -> String {
        """
        {
          "id": \(id),
          "title": "ニュース",
          "description": "番組内容",
          "is_free": true,
          "recorded_video": {"id": \(videoID), "duration": 75.5, "status": "Recorded"}
        }
        """
    }

    private func listJSON(total: Int = 1, object: String? = nil) -> Data {
        let object = object ?? recordingObjectJSON()
        return Data("{\"total\":\(total),\"recorded_programs\":[\(object)]}".utf8)
    }

    func testQueryRoutesSearchAndEncodesPageOrderAndKeyword() async throws {
        let (client, session) = try clientAndSession()
        var captured: URLRequest?
        RecordingLibraryURLProtocol.handler = { request in
            captured = request
            return self.jsonResponse(request, 200, self.listJSON())
        }
        defer { RecordingLibraryURLProtocol.handler = nil }

        let response = try await client.recordings(
            query: RecordingQuery(keyword: "番組 & 特番", page: 2, order: .oldest),
            using: session
        )

        let url = try XCTUnwrap(captured?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.path, "/proxy/api/videos/search")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "order", value: "asc"),
            URLQueryItem(name: "query", value: "番組 & 特番")
        ])
        XCTAssertEqual(response.total, 1)
        XCTAssertEqual(response.recordedPrograms.first?.recordedVideo.id, 42)
    }

    func testBackendAuthorizationHeaderIsAppliedToRecordingRoute() async throws {
        let (client, session) = try authenticatedClientAndSession()
        var captured: URLRequest?
        RecordingLibraryURLProtocol.handler = { request in
            captured = request
            return self.jsonResponse(request, 200, Data(#"{"total":0,"recorded_programs":[]}"#.utf8))
        }
        defer { session.invalidateAndCancel(); RecordingLibraryURLProtocol.handler = nil }

        _ = try await client.recordings(using: session)

        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testEmptyKeywordUsesListRouteAndNormalizesInvalidPage() async throws {
        let (client, session) = try clientAndSession()
        var captured: URLRequest?
        RecordingLibraryURLProtocol.handler = { request in
            captured = request
            return self.jsonResponse(request, 200, self.listJSON())
        }
        defer { RecordingLibraryURLProtocol.handler = nil }

        _ = try await client.recordings(
            query: RecordingQuery(keyword: "   ", page: 0, order: .newest),
            using: session
        )

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(captured?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(captured?.url?.path, "/proxy/api/videos")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "order", value: "desc")
        ])
    }

    func testDetailUsesRecordedProgramIDAndPreservesMetadata() async throws {
        let (client, session) = try clientAndSession()
        var captured: URLRequest?
        let object = """
        {
          "id": 7,
          "recorded_video": {"id": 42, "duration": 75.5, "status": "Recorded"},
          "channel": {"id":"NID-SID","display_channel_id":"gr011","name":"NHK","type":"GR","channel_number":"011"},
          "title": "ニュース",
          "series_title": "定時ニュース",
          "subtitle": "夕方",
          "description": "概要",
          "detail": {"番組内容":"詳細"},
          "start_time": "2026-10-18T18:00:00+09:00",
          "end_time": "2026-10-18T18:30:00+09:00",
          "genres": [{"major":"ニュース・報道","middle":"定時"}],
          "is_free": true
        }
        """
        RecordingLibraryURLProtocol.handler = { request in
            captured = request
            return self.jsonResponse(request, 200, Data(object.utf8))
        }
        defer { RecordingLibraryURLProtocol.handler = nil }

        let recording = try await client.recording(id: 7, using: session)

        XCTAssertEqual(captured?.url?.path, "/proxy/api/videos/7")
        XCTAssertEqual(recording.id, 7)
        XCTAssertEqual(recording.recordedVideo.id, 42)
        XCTAssertEqual(recording.channel?.name, "NHK")
        XCTAssertEqual(recording.seriesTitle, "定時ニュース")
        XCTAssertEqual(recording.endTime, "2026-10-18T18:30:00+09:00")
        XCTAssertEqual(recording.detail?["番組内容"], "詳細")
        XCTAssertEqual(recording.genres.first?.major, "ニュース・報道")
    }

    func testDetailRejectsWrongReturnedID() async throws {
        let (client, session) = try clientAndSession()
        RecordingLibraryURLProtocol.handler = { request in
            self.jsonResponse(
                request,
                200,
                Data(self.recordingObjectJSON(id: 8, videoID: 42).utf8)
            )
        }
        defer { RecordingLibraryURLProtocol.handler = nil }

        do {
            _ = try await client.recording(id: 7, using: session)
            XCTFail("a detail response for another recording must fail")
        } catch let error as RecordingLibraryError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testMissingOptionalMetadataRemainsUsable() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = Data(#"{"id":7,"title":"番組","description":"説明","is_free":true,"recorded_video":{"id":42,"duration":10}}"#.utf8)

        let recording = try decoder.decode(Recording.self, from: data)

        XCTAssertEqual(recording.id, 7)
        XCTAssertEqual(recording.title, "番組")
        XCTAssertNil(recording.channel)
        XCTAssertNil(recording.endTime)
        XCTAssertNil(recording.detail)
        XCTAssertEqual(recording.genres, [])
    }

    func testMissingRequiredProgramFieldsFail() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let base = #"{"id":7,"title":"番組","description":"説明","is_free":true,"recorded_video":{"id":42,"duration":10}}"#

        XCTAssertNoThrow(try decoder.decode(Recording.self, from: Data(base.utf8)))
        XCTAssertThrowsError(try decoder.decode(
            Recording.self,
            from: Data(#"{"id":7,"description":"説明","is_free":true,"recorded_video":{"id":42,"duration":10}}"#.utf8)
        ))
        XCTAssertThrowsError(try decoder.decode(
            Recording.self,
            from: Data(#"{"id":7,"title":"番組","is_free":true,"recorded_video":{"id":42,"duration":10}}"#.utf8)
        ))
        XCTAssertThrowsError(try decoder.decode(
            Recording.self,
            from: Data(#"{"id":7,"title":"番組","description":"説明","recorded_video":{"id":42,"duration":10}}"#.utf8)
        ))
    }

    func testMalformedRequiredIDsFail() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        XCTAssertThrowsError(try decoder.decode(
            Recording.self,
            from: Data(#"{"id":0,"title":"番組","description":"説明","is_free":true,"recorded_video":{"id":42,"duration":10}}"#.utf8)
        ))
        XCTAssertThrowsError(try decoder.decode(
            Recording.self,
            from: Data(#"{"id":7,"title":"番組","description":"説明","is_free":true,"recorded_video":{"id":0,"duration":10}}"#.utf8)
        ))
    }

    func testResponseRejectsNegativeTotalsAndPagesOverBackendLimit() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertThrowsError(try decoder.decode(
            RecordingsResponse.self,
            from: Data(#"{"total":-1,"recorded_programs":[]}"#.utf8)
        ))

        let objects = Array(repeating: recordingObjectJSON(), count: RecordingQuery.pageSize + 1)
            .joined(separator: ",")
        let data = Data("{\"total\":31,\"recorded_programs\":[\(objects)]}".utf8)
        XCTAssertThrowsError(try decoder.decode(RecordingsResponse.self, from: data))
    }

    func testResponseRejectsDuplicateRecordingIDs() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let object = recordingObjectJSON(id: 7, videoID: 42)
        let data = Data("{\"total\":2,\"recorded_programs\":[\(object),\(object)]}".utf8)

        XCTAssertThrowsError(try decoder.decode(RecordingsResponse.self, from: data)) { error in
            XCTAssertEqual(error as? RecordingLibraryError, .invalidResponse)
        }
    }

    func testHTTPErrorAndInvalidIdentifierDoNotBecomeSuccess() async throws {
        let (client, session) = try clientAndSession()
        RecordingLibraryURLProtocol.handler = { request in
            self.jsonResponse(request, 404, Data(#"{"detail":"not found"}"#.utf8))
        }
        defer { RecordingLibraryURLProtocol.handler = nil }

        do {
            _ = try await client.recording(id: 0, using: session)
            XCTFail("invalid identifier should fail before HTTP")
        } catch let error as RecordingLibraryError {
            XCTAssertEqual(error, .invalidIdentifier)
        }

        do {
            _ = try await client.recordings(using: session)
            XCTFail("HTTP error should not decode as an empty list")
        } catch let error as ConnectionError {
            guard case .http(let status) = error else {
                return XCTFail("expected HTTP 404, got \(error)")
            }
            XCTAssertEqual(status, 404)
        }
    }
}
