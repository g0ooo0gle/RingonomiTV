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

    private func reservationObjectJSON(
        id: Int = 21,
        includeOptionals: Bool = true
    ) -> String {
        let optionalFields = includeOptionals
            ? """
              "ruleId": 7,
              "programId": 31,
              "description": "予約詳細\\n次の行\\t項目",
              "extended": "拡張\\r\\n補足",
              """
            : ""
        return """
        {
          "id": \(id),
          "channelId": 2,
          \(optionalFields)
          "startAt": 1700000000000,
          "endAt": 1700003600000,
          "name": "予約番組",
          "isSkip": false,
          "isConflict": true,
          "isOverlap": false,
          "allowEndLack": true,
          "isTimeSpecified": false,
          "isDeleteOriginalAfterEncode": false,
          "futureEncodeMode": "ignored"
        }
        """
    }

    private func reservationPageJSON(
        reservations: String? = nil,
        total: Int = 3
    ) -> Data {
        let reservations = reservations ?? "[\(reservationObjectJSON())]"
        return Data("{\"reserves\":\(reservations),\"total\":\(total)}".utf8)
    }

    private func editableReservationObjectJSON() -> String {
        """
        {
          "id": 21,
          "channelId": 2,
          "programId": 31,
          "startAt": 1700000000000,
          "endAt": 1700003600000,
          "name": "予約番組",
          "description": "予約詳細",
          "extended": "拡張",
          "tags": [5, 9],
          "parentDirectoryName": "録画",
          "directory": "番組",
          "recordedFormat": "ts",
          "encodeMode1": "H.264",
          "encodeParentDirectoryName1": "変換",
          "encodeDirectory1": "番組",
          "encodeMode2": "H.265",
          "encodeParentDirectoryName2": "変換2",
          "encodeDirectory2": "番組2",
          "encodeMode3": null,
          "encodeParentDirectoryName3": null,
          "encodeDirectory3": null,
          "isSkip": false,
          "isConflict": false,
          "isOverlap": false,
          "allowEndLack": true,
          "isTimeSpecified": false,
          "isDeleteOriginalAfterEncode": true
        }
        """
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let body: Data
        if let httpBody = request.httpBody {
            body = httpBody
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var streamedBody = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                streamedBody.append(buffer, count: count)
            }
            body = streamedBody
        }
        let value = try JSONSerialization.jsonObject(with: body)
        return try XCTUnwrap(value as? [String: Any])
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

    func testReservationsBuildExpectedQueryAndDecodeUnknownFields() async throws {
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            return EPGStationURLProtocol.Stub(body: self.reservationPageJSON())
        }
        defer { EPGStationURLProtocol.handler = nil }

        let client = try client(
            additionalHeaders: [
                "Authorization": "secret-token",
                "Cookie": "secret-cookie",
                "X-Test": "kept"
            ]
        )
        let page = try await client.reservations(
            offset: 10,
            limit: 25,
            filter: .conflict,
            ruleID: 7
        )

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/proxy/api/reserves")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        let queryItems = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(query["isHalfWidth"], "true")
        XCTAssertEqual(query["type"], "conflict")
        XCTAssertEqual(query["offset"], "10")
        XCTAssertEqual(query["limit"], "25")
        XCTAssertEqual(query["ruleId"], "7")

        let reservation = try XCTUnwrap(page.reservations.first)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(reservation.id, 21)
        XCTAssertEqual(reservation.channelID, 2)
        XCTAssertEqual(reservation.ruleID, 7)
        XCTAssertEqual(reservation.programID, 31)
        XCTAssertEqual(reservation.startAt, 1_700_000_000_000)
        XCTAssertEqual(reservation.endAt, 1_700_003_600_000)
        XCTAssertEqual(reservation.description, "予約詳細\n次の行\t項目")
        XCTAssertEqual(reservation.extended, "拡張\r\n補足")
        XCTAssertFalse(reservation.isSkip)
        XCTAssertTrue(reservation.isConflict)
        XCTAssertFalse(reservation.isOverlap)
        XCTAssertTrue(reservation.allowEndLack)
        XCTAssertFalse(reservation.isTimeSpecified)
        XCTAssertFalse(reservation.isDeleteOriginalAfterEncode)
    }

    func testReservationDetailUsesReservationIDAndRejectsMismatchedResponse() async throws {
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            return EPGStationURLProtocol.Stub(
                body: Data(self.reservationObjectJSON(id: 21).utf8)
            )
        }
        defer { EPGStationURLProtocol.handler = nil }

        let client = try client()
        let reservation = try await client.reservation(id: 21)
        XCTAssertEqual(reservation.id, 21)
        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.url?.path, "/proxy/api/reserves/21")
        XCTAssertEqual(request.url?.query, "isHalfWidth=true")

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(
                body: Data(self.reservationObjectJSON(id: 22).utf8)
            )
        }
        do {
            _ = try await client.reservation(id: 21)
            XCTFail("a detail response for another reservation must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testMinimalReservationPreservesMissingOptionalFields() throws {
        let payload = Data(
            #"{"id":22,"channelId":2,"startAt":1700000000000,"endAt":1700000001000,"name":"最小予約","isSkip":false,"isConflict":false,"isOverlap":false,"allowEndLack":false,"isTimeSpecified":true,"isDeleteOriginalAfterEncode":false}"#.utf8
        )
        let reservation = try JSONDecoder().decode(EPGStationReservation.self, from: payload)
        XCTAssertEqual(reservation.id, 22)
        XCTAssertNil(reservation.ruleID)
        XCTAssertNil(reservation.programID)
        XCTAssertNil(reservation.description)
        XCTAssertNil(reservation.extended)
        XCTAssertEqual(
            EPGStationReservationFilter.allCases.map(\.rawValue),
            ["all", "normal", "conflict", "skip", "overlap"]
        )
    }

    func testReservationRequiredFieldsAndValuesAreValidated() throws {
        let missingFlag = reservationObjectJSON()
            .replacingOccurrences(of: "\"isConflict\": true,", with: "")
        XCTAssertFalse(missingFlag.contains("\"isConflict\""))
        let wrongFlagType = reservationObjectJSON()
            .replacingOccurrences(of: "\"isConflict\": true", with: "\"isConflict\": \"true\"")
        let reversedTime = reservationObjectJSON()
            .replacingOccurrences(of: "\"endAt\": 1700003600000", with: "\"endAt\": 1699999999000")
        let unsafeDescription = reservationObjectJSON()
            .replacingOccurrences(of: "予約詳細\\n次の行\\t項目", with: "不正\\u0000文字")
        let invalidIdentifier = reservationObjectJSON()
            .replacingOccurrences(of: "\"id\": 21", with: "\"id\": 0")
        let invalidRuleIdentifier = reservationObjectJSON()
            .replacingOccurrences(of: "\"ruleId\": 7", with: "\"ruleId\": -1")

        // A missing required flag must remain a decoding failure; it must not
        // be silently defaulted to false.
        XCTAssertThrowsError(
            try JSONDecoder().decode(EPGStationReservation.self, from: Data(missingFlag.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(EPGStationReservation.self, from: Data(wrongFlagType.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
        for source in [
            reversedTime,
            unsafeDescription,
            invalidIdentifier,
            invalidRuleIdentifier
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(EPGStationReservation.self, from: Data(source.utf8))
            ) { error in
                XCTAssertEqual(error as? EPGStationError, .invalidResponse)
            }
        }
    }

    func testReservationPaginationParametersAndDuplicateIDsAreRejected() async throws {
        let client = try client()
        do {
            _ = try await client.reservations(offset: -1)
            XCTFail("negative offset must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidRequest)
        }
        do {
            _ = try await client.reservations(limit: 0)
            XCTFail("zero limit must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidRequest)
        }
        do {
            _ = try await client.reservations(limit: EPGStationClient.maximumPageLimit + 1)
            XCTFail("an oversized limit must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidRequest)
        }
        do {
            _ = try await client.reservations(ruleID: 0)
            XCTFail("zero rule ID must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidIdentifier)
        }

        EPGStationURLProtocol.handler = { _ in
            let one = self.reservationObjectJSON()
            return EPGStationURLProtocol.Stub(
                body: self.reservationPageJSON(reservations: "[\(one),\(one)]", total: 2)
            )
        }
        defer { EPGStationURLProtocol.handler = nil }
        do {
            _ = try await client.reservations(limit: 2)
            XCTFail("duplicate reservation IDs must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }

        EPGStationURLProtocol.handler = { _ in
            let one = self.reservationObjectJSON(id: 21)
            let two = self.reservationObjectJSON(id: 22)
            return EPGStationURLProtocol.Stub(
                body: self.reservationPageJSON(reservations: "[\(one),\(two)]", total: 2)
            )
        }
        do {
            _ = try await client.reservations(limit: 1)
            XCTFail("a page larger than the requested limit must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testReservationHTTPStatusAndMalformedResponsesMapToSafeErrors() async throws {
        let client = try client()
        defer { EPGStationURLProtocol.handler = nil }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(
                status: 404,
                body: Data(#"{"secret":"must not appear"}"#.utf8)
            )
        }
        do {
            _ = try await client.reservation(id: 21)
            XCTFail("HTTP 404 must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .httpStatus(404))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(status: 503, body: Data())
        }
        do {
            _ = try await client.reservations()
            XCTFail("HTTP 503 must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .httpStatus(503))
        }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(body: Data(#"{"reserves":}"#.utf8))
        }
        do {
            _ = try await client.reservations()
            XCTFail("malformed JSON must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testChannelsUseReadOnlyGETAndIgnoreUnknownFields() async throws {
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            let body = """
            [
              {"id":1,"name":"地デジ1","halfWidthName":"地デジ1","serviceId":101,"hasLogoData":true,"futureField":"ignored"},
              {"id":2,"name":"衛星2","channelType":"BS"}
            ]
            """
            return EPGStationURLProtocol.Stub(body: Data(body.utf8))
        }
        defer { EPGStationURLProtocol.handler = nil }

        let client = try client(
            additionalHeaders: [
                "Authorization": "secret-token",
                "Cookie": "secret-cookie"
            ]
        )
        let channels = try await client.channels()

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/proxy/api/channels")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].id, 1)
        XCTAssertEqual(channels[0].name, "地デジ1")
        XCTAssertEqual(channels[0].halfWidthName, "地デジ1")
        XCTAssertEqual(channels[1].id, 2)
        XCTAssertNil(channels[1].halfWidthName)
    }

    func testChannelsRejectDuplicateIDsAndUnsafeRequiredFields() async throws {
        let client = try client()
        defer { EPGStationURLProtocol.handler = nil }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(
                body: Data(#"[{"id":1,"name":"地デジ1"},{"id":1,"name":"重複"}]"#.utf8)
            )
        }
        do {
            _ = try await client.channels()
            XCTFail("duplicate channel IDs must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let invalidPayloads = [
            Data(#"[{"id":0,"name":"不正ID"}]"#.utf8),
            Data(#"[{"id":2,"name":""}]"#.utf8),
            Data(#"[{"id":3,"name":"不正\u0000文字"}]"#.utf8)
        ]
        for payload in invalidPayloads {
            EPGStationURLProtocol.handler = { _ in
                EPGStationURLProtocol.Stub(body: payload)
            }
            do {
                _ = try await client.channels()
                XCTFail("invalid channel payload must fail")
            } catch let error as EPGStationError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
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

    func testReservationActionsEncodeProgramAndTimeSpecifiedRequests() async throws {
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/proxy/api/reserves"):
                let requestCount = recorder.all.count
                let responseID = requestCount == 1 ? 301 : 302
                return EPGStationURLProtocol.Stub(
                    status: 201,
                    body: Data("{\"reserveId\":\(responseID)}".utf8)
                )
            default:
                return EPGStationURLProtocol.Stub(status: 500, body: Data())
            }
        }
        defer { EPGStationURLProtocol.handler = nil }

        let client = try client(
            additionalHeaders: [
                "Authorization": "must-be-removed",
                "Cookie": "must-be-removed"
            ]
        )
        let options = EPGStationReservationEditOptions(
            allowEndLack: true,
            tags: [5, 9],
            saveOption: EPGStationReservationSaveOption(
                parentDirectoryName: "録画",
                directory: "番組",
                recordedFormat: "ts"
            ),
            encodeOption: EPGStationReservationEncodeOption(
                mode1: "H.264",
                encodeParentDirectoryName1: "変換",
                directory1: "番組",
                isDeleteOriginalAfterEncode: true
            )
        )

        let programReservationID = try await client.createReservation(
            programID: 31,
            options: options
        )
        XCTAssertEqual(programReservationID, 301)
        let programRequest = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(programRequest.httpMethod, "POST")
        XCTAssertEqual(programRequest.url?.path, "/proxy/api/reserves")
        XCTAssertNil(programRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(programRequest.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(programRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let programBody = try jsonBody(programRequest)
        XCTAssertEqual(programBody["programId"] as? Int, 31)
        XCTAssertNil(programBody["timeSpecifiedOption"])
        XCTAssertEqual(programBody["allowEndLack"] as? Bool, true)
        XCTAssertEqual(programBody["tags"] as? [Int], [5, 9])
        let saveOption = try XCTUnwrap(programBody["saveOption"] as? [String: Any])
        XCTAssertEqual(saveOption["parentDirectoryName"] as? String, "録画")
        XCTAssertEqual(saveOption["directory"] as? String, "番組")
        XCTAssertEqual(saveOption["recordedFormat"] as? String, "ts")
        let encodeOption = try XCTUnwrap(programBody["encodeOption"] as? [String: Any])
        XCTAssertEqual(encodeOption["mode1"] as? String, "H.264")
        XCTAssertEqual(encodeOption["encodeParentDirectoryName1"] as? String, "変換")
        XCTAssertEqual(encodeOption["directory1"] as? String, "番組")
        XCTAssertEqual(encodeOption["isDeleteOriginalAfterEncode"] as? Bool, true)

        let timeReservationID = try await client.createTimeSpecifiedReservation(
            name: "時間指定",
            channelID: 2,
            startAt: 1_700_000_000_000,
            endAt: 1_700_003_600_000,
            options: options
        )
        XCTAssertEqual(timeReservationID, 302)
        let timeRequest = try XCTUnwrap(recorder.all.dropFirst().first)
        let timeBody = try jsonBody(timeRequest)
        XCTAssertNil(timeBody["programId"])
        let timeOption = try XCTUnwrap(timeBody["timeSpecifiedOption"] as? [String: Any])
        XCTAssertEqual(timeOption["name"] as? String, "時間指定")
        XCTAssertEqual(timeOption["channelId"] as? Int, 2)
        XCTAssertEqual(timeOption["startAt"] as? Int, 1_700_000_000_000)
        XCTAssertEqual(timeOption["endAt"] as? Int, 1_700_003_600_000)
    }

    func testUpdatePreservesAllLatestSaveEncodeAndTagValues() async throws {
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            return EPGStationURLProtocol.Stub(
                body: Data(#"{"code":201,"message":"ok"}"#.utf8)
            )
        }
        defer { EPGStationURLProtocol.handler = nil }

        let client = try client()
        let reservation = try JSONDecoder().decode(
            EPGStationReservation.self,
            from: Data(editableReservationObjectJSON().utf8)
        )
        let options = EPGStationReservationEditOptions(
            preserving: reservation,
            allowEndLack: false
        )
        try await client.updateReservation(id: reservation.id, options: options)

        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/proxy/api/reserves/21")
        let body = try jsonBody(request)
        XCTAssertEqual(body["allowEndLack"] as? Bool, false)
        XCTAssertEqual(body["tags"] as? [Int], [5, 9])

        let saveOption = try XCTUnwrap(body["saveOption"] as? [String: Any])
        XCTAssertEqual(saveOption["parentDirectoryName"] as? String, "録画")
        XCTAssertEqual(saveOption["directory"] as? String, "番組")
        XCTAssertEqual(saveOption["recordedFormat"] as? String, "ts")

        let encodeOption = try XCTUnwrap(body["encodeOption"] as? [String: Any])
        XCTAssertEqual(encodeOption["mode1"] as? String, "H.264")
        XCTAssertEqual(encodeOption["encodeParentDirectoryName1"] as? String, "変換")
        XCTAssertEqual(encodeOption["directory1"] as? String, "番組")
        XCTAssertEqual(encodeOption["mode2"] as? String, "H.265")
        XCTAssertEqual(encodeOption["encodeParentDirectoryName2"] as? String, "変換2")
        XCTAssertEqual(encodeOption["directory2"] as? String, "番組2")
        XCTAssertTrue(encodeOption["isDeleteOriginalAfterEncode"] as? Bool == true)
        XCTAssertTrue(encodeOption.keys.contains("mode3"))
        XCTAssertTrue(encodeOption.keys.contains("encodeParentDirectoryName3"))
        XCTAssertTrue(encodeOption.keys.contains("directory3"))
    }

    func testDeleteReservationSendsNoBodyAndAcceptsServerSuccessBodies() async throws {
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            return EPGStationURLProtocol.Stub(body: Data())
        }
        defer { EPGStationURLProtocol.handler = nil }

        let client = try client()
        try await client.deleteReservation(id: 21)
        let request = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/proxy/api/reserves/21")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))

        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            return EPGStationURLProtocol.Stub(body: Data(#"{"message":"ok"}"#.utf8))
        }
        try await client.deleteReservation(id: 21)
        XCTAssertEqual(recorder.all.count, 2)
    }

    func testReservationWriteFailuresNeverSuggestAnAutomaticRetry() async throws {
        let client = try client()
        defer { EPGStationURLProtocol.handler = nil }
        let options = EPGStationReservationEditOptions()

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(status: 409, body: Data())
        }
        do {
            try await client.updateReservation(id: 21, options: options)
            XCTFail("conflict must fail")
        } catch let error as EPGStationWriteError {
            XCTAssertEqual(error, .httpStatus(409))
            XCTAssertFalse(error.isOutcomeUnknown)
        }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(status: 503, body: Data())
        }
        do {
            _ = try await client.createReservation(programID: 31)
            XCTFail("server failure must be indeterminate")
        } catch let error as EPGStationWriteError {
            XCTAssertEqual(error, .outcomeUnknown)
            XCTAssertTrue(error.isOutcomeUnknown)
        }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(
                status: 201,
                body: Data(#"{"reserveId":0}"#.utf8)
            )
        }
        do {
            _ = try await client.createReservation(programID: 31)
            XCTFail("an invalid success response must be indeterminate")
        } catch let error as EPGStationWriteError {
            XCTAssertEqual(error, .outcomeUnknown)
        }

        EPGStationURLProtocol.handler = { _ in
            EPGStationURLProtocol.Stub(
                status: 201,
                body: Data(#"{"unexpected":true}"#.utf8)
            )
        }
        do {
            _ = try await client.createReservation(programID: 31)
            XCTFail("a malformed success response must be indeterminate")
        } catch let error as EPGStationWriteError {
            XCTAssertEqual(error, .outcomeUnknown)
        }

        do {
            _ = try await client.createReservation(programID: 0)
            XCTFail("invalid IDs must fail before sending a request")
        } catch let error as EPGStationWriteError {
            XCTAssertEqual(error, .invalidRequest)
            XCTAssertFalse(error.isOutcomeUnknown)
        }
    }

    func testConfigAndChannelScheduleUseReadOnlyQueries() async throws {
        let recorder = EPGStationRequestRecorder()
        EPGStationURLProtocol.handler = { request in
            recorder.append(request)
            switch request.url?.path {
            case "/proxy/api/config":
                return EPGStationURLProtocol.Stub(
                    body: Data(#"{"recorded":["録画"],"encode":["H.264"],"future":true}"#.utf8)
                )
            case "/proxy/api/schedules/2":
                let body = """
                [
                  {
                    "channel": {
                      "id": 2,
                      "serviceId": 101,
                      "networkId": 1,
                      "name": "地デジ1",
                      "remoteControlKeyId": 1,
                      "hasLogoData": false,
                      "channelType": "GR",
                      "type": 1
                    },
                    "programs": [
                      {
                        "id": 501,
                        "channelId": 2,
                        "startAt": 1700000000000,
                        "endAt": 1700003600000,
                        "isFree": true,
                        "name": "番組",
                        "description": "説明\\n続き",
                        "extended": "拡張"
                      }
                    ]
                  }
                ]
                """
                return EPGStationURLProtocol.Stub(body: Data(body.utf8))
            default:
                return EPGStationURLProtocol.Stub(status: 404, body: Data())
            }
        }
        defer { EPGStationURLProtocol.handler = nil }

        let client = try client()
        let config = try await client.config()
        XCTAssertEqual(config.recordedDirectories, ["録画"])
        XCTAssertEqual(config.encodeModes, ["H.264"])

        let schedules = try await client.channelSchedule(
            channelID: 2,
            startAt: 1_700_000_000_000,
            days: 2,
            isHalfWidth: false,
            needsRawExtended: true,
            isFree: false
        )
        let schedule = try XCTUnwrap(schedules.first)
        XCTAssertEqual(schedule.channel.id, 2)
        XCTAssertEqual(schedule.channel.name, "地デジ1")
        let program = try XCTUnwrap(schedule.programs.first)
        XCTAssertEqual(program.id, 501)
        XCTAssertEqual(program.channelID, 2)
        XCTAssertTrue(program.isFree)
        XCTAssertEqual(program.description, "説明\n続き")

        let scheduleRequest = try XCTUnwrap(recorder.all.last)
        XCTAssertEqual(scheduleRequest.httpMethod, "GET")
        XCTAssertEqual(scheduleRequest.url?.path, "/proxy/api/schedules/2")
        let queryItems = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(scheduleRequest.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(query["startAt"], "1700000000000")
        XCTAssertEqual(query["days"], "2")
        XCTAssertEqual(query["isHalfWidth"], "false")
        XCTAssertEqual(query["needsRawExtended"], "true")
        XCTAssertEqual(query["isFree"], "false")

        EPGStationURLProtocol.handler = { _ in
            let body = """
            [
              {
                "channel": {
                  "id": 3,
                  "serviceId": 102,
                  "networkId": 1,
                  "name": "別チャンネル",
                  "hasLogoData": false,
                  "channelType": "GR"
                },
                "programs": []
              }
            ]
            """
            return EPGStationURLProtocol.Stub(body: Data(body.utf8))
        }
        do {
            _ = try await client.channelSchedule(
                channelID: 2,
                startAt: 1_700_000_000_000
            )
            XCTFail("a schedule for another channel must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }

        EPGStationURLProtocol.handler = { _ in
            let body = """
            [
              {
                "channel": {
                  "id": 2,
                  "serviceId": 101,
                  "networkId": 1,
                  "name": "地デジ1",
                  "hasLogoData": false,
                  "channelType": "GR"
                },
                "programs": [
                  {
                    "id": 501,
                    "channelId": 2,
                    "startAt": 1700000000000,
                    "endAt": 1700003600000,
                    "isFree": true,
                    "name": "番組1"
                  }
                ]
              },
              {
                "channel": {
                  "id": 2,
                  "serviceId": 101,
                  "networkId": 1,
                  "name": "地デジ1",
                  "hasLogoData": false,
                  "channelType": "GR"
                },
                "programs": [
                  {
                    "id": 501,
                    "channelId": 2,
                    "startAt": 1700003600000,
                    "endAt": 1700007200000,
                    "isFree": true,
                    "name": "番組2"
                  }
                ]
              }
            ]
            """
            return EPGStationURLProtocol.Stub(body: Data(body.utf8))
        }
        do {
            _ = try await client.channelSchedule(
                channelID: 2,
                startAt: 1_700_000_000_000
            )
            XCTFail("duplicate program IDs across schedules must fail")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidResponse)
        }

        do {
            _ = try await client.channelSchedule(channelID: 2, startAt: 1_700_000_000_000, days: 0)
            XCTFail("zero schedule days must fail before sending a request")
        } catch let error as EPGStationError {
            XCTAssertEqual(error, .invalidRequest)
        }
    }
}
