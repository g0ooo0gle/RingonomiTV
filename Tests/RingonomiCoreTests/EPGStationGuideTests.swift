import Foundation
import XCTest
@testable import RingonomiCore

private final class GuideURLProtocol: URLProtocol {
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
        guard let handler = Self.handler,
              let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        guard let response = HTTPURLResponse(
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

private final class GuideBlockingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var numberOfRequests = 0

    static func reset() {
        lock.lock()
        numberOfRequests = 0
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return numberOfRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.numberOfRequests += 1
        Self.lock.unlock()
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
        // Deliberately keep the response open. URLSession cancellation calls
        // stopLoading without blocking this URLProtocol callback thread.
    }

    override func stopLoading() {}
}

private final class GuideRequestRecorder: @unchecked Sendable {
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

final class EPGStationGuideTests: XCTestCase {
    private let startAt = 1_700_000_000_000.0
    private let endAt = 1_700_003_600_000.0

    private func client() throws -> EPGStationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideURLProtocol.self]
        return try EPGStationClient(
            address: "http://example.invalid/proxy",
            sessionConfiguration: configuration
        )
    }

    private func response(_ objects: [String]) -> Data {
        Data("[\(objects.joined(separator: ","))]".utf8)
    }

    private func scheduleObject(
        channelID: Int = 101,
        programID: Int = 5_001,
        programChannelID: Int? = nil,
        programStartAt: Int = 1_700_000_000_000,
        programEndAt: Int = 1_700_003_600_000,
        metadata: String = ""
    ) -> String {
        let programChannelID = programChannelID ?? channelID
        let metadataSuffix = metadata.isEmpty ? "" : ",\(metadata)"
        return """
        {
          "channel": {
            "id": \(channelID),
            "serviceId": 201,
            "networkId": 301,
            "name": "架空チャンネル\(channelID)",
            "hasLogoData": false,
            "channelType": "GR"
          },
          "programs": [{
            "id": \(programID),
            "channelId": \(programChannelID),
            "startAt": \(programStartAt),
            "endAt": \(programEndAt),
            "isFree": true,
            "name": "架空番組"
            \(metadataSuffix)
          }]
        }
        """
    }

    private func queryItems(from request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        return items.reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value
        }
    }

    private func captureError(
        _ operation: () async throws -> [EPGStationSchedule]
    ) async -> EPGStationError? {
        do {
            _ = try await operation()
            return nil
        } catch let error as EPGStationError {
            return error
        } catch {
            return nil
        }
    }

    func testProgramGuideSendsEveryFlagAndPreservesMetadata() async throws {
        let recorder = GuideRequestRecorder()
        let body = response([
            scheduleObject(
                programStartAt: 1_699_996_400_000,
                programEndAt: 1_700_007_200_000,
                metadata: #""rawExtended":{"出演者":"架空","":"値"},"genre1":1,"subGenre1":2,"genre2":3,"subGenre2":4,"genre3":5,"subGenre3":6"#
            )
        ])
        GuideURLProtocol.handler = { request in
            recorder.append(request)
            return GuideURLProtocol.Stub(body: body)
        }
        defer { GuideURLProtocol.handler = nil }

        let schedules = try await client().programGuide(
            startAt: startAt,
            endAt: endAt,
            broadcast: .terrestrial
        )

        XCTAssertEqual(recorder.all.count, 1)
        XCTAssertEqual(recorder.all.first?.url?.path, "/proxy/api/schedules")
        let query = queryItems(from: try XCTUnwrap(recorder.all.first))
        XCTAssertEqual(query["startAt"], "1700000000000")
        XCTAssertEqual(query["endAt"], "1700003600000")
        XCTAssertEqual(query["isHalfWidth"], "true")
        XCTAssertEqual(query["needsRawExtended"], "true")

        let fixedFlags = ["GR", "BS", "CS", "SKY", "BS4K", "CS4K"]
        for flag in fixedFlags {
            XCTAssertEqual(query[flag], flag == "GR" ? "true" : "false")
        }
        for index in 1...40 {
            XCTAssertEqual(query["NW\(index)"], "true")
        }
        XCTAssertEqual(query.count, 50)

        let program = try XCTUnwrap(schedules.first?.programs.first)
        XCTAssertEqual(program.rawExtended?["出演者"], "架空")
        XCTAssertEqual(program.rawExtended?[""], "値")
        XCTAssertEqual(program.genre1, 1)
        XCTAssertEqual(program.subGenre1, 2)
        XCTAssertEqual(program.genre3, 5)
        XCTAssertEqual(program.subGenre3, 6)
        XCTAssertEqual(program.startAt, 1_699_996_400_000)
        XCTAssertEqual(program.endAt, 1_700_007_200_000)
    }

    func testBroadcastScopesSendACompleteBooleanSet() async throws {
        let recorder = GuideRequestRecorder()
        GuideURLProtocol.handler = { request in
            recorder.append(request)
            return GuideURLProtocol.Stub(body: Data("[]".utf8))
        }
        defer { GuideURLProtocol.handler = nil }

        let expected: [EPGStationGuideBroadcast: Set<String>] = [
            .all: Set(["GR", "BS", "CS", "SKY", "BS4K", "CS4K"] + (1...40).map { "NW\($0)" }),
            .terrestrial: Set(["GR"] + (1...40).map { "NW\($0)" }),
            .bs: ["BS"],
            .cs: ["CS"],
            .sky: ["SKY"],
            .bs4K: ["BS4K"],
            .cs4K: ["CS4K"]
        ]

        for scope in EPGStationGuideBroadcast.allCases {
            _ = try await client().programGuide(
                startAt: startAt,
                endAt: endAt,
                broadcast: scope
            )
            let query = queryItems(from: try XCTUnwrap(recorder.all.last))
            let actual = Set(query.filter { key, value in
                (key == "GR" || key == "BS" || key == "CS" || key == "SKY" ||
                 key == "BS4K" || key == "CS4K" || key.hasPrefix("NW")) &&
                value == "true"
            }.map { $0.key })
            XCTAssertEqual(actual, expected[scope] ?? [])
            XCTAssertEqual(
                query.filter { key, _ in
                    key == "GR" || key == "BS" || key == "CS" || key == "SKY" ||
                    key == "BS4K" || key == "CS4K" || key.hasPrefix("NW")
                }.count,
                46
            )
        }
    }

    func testInvalidPeriodsFailBeforeMakingARequest() async throws {
        let recorder = GuideRequestRecorder()
        GuideURLProtocol.handler = { request in
            recorder.append(request)
            return GuideURLProtocol.Stub(body: Data("[]".utf8))
        }
        defer { GuideURLProtocol.handler = nil }

        let invalidRanges: [(Double, Double)] = [
            (-1, 10),
            (10.5, 20),
            (10, 10),
            (10, 10 + 86_400_001),
            (Double.nan, 20),
            (10, Double.infinity),
            (0, 9_007_199_254_740_992)
        ]
        for (invalidStart, invalidEnd) in invalidRanges {
            let error = await captureError {
                try await self.client().programGuide(
                    startAt: invalidStart,
                    endAt: invalidEnd
                )
            }
            XCTAssertEqual(error, .invalidRequest)
        }
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testDuplicateAndMismatchedSchedulesAreInvalid() async throws {
        let duplicateChannelBody = response([
            scheduleObject(channelID: 101, programID: 5_001),
            scheduleObject(channelID: 101, programID: 5_002)
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: duplicateChannelBody) }
        defer { GuideURLProtocol.handler = nil }

        var error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .invalidResponse)

        let duplicateProgramBody = response([
            scheduleObject(channelID: 101, programID: 5_001),
            scheduleObject(channelID: 102, programID: 5_001)
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: duplicateProgramBody) }
        error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .invalidResponse)

        let mismatchedProgramBody = response([
            scheduleObject(channelID: 101, programID: 5_001, programChannelID: 999)
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: mismatchedProgramBody) }
        error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .invalidResponse)

        let invalidTimeBody = response([
            scheduleObject(
                programStartAt: 1_700_003_600_000,
                programEndAt: 1_700_000_000_000
            )
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: invalidTimeBody) }
        error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .invalidResponse)
    }

    func testInvalidGuideMetadataIsRejected() async throws {
        let invalidGenreBody = response([
            scheduleObject(metadata: #""genre1":16"#
            )
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: invalidGenreBody) }
        defer { GuideURLProtocol.handler = nil }

        var error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .invalidResponse)

        let invalidRawExtendedBody = response([
            scheduleObject(metadata: #""rawExtended":{"key":"\u0000"}"#)
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: invalidRawExtendedBody) }
        error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .invalidResponse)
    }

    func testRawExtendedNullAndEmptyDictionaryAreValid() async throws {
        let nullBody = response([
            scheduleObject(metadata: #""rawExtended":null"#
            )
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: nullBody) }
        defer { GuideURLProtocol.handler = nil }

        var schedules = try await client().programGuide(
            startAt: startAt,
            endAt: endAt
        )
        let nullProgram = try XCTUnwrap(schedules.first?.programs.first)
        XCTAssertNil(nullProgram.rawExtended)

        let emptyBody = response([
            scheduleObject(metadata: #""rawExtended":{}"#
            )
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: emptyBody) }
        schedules = try await client().programGuide(
            startAt: startAt,
            endAt: endAt
        )
        let emptyProgram = try XCTUnwrap(schedules.first?.programs.first)
        XCTAssertTrue(emptyProgram.rawExtended?.isEmpty == true)
    }

    func testRawExtendedCountAndTotalBoundsAreRejected() async throws {
        let countEntries = (0..<257)
            .map { #""key\#($0)":"value""# }
            .joined(separator: ",")
        let countBody = response([
            scheduleObject(metadata: #""rawExtended":{\#(countEntries)}"#)
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: countBody) }
        defer { GuideURLProtocol.handler = nil }

        var error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .invalidResponse)

        let largeText = String(repeating: "x", count: 64 * 1024)
        let totalEntries = (0..<9)
            .map { #""key\#($0)":"\#(largeText)""# }
            .joined(separator: ",")
        let totalBody = response([
            scheduleObject(metadata: #""rawExtended":{\#(totalEntries)}"#)
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: totalBody) }
        error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .invalidResponse)
    }

    func testProgramGuidePreservesServerChannelOrder() async throws {
        let body = response([
            scheduleObject(channelID: 102, programID: 5_002),
            scheduleObject(channelID: 101, programID: 5_001)
        ])
        GuideURLProtocol.handler = { _ in GuideURLProtocol.Stub(body: body) }
        defer { GuideURLProtocol.handler = nil }

        let schedules = try await client().programGuide(
            startAt: startAt,
            endAt: endAt
        )
        XCTAssertEqual(schedules.map(\.channel.id), [102, 101])
    }

    func testProgramGuideAcceptsExactDayAndSafeTimestampBoundary() async throws {
        let recorder = GuideRequestRecorder()
        GuideURLProtocol.handler = { request in
            recorder.append(request)
            return GuideURLProtocol.Stub(body: Data("[]".utf8))
        }
        defer { GuideURLProtocol.handler = nil }

        _ = try await client().programGuide(
            startAt: startAt,
            endAt: startAt + 86_400_000
        )
        _ = try await client().programGuide(
            startAt: 9_007_199_254_740_000,
            endAt: 9_007_199_254_740_991
        )
        XCTAssertEqual(recorder.all.count, 2)
        let lastQuery = queryItems(from: try XCTUnwrap(recorder.all.last))
        XCTAssertEqual(lastQuery["endAt"], "9007199254740991")
    }

    func testProgramGuideCancellationDoesNotRetry() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideBlockingURLProtocol.self]
        let blockingClient = try EPGStationClient(
            address: "http://example.invalid/proxy",
            sessionConfiguration: configuration
        )
        GuideBlockingURLProtocol.reset()
        defer { GuideBlockingURLProtocol.reset() }

        let taskStartAt = startAt
        let taskEndAt = endAt
        let task = Task { () -> Bool in
            do {
                _ = try await blockingClient.programGuide(
                    startAt: taskStartAt,
                    endAt: taskEndAt
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        defer { task.cancel() }
        // Observe the request before cancelling so slow CI startup cannot
        // turn this into a cancellation-before-send test.
        for _ in 0..<200 {
            if GuideBlockingURLProtocol.requestCount() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(GuideBlockingURLProtocol.requestCount(), 1)
        task.cancel()
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(GuideBlockingURLProtocol.requestCount(), 1)
    }

    func testOptionalGuideMetadataIsOmittedWhenEncoding() throws {
        let program = try EPGStationScheduleProgram(
            id: 5_001,
            channelID: 101,
            startAt: startAt,
            endAt: endAt,
            isFree: true,
            name: "架空番組"
        )
        let data = try JSONEncoder().encode(program)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["rawExtended"])
        XCTAssertNil(object["genre1"])
        XCTAssertNil(object["subGenre3"])
    }

    func testTransportBoundsAndRedirectRemainEnforced() async throws {
        GuideURLProtocol.handler = { _ in
            GuideURLProtocol.Stub(
                headers: [
                    "Content-Type": "application/json",
                    "Content-Length": String(EPGStationClient.maximumResponseBytes + 1)
                ],
                body: Data("[]".utf8)
            )
        }
        defer { GuideURLProtocol.handler = nil }

        var error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .responseTooLarge)

        GuideURLProtocol.handler = { _ in
            GuideURLProtocol.Stub(
                body: Data(),
                redirectURL: URL(string: "http://example.invalid/elsewhere")
            )
        }
        error = await captureError {
            try await self.client().programGuide(startAt: self.startAt, endAt: self.endAt)
        }
        XCTAssertEqual(error, .redirectRejected)
    }
}
