import Foundation
import XCTest
@testable import RingonomiCore

private final class ReservationURLProtocol: URLProtocol {
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

final class ReservationTests: XCTestCase {
    private func clientAndSession() throws -> (RingonomiClient, URLSession) {
        let client = try RingonomiClient(address: "https://example.invalid/proxy")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReservationURLProtocol.self]
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

    private var reservationJSON: Data {
        Data("""
        {
          "id": 12,
          "channel": {
            "id": "NID1-SID2",
            "display_channel_id": "gr011",
            "name": "テスト局",
            "type": "GR",
            "is_watchable": true
          },
          "program": {
            "id": "program-12",
            "channel_id": "NID1-SID2",
            "title": "テスト番組",
            "description": "説明",
            "start_time": "2026-10-18T12:00:00+09:00",
            "end_time": "2026-10-18T13:00:00+09:00",
            "duration": 3600,
            "is_free": true,
            "detail": {},
            "genres": []
          },
          "is_recording_in_progress": false,
          "recording_availability": "Full",
          "comment": "",
          "scheduled_recording_file_name": "test.ts",
          "estimated_recording_file_size": 1234,
          "record_settings": {
            "is_enabled": true,
            "priority": 3,
            "recording_folders": [{
              "recording_folder_path": "/recordings",
              "recording_file_name_template": null,
              "is_oneseg_separate_recording_folder": false,
              "future_folder_key": {"keep": true}
            }],
            "recording_start_margin": null,
            "recording_end_margin": null,
            "recording_mode": "SpecifiedService",
            "caption_recording_mode": "Default",
            "data_broadcasting_recording_mode": "Default",
            "post_recording_mode": "Default",
            "post_recording_bat_file_path": null,
            "is_event_relay_follow_enabled": true,
            "is_exact_recording_enabled": false,
            "is_oneseg_separate_output_enabled": false,
            "is_sequential_recording_in_single_file_enabled": false,
            "forced_tuner_id": null,
            "future_setting": [1, "keep"]
          }
        }
        """.utf8)
    }

    func testRecordSettingsDefaultsAndUnknownValuesRoundTrip() throws {
        let data = Data("""
        {
          "priority": 5,
          "recording_folders": [{"recording_folder_path": "/nas", "future_folder_value": 42}],
          "recording_start_margin": null,
          "forced_tuner_id": null,
          "future_setting": {"enabled": true}
        }
        """.utf8)
        let settings = try JSONDecoder().decode(RecordSettings.self, from: data)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.priority, 5)
        XCTAssertNil(settings.startMargin)
        XCTAssertNil(settings.forcedTunerID)
        XCTAssertEqual(settings.recordingMode, "SpecifiedService")
        XCTAssertEqual(settings.recordingFolders.first?.recordingFolderPath, "/nas")
        XCTAssertEqual(settings.rawValues["future_setting"], .object(["enabled": .bool(true)]))
        XCTAssertEqual(settings.recordingFolders.first?.rawValues["future_folder_value"], .integer(42))

        let overflow = try JSONDecoder().decode(
            RecordSettings.self,
            from: Data("{\"recording_start_margin\":1e308}".utf8)
        )
        XCTAssertNil(overflow.startMargin)

        var edited = settings
        edited.priority = 2
        edited.startMargin = 10
        edited.recordingFolders[0].recordingFileNameTemplate = "{title}"
        let encoded = try JSONEncoder().encode(edited)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["priority"] as? Int, 2)
        XCTAssertEqual(object["recording_start_margin"] as? Int, 10)
        XCTAssertNotNil(object["future_setting"])
        let folders = try XCTUnwrap(object["recording_folders"] as? [[String: Any]])
        XCTAssertEqual(folders.first?["future_folder_value"] as? Int, 42)
        XCTAssertEqual(folders.first?["recording_file_name_template"] as? String, "{title}")
    }

    func testMalformedReservationCannotBecomeAnEmptyReservation() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let missingID = Data("{\"program\":{\"id\":\"program-1\"},\"record_settings\":{}}".utf8)
        XCTAssertThrowsError(try decoder.decode(Reservation.self, from: missingID))

        let emptyProgram = Data("{\"id\":1,\"program\":{\"id\":\"\"},\"record_settings\":{}}".utf8)
        XCTAssertThrowsError(try decoder.decode(Reservation.self, from: emptyProgram))

        let missingSettings = Data("{\"id\":1,\"program\":{\"id\":\"program-1\"}}".utf8)
        XCTAssertThrowsError(try decoder.decode(Reservation.self, from: missingSettings))

        let malformedRecordingState = Data("{\"id\":1,\"is_recording_in_progress\":\"no\",\"program\":{\"id\":\"program-1\"},\"record_settings\":{}}".utf8)
        XCTAssertThrowsError(try decoder.decode(Reservation.self, from: malformedRecordingState))
    }

    func testMalformedReservationListFailsInsteadOfReturningEmptyList() async throws {
        let (client, session) = try clientAndSession()
        ReservationURLProtocol.handler = { request in
            self.jsonResponse(request, 200, Data("{\"total\":1}".utf8))
        }
        defer { ReservationURLProtocol.handler = nil }

        do {
            _ = try await client.reservations(using: session)
            XCTFail("a list without reservations must not decode as an empty list")
        } catch let error as ReservationError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testReservationResponseDecodesGuideModelsAndSettings() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reservation = try decoder.decode(Reservation.self, from: reservationJSON)
        XCTAssertEqual(reservation.id, 12)
        XCTAssertEqual(reservation.channel.displayChannelId, "gr011")
        XCTAssertEqual(reservation.program.id, "program-12")
        XCTAssertEqual(reservation.recordingAvailability, "Full")
        XCTAssertEqual(reservation.estimatedRecordingFileSize, 1234)
        XCTAssertEqual(reservation.recordSettings.recordingFolders.first?.rawValues["future_folder_key"], .object(["keep": .bool(true)]))
        XCTAssertEqual(reservation.recordSettings.rawValues["future_setting"], .array([.integer(1), .string("keep")]))
    }

    func testClientUsesExactReservationMethodsAndBodies() async throws {
        let (client, session) = try clientAndSession()
        var requests: [URLRequest] = []
        let lock = NSLock()
        ReservationURLProtocol.handler = { request in
            lock.lock(); requests.append(request); lock.unlock()
            if request.httpMethod == "GET" && request.url?.path.hasSuffix("/12") == true {
                return self.jsonResponse(request, 200, self.reservationJSON)
            }
            if request.httpMethod == "GET" {
                let body = Data(("{\"total\":1,\"reservations\":[" + String(data: self.reservationJSON, encoding: .utf8)! + "]}").utf8)
                return self.jsonResponse(request, 200, body)
            }
            if request.httpMethod == "DELETE" { return self.jsonResponse(request, 204) }
            return self.jsonResponse(request, 200, self.reservationJSON)
        }
        defer { ReservationURLProtocol.handler = nil }

        let list = try await client.reservations(using: session)
        XCTAssertEqual(list.total, 1)
        let fetched = try await client.reservation(id: 12, using: session)
        XCTAssertEqual(fetched.id, 12)
        var settings = RecordSettings()
        settings.priority = 4
        _ = try await client.addReservation(programID: "program-12", settings: settings, using: session)
        _ = try await client.updateReservation(id: 12, settings: settings, using: session)
        try await client.deleteReservation(id: 12, using: session)

        let captured = requests
        XCTAssertEqual(captured.map(\.httpMethod), ["GET", "GET", "POST", "PUT", "DELETE"])
        XCTAssertEqual(captured[2].url?.path, "/proxy/api/recording/reservations")
        XCTAssertEqual(captured[3].url?.path, "/proxy/api/recording/reservations/12")
        let postObject = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requestBody(captured[2]))) as? [String: Any])
        XCTAssertEqual(postObject.keys.sorted(), ["program_id", "record_settings"])
        XCTAssertEqual(postObject["program_id"] as? String, "program-12")
        let putObject = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requestBody(captured[3]))) as? [String: Any])
        XCTAssertEqual(putObject.keys.sorted(), ["record_settings"])
    }

    func testHTTPErrorUsesJapaneseStatusMessageAndServerDetail() async throws {
        let (client, session) = try clientAndSession()
        ReservationURLProtocol.handler = { request in
            self.jsonResponse(request, 403, Data("{\"detail\":\"録画権限がありません\"}".utf8))
        }
        defer { ReservationURLProtocol.handler = nil }

        do {
            _ = try await client.reservations(using: session)
            XCTFail("expected HTTP error")
        } catch let error as ReservationError {
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertTrue(error.localizedDescription.contains("権限"))
            XCTAssertTrue(error.localizedDescription.contains("録画権限がありません"))
        }
    }

    func testAddEmpty201PerformsOneReadbackWithoutRetryingPOST() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        ReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" { return self.jsonResponse(request, 201) }
            let body = Data(("{\"total\":1,\"reservations\":[" + String(data: self.reservationJSON, encoding: .utf8)! + "]}").utf8)
            return self.jsonResponse(request, 200, body)
        }
        defer { ReservationURLProtocol.handler = nil }

        let reservation = try await client.addReservation(programID: "program-12", using: session)
        XCTAssertEqual(reservation.id, 12)
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testAddNull201PerformsOneReadbackWithoutRetryingPOST() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        ReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                return self.jsonResponse(request, 201, Data(" \n null \t".utf8))
            }
            let body = Data(("{\"total\":1,\"reservations\":[" + String(data: self.reservationJSON, encoding: .utf8)! + "]}").utf8)
            return self.jsonResponse(request, 200, body)
        }
        defer { ReservationURLProtocol.handler = nil }

        let reservation = try await client.addReservation(programID: "program-12", using: session)
        XCTAssertEqual(reservation.id, 12)
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testAddMalformed201ObjectFailsWithoutReadback() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        ReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return self.jsonResponse(request, 201, Data("{\"unexpected\":true}".utf8))
        }
        defer { ReservationURLProtocol.handler = nil }

        do {
            _ = try await client.addReservation(programID: "program-12", using: session)
            XCTFail("a malformed reservation object must not be treated as an empty 201")
        } catch let error as ReservationError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(methods, ["POST"])
    }

    func testUpdateEmptySuccessReadsBackOnce() async throws {
        let (client, session) = try clientAndSession()
        var methods: [String] = []
        ReservationURLProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "PUT" { return self.jsonResponse(request, 200, Data("\nnull\n".utf8)) }
            return self.jsonResponse(request, 200, self.reservationJSON)
        }
        defer { ReservationURLProtocol.handler = nil }

        let reservation = try await client.updateReservation(id: 12, settings: RecordSettings(), using: session)
        XCTAssertEqual(reservation.id, 12)
        XCTAssertEqual(methods, ["PUT", "GET"])
    }
}
