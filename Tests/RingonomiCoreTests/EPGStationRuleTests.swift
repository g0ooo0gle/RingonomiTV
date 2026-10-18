import Foundation
import XCTest
@testable import RingonomiCore

private final class RuleURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: Data

        init(status: Int = 200, body: Data) {
            self.status = status
            self.body = body
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
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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

private final class RuleRequestRecorder: @unchecked Sendable {
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

final class EPGStationRuleTests: XCTestCase {
    private func client() throws -> EPGStationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuleURLProtocol.self]
        return try EPGStationClient(
            address: "http://example.invalid/epg",
            sessionConfiguration: configuration
        )
    }

    private func ruleJSON(id: Int = 17, keyword: String = "ニュース") -> String {
        """
        {
          "id": \(id),
          "reservesCnt": 2,
          "isTimeSpecification": false,
          "searchOption": {
            "keyword": "\(keyword)",
            "name": true,
            "channelIds": [2],
            "times": [{"start": 10, "range": 2, "week": 127}],
            "futureSearchField": {"keep": true}
          },
          "reserveOption": {
            "enable": true,
            "allowEndLack": false,
            "avoidDuplicate": true,
            "tags": [5]
          },
          "saveOption": {"directory": "番組"},
          "encodeOption": {"isDeleteOriginalAfterEncode": false},
          "futureRuleField": "keep"
        }
        """
    }

    private func ruleOptions() -> EPGStationRuleOptions {
        EPGStationRuleOptions(rawValues: [
            "isTimeSpecification": .bool(false),
            "searchOption": .object([
                "keyword": .string("ニュース"),
                "name": .bool(true),
                "channelIds": .array([.integer(2)]),
                "times": .array([
                    .object(["start": .integer(10), "range": .integer(2), "week": .integer(127)])
                ])
            ]),
            "reserveOption": .object([
                "enable": .bool(true),
                "allowEndLack": .bool(false),
                "avoidDuplicate": .bool(true),
                "tags": .array([.integer(5)])
            ]),
            "saveOption": .object(["directory": .string("番組")]),
            "encodeOption": .object(["isDeleteOriginalAfterEncode": .bool(false)]),
            "futureRuleField": .string("preserve")
        ])
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let body: Data
        if let httpBody = request.httpBody {
            body = httpBody
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            body = result
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testRuleOptionsDecodeLosslesslyAndExposeConvenienceValues() throws {
        let data = Data(ruleJSON().utf8)
        let rule = try JSONDecoder().decode(EPGStationRule.self, from: data)

        XCTAssertEqual(rule.id, 17)
        XCTAssertEqual(rule.reservesCount, 2)
        XCTAssertEqual(rule.options.isTimeSpecification, false)
        XCTAssertEqual(rule.options.enabled, true)
        XCTAssertEqual(rule.options.searchValues["keyword"], .string("ニュース"))
        XCTAssertEqual(rule.options.searchValues["futureSearchField"], .object(["keep": .bool(true)]))
        XCTAssertEqual(rule.options.rawValues["futureRuleField"], .string("keep"))

        var edited = rule.options
        edited.enabled = false
        XCTAssertEqual(edited.enabled, false)
        XCTAssertEqual(edited.searchValues["futureSearchField"], .object(["keep": .bool(true)]))
    }

    func testRulesBuildQueryAndDecodePage() async throws {
        let recorder = RuleRequestRecorder()
        RuleURLProtocol.handler = { request in
            recorder.append(request)
            let page = "{\"rules\":[\(self.ruleJSON())],\"total\":3}"
            return RuleURLProtocol.Stub(body: Data(page.utf8))
        }
        defer { RuleURLProtocol.handler = nil }

        let page = try await client().rules(
            offset: 4,
            limit: 10,
            filter: .conflict,
            keyword: " ニュース "
        )
        let request = try XCTUnwrap(recorder.all.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(query["offset"], "4")
        XCTAssertEqual(query["limit"], "10")
        XCTAssertEqual(query["type"], "conflict")
        XCTAssertEqual(query["keyword"], "ニュース")
        XCTAssertEqual(page.rules.first?.id, 17)
        XCTAssertEqual(page.total, 3)
    }

    func testRulePreviewUsesReadOnlyScheduleSearch() async throws {
        let recorder = RuleRequestRecorder()
        RuleURLProtocol.handler = { request in
            recorder.append(request)
            let body = """
            [{"id":31,"channelId":2,"startAt":1700000000000,"endAt":1700003600000,"isFree":true,"name":"番組","description":"概要"}]
            """
            return RuleURLProtocol.Stub(body: Data(body.utf8))
        }
        defer { RuleURLProtocol.handler = nil }

        let programs = try await client().previewRule(
            searchValues: ["keyword": .string("ニュース"), "name": .bool(true)],
            limit: 12
        )
        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/epg/api/schedules/search")
        let body = try jsonBody(request)
        let option = try XCTUnwrap(body["option"] as? [String: Any])
        XCTAssertEqual(option["keyword"] as? String, "ニュース")
        XCTAssertEqual(option["name"] as? Bool, true)
        XCTAssertEqual(body["isHalfWidth"] as? Bool, true)
        XCTAssertEqual(body["limit"] as? Int, 12)
        XCTAssertEqual(programs.first?.id, 31)
    }

    func testRuleMutationsUseExpectedRoutesAndValidateSuccessBodies() async throws {
        let recorder = RuleRequestRecorder()
        RuleURLProtocol.handler = { request in
            recorder.append(request)
            if request.httpMethod == "POST" {
                return RuleURLProtocol.Stub(body: Data(#"{"ruleId":42}"#.utf8))
            }
            return RuleURLProtocol.Stub(body: Data(#"{"code":200}"#.utf8))
        }
        defer { RuleURLProtocol.handler = nil }

        let api = try client()
        let created = try await api.createRule(options: ruleOptions())
        try await api.updateRule(id: 42, options: ruleOptions())
        try await api.setRuleEnabled(id: 42, enabled: false)
        try await api.deleteRule(id: 42)

        XCTAssertEqual(created, 42)
        XCTAssertEqual(recorder.all.map(\.httpMethod), ["POST", "PUT", "PUT", "DELETE"])
        XCTAssertEqual(recorder.all.map { $0.url?.path }, [
            "/epg/api/rules",
            "/epg/api/rules/42",
            "/epg/api/rules/42/disable",
            "/epg/api/rules/42"
        ])
        let createBody = try jsonBody(try XCTUnwrap(recorder.all.first))
        XCTAssertEqual(createBody["futureRuleField"] as? String, "preserve")
    }

    func testRuleWriteOmitsKnownNullsAndPreservesUnknownNulls() async throws {
        let recorder = RuleRequestRecorder()
        RuleURLProtocol.handler = { request in
            recorder.append(request)
            return RuleURLProtocol.Stub(body: Data(#"{"ruleId":42}"#.utf8))
        }
        defer { RuleURLProtocol.handler = nil }

        let options = EPGStationRuleOptions(rawValues: [
            "isTimeSpecification": .bool(false),
            "searchOption": .object([
                "keyword": .null,
                "ignoreKeyword": .null,
                "keyCS": .null,
                "channelIds": .null,
                "genres": .array([
                    .object([
                        "genre": .integer(1),
                        "subGenre": .null,
                        "futureGenreField": .null
                    ])
                ]),
                "times": .array([
                    .object([
                        "week": .integer(0x7F),
                        "start": .null,
                        "range": .null,
                        "futureTimeField": .null
                    ])
                ]),
                "isFree": .null,
                "durationMin": .null,
                "durationMax": .integer(30),
                "searchPeriods": .null,
                "futureSearchField": .null
            ]),
            "reserveOption": .object([
                "enable": .bool(true),
                "allowEndLack": .bool(true),
                "avoidDuplicate": .bool(false),
                "periodToAvoidDuplicate": .null,
                "tags": .null,
                "futureReserveField": .null
            ]),
            "saveOption": .object([
                "parentDirectoryName": .null,
                "directory": .null,
                "recordedFormat": .null,
                "futureSaveField": .null
            ]),
            "encodeOption": .object([
                "mode1": .null,
                "encodeParentDirectoryName1": .null,
                "directory1": .null,
                "isDeleteOriginalAfterEncode": .bool(false),
                "futureEncodeField": .null
            ]),
            "futureRuleField": .null
        ])

        _ = try await client().createRule(options: options)
        let request = try XCTUnwrap(recorder.all.first)
        let body = try jsonBody(request)
        let search = try XCTUnwrap(body["searchOption"] as? [String: Any])
        XCTAssertNil(search["keyword"])
        XCTAssertNil(search["keyCS"])
        XCTAssertTrue(search["futureSearchField"] is NSNull)
        let genres = try XCTUnwrap(search["genres"] as? [[String: Any]])
        XCTAssertNil(genres.first?["subGenre"])
        XCTAssertTrue(genres.first?["futureGenreField"] is NSNull)
        let times = try XCTUnwrap(search["times"] as? [[String: Any]])
        XCTAssertNil(times.first?["start"])
        XCTAssertNil(times.first?["range"])
        XCTAssertTrue(times.first?["futureTimeField"] is NSNull)

        let reserve = try XCTUnwrap(body["reserveOption"] as? [String: Any])
        XCTAssertNil(reserve["periodToAvoidDuplicate"])
        XCTAssertNil(reserve["tags"])
        XCTAssertTrue(reserve["futureReserveField"] is NSNull)
        let save = try XCTUnwrap(body["saveOption"] as? [String: Any])
        XCTAssertNil(save["parentDirectoryName"])
        XCTAssertTrue(save["futureSaveField"] is NSNull)
        let encode = try XCTUnwrap(body["encodeOption"] as? [String: Any])
        XCTAssertNil(encode["mode1"])
        XCTAssertEqual(encode["isDeleteOriginalAfterEncode"] as? Bool, false)
        XCTAssertTrue(encode["futureEncodeField"] is NSNull)
        XCTAssertTrue(body["futureRuleField"] is NSNull)
    }

    func testPreviewNormalizesKnownNullsAndReadbackComparisonUsesSameShape() async throws {
        let recorder = RuleRequestRecorder()
        RuleURLProtocol.handler = { request in
            recorder.append(request)
            return RuleURLProtocol.Stub(body: Data("[]".utf8))
        }
        defer { RuleURLProtocol.handler = nil }

        let searchValues: [String: RawJSONValue] = [
            "keyword": .null,
            "name": .null,
            "times": .array([
                .object([
                    "week": .integer(0x7F),
                    "start": .null,
                    "range": .null,
                    "futureTimeField": .null
                ])
            ]),
            "futureSearchField": .null
        ]
        _ = try await client().previewRule(searchValues: searchValues)
        let body = try jsonBody(try XCTUnwrap(recorder.all.first))
        let option = try XCTUnwrap(body["option"] as? [String: Any])
        XCTAssertNil(option["keyword"])
        XCTAssertNil(option["name"])
        XCTAssertTrue(option["futureSearchField"] is NSNull)
        let times = try XCTUnwrap(option["times"] as? [[String: Any]])
        XCTAssertNil(times.first?["start"])
        XCTAssertNil(times.first?["range"])
        XCTAssertTrue(times.first?["futureTimeField"] is NSNull)

        let requested = EPGStationRuleOptions(rawValues: [
            "isTimeSpecification": .bool(false),
            "searchOption": .object(searchValues),
            "reserveOption": .object([
                "enable": .bool(true),
                "allowEndLack": .bool(true),
                "avoidDuplicate": .bool(false)
            ])
        ])
        let actual = EPGStationRuleOptions(rawValues: [
            "isTimeSpecification": .bool(false),
            "searchOption": .object([
                "times": .array([
                    .object([
                        "week": .integer(0x7F),
                        "futureTimeField": .null
                    ])
                ]),
                "futureSearchField": .null
            ]),
            "reserveOption": .object([
                "enable": .bool(true),
                "allowEndLack": .bool(true),
                "avoidDuplicate": .bool(false)
            ])
        ])
        XCTAssertTrue(requested.matchesServerReadback(actual))

        let droppedUnknown = EPGStationRuleOptions(rawValues: [
            "isTimeSpecification": .bool(false),
            "searchOption": .object([
                "times": .array([
                    .object(["week": .integer(0x7F)])
                ]),
                "futureSearchField": .null
            ]),
            "reserveOption": .object([
                "enable": .bool(true),
                "allowEndLack": .bool(true),
                "avoidDuplicate": .bool(false)
            ])
        ])
        XCTAssertFalse(droppedUnknown.matchesServerReadback(actual))
    }

    func testRuleMutationAmbiguousBodiesFailAsOutcomeUnknown() async throws {
        let cases: [(name: String, body: Data, operation: Int)] = [
            ("post missing id", Data(#"{}"#.utf8), 0),
            ("post nonpositive id", Data(#"{"ruleId":0}"#.utf8), 1),
            ("put invalid code", Data(#"{"code":201}"#.utf8), 2),
            ("delete malformed body", Data("not-json".utf8), 3)
        ]

        for testCase in cases {
            RuleURLProtocol.handler = { _ in RuleURLProtocol.Stub(body: testCase.body) }
            defer { RuleURLProtocol.handler = nil }
            let api = try client()
            do {
                switch testCase.operation {
                case 0, 1:
                    _ = try await api.createRule(options: ruleOptions())
                case 2:
                    try await api.updateRule(id: 42, options: ruleOptions())
                default:
                    try await api.deleteRule(id: 42)
                }
                XCTFail("\(testCase.name) must be ambiguous")
            } catch let error as EPGStationWriteError {
                XCTAssertEqual(error, .outcomeUnknown, testCase.name)
            }
        }
    }

    func testRuleMutationHTTPFailuresMapStatusAndSendOnce() async throws {
        for status in [400, 503] {
            let recorder = RuleRequestRecorder()
            RuleURLProtocol.handler = { request in
                recorder.append(request)
                return RuleURLProtocol.Stub(status: status, body: Data())
            }
            defer { RuleURLProtocol.handler = nil }

            let api = try client()
            do {
                try await api.updateRule(id: 42, options: ruleOptions())
                XCTFail("HTTP \(status) must fail")
            } catch let error as EPGStationWriteError {
                let expected: EPGStationWriteError = status == 400 ? .httpStatus(400) : .outcomeUnknown
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(recorder.all.count, 1, "HTTP \(status) must be sent once")
        }
    }

    func testRulePreviewPreservesHTTPErrorAndRejectsDuplicatePrograms() async throws {
        RuleURLProtocol.handler = { _ in RuleURLProtocol.Stub(status: 503, body: Data()) }
        do {
            _ = try await client().previewRule(searchValues: [
                "keyword": .string("ニュース"),
                "name": .bool(true)
            ])
            XCTFail("preview HTTP failure must be reported")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .httpStatus(503))
        }

        let duplicate = """
        [
          {"id":31,"channelId":2,"startAt":1700000000000,"endAt":1700003600000,"isFree":true,"name":"番組"},
          {"id":31,"channelId":2,"startAt":1700000000000,"endAt":1700003600000,"isFree":true,"name":"番組"}
        ]
        """
        RuleURLProtocol.handler = { _ in RuleURLProtocol.Stub(body: Data(duplicate.utf8)) }
        defer { RuleURLProtocol.handler = nil }
        do {
            _ = try await client().previewRule(searchValues: [
                "keyword": .string("ニュース"),
                "name": .bool(true)
            ])
            XCTFail("duplicate program IDs must be rejected")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testRuleMergePreservesIndependentChangesAndRejectsOverlap() throws {
        let original = ruleOptions()
        var edited = original
        var editedSearch = edited.searchValues
        editedSearch["keyword"] = .string("編集済み")
        edited.searchValues = editedSearch

        var latest = original
        var latestSearch = latest.searchValues
        latestSearch["futureServerField"] = .string("追加")
        latest.searchValues = latestSearch
        let merged = try mergingEditedRuleOptions(
            original: original,
            edited: edited,
            latest: latest
        )
        XCTAssertEqual(merged.searchValues["keyword"], .string("編集済み"))
        XCTAssertEqual(merged.searchValues["futureServerField"], .string("追加"))

        latestSearch["keyword"] = .string("別クライアント")
        latest.searchValues = latestSearch
        XCTAssertThrowsError(try mergingEditedRuleOptions(
            original: original,
            edited: edited,
            latest: latest
        )) { error in
            XCTAssertEqual(error as? SettingsPatchError, .conflictingChange)
        }
    }

    func testRuleReadbackComparisonNormalizesServerDefaultsAndKeepsUnknownFields() {
        let requested = EPGStationRuleOptions(rawValues: [
            "isTimeSpecification": .bool(false),
            "searchOption": .object([
                "keyword": .string("ニュース"),
                "name": .bool(true)
            ]),
            "reserveOption": .object([
                "enable": .bool(true),
                "allowEndLack": .bool(true),
                "avoidDuplicate": .bool(false)
            ]),
            "encodeOption": .object([
                "isDeleteOriginalAfterEncode": .bool(false)
            ]),
            "futureRuleField": .string("keep")
        ])

        let actual = EPGStationRuleOptions(rawValues: [
            "isTimeSpecification": .bool(false),
            "searchOption": .object([
                "keyword": .string("ニュース"),
                "name": .bool(true),
                "keyCS": .bool(false),
                "futureSearchField": .string("server-added")
            ]),
            "reserveOption": .object([
                "enable": .bool(true),
                "allowEndLack": .bool(true),
                "avoidDuplicate": .bool(false)
            ]),
            "futureTopLevelField": .string("server-added"),
            "futureRuleField": .string("keep")
        ])
        XCTAssertTrue(requested.matchesServerReadback(actual))

        var droppedUnknown = requested
        var search = droppedUnknown.searchValues
        search["futureRequestedField"] = .string("must-survive")
        droppedUnknown.searchValues = search
        XCTAssertFalse(droppedUnknown.matchesServerReadback(actual))

        var changedDefault = requested
        changedDefault.rawValues["encodeOption"] = .object([
            "isDeleteOriginalAfterEncode": .bool(true)
        ])
        XCTAssertFalse(changedDefault.matchesServerReadback(actual))

        var explicitEmpty = requested
        var explicitSearch = explicitEmpty.searchValues
        explicitSearch["channelIds"] = .array([])
        explicitEmpty.searchValues = explicitSearch
        XCTAssertFalse(explicitEmpty.matchesServerReadback(actual))
    }

    func testTimeSpecificationAcceptsFullDaySecondRange() async throws {
        RuleURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return RuleURLProtocol.Stub(body: Data(#"{"ruleId":42}"#.utf8))
        }
        defer { RuleURLProtocol.handler = nil }

        let options = EPGStationRuleOptions(rawValues: [
            "isTimeSpecification": .bool(true),
            "searchOption": .object([
                "keyword": .string("ニュース"),
                "channelIds": .array([.integer(1)]),
                "times": .array([
                    .object([
                        "start": .integer(60 * 60 * 23),
                        "range": .integer(60 * 60 * 24),
                        "week": .integer(0x7F)
                    ])
                ])
            ]),
            "reserveOption": .object([
                "enable": .bool(true),
                "allowEndLack": .bool(true),
                "avoidDuplicate": .bool(false)
            ])
        ])

        let createdID = try await client().createRule(options: options)
        XCTAssertEqual(createdID, 42)
    }

    func testMalformedRuleAndIncompleteWriteOptionsFailClosed() async throws {
        let malformed = Data(#"{"id":17,"isTimeSpecification":false,"searchOption":{},"reserveOption":{"enable":true}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EPGStationRule.self, from: malformed)) { error in
            XCTAssertEqual(error as? EPGStationError, .invalidResponse)
        }

        let api = try client()
        do {
            _ = try await api.createRule(options: EPGStationRuleOptions(rawValues: [:]))
            XCTFail("incomplete options must not reach the transport")
        } catch let error as EPGStationWriteError {
            XCTAssertEqual(error, .invalidRequest)
        }
    }
}
