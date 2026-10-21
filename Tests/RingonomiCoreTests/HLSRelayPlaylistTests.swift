import Foundation
import XCTest
@testable import RingonomiCore

final class HLSRelayPlaylistTests: XCTestCase {
    private let source = URL(string: "https://example.test/proxy/hls/master.m3u8?session=fixture")!
    private func scope() throws -> HTTPBasicAuthenticationScope {
        try HTTPBasicAuthenticationScope(address: "https://example.test/proxy/")
    }
    private func parse(_ text: String, source: URL? = nil) throws -> HLSRelayPlaylist {
        try HLSRelayPlaylist(data: Data(text.utf8), sourceURL: source ?? self.source, scope: scope())
    }
    private func routes() throws -> HTTPMediaRelayRoutes {
        try HTTPMediaRelayRoutes(loopbackOrigin: URL(string: "http://127.0.0.1:12345")!, scope: scope())
    }

    func testMasterVariantsAudioSubtitlesIFramesAndKeysAreAllRewritten() throws {
        let document = try parse("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-SESSION-KEY:METHOD=AES-128,URI="../keys/key.bin"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="main, alternate",URI="audio/index.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="字幕",URI="subs/index.m3u8"
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,URI="iframe/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="avc1.64001f,mp4a.40.2",AUDIO="audio"
        # a comment between the variant tag and its URI
        video/index.m3u8?session=fixture
        """)
        XCTAssertEqual(document.references.map(\.kind), [.media, .playlist, .playlist, .playlist, .playlist])
        XCTAssertEqual(document.references[0].url.absoluteString, "https://example.test/proxy/keys/key.bin")
        XCTAssertEqual(document.references[4].url.absoluteString, "https://example.test/proxy/hls/video/index.m3u8?session=fixture")
        let routes = try routes()
        let result = String(decoding: try document.rewritten(using: routes), as: UTF8.self)
        XCTAssertTrue(result.contains("NAME=\"main, alternate\""))
        XCTAssertTrue(result.contains("CODECS=\"avc1.64001f,mp4a.40.2\""))
        XCTAssertFalse(result.contains("example.test"))
        XCTAssertFalse(result.contains("session=fixture"))
        for reference in document.references {
            let local = try routes.localURL(for: reference.url, kind: reference.kind)
            XCTAssertTrue(result.contains(local.absoluteString))
            XCTAssertEqual(try routes.resolve(local), reference)
        }
    }

    func testMediaKeyMapSegmentsAndByteRangesArePreserved() throws {
        let document = try parse("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="128@0"
        #EXT-X-KEY:METHOD=AES-128,URI="keys/current.bin",IV=0x00000000000000000000000000000001
        #EXTINF:6.0,
        #EXT-X-BYTERANGE:1024@128
        media.mp4
        #EXT-X-DISCONTINUITY
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:6.0,
        media2.ts
        #EXT-X-ENDLIST
        """)
        XCTAssertEqual(document.references.map(\.kind), [.media, .media, .media, .media])
        let result = String(decoding: try document.rewritten(using: routes()), as: UTF8.self)
        XCTAssertTrue(result.contains("BYTERANGE=\"128@0\""))
        XCTAssertTrue(result.contains("#EXT-X-BYTERANGE:1024@128"))
        XCTAssertTrue(result.contains("#EXT-X-KEY:METHOD=NONE"))
        XCTAssertTrue(result.contains("#EXT-X-DISCONTINUITY"))
        XCTAssertTrue(result.contains("#EXT-X-ENDLIST"))
        XCTAssertFalse(result.contains("keys/current.bin"))
    }

    func testChildPlaylistResolvesAgainstItsOwnURL() throws {
        let child = URL(string: "https://example.test/proxy/hls/video/index.m3u8")!
        let document = try parse("#EXTM3U\n#EXTINF:6,\n../segments/one.ts\n", source: child)
        XCTAssertEqual(document.references[0].url.absoluteString, "https://example.test/proxy/hls/segments/one.ts")
    }

    func testLLHLSResourceReferencesAreRewritten() throws {
        let document = try parse("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.5
        #EXT-X-PART-INF:PART-TARGET=0.5
        #EXT-X-PART:DURATION=0.5,URI="part.m4s",BYTERANGE="100@0"
        #EXT-X-PRELOAD-HINT:TYPE=PART,URI="next.m4s",BYTERANGE-START=100
        #EXT-X-RENDITION-REPORT:URI="audio/index.m3u8",LAST-MSN=12,LAST-PART=2
        """)
        XCTAssertEqual(document.references.map(\.kind), [.media, .media, .playlist])
        let result = String(decoding: try document.rewritten(using: routes()), as: UTF8.self)
        XCTAssertTrue(result.contains("CAN-BLOCK-RELOAD=YES"))
        XCTAssertTrue(result.contains("BYTERANGE-START=100"))
        XCTAssertFalse(result.contains("next.m4s"))
    }

    func testInBandMediaAndInlineSessionDataNeedNoExternalURI() throws {
        let document = try parse("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="captions",INSTREAM-ID="CC1"
        #EXT-X-SESSION-DATA:DATA-ID="fixture.title",VALUE="a title, with comma"
        #EXT-X-STREAM-INF:BANDWIDTH=1000
        video.m3u8
        """)
        XCTAssertEqual(document.references.count, 1)
        XCTAssertEqual(document.references[0].kind, .playlist)
    }

    func testExternalOrSiblingResourcesAreRejectedInEveryURIPosition() throws {
        for bad in ["https://other.test/proxy/file", "https://example.test:444/proxy/file",
                    "http://example.test/proxy/file", "/proxy2/file", "../../outside/file",
                    "//other.test/proxy/file", "skd://example.test/key", "data:text/plain,fixture"] {
            let placements = [
                "#EXTINF:6,\n\(bad)",
                "#EXT-X-STREAM-INF:BANDWIDTH=1000\n\(bad)",
                "#EXT-X-KEY:METHOD=AES-128,URI=\"\(bad)\"",
                "#EXT-X-MAP:URI=\"\(bad)\"",
                "#EXT-X-MEDIA:TYPE=AUDIO,URI=\"\(bad)\"",
                "#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(bad)\""
            ]
            for placement in placements { XCTAssertThrowsError(try parse("#EXTM3U\n" + placement + "\n"), placement) }
        }
    }

    func testAmbiguousOrCredentialBearingReferencesAreRejected() {
        for uri in ["https://user:pass@example.test/proxy/a.ts", "a.ts#fragment", "a%2fts", "a%5cts",
                    "%2e%2e/a.ts", "%252e%252e/a.ts", "a%00.ts", "a%0d%0a.ts", "a\\b.ts",
                    "{$host}/a.ts", " a.ts", "a.ts "] {
            XCTAssertThrowsError(try parse("#EXTM3U\n#EXTINF:1,\n" + uri + "\n"), uri)
        }
    }

    func testResourceBearingMetadataAndUnknownExtensionsAreRejected() {
        for tag in ["#EXT-X-DEFINE:NAME=\"path\",VALUE=\"video\"",
                    "#EXT-X-CONTENT-STEERING:SERVER-URI=\"steering.json\"",
                    "#EXT-X-SESSION-DATA:DATA-ID=\"fixture\",URI=\"chapters.json\"",
                    "#EXT-X-DATERANGE:ID=\"fixture\",X-ASSET-URI=\"ad.m3u8\"",
                    "#EXT-X-DATERANGE:ID=\"fixture\",X-ASSET-LIST=\"assets.json\"",
                    "#EXT-X-MAP:URI=\"init.mp4\",X-URI=\"other\"",
                    "#EXT-X-FUTURE:URI=\"unknown\""] {
            XCTAssertThrowsError(try parse("#EXTM3U\n" + tag + "\n"), tag) {
                XCTAssertEqual($0 as? HLSRelayError, .unsupportedPlaylist)
            }
        }
    }

    func testMalformedAttributesCannotHideASecondURI() {
        for tag in ["#EXT-X-KEY:METHOD=AES-128,URI=\"one\",URI=\"two\"",
                    "#EXT-X-KEY:METHOD=AES-128,uri=\"one\"",
                    "#EXT-X-KEY:METHOD=AES-128,URI=one",
                    "#EXT-X-KEY:METHOD=AES-128,URI=\"one",
                    "#EXT-X-KEY:METHOD=AES-128,URI=\"one\"tail",
                    "#EXT-X-MAP:URI=\"one\\\"two\"",
                    "#EXT-X-MAP:URI=\"one\",",
                    "#EXT-X-MAP:", "#EXT-X-MAP:BYTERANGE=\"10@0\""] {
            XCTAssertThrowsError(try parse("#EXTM3U\n" + tag + "\n"), tag)
        }
    }

    func testHeaderEncodingAndDanglingVariantsAreRejected() throws {
        for text in ["", "# comment\n#EXTM3U", "\u{FEFF}#EXTM3U\n", "#EXTM3U\n#EXTM3U",
                     "#EXTM3U\rbad", "#EXTM3U\n#EXTINF:1,\na\u{0}.ts",
                     "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n"] {
            XCTAssertThrowsError(try parse(text))
        }
        XCTAssertThrowsError(try HLSRelayPlaylist(data: Data([0xFF]), sourceURL: source, scope: scope()))
        let valid = try parse("#EXTM3U\r\n#EXTINF:1,\r\na.ts\r\n")
        XCTAssertEqual(valid.references.count, 1)
    }

    func testSizeAndReferenceLimitsIncludeResolvedURLExpansion() throws {
        XCTAssertThrowsError(try parse(String(repeating: "x", count: HLSRelayPlaylist.maximumInputBytes + 1)))
        XCTAssertThrowsError(try parse("#EXTM3U\n" + String(repeating: "a.ts\n", count: HLSRelayPlaylist.maximumReferences + 1)))
        let longSource = URL(string: "https://example.test/proxy/" + String(repeating: "p", count: 1000) + "/list.m3u8")!
        XCTAssertThrowsError(try parse("#EXTM3U\n" + String(repeating: "a.ts\n", count: 5000), source: longSource)) {
            XCTAssertEqual($0 as? HLSRelayError, .playlistTooLarge)
        }
    }

    func testLargePlaylistHasBoundedRewrittenOutput() throws {
        let uri = "a.ts?q=" + String(repeating: "/", count: 6000)
        let document = try parse("#EXTM3U\n" + String(repeating: uri + "\n", count: 600))
        let data = try document.rewritten(using: routes())
        XCTAssertLessThanOrEqual(data.count, HLSRelayPlaylist.maximumOutputBytes)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("example.test"))
    }

    func testDescriptionsDoNotIncludeResourceAddresses() throws {
        let document = try parse("#EXTM3U\n#EXTINF:1,\na.ts?session=fixture\n")
        let output = [String(reflecting: document), String(describing: document.references[0]),
                      Mirror(reflecting: document).children.map { String(reflecting: $0.value) }.joined()].joined()
        XCTAssertFalse(output.contains("example.test"))
        XCTAssertFalse(output.contains("session=fixture"))
    }
}
