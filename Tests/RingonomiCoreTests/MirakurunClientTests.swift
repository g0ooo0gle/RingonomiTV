import Foundation
import XCTest
@testable import RingonomiCore

private final class MirakurunURLProtocol: URLProtocol {
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
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MirakurunClientTests: XCTestCase {
    private func clientAndSession(
        address: String = "http://example.invalid/proxy"
    ) throws -> (MirakurunClient, URLSession) {
        let client = try MirakurunClient(address: address)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MirakurunURLProtocol.self]
        configuration.httpShouldSetCookies = true
        return (client, URLSession(configuration: configuration))
    }

    private func serviceJSON(
        id: Int = 100_002,
        serviceID: Int = 2,
        networkID: Int = 1
    ) -> Data {
        Data(
            """
            [{
              "id": \(id),
              "serviceId": \(serviceID),
              "networkId": \(networkID),
              "name": "地デジサンプル",
              "type": 1,
              "logoId": 42,
              "hasLogoData": true,
              "remoteControlKeyId": 1,
              "epgReady": true,
              "epgUpdatedAt": 1700000000000,
              "transportStreamId": 15,
              "channel": {"type": "GR", "channel": "13", "name": "地デジ"}
            }]
            """.utf8
        )
    }

    func testServiceKeyUsesCheckedServiceItemIDFormula() throws {
        let key = try MirakurunServiceKey(networkID: 32736, serviceID: 101, transportStreamID: 7)
        XCTAssertEqual(key.networkID, 32736)
        XCTAssertEqual(key.serviceID, 101)
        XCTAssertEqual(key.transportStreamID, 7)
        XCTAssertEqual(key.serviceItemID, 3_273_600_101)
        XCTAssertEqual(
            MirakurunServiceKey.serviceItemID(networkID: 32736, serviceID: 101),
            3_273_600_101
        )
    }

    func testServiceKeyUsesUInt16BoundariesAndRejectsOutsideValues() throws {
        let zero = try MirakurunServiceKey(networkID: 0, serviceID: 0, transportStreamID: 0)
        XCTAssertEqual(zero.serviceItemID, 0)
        let maximum = try MirakurunServiceKey(
            networkID: MirakurunServiceKey.maximumIdentifier,
            serviceID: MirakurunServiceKey.maximumIdentifier,
            transportStreamID: MirakurunServiceKey.maximumIdentifier
        )
        XCTAssertEqual(maximum.serviceItemID, MirakurunServiceKey.maximumServiceItemID)

        XCTAssertThrowsError(try MirakurunServiceKey(networkID: -1, serviceID: 1))
        XCTAssertThrowsError(try MirakurunServiceKey(networkID: 1, serviceID: 65_536))
        XCTAssertThrowsError(try MirakurunServiceKey(networkID: 1, serviceID: 1, transportStreamID: -1))
        XCTAssertThrowsError(try MirakurunServiceKey(networkID: 1, serviceID: 1, transportStreamID: 65_536))
        XCTAssertNil(MirakurunServiceKey.serviceItemID(networkID: Int.max, serviceID: 1))
    }

    func testServiceKeyDecodingAlwaysRunsIdentifierValidation() throws {
        let decoder = JSONDecoder()
        let invalidService = Data(#"{"networkID":1,"serviceID":100000,"transportStreamID":0}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(MirakurunServiceKey.self, from: invalidService)) { error in
            XCTAssertEqual(error as? MirakurunError, .invalidIdentifier)
        }

        let invalidNetwork = Data(#"{"networkID":-1,"serviceID":1}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(MirakurunServiceKey.self, from: invalidNetwork)) { error in
            XCTAssertEqual(error as? MirakurunError, .invalidIdentifier)
        }
    }

    func testOfficialServiceShapeDecodesRequiredAndOptionalFields() throws {
        let services = try JSONDecoder().decode([MirakurunService].self, from: serviceJSON())
        let service = try XCTUnwrap(services.first)

        XCTAssertEqual(service.id, 100_002)
        XCTAssertEqual(service.networkID, 1)
        XCTAssertEqual(service.serviceID, 2)
        XCTAssertEqual(service.name, "地デジサンプル")
        XCTAssertEqual(service.type, 1)
        XCTAssertEqual(service.logoID, 42)
        XCTAssertEqual(service.hasLogoData, true)
        XCTAssertEqual(service.channel?.type, "GR")
        XCTAssertEqual(service.transportStreamID, 15)
        XCTAssertEqual(service.key.serviceItemID, 100_002)
    }

    func testOptionalServiceFieldsMayBeMissingButRequiredFieldsMayNot() throws {
        let minimal = Data(#"[{"id":100002,"serviceId":2,"networkId":1,"name":"サービス","type":1}]"#.utf8)
        let service = try XCTUnwrap(JSONDecoder().decode([MirakurunService].self, from: minimal).first)
        XCTAssertNil(service.logoID)
        XCTAssertNil(service.channel)

        let missingID = Data(#"[{"serviceId":2,"networkId":1,"name":"サービス","type":1}]"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([MirakurunService].self, from: missingID))
    }

    func testOfficialServiceMayHaveAnEmptyNameButNotControlCharacters() throws {
        let emptyName = Data(#"[{"id":100002,"serviceId":2,"networkId":1,"name":"","type":1}]"#.utf8)
        let service = try XCTUnwrap(JSONDecoder().decode([MirakurunService].self, from: emptyName).first)
        XCTAssertEqual(service.name, "")

        let controlCharacter = Data("[{\"id\":100002,\"serviceId\":2,\"networkId\":1,\"name\":\"bad\\u0001\",\"type\":1}]".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([MirakurunService].self, from: controlCharacter))
    }

    func testServiceRejectsIDThatDoesNotMatchNetworkAndService() throws {
        XCTAssertThrowsError(
            try MirakurunService(
                id: 100_003,
                serviceID: 2,
                networkID: 1,
                name: "サービス",
                type: 1
            )
        ) { error in
            XCTAssertEqual(error as? MirakurunError, .invalidIdentifier)
        }
    }

    func testServiceURLsPreserveConfiguredProxyPath() throws {
        let client = try MirakurunClient(address: "http://example.invalid/proxy///")
        let key = try MirakurunServiceKey(networkID: 1, serviceID: 2)

        XCTAssertEqual(
            client.streamURL(for: key).absoluteString,
            "http://example.invalid/proxy/api/services/100002/stream"
        )
        XCTAssertEqual(
            client.logoURL(for: key).absoluteString,
            "http://example.invalid/proxy/api/services/100002/logo"
        )
    }

    func testInitializerRejectsUnsafeAddressForms() {
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
            XCTAssertThrowsError(try MirakurunClient(address: address), "unsafe address should fail: \(address)") { error in
                XCTAssertEqual(error as? MirakurunError, .invalidAddress)
            }
        }
    }

    func testServicesUsesAnonymousGETAndDecodesResponse() async throws {
        let (client, session) = try clientAndSession()
        var captured: URLRequest?
        MirakurunURLProtocol.handler = { request in
            captured = request
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            return MirakurunURLProtocol.Stub(body: self.serviceJSON())
        }
        defer {
            session.invalidateAndCancel()
            MirakurunURLProtocol.handler = nil
        }

        let services = try await client.services(using: session)
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(captured?.url?.path, "/proxy/api/services")
    }

    func testServicesMapsHTTPStatusWithoutReadingServerBody() async throws {
        let (client, session) = try clientAndSession()
        MirakurunURLProtocol.handler = { request in
            MirakurunURLProtocol.Stub(
                status: 503,
                body: Data(#"{"secret":"must not appear"}"#.utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            MirakurunURLProtocol.handler = nil
        }

        do {
            _ = try await client.services(using: session)
            XCTFail("non-success status must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .httpStatus(503))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testServicesRejectsMalformedAndOversizedResponses() async throws {
        let (client, session) = try clientAndSession()
        defer {
            session.invalidateAndCancel()
            MirakurunURLProtocol.handler = nil
        }

        MirakurunURLProtocol.handler = { _ in
            MirakurunURLProtocol.Stub(body: Data(#"{"not":"an array"}"#.utf8))
        }
        do {
            _ = try await client.services(using: session)
            XCTFail("malformed list must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .invalidResponse)
        }

        MirakurunURLProtocol.handler = { _ in
            MirakurunURLProtocol.Stub(
                headers: ["Content-Length": String(MirakurunClient.maximumServiceResponseBytes + 1)],
                body: Data(repeating: 0x20, count: MirakurunClient.maximumServiceResponseBytes + 1)
            )
        }
        do {
            _ = try await client.services(using: session)
            XCTFail("oversized list must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testServicesRejectsDuplicateServiceItemIDs() async throws {
        let (client, session) = try clientAndSession()
        MirakurunURLProtocol.handler = { _ in
            let one = String(decoding: self.serviceJSON(), as: Unicode.UTF8.self)
                .dropFirst()
                .dropLast()
            return MirakurunURLProtocol.Stub(
                body: Data("[\(one),\(one)]".utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            MirakurunURLProtocol.handler = nil
        }

        do {
            _ = try await client.services(using: session)
            XCTFail("duplicate service IDs must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testRedirectIsRejectedWithoutFollowingIt() async throws {
        let (client, session) = try clientAndSession()
        var requestCount = 0
        MirakurunURLProtocol.handler = { request in
            requestCount += 1
            return MirakurunURLProtocol.Stub(
                status: 302,
                headers: ["Location": "https://other.invalid/api/services"],
                body: Data(),
                redirectURL: URL(string: "https://other.invalid/api/services")
            )
        }
        defer {
            session.invalidateAndCancel()
            MirakurunURLProtocol.handler = nil
        }

        do {
            _ = try await client.services(using: session)
            XCTFail("redirect must fail")
        } catch let error as MirakurunError {
            XCTAssertEqual(error, .redirectRejected)
        }
        XCTAssertEqual(requestCount, 1)
    }
}
