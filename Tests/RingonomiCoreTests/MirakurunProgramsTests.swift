import Foundation
import XCTest
@testable import RingonomiCore

private final class MirakurunProgramsTestURLProtocol: URLProtocol {
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
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
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
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MirakurunProgramsTests: XCTestCase {
    func testPartialJSONResponseIsRejected() async throws {
        let (client, session) = try clientAndSession()
        defer { session.invalidateAndCancel(); MirakurunProgramsTestURLProtocol.handler = nil }
        let body = programJSON()
        MirakurunProgramsTestURLProtocol.handler = { _ in
            MirakurunProgramsTestURLProtocol.Stub(status: 206, body: body)
        }
        do {
            _ = try await client.programs(for: MirakurunServiceKey(networkID: 1, serviceID: 2), using: session)
            XCTFail("partial JSON must not be presented as a complete service guide")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .httpStatus(206))
        }
    }

    private func clientAndSession(
        address: String = "http://example.invalid/proxy"
    ) throws -> (MirakurunClient, URLSession) {
        let client = try MirakurunClient(address: address)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MirakurunProgramsTestURLProtocol.self]
        configuration.httpShouldSetCookies = true
        return (client, URLSession(configuration: configuration))
    }

    private func programJSON(
        id: Int = 1001,
        networkID: Int = 1,
        serviceID: Int = 2
    ) -> Data {
        Data(
            """
            [{
              "id": \(id),
              "eventId": 7,
              "serviceId": \(serviceID),
              "networkId": \(networkID),
              "startAt": 1700000000123,
              "duration": 3600000,
              "isFree": true,
              "name": "サンプル番組",
              "description": "番組の説明",
              "extended": {"出演者": "出演者情報"},
              "genres": [{"lv1": 3, "lv2": 1}],
              "video": {"type": "MPEG2", "resolution": "1080i", "streamContent": 1},
              "audios": [{"componentType": 2, "isMain": true, "samplingRate": 48000, "langs": ["jpn"]}]
            }]
            """.utf8
        )
    }

    func testProgramsUsesAnonymousGETAndExactServiceQuery() async throws {
        let (client, session) = try clientAndSession()
        var captured: URLRequest?
        MirakurunProgramsTestURLProtocol.handler = { request in
            captured = request
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            return MirakurunProgramsTestURLProtocol.Stub(body: self.programJSON())
        }
        defer {
            session.invalidateAndCancel()
            MirakurunProgramsTestURLProtocol.handler = nil
            MirakurunProgramsTestURLProtocol.requestCount = 0
        }

        let key = try MirakurunServiceKey(networkID: 1, serviceID: 2)
        let programs = try await client.programs(for: key, using: session)

        XCTAssertEqual(programs.count, 1)
        XCTAssertEqual(programs.first?.id, 1001)
        XCTAssertEqual(captured?.url?.path, "/proxy/api/programs")
        let queryItems = URLComponents(url: try XCTUnwrap(captured?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(queryItems?.map { "\($0.name)=\($0.value ?? "")" }, [
            "networkId=1", "serviceId=2"
        ])
    }

    func testProgramDecodesMillisecondsAndOptionalMetadata() async throws {
        let (client, session) = try clientAndSession()
        MirakurunProgramsTestURLProtocol.handler = { _ in
            MirakurunProgramsTestURLProtocol.Stub(body: self.programJSON())
        }
        defer {
            session.invalidateAndCancel()
            MirakurunProgramsTestURLProtocol.handler = nil
        }

        let key = try MirakurunServiceKey(networkID: 1, serviceID: 2)
        let fetched = try await client.programs(for: key, using: session)
        let program = try XCTUnwrap(fetched.first)
        XCTAssertEqual(program.startAt, 1_700_000_000_123)
        XCTAssertEqual(program.duration, 3_600_000)
        XCTAssertEqual(program.endAt, 1_700_003_600_123)
        XCTAssertEqual(program.name, "サンプル番組")
        XCTAssertEqual(program.extended?["出演者"], "出演者情報")
        XCTAssertEqual(program.genres.first?.lv1, 3)
        XCTAssertEqual(program.video?.resolution, "1080i")
        XCTAssertEqual(program.audios.first?.langs, ["jpn"])
    }

    func testMalformedOptionalFieldsAreIgnoredButRequiredFieldsStayStrict() async throws {
        let (client, session) = try clientAndSession()
        let malformedOptionals = Data(
            #"[{"id":1001,"eventId":7,"serviceId":2,"networkId":1,"startAt":1700000000000,"duration":1000,"isFree":true,"name":12,"genres":{},"video":"bad","audios":"bad"}]"#.utf8
        )
        MirakurunProgramsTestURLProtocol.handler = { _ in
            MirakurunProgramsTestURLProtocol.Stub(body: malformedOptionals)
        }
        defer {
            session.invalidateAndCancel()
            MirakurunProgramsTestURLProtocol.handler = nil
        }

        let key = try MirakurunServiceKey(networkID: 1, serviceID: 2)
        let fetched = try await client.programs(for: key, using: session)
        let program = try XCTUnwrap(fetched.first)
        XCTAssertNil(program.name)
        XCTAssertTrue(program.genres.isEmpty)
        XCTAssertNil(program.video)
        XCTAssertTrue(program.audios.isEmpty)

        MirakurunProgramsTestURLProtocol.handler = { _ in
            MirakurunProgramsTestURLProtocol.Stub(
                body: Data(#"[{"id":1001,"eventId":7,"serviceId":2,"networkId":1,"startAt":1700000000000,"duration":1000}]"#.utf8)
            )
        }
        do {
            _ = try await client.programs(for: key, using: session)
            XCTFail("missing required isFree must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testDuplicateAndCrossServiceProgramsAreRejected() async throws {
        let (client, session) = try clientAndSession()
        let duplicate = Data(
            """
            [
              {"id":1001,"eventId":1,"serviceId":2,"networkId":1,"startAt":1700000000000,"duration":1000,"isFree":true},
              {"id":1001,"eventId":2,"serviceId":2,"networkId":1,"startAt":1700000001000,"duration":1000,"isFree":true}
            ]
            """.utf8
        )
        MirakurunProgramsTestURLProtocol.handler = { _ in
            MirakurunProgramsTestURLProtocol.Stub(body: duplicate)
        }
        defer {
            session.invalidateAndCancel()
            MirakurunProgramsTestURLProtocol.handler = nil
        }

        let key = try MirakurunServiceKey(networkID: 1, serviceID: 2)
        do {
            _ = try await client.programs(for: key, using: session)
            XCTFail("duplicate program IDs must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let crossService = Data(
            #"[{"id":1001,"eventId":1,"serviceId":3,"networkId":1,"startAt":1700000000000,"duration":1000,"isFree":true}]"#.utf8
        )
        MirakurunProgramsTestURLProtocol.handler = { _ in
            MirakurunProgramsTestURLProtocol.Stub(body: crossService)
        }
        do {
            _ = try await client.programs(for: key, using: session)
            XCTFail("a program from another service must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testHTTPErrorRedirectAndResponseLimitDoNotExposeBody() async throws {
        let (client, session) = try clientAndSession()
        let key = try MirakurunServiceKey(networkID: 1, serviceID: 2)
        defer {
            session.invalidateAndCancel()
            MirakurunProgramsTestURLProtocol.handler = nil
        }

        MirakurunProgramsTestURLProtocol.handler = { _ in
            MirakurunProgramsTestURLProtocol.Stub(
                status: 503,
                body: Data(#"{"detail":"private server detail"}"#.utf8)
            )
        }
        do {
            _ = try await client.programs(for: key, using: session)
            XCTFail("HTTP error must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .httpStatus(503))
            XCTAssertFalse(error.localizedDescription.contains("private server detail"))
        }

        MirakurunProgramsTestURLProtocol.handler = { request in
            MirakurunProgramsTestURLProtocol.Stub(
                body: Data(),
                redirectURL: URL(string: "http://other.example.invalid/api/programs")
            )
        }
        do {
            _ = try await client.programs(for: key, using: session)
            XCTFail("redirect must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .redirectRejected)
        }

        MirakurunProgramsTestURLProtocol.handler = { _ in
            MirakurunProgramsTestURLProtocol.Stub(
                headers: ["Content-Length": String(MirakurunClient.maximumProgramResponseBytes + 1)],
                body: Data("[]".utf8)
            )
        }
        do {
            _ = try await client.programs(for: key, using: session)
            XCTFail("oversized response must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testCancelledTaskDoesNotStartHTTPRequest() async throws {
        let (client, session) = try clientAndSession()
        MirakurunProgramsTestURLProtocol.requestCount = 0
        MirakurunProgramsTestURLProtocol.handler = { _ in
            MirakurunProgramsTestURLProtocol.Stub(body: Data("[]".utf8))
        }
        defer {
            session.invalidateAndCancel()
            MirakurunProgramsTestURLProtocol.handler = nil
            MirakurunProgramsTestURLProtocol.requestCount = 0
        }

        let key = try MirakurunServiceKey(networkID: 1, serviceID: 2)
        let task = Task<[MirakurunProgram], Error> {
            try await client.programs(for: key, using: session)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled request must throw")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(MirakurunProgramsTestURLProtocol.requestCount, 0)
    }
}
