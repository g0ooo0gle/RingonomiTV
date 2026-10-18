import Foundation
import XCTest
@testable import RingonomiCore

private final class BackendAuthenticationURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: Data
        let redirectURL: URL?
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
        if let redirectURL = stub.redirectURL {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: nil,
                headerFields: ["Location": redirectURL.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: redirectURL),
                redirectResponse: response
            )
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class BackendAuthenticationTests: XCTestCase {
    override func tearDown() {
        BackendAuthenticationURLProtocol.handler = nil
        BackendAuthenticationURLProtocol.requestCount = 0
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendAuthenticationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                stream.read(pointer.baseAddress!, maxLength: pointer.count)
            }
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    private func stub(status: Int = 200, body: String = "{}", redirectURL: URL? = nil) -> BackendAuthenticationURLProtocol.Stub {
        BackendAuthenticationURLProtocol.Stub(
            status: status,
            body: Data(body.utf8),
            redirectURL: redirectURL
        )
    }

    func testTokenValidationAndRedactedDescriptions() throws {
        let token = try BackendAccessToken(rawValue: "token-123._~")
        XCTAssertEqual(token.rawValue, "token-123._~")
        XCTAssertEqual(token.tokenType, "bearer")
        XCTAssertFalse(token.description.contains(token.rawValue))
        XCTAssertFalse(String(reflecting: token).contains(token.rawValue))
        let mirrorValues = Mirror(reflecting: token).children
            .map { String(describing: $0.value) }
            .joined(separator: "|")
        XCTAssertFalse(mirrorValues.contains(token.rawValue))

        for invalid in ["", "has space", "line\nfeed", "\tindent", "日本語"] {
            XCTAssertThrowsError(try BackendAccessToken(rawValue: invalid))
        }
        XCTAssertThrowsError(try BackendAccessToken(rawValue: String(repeating: "x", count: 16 * 1024 + 1)))
        XCTAssertThrowsError(try BackendAccessToken(token: "valid", tokenType: "basic"))
    }

    func testBaseURLCanonicalizationAndAccountKey() throws {
        let client = try RingonomiClient(address: "HTTPS://Example.COM:443/proxy/tv/")
        XCTAssertTrue(client.baseURL.absoluteString.hasSuffix("/proxy/"))
        XCTAssertEqual(client.accountKeyString, "https://example.com/proxy/")

        let root = try RingonomiClient(address: "http://Example.COM:80/tv")
        XCTAssertTrue(root.baseURL.absoluteString.hasSuffix("/"))
        XCTAssertEqual(root.accountKeyString, "http://example.com/")

        let nestedTV = try RingonomiClient(address: "https://Example.COM/proxy/tv/tv/")
        XCTAssertTrue(nestedTV.baseURL.absoluteString.hasSuffix("/proxy/tv/"))
        XCTAssertEqual(nestedTV.accountKeyString, "https://example.com/proxy/tv/")

        let ipv6 = try RingonomiClient(address: "HTTPS://[::1]:8443/proxy/")
        XCTAssertEqual(ipv6.accountKeyString, "https://[::1]:8443/proxy/")

        let unicodePath = try RingonomiClient(address: "https://Example.COM/proxy/視聴/")
        XCTAssertTrue(unicodePath.accountKeyString.contains("%E8%A6%96%E8%81%B4"))
    }

    func testAuthorizationIsLimitedToSameServerAPI() throws {
        let token = try BackendAccessToken(rawValue: "scope-test")
        let client = try RingonomiClient(address: "https://example.invalid/proxy", accessToken: token)

        let apiRequest = URLRequest(url: client.endpoint(["api", "users", "me"]))
        let authorized = try client.backendAuthorizedRequest(apiRequest)
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer scope-test")

        for url in [
            URL(string: "https://example.invalid/proxy/not-api")!,
            URL(string: "https://other.invalid/proxy/api/users/me")!
        ] {
            XCTAssertThrowsError(try client.backendAuthorizedRequest(URLRequest(url: url))) { error in
                XCTAssertEqual(error as? ConnectionError, .tokenScopeViolation)
            }
        }

        let httpClient = try RingonomiClient(
            address: "http://example.invalid/proxy",
            accessToken: token
        )
        XCTAssertThrowsError(
            try httpClient.backendAuthorizedRequest(
                URLRequest(url: httpClient.endpoint(["api", "users", "me"]))
            )
        ) { error in
            XCTAssertEqual(error as? ConnectionError, .tokenScopeViolation)
        }
    }

    func testRejectsDotSegmentsAndAmbiguousEncodedPathForAddressAndRequest() throws {
        for address in [
            "https://example.invalid/proxy/../api",
            "https://example.invalid/proxy/%2e%2e/api",
            "https://example.invalid/proxy/%2Fapi",
            "https://example.invalid/proxy/%5Capi",
            "https://example.invalid/proxy/%252e%252e/api"
        ] {
            XCTAssertThrowsError(try RingonomiClient(address: address), address)
        }

        let token = try BackendAccessToken(rawValue: "scope-test")
        let client = try RingonomiClient(address: "https://example.invalid/proxy", accessToken: token)
        for path in [
            "/proxy/../api/users/me",
            "/proxy/%2e%2e/api/users/me",
            "/proxy/api/%2Fusers",
            "/proxy/api/%5Cusers",
            "/proxy/api/%252e%252e/users"
        ] {
            let url = try XCTUnwrap(URL(string: "https://example.invalid\(path)"))
            XCTAssertThrowsError(try client.backendAuthorizedRequest(URLRequest(url: url)), path)
        }
    }

    func testBackendDataPreservesNonSuccessResponseForTypedAPIClients() async throws {
        BackendAuthenticationURLProtocol.handler = { _ in
            self.stub(status: 409, body: #"{"detail":"conflict"}"#)
        }
        let client = try RingonomiClient(address: "https://example.invalid/proxy")
        let request = URLRequest(url: client.endpoint(["api", "reservations"]))
        let (data, response) = try await client.backendData(for: request, using: session())
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"detail":"conflict"}"#)
    }

    func testLoginUsesFormEncodingAndReturnsBearerToken() async throws {
        var captured: URLRequest?
        var capturedBody: Data?
        BackendAuthenticationURLProtocol.handler = { request in
            captured = request
            capturedBody = self.requestBodyData(request)
            return self.stub(body: #"{"access_token":"abc123","token_type":"bearer"}"#)
        }
        let client = try RingonomiClient(address: "https://example.invalid/proxy")
        let token = try await client.login(
            username: "user name",
            password: "p&ss/日本語",
            using: session()
        )

        XCTAssertEqual(token.rawValue, "abc123")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/proxy/api/users/token")
        XCTAssertEqual(
            String(data: try XCTUnwrap(capturedBody), encoding: .utf8),
            "grant_type=password&username=user+name&password=p%26ss%2F%E6%97%A5%E6%9C%AC%E8%AA%9E"
        )
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    }

    func testLoginRequiresHTTPSAndCannotReuseAuthenticatedClient() async throws {
        let anonymous = try RingonomiClient(address: "http://example.invalid/proxy")
        do {
            _ = try await anonymous.login(username: "user", password: "pass", using: session())
            XCTFail("HTTP login must be rejected before a request is sent")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .insecureAuthentication)
        }

        let authenticated = try RingonomiClient(
            address: "https://example.invalid/proxy",
            accessToken: try BackendAccessToken(rawValue: "already-set")
        )
        do {
            _ = try await authenticated.login(username: "user", password: "pass", using: session())
            XCTFail("a configured client must not send another password")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .authenticationAlreadyConfigured)
        }
    }

    func testLoginRejectsEmptyAndOversizedCredentialsBeforeNetwork() async throws {
        BackendAuthenticationURLProtocol.handler = { _ in
            XCTFail("invalid credentials must not reach the server")
            return self.stub(body: #"{"access_token":"unexpected","token_type":"bearer"}"#)
        }
        let client = try RingonomiClient(address: "https://example.invalid/proxy")
        for (username, password) in [
            ("", "pass"),
            ("user", ""),
            (String(repeating: "u", count: 1025), "pass"),
            ("user", String(repeating: "p", count: 16 * 1024 + 1))
        ] {
            do {
                _ = try await client.login(username: username, password: password, using: session())
                XCTFail("invalid credentials must fail")
            } catch let error as ConnectionError {
                XCTAssertEqual(error, .invalidCredentials)
            }
        }
        XCTAssertEqual(BackendAuthenticationURLProtocol.requestCount, 0)
    }

    func testLoginMapsUnauthorizedAndForbiddenWithoutExposingBody() async throws {
        XCTAssertTrue(ConnectionError.http(401).localizedDescription.contains("HTTP 401"))
        XCTAssertTrue(ConnectionError.http(403).localizedDescription.contains("HTTP 403"))
        for (status, expected) in [(401, ConnectionError.http(401)), (403, ConnectionError.http(403))] {
            BackendAuthenticationURLProtocol.handler = { _ in
                self.stub(status: status, body: #"{"detail":"private server detail"}"#)
            }
            let client = try RingonomiClient(address: "https://example.invalid/proxy")
            do {
                _ = try await client.login(username: "user", password: "pass", using: session())
                XCTFail("status \(status) must fail")
            } catch let error as ConnectionError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.localizedDescription.contains("private server detail"))
            }
        }
    }

    func testInvalidTokenResponseAndCurrentUserProfile() async throws {
        BackendAuthenticationURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/token") == true {
                return self.stub(body: #"{"access_token":"abc","token_type":"basic"}"#)
            }
            return self.stub(body: #"{"id":12,"name":"視聴者","is_admin":false}"#)
        }
        let anonymous = try RingonomiClient(address: "https://example.invalid/proxy")
        do {
            _ = try await anonymous.login(username: "user", password: "pass", using: session())
            XCTFail("non-bearer token response must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidToken)
        }

        let client = try RingonomiClient(
            address: "https://example.invalid/proxy",
            accessToken: try BackendAccessToken(rawValue: "abc")
        )
        let user = try await client.currentUser(using: session())
        XCTAssertEqual(user.id, 12)
        XCTAssertEqual(user.name, "視聴者")
        XCTAssertFalse(user.isAdmin)
    }

    func testCurrentUserRequiresTokenAndRejectsMalformedProfile() async throws {
        let anonymous = try RingonomiClient(address: "https://example.invalid/proxy")
        do {
            _ = try await anonymous.currentUser(using: session())
            XCTFail("anonymous profile request must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .notAuthenticated)
        }

        BackendAuthenticationURLProtocol.handler = { _ in
            self.stub(body: #"{"id":"wrong","name":"視聴者","is_admin":false}"#)
        }
        let client = try RingonomiClient(
            address: "https://example.invalid/proxy",
            accessToken: try BackendAccessToken(rawValue: "abc")
        )
        do {
            _ = try await client.currentUser(using: session())
            XCTFail("malformed profile must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testAuthenticatedRedirectToAnotherOriginIsRejected() async throws {
        BackendAuthenticationURLProtocol.handler = { request in
            self.stub(
                status: 302,
                redirectURL: URL(string: "https://other.invalid/api/users/me")
            )
        }
        let client = try RingonomiClient(
            address: "https://example.invalid/proxy",
            accessToken: try BackendAccessToken(rawValue: "abc")
        )
        do {
            _ = try await client.currentUser(using: session())
            XCTFail("cross-origin redirect must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .redirectRejected)
        }
        XCTAssertEqual(BackendAuthenticationURLProtocol.requestCount, 1)
    }

    func testLoginRejectsEvenSameOriginRedirect() async throws {
        BackendAuthenticationURLProtocol.handler = { request in
            self.stub(
                status: 302,
                redirectURL: URL(string: "https://example.invalid/proxy/api/users/token")
            )
        }
        let client = try RingonomiClient(address: "https://example.invalid/proxy")
        do {
            _ = try await client.login(username: "user", password: "pass", using: session())
            XCTFail("password login must never follow a redirect")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .redirectRejected)
        }
        XCTAssertEqual(BackendAuthenticationURLProtocol.requestCount, 1)
    }

    func testAuthenticatedRedirectWithAmbiguousPathIsRejected() async throws {
        BackendAuthenticationURLProtocol.handler = { _ in
            self.stub(
                status: 302,
                redirectURL: URL(string: "https://example.invalid/proxy/api/%2e%2e/users/me")
            )
        }
        let client = try RingonomiClient(
            address: "https://example.invalid/proxy",
            accessToken: try BackendAccessToken(rawValue: "abc")
        )
        do {
            _ = try await client.currentUser(using: session())
            XCTFail("ambiguous redirect path must fail")
        } catch let error as ConnectionError {
            XCTAssertEqual(error, .redirectRejected)
        }
    }
}
