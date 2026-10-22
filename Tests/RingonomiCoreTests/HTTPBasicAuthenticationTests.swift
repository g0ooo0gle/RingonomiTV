import Foundation
import XCTest
@testable import RingonomiCore

final class HTTPBasicAuthenticationTests: XCTestCase {
    private func scope(_ address: String = "https://example.test/proxy/") throws -> HTTPBasicAuthenticationScope {
        try HTTPBasicAuthenticationScope(address: address)
    }

    private func credential() throws -> HTTPBasicCredential {
        try HTTPBasicCredential(username: "fixture-user", password: "fixture-password")
    }

    func testRFC7617ASCIIExample() throws {
        let value = try HTTPBasicCredential(username: "Aladdin", password: "open sesame")
        XCTAssertEqual(value.authorizationValue, "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
    }

    func testEmptyPasswordAndMeaningfulWhitespaceArePreserved() throws {
        let empty = try HTTPBasicCredential(username: "user", password: "")
        XCTAssertEqual(empty.authorizationValue, "Basic dXNlcjo=")
        let spaced = try HTTPBasicCredential(username: " user ", password: " :pass: ")
        let data = Data(base64Encoded: String(spaced.authorizationValue.dropFirst(6)))!
        XCTAssertEqual(String(decoding: data, as: UTF8.self), " user : :pass: ")
    }

    func testInvalidUsernameAndControlsAreRejected() {
        for name in ["", "user:other", "line\nfeed", "tab\tname", "\0", "\u{7F}", "\u{85}"] {
            XCTAssertThrowsError(try HTTPBasicCredential(username: name, password: "fixture")) {
                XCTAssertEqual($0 as? HTTPBasicAuthenticationError, .invalidCredentials)
            }
        }
        for password in ["\0", "line\r\nfeed", "tab\t", "\u{7F}", "\u{85}"] {
            XCTAssertThrowsError(try HTTPBasicCredential(username: "fixture", password: password))
        }
    }

    func testCredentialSizeLimitsUseBytes() throws {
        _ = try HTTPBasicCredential(username: String(repeating: "u", count: 1024), password: String(repeating: "p", count: 16 * 1024))
        XCTAssertThrowsError(try HTTPBasicCredential(username: String(repeating: "u", count: 1025), password: "p"))
        XCTAssertThrowsError(try HTTPBasicCredential(username: "u", password: String(repeating: "p", count: 16 * 1024 + 1)))
        XCTAssertThrowsError(try HTTPBasicCredential(username: String(repeating: "あ", count: 342), password: "p", encoding: .utf8))
    }

    func testNonASCIIRequiresExplicitUTF8AndUsesNFC() throws {
        XCTAssertThrowsError(try HTTPBasicCredential(username: "視聴者", password: "fixture")) {
            XCTAssertEqual($0 as? HTTPBasicAuthenticationError, .unsupportedEncoding)
        }
        XCTAssertThrowsError(try HTTPBasicCredential(username: "fixture", password: "合成パスワード"))
        let composed = try HTTPBasicCredential(username: "café", password: "é", encoding: .utf8)
        let decomposed = try HTTPBasicCredential(username: "cafe\u{301}", password: "e\u{301}", encoding: .utf8)
        XCTAssertEqual(composed, decomposed)
        let data = Data(base64Encoded: String(composed.authorizationValue.dropFirst(6)))!
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "café:é")
    }

    func testCredentialDescriptionsAndMirrorNeverExposeEitherForm() throws {
        let value = try credential()
        let output = [value.description, value.debugDescription, String(describing: value),
                      String(reflecting: value),
                      Mirror(reflecting: value).children.map { String(reflecting: $0.value) }.joined()]
            .joined(separator: "|")
        for secret in ["fixture-user", "fixture-password", value.authorizationValue,
                       String(value.authorizationValue.dropFirst(6))] {
            XCTAssertFalse(output.contains(secret))
        }
    }

    func testCanonicalScopeIdentityRetainsPathAndDefaultPort() throws {
        let value = try scope(" HTTPS://EXAMPLE.test:443/proxy ")
        XCTAssertEqual(value.baseURL.absoluteString, "https://example.test/proxy/")
        XCTAssertEqual(value.storageIdentity, "https://example.test/proxy/")
        XCTAssertEqual(value, try scope("https://example.test/proxy/"))
        XCTAssertNotEqual(value, try scope("https://example.test:444/proxy/"))
        XCTAssertNotEqual(value, try scope("https://example.test/other/"))
        XCTAssertEqual(try scope("https://example.test/proxy/tv/").storageIdentity, "https://example.test/proxy/tv/")
    }

    func testInvalidBaseAddressesAreRejected() {
        for address in ["", "example.test", "/proxy/", "ftp://example.test/", "https:///",
                        "https://user:pass@example.test/", "https://user@example.test/",
                        "https://example.test/?query=1", "https://example.test/#fragment",
                        "https://example.test:0/", "https://example.test:65536/",
                        "https://exam\nple.test/"] {
            XCTAssertThrowsError(try scope(address), address)
        }
    }

    func testPlainHTTPIsNotAValidCredentialScope() {
        XCTAssertThrowsError(try scope("http://example.test/proxy/")) {
            XCTAssertEqual($0 as? HTTPBasicAuthenticationError, .insecureConnection)
        }
    }

    func testSameOriginAPIAndMediaRequestsAreAllowed() throws {
        let value = try scope()
        for suffix in ["", "api/channels", "api/videos?page=2", "hls/master.m3u8",
                       "hls/variant/playlist.m3u8", "hls/segment-1.ts?session=fixture",
                       "hls/init.mp4", "hls/key.bin", "日本語/録画.mp4"] {
            let url = URL(string: "https://example.test/proxy/" + suffix)!
            XCTAssertTrue(value.contains(url), suffix)
            let request = try value.authorizing(URLRequest(url: url), credential: credential())
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), try credential().authorizationValue)
            XCTAssertEqual(request.url, url)
        }
    }

    func testDifferentOriginsDowngradesAndPathSiblingsAreDenied() throws {
        let value = try scope()
        for address in ["https://other.test/proxy/api", "https://example.test.evil.test/proxy/api",
                        "https://example.test:444/proxy/api", "http://example.test/proxy/api",
                        "https://example.test/proxy", "https://example.test/proxy2/api",
                        "https://example.test/Proxy/api", "https://example.test/api",
                        "wss://example.test/proxy/comments", "file:///proxy/recording.mp4",
                        "https://user:pass@example.test/proxy/api", "https://example.test/proxy/api#fragment"] {
            let url = URL(string: address)!
            XCTAssertFalse(value.contains(url), address)
            XCTAssertThrowsError(try value.authorizing(URLRequest(url: url), credential: credential()), address) {
                XCTAssertEqual($0 as? HTTPBasicAuthenticationError, .outsideScope)
            }
        }
    }

    func testDotSegmentsEncodedSeparatorsAndDoubleDecodingAreDenied() throws {
        let value = try scope()
        for path in ["/proxy/../api", "/proxy/./api", "/proxy/%2e%2e/api", "/proxy/%2E/api",
                     "/proxy/%2fother/api", "/proxy/%2Fother/api", "/proxy/%5cother/api",
                     "/proxy/%252e%252e/api", "/proxy/%252fother/api",
                     "/proxy//api", "/proxy/..;/api", "/proxy/segment%3Bparam/file",
                     "/proxy/%00/api", "/proxy/%0d%0a/api", "/proxy/%7F/api"] {
            let url = URL(string: "https://example.test" + path)!
            XCTAssertFalse(value.contains(url), path)
            XCTAssertThrowsError(try value.authorizing(URLRequest(url: url), credential: credential()), path)
            XCTAssertThrowsError(try scope("https://example.test" + path), path)
        }
    }

    func testRootScopeStillRejectsForeignOriginsAndAmbiguousPaths() throws {
        let value = try scope("https://example.test")
        XCTAssertEqual(value.storageIdentity, "https://example.test/")
        XCTAssertTrue(value.contains(URL(string: "https://example.test/api/videos")!))
        XCTAssertFalse(value.contains(URL(string: "https://other.test/api/videos")!))
        XCTAssertFalse(value.contains(URL(string: "https://example.test/%2e%2e/private")!))
    }

    func testIPv6AndExplicitDefaultPortHaveTheSameScope() throws {
        let value = try scope("https://[2001:db8::1]:443/proxy/")
        XCTAssertTrue(value.contains(URL(string: "https://[2001:db8::1]/proxy/api")!))
        XCTAssertFalse(value.contains(URL(string: "https://[2001:db8::2]/proxy/api")!))
        XCTAssertFalse(value.contains(URL(string: "https://[2001:db8::1]:444/proxy/api")!))
    }

    func testRelativeURLsMustBeResolvedAndCheckedBeforeAuthorization() throws {
        let value = try scope()
        let relative = URL(string: "api/videos", relativeTo: value.baseURL)!
        XCTAssertFalse(value.contains(relative))
        XCTAssertTrue(value.contains(relative.absoluteURL))
        let external = URL(string: "//other.test/proxy/segment.ts", relativeTo: value.baseURL)!
        XCTAssertFalse(value.contains(external.absoluteURL))
    }

    func testCookiesAreStrippedAndRequestContentIsPreserved() throws {
        let value = try scope()
        let url = URL(string: "https://example.test/proxy/api/reserves")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"fixture\":true}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("session=unrelated", forHTTPHeaderField: "Cookie")
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.httpShouldHandleCookies = true
        let result = try value.authorizing(request, credential: credential())
        XCTAssertEqual(result.url, url)
        XCTAssertEqual(result.httpBody, request.httpBody)
        XCTAssertEqual(result.httpMethod, "POST")
        XCTAssertEqual(result.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(result.value(forHTTPHeaderField: "Range"), "bytes=0-1023")
        XCTAssertNil(result.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(result.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=unrelated")
    }

    func testExistingBearerBasicOrProxyAuthorizationIsNotOverwritten() throws {
        let value = try scope()
        for (header, authorization) in [("Authorization", "Bearer fixture-token"),
                                        ("authorization", "Basic Zml4dHVyZQ=="),
                                        ("Proxy-Authorization", "Basic Zml4dHVyZQ==")] {
            var request = URLRequest(url: URL(string: "https://example.test/proxy/api")!)
            request.setValue(authorization, forHTTPHeaderField: header)
            XCTAssertThrowsError(try value.authorizing(request, credential: credential())) {
                XCTAssertEqual($0 as? HTTPBasicAuthenticationError, .conflictingAuthorization)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: header), authorization)
        }
    }

    func testScopeDescriptionsAndErrorsDoNotExposePrivateDetails() throws {
        let value = try scope()
        let output = [value.description, value.debugDescription, String(reflecting: value),
                      Mirror(reflecting: value).children.map { String(reflecting: $0.value) }.joined()]
            .joined()
        XCTAssertFalse(output.contains("example.test"))
        XCTAssertFalse(output.contains("proxy"))
        for error in [HTTPBasicAuthenticationError.invalidCredentials, .unsupportedEncoding, .invalidAddress,
                      .insecureConnection, .outsideScope, .conflictingAuthorization] {
            XCTAssertFalse(error.localizedDescription.contains("example.test"))
            XCTAssertFalse(error.localizedDescription.contains("fixture"))
        }
    }
}
