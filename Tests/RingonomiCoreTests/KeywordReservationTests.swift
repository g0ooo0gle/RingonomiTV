import Foundation
import XCTest
@testable import RingonomiCore

private final class KeywordReservationURLProtocol: URLProtocol {
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

final class KeywordReservationTests: XCTestCase {
    private func clientAndSession() throws -> (RingonomiClient, URLSession) {
        let client = try RingonomiClient(address: "https://example.invalid/proxy")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeywordReservationURLProtocol.self]
        return (client, URLSession(configuration: configuration))
    }

    private func jsonResponse(_ request: URLRequest, _ status: Int = 200, _ body: Data = Data()) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!, body)
    }

    private func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func conditionJSON(keyword: String = "NHK") -> Data {
        Data("""
        {
          "id": 7,
          "reservation_count": 2,
          "program_search_condition": {
            "is_enabled": true,
            "keyword": "\(keyword)",
            "exclude_keyword": "再放送",
            "note": "free news",
            "is_title_only": false,
            "is_case_sensitive": false,
            "is_fuzzy_search_enabled": false,
            "is_regex_search_enabled": false,
            "service_ranges": [{
              "network_id": 1,
              "transport_stream_id": 2,
              "service_id": 3,
              "future_service": {"keep": true}
            }],
            "genre_ranges": [{
              "major": "ニュース",
              "middle": "定時",
              "future_genre": [1, "keep"]
            }],
            "is_exclude_genre_ranges": false,
            "date_ranges": [{
              "start_day_of_week": 1,
              "start_hour": 12,
              "start_minute": 0,
              "end_day_of_week": 1,
              "end_hour": 12,
              "end_minute": 10,
              "future_date": "keep"
            }],
            "is_exclude_date_ranges": false,
            "duration_range_min": null,
            "duration_range_max": 600,
            "broadcast_type": "FreeOnly",
            "duplicate_title_check_scope": "None",
            "duplicate_title_check_period_days": 6,
            "future_condition": {"keep": true}
          },
          "record_settings": {}
        }
        """.utf8)
    }

    private func listJSON(keyword: String = "NHK", count: Int = 1) -> Data {
        let item = String(data: conditionJSON(keyword: keyword), encoding: .utf8)!
        let items = Array(repeating: item, count: count).joined(separator: ",")
        return Data("{\"total\":\(count),\"reservation_conditions\":[\(items)]}".utf8)
    }

    private var programSearchResponseJSON: Data {
        Data("""
        {
          "total": 1,
          "programs": [{
            "id": "preview-1",
            "channel_id": "NID1-SID2",
            "network_id": 1,
            "service_id": 2,
            "event_id": 3,
            "title": "日本語ニュース",
            "description": "番組の説明",
            "detail": {"出演者": "司会"},
            "start_time": "2026-10-19T12:00:00+09:00",
            "end_time": "2026-10-19T12:10:00+09:00",
            "duration": 600,
            "is_free": true,
            "genres": [{"major": "ニュース", "middle": "定時"}],
            "video_type": null,
            "video_codec": null,
            "video_resolution": null,
            "primary_audio_type": "ステレオ",
            "primary_audio_language": "日本語",
            "primary_audio_sampling_rate": "48kHz",
            "secondary_audio_type": null,
            "secondary_audio_language": null,
            "secondary_audio_sampling_rate": null
          }]
        }
        """.utf8)
    }

    func testProgramSearchConditionRoundTripsUnknownNestedValues() throws {
        let data = Data("""
        {
          "keyword": "NHK",
          "service_ranges": [{"network_id": 1, "transport_stream_id": 2, "service_id": 3, "future": true}],
          "genre_ranges": [{"major": "ニュース", "middle": "定時", "future_genre": {"keep": true}}],
          "date_ranges": [{"start_day_of_week": 1, "start_hour": 12, "start_minute": 0, "end_day_of_week": 1, "end_hour": 12, "end_minute": 10, "future_date": [1, 2]}],
          "duration_range_min": null,
          "duration_range_max": 600,
          "future_condition": {"keep": true}
        }
        """.utf8)
        let search = try JSONDecoder().decode(ProgramSearchCondition.self, from: data)
        XCTAssertEqual(search.keyword, "NHK")
        XCTAssertEqual(search.broadcastType, "All")
        XCTAssertNil(search.durationRangeMin)
        XCTAssertEqual(search.durationRangeMax, 600)
        XCTAssertEqual(search.serviceRanges?.first?.networkID, 1)
        XCTAssertEqual(search.serviceRanges?.first?.transportStreamID, 2)
        XCTAssertEqual(search.serviceRanges?.first?.serviceID, 3)
        XCTAssertEqual(search.genreRanges?.first?.major, "ニュース")
        XCTAssertEqual(search.dateRanges?.first?.startHour, 12)
        XCTAssertEqual(search.dateRanges?.first?.endMinute, 10)

        let encoded = try JSONEncoder().encode(search)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["broadcast_type"] as? String, "All")
        XCTAssertNotNil(object["future_condition"])
        let services = try XCTUnwrap(object["service_ranges"] as? [[String: Any]])
        XCTAssertEqual(services.first?["future"] as? Bool, true)
        let genres = try XCTUnwrap(object["genre_ranges"] as? [[String: Any]])
        XCTAssertNotNil(genres.first?["future_genre"])
        let dates = try XCTUnwrap(object["date_ranges"] as? [[String: Any]])
        XCTAssertEqual(dates.first?["future_date"] as? [Int], [1, 2])
    }

    func testNewSearchDefaultsFreeOnlyExistingMissingUsesAllAndUnknownIsPreserved() throws {
        XCTAssertEqual(ProgramSearchCondition().broadcastType, "FreeOnly")

        let decoder = JSONDecoder()
        let missing = try decoder.decode(ProgramSearchCondition.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.broadcastType, "All")

        let unknown = try decoder.decode(
            ProgramSearchCondition.self,
            from: Data("{\"broadcast_type\":\"FutureBroadcast\"}".utf8)
        )
        XCTAssertEqual(unknown.broadcastType, "FutureBroadcast")
        XCTAssertEqual(unknown.rawValues["broadcast_type"], .string("FutureBroadcast"))
    }

    func testServiceRangeTypedSetterPreservesContract() throws {
        var search = ProgramSearchCondition()
        search.serviceRanges = [ProgramSearchService(networkID: 10, transportStreamID: 20, serviceID: 30)]
        XCTAssertEqual(search.serviceRanges?.first?.networkId, 10)
        XCTAssertEqual(search.serviceRanges?.first?.transportStreamID, 20)
        search.serviceRanges = nil
        XCTAssertNil(search.serviceRanges)
        XCTAssertEqual(search.rawValues["service_ranges"], .null)
    }

    func testSearchProgramsPostsConditionAndDecodesJapanesePreview() async throws {
        let (client, session) = try clientAndSession()
        var captured: [URLRequest] = []
        let lock = NSLock()
        KeywordReservationURLProtocol.handler = { request in
            lock.lock(); captured.append(request); lock.unlock()
            return self.jsonResponse(request, 200, self.programSearchResponseJSON)
        }
        defer { KeywordReservationURLProtocol.handler = nil }

        var condition = ProgramSearchCondition()
        condition.keyword = "NHK"
        let response = try await client.searchPrograms(condition: condition, using: session)
        XCTAssertEqual(response.total, 1)
        XCTAssertEqual(response.programs.first?.title, "日本語ニュース")
        XCTAssertEqual(response.programs.first?.detail["出演者"], "司会")
        XCTAssertTrue(response.programs.first?.isFree == true)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.httpMethod, "POST")
        XCTAssertEqual(captured.first?.url?.path, "/proxy/api/programs/search")
        let body = try XCTUnwrap(captured.first.flatMap(requestBody))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["keyword"] as? String, "NHK")
        XCTAssertNil(object["program_search_condition"])
    }

    func testSearchProgramsRejectsMalformedResponse() async throws {
        let (client, session) = try clientAndSession()
        KeywordReservationURLProtocol.handler = { request in
            self.jsonResponse(request, 200, Data("{\"total\":1}".utf8))
        }
        defer { KeywordReservationURLProtocol.handler = nil }

        do {
            _ = try await client.searchPrograms(condition: ProgramSearchCondition(), using: session)
            XCTFail("missing programs must fail as an invalid response")
        } catch let error as ReservationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testMalformedKeywordConditionIsRejectedStrictly() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let zeroID = Data("{\"id\":0,\"reservation_count\":0,\"program_search_condition\":{},\"record_settings\":{}}".utf8)
        XCTAssertThrowsError(try decoder.decode(ReservationCondition.self, from: zeroID))

        let negativeCount = Data("{\"id\":1,\"reservation_count\":-1,\"program_search_condition\":{},\"record_settings\":{}}".utf8)
        XCTAssertThrowsError(try decoder.decode(ReservationCondition.self, from: negativeCount))

        let missingSearch = Data("{\"id\":1,\"reservation_count\":0,\"record_settings\":{}}".utf8)
        XCTAssertThrowsError(try decoder.decode(ReservationCondition.self, from: missingSearch))

        let missingSettings = Data("{\"id\":1,\"reservation_count\":0,\"program_search_condition\":{}}".utf8)
        XCTAssertThrowsError(try decoder.decode(ReservationCondition.self, from: missingSettings))

        let negativeTotal = Data("{\"total\":-1,\"reservation_conditions\":[]}".utf8)
        XCTAssertThrowsError(try decoder.decode(ReservationConditions.self, from: negativeTotal))
    }

    func testClientUsesExactKeywordReservationMethodsAndBodies() async throws {
        let (client, session) = try clientAndSession()
        var requests: [URLRequest] = []
        let lock = NSLock()
        KeywordReservationURLProtocol.handler = { request in
            lock.lock(); requests.append(request); lock.unlock()
            if request.httpMethod == "GET" && request.url?.path.hasSuffix("/7") == true {
                return self.jsonResponse(request, 200, self.conditionJSON())
            }
            if request.httpMethod == "GET" {
                return self.jsonResponse(request, 200, self.listJSON())
            }
            if request.httpMethod == "DELETE" { return self.jsonResponse(request, 204) }
            return self.jsonResponse(request, 200, self.conditionJSON())
        }
        defer { KeywordReservationURLProtocol.handler = nil }

        let list = try await client.keywordReservations(using: session)
        XCTAssertEqual(list.total, 1)
        let fetched = try await client.keywordReservation(id: 7, using: session)
        XCTAssertEqual(fetched.id, 7)
        let search = fetched.programSearchCondition
        _ = try await client.addKeywordReservation(search: search, settings: fetched.recordSettings, using: session)
        _ = try await client.updateKeywordReservation(id: 7, search: search, settings: fetched.recordSettings, using: session)
        try await client.deleteKeywordReservation(id: 7, using: session)

        let captured = requests
        XCTAssertEqual(captured.map(\.httpMethod), ["GET", "GET", "POST", "PUT", "DELETE"])
        XCTAssertEqual(captured[2].url?.path, "/proxy/api/recording/conditions")
        XCTAssertEqual(captured[3].url?.path, "/proxy/api/recording/conditions/7")
        let post = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requestBody(captured[2]))) as? [String: Any])
        XCTAssertEqual(post.keys.sorted(), ["program_search_condition", "record_settings"])
        let put = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requestBody(captured[3]))) as? [String: Any])
        XCTAssertEqual(put.keys.sorted(), ["program_search_condition", "record_settings"])
    }

    func testAddNull201ReadsBackUniqueSearchWithoutRetryingPOST() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let search = try decoder.decode(ReservationCondition.self, from: conditionJSON()).programSearchCondition
        KeywordReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" { return self.jsonResponse(request, 201, Data(" \nnull\n".utf8)) }
            return self.jsonResponse(request, 200, self.listJSON(keyword: "NHK"))
        }
        defer { KeywordReservationURLProtocol.handler = nil }

        let created = try await client.addKeywordReservation(search: search, using: session)
        XCTAssertEqual(created.id, 7)
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testAddNull201WithMultipleMatchingSearchAndSettingsIsOutcomeUnknown() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let condition = try decoder.decode(ReservationCondition.self, from: conditionJSON())
        KeywordReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" { return self.jsonResponse(request, 201, Data("null".utf8)) }
            return self.jsonResponse(request, 200, self.listJSON(keyword: condition.programSearchCondition.keyword, count: 2))
        }
        defer { KeywordReservationURLProtocol.handler = nil }

        do {
            _ = try await client.addKeywordReservation(
                search: condition.programSearchCondition,
                settings: condition.recordSettings,
                using: session
            )
            XCTFail("multiple matching keyword conditions must not identify the POST result")
        } catch let error as ReservationError {
            XCTAssertEqual(error, .outcomeUnknown)
        }
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testAddNull201DoesNotAcceptSearchOnlyMatchWithDifferentSettings() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let condition = try decoder.decode(ReservationCondition.self, from: conditionJSON())
        var differentSettings = condition.recordSettings
        differentSettings.priority += 1
        KeywordReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" { return self.jsonResponse(request, 201, Data("null".utf8)) }
            return self.jsonResponse(request, 200, self.listJSON(keyword: condition.programSearchCondition.keyword))
        }
        defer { KeywordReservationURLProtocol.handler = nil }

        do {
            _ = try await client.addKeywordReservation(
                search: condition.programSearchCondition,
                settings: differentSettings,
                using: session
            )
            XCTFail("a search-only match with different settings must not be accepted")
        } catch let error as ReservationError {
            XCTAssertEqual(error, .emptyCreatedReservation)
        }
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testAddDuplicateSearchCannotBeResolvedFromNull201() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        let search = ProgramSearchCondition(rawValues: ["keyword": .string("NHK")])
        KeywordReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" { return self.jsonResponse(request, 201, Data("null".utf8)) }
            return self.jsonResponse(request, 200, self.listJSON(keyword: "NHK", count: 2))
        }
        defer { KeywordReservationURLProtocol.handler = nil }

        do {
            _ = try await client.addKeywordReservation(search: search, using: session)
            XCTFail("duplicate search conditions must not be guessed")
        } catch let error as ReservationError {
            XCTAssertEqual(error, .emptyCreatedReservation)
        }
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testAddMalformed201ObjectFailsWithoutReadback() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        KeywordReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return self.jsonResponse(request, 201, Data("{\"unexpected\":true}".utf8))
        }
        defer { KeywordReservationURLProtocol.handler = nil }

        do {
            _ = try await client.addKeywordReservation(search: ProgramSearchCondition(), using: session)
            XCTFail("malformed condition object must not be treated as an empty 201")
        } catch let error as ReservationError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(methods, ["POST"])
    }

    func testUpdateNullSuccessReadsBackByID() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        KeywordReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "PUT" { return self.jsonResponse(request, 200, Data("null".utf8)) }
            return self.jsonResponse(request, 200, self.conditionJSON())
        }
        defer { KeywordReservationURLProtocol.handler = nil }

        let updated = try await client.updateKeywordReservation(
            id: 7,
            search: ProgramSearchCondition(rawValues: ["keyword": .string("NHK")]),
            settings: RecordSettings(),
            using: session
        )
        XCTAssertEqual(updated.id, 7)
        XCTAssertEqual(methods, ["PUT", "GET"])
    }

    func testMalformedListAndHTTPErrorDoNotBecomeSuccess() async throws {
        let (client, session) = try clientAndSession()
        KeywordReservationURLProtocol.handler = { request in
            self.jsonResponse(request, 200, Data("{\"total\":1}".utf8))
        }
        defer { KeywordReservationURLProtocol.handler = nil }
        do {
            _ = try await client.keywordReservations(using: session)
            XCTFail("missing reservation_conditions must fail")
        } catch let error as ReservationError {
            XCTAssertEqual(error, .invalidResponse)
        }

        KeywordReservationURLProtocol.handler = { request in
            self.jsonResponse(request, 403, Data("{\"detail\":\"自動予約権限がありません\"}".utf8))
        }
        do {
            _ = try await client.keywordReservations(using: session)
            XCTFail("expected HTTP error")
        } catch let error as ReservationError {
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertTrue(error.localizedDescription.contains("権限"))
            XCTAssertTrue(error.localizedDescription.contains("HTTP 403"))
            XCTAssertFalse(error.localizedDescription.contains("自動予約権限がありません"))
        }
    }
}
