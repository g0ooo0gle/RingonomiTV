import Foundation
import XCTest
@testable import RingonomiCore

final class HTTPMediaRelayRequestTests: XCTestCase {
    private let origin = URL(string: "http://127.0.0.1:12345/")!
    private func request(_ line: String = "GET /media/fixture/file.bin HTTP/1.1", fields: String = "") throws -> HTTPMediaRelayRequest {
        try HTTPMediaRelayRequest(header: Data((line + "\r\nHost: 127.0.0.1:12345\r\n" + fields + "\r\n").utf8), origin: origin)
    }

    func testGETHEADAndRangeAreParsed() throws {
        let get = try request(fields: "Range: bytes=10-20\r\n")
        XCTAssertFalse(get.isHead)
        XCTAssertEqual(get.url.absoluteString, "http://127.0.0.1:12345/media/fixture/file.bin")
        XCTAssertEqual(get.range?.headerValue, "bytes=10-20")
        XCTAssertTrue(try request("HEAD /media/fixture/file.bin HTTP/1.1").isHead)
    }

    func testHEADIgnoresRangeIncludingUnsupportedUnits() throws {
        for range in ["bytes=999999-", "items=0-1"] {
            let head = try request("HEAD /media/fixture/file.bin HTTP/1.1", fields: "Range: \(range)\r\n")
            XCTAssertTrue(head.isHead)
            XCTAssertNil(head.range)
        }
    }

    func testAbsoluteTargetsOtherMethodsAndHTTPVersionsAreRejected() {
        for line in ["POST /media/fixture/file.bin HTTP/1.1", "GET http://other.test/ HTTP/1.1",
                     "GET //other.test/path HTTP/1.1", "GET /media/fixture/file.bin HTTP/2",
                     "GET  /media/fixture/file.bin HTTP/1.1"] { XCTAssertThrowsError(try request(line), line) }
    }

    func testDuplicateHeadersBodiesAndSmugglingAreRejected() {
        for fields in ["Host: other.test\r\n", "Range: bytes=0-1\r\nRange: bytes=2-3\r\n",
                       "Transfer-Encoding: chunked\r\n", "Content-Length: 5\r\n",
                       "X-Value: one\r\n two\r\n", "X: one\r\n\r\nGET /other HTTP/1.1\r\n"] {
            XCTAssertThrowsError(try request(fields: fields))
        }
        let wrong = Data("GET /media/file.bin HTTP/1.1\r\nHost: other.test\r\n\r\n".utf8)
        XCTAssertThrowsError(try HTTPMediaRelayRequest(header: wrong, origin: origin))
    }

    func testByteRangesResolveWithoutOverflow() throws {
        XCTAssertEqual(try HTTPMediaByteRange("bytes=10-20").indices(in: 15), 10..<15)
        XCTAssertEqual(try HTTPMediaByteRange("bytes=10-").indices(in: 15), 10..<15)
        XCTAssertEqual(try HTTPMediaByteRange("bytes=-5").indices(in: 15), 10..<15)
        XCTAssertEqual(try HTTPMediaByteRange("bytes=-50").indices(in: 15), 0..<15)
        XCTAssertEqual(try HTTPMediaByteRange("bytes=0-9223372036854775807").indices(in: 15), 0..<15)
        for value in ["bytes=-", "bytes=-0", "bytes=20-10", "bytes=0-1,2-3", "bytes=+1-2",
                      "bytes=0-9223372036854775808", "bytes= 1-2", "items=0-1"] {
            XCTAssertThrowsError(try HTTPMediaByteRange(value), value)
        }
        XCTAssertThrowsError(try HTTPMediaByteRange("bytes=20-").indices(in: 15))
        XCTAssertThrowsError(try HTTPMediaByteRange("bytes=0-").indices(in: 0))
    }
}
