import Foundation
import XCTest
@testable import RingonomiCore

final class ID3ARIBFramesTests: XCTestCase {
    private let payload: [UInt8] = [0x80, 0xFF, 0x01]
    private func size(_ count: Int, synchsafe: Bool) -> [UInt8] {
        let shifts = synchsafe ? [21, 14, 7, 0] : [24, 16, 8, 0]
        return shifts.map { UInt8(truncatingIfNeeded: count >> $0) & (synchsafe ? 0x7F : 0xFF) }
    }
    private func tag(major: UInt8 = 4, flags: UInt8 = 0, extended: [UInt8] = [], footer: Bool = false) -> [UInt8] {
        let body = Array("aribb24.js".utf8) + [0] + payload
        let frame = Array("PRIV".utf8) + size(body.count, synchsafe: major == 4) + [0, 0] + body
        let header: [UInt8] = [0x49, 0x44, 0x33, major, 0, flags] + size(extended.count + frame.count, synchsafe: true)
        return header + extended + frame + (footer ? [0x33, 0x44, 0x49] + Array(header.suffix(7)) : [])
    }
    func testPaddingBetweenMultipleTagsIsSkipped() {
        let input = [UInt8](repeating: 0xEE, count: 5) + tag() + [0, 0, 0] + tag(major: 3)
        XCTAssertEqual(ID3ARIBFrames.payloads(in: input), [Data(payload), Data(payload)])
    }
    func testMalformedExtendedHeaderAdvancesToNextTag() {
        var malformed = tag(flags: 0x40, extended: [0x7F, 0x7F, 0x7F, 0x7F])
        malformed += tag()
        XCTAssertEqual(ID3ARIBFrames.payloads(in: malformed), [Data(payload)])
    }
    func testVersion3ExtendedHeaderSizeExcludesItsOwnSizeField() {
        let extended: [UInt8] = [0, 0, 0, 6, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(ID3ARIBFrames.payloads(in: tag(major: 3, flags: 0x40, extended: extended)), [Data(payload)])
    }
    func testVersion4ExtendedHeaderAndFooterDoNotTrimTheLastFrame() {
        let extended: [UInt8] = [0, 0, 0, 6, 1, 0]
        XCTAssertEqual(ID3ARIBFrames.payloads(in: tag(flags: 0x50, extended: extended, footer: true)), [Data(payload)])
    }
    func testMalformedFooterAndTruncatedFrameAreDiscarded() {
        var footer = tag(flags: 0x10, footer: true)
        footer[footer.count - 10] = 0
        XCTAssertTrue(ID3ARIBFrames.payloads(in: footer).isEmpty)
        XCTAssertTrue(ID3ARIBFrames.payloads(in: Array(tag().dropLast())).isEmpty)
    }
}
