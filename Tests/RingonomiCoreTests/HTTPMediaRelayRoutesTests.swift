import Foundation
import XCTest
@testable import RingonomiCore

final class HTTPMediaRelayRoutesTests: XCTestCase {
    private let origin = URL(string: "http://127.0.0.1:12345")!
    private let upstream = URL(string: "https://example.test/proxy/playlist.m3u8?session=fixture")!
    private func routes(origin: URL? = nil) throws -> HTTPMediaRelayRoutes {
        try HTTPMediaRelayRoutes(loopbackOrigin: origin ?? self.origin,
                                 scope: HTTPBasicAuthenticationScope(address: "https://example.test/proxy/"))
    }

    func testOnlyExplicitIPv4LoopbackOriginIsAccepted() {
        for address in ["https://127.0.0.1:12345", "http://localhost:12345", "http://0.0.0.0:12345",
                        "http://example.test:12345", "http://127.0.0.1", "http://127.0.0.1:12345/path",
                        "http://user:pass@127.0.0.1:12345", "http://127.0.0.1:12345?q=fixture"] {
            XCTAssertThrowsError(try routes(origin: URL(string: address)!))
        }
    }

    func testRouteIsOpaqueStableAndRoundTrips() throws {
        let routes = try routes()
        let first = try routes.localURL(for: upstream, kind: .playlist)
        XCTAssertEqual(first, try routes.localURL(for: upstream, kind: .playlist))
        XCTAssertEqual(first.host, "127.0.0.1")
        XCTAssertEqual(first.port, 12345)
        XCTAssertTrue(first.path.hasSuffix(".m3u8"))
        XCTAssertNil(first.query)
        XCTAssertFalse(first.absoluteString.contains("example.test"))
        XCTAssertFalse(first.absoluteString.contains("session"))
        XCTAssertFalse(first.absoluteString.contains("fixture"))
        XCTAssertEqual(try routes.resolve(first).url, upstream)
        XCTAssertEqual(try routes.resolve(first).kind, .playlist)
        let binary = try routes.localURL(for: upstream, kind: .media)
        XCTAssertTrue(binary.path.hasSuffix(".bin"))
        XCTAssertNotEqual(first, binary)
    }

    func testCacheEvictionDoesNotBreakPreviouslyIssuedRoutes() throws {
        let routes = try routes()
        let original = try routes.localURL(for: upstream, kind: .playlist)
        for index in 0..<600 {
            _ = try routes.localURL(for: URL(string: "https://example.test/proxy/segment-\(index).ts")!, kind: .media)
        }
        XCTAssertEqual(try routes.resolve(original).url, upstream)
        let replacement = try routes.localURL(for: upstream, kind: .playlist)
        XCTAssertNotEqual(replacement, original)
        XCTAssertEqual(try routes.resolve(replacement).url, upstream)
    }

    func testRouteCannotMoveToAnotherGenerationOriginOrResourceKind() throws {
        let routes = try routes()
        let route = try routes.localURL(for: upstream, kind: .playlist)
        let other = try self.routes()
        XCTAssertThrowsError(try other.resolve(route))
        var changed = URLComponents(url: route, resolvingAgainstBaseURL: false)!
        changed.port = 12346
        XCTAssertThrowsError(try routes.resolve(changed.url!))
        changed.port = 12345
        changed.percentEncodedPath = changed.percentEncodedPath.replacingOccurrences(of: ".m3u8", with: ".bin")
        XCTAssertThrowsError(try routes.resolve(changed.url!))
    }

    func testCiphertextTamperingAndPathInjectionAreRejected() throws {
        let routes = try routes()
        let route = try routes.localURL(for: upstream, kind: .playlist)
        var changed = URLComponents(url: route, resolvingAgainstBaseURL: false)!
        let name = route.lastPathComponent
        let altered = (name.first == "A" ? "B" : "A") + name.dropFirst()
        changed.percentEncodedPath = routes.baseURL.path + altered
        XCTAssertThrowsError(try routes.resolve(changed.url!))
        for name in ["../outside.bin", "unknown.bin", "%2froute.bin", "a/b.bin", ".m3u8"] {
            changed.percentEncodedPath = routes.baseURL.path + name
            XCTAssertThrowsError(try routes.resolve(changed.url!))
        }
    }

    func testStopInvalidatesEveryRouteIncludingEvictedOnes() throws {
        let routes = try routes()
        let route = try routes.localURL(for: upstream, kind: .playlist)
        routes.invalidate()
        routes.invalidate()
        XCTAssertThrowsError(try routes.resolve(route)) { XCTAssertEqual($0 as? HLSRelayError, .stopped) }
        XCTAssertThrowsError(try routes.localURL(for: upstream, kind: .playlist)) { XCTAssertEqual($0 as? HLSRelayError, .stopped) }
    }

    func testOutOfScopeResourcesAreNotRegistered() throws {
        let routes = try routes()
        for address in ["https://other.test/proxy/file", "https://example.test/proxy2/file",
                        "http://example.test/proxy/file", "https://example.test:444/proxy/file"] {
            XCTAssertThrowsError(try routes.localURL(for: URL(string: address)!, kind: .media)) {
                XCTAssertEqual($0 as? HTTPBasicAuthenticationError, .outsideScope)
            }
        }
    }

    func testBlockingReloadQueryIsBoundedAndPreservesUpstreamSession() throws {
        let routes = try routes()
        let local = try routes.localURL(for: upstream, kind: .playlist)
        let reload = URL(string: local.absoluteString + "?_HLS_msn=12&_HLS_part=3&_HLS_skip=v2")!
        let result = try routes.resolve(reload)
        let query = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(URLQueryItem(name: "session", value: "fixture")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "_HLS_msn", value: "12")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "_HLS_part", value: "3")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "_HLS_skip", value: "v2")))
    }

    func testUnknownDuplicateMalformedOrBinaryQueryIsRejected() throws {
        let routes = try routes()
        let playlist = try routes.localURL(for: upstream, kind: .playlist)
        let binary = try routes.localURL(for: upstream, kind: .media)
        for query in ["url=https://other.test/", "_HLS_msn=1&_HLS_msn=2", "_HLS_msn=-1",
                      "_HLS_part=hello", "_HLS_skip=NO", "_HLS_msn=9999999999999999999",
                      "_HLS_msn", "_HLS_part=", "_HLS_skip=v2&extra=1"] {
            XCTAssertThrowsError(try routes.resolve(URL(string: playlist.absoluteString + "?" + query)!))
        }
        XCTAssertThrowsError(try routes.resolve(URL(string: binary.absoluteString + "?_HLS_msn=1")!))
    }

    func testMaximumLengthQueryStillProducesAReadableRoute() throws {
        let routes = try routes()
        let url = URL(string: "https://example.test/proxy/a.ts?q=" + String(repeating: "/", count: 8000))!
        let local = try routes.localURL(for: url, kind: .media)
        XCTAssertEqual(try routes.resolve(local).url, url)
        XCTAssertLessThan(local.lastPathComponent.utf8.count, 16 * 1024)
    }

    func testDescriptionsAndErrorsDoNotExposeUpstreamValues() throws {
        let routes = try routes()
        let output = [String(describing: routes), String(reflecting: routes),
                      Mirror(reflecting: routes).children.map { String(reflecting: $0.value) }.joined()].joined()
        XCTAssertFalse(output.contains("example.test"))
        XCTAssertFalse(output.contains("fixture"))
        for error in [HLSRelayError.invalidPlaylist, .unsupportedPlaylist, .playlistTooLarge, .invalidRoute, .stopped] {
            XCTAssertFalse(error.localizedDescription.contains("example.test"))
        }
    }
}
