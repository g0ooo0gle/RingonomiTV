import XCTest
@testable import RingonomiCore

final class ARIBCaptionPacketTests: XCTestCase {
    func testRecognizesBothPrivatePayloadKindsAndConvertsPresentationTime() throws {
        let caption = try ARIBCaptionPacket(payload: Data([0x80, 0xFF, 0xF0]), presentationSeconds: 12.3456)
        XCTAssertEqual(caption.kind, .caption)
        XCTAssertEqual(caption.milliseconds, 12_346)
        let superimpose = try ARIBCaptionPacket(payload: Data([0x81, 0xFF, 0xF0]), presentationSeconds: 0)
        XCTAssertEqual(superimpose.kind, .superimpose)
    }

    func testRejectsID3EnvelopeWrongStreamIDAndOversizedPackets() {
        let invalidPackets: [[UInt8]] = [[], [0x80], [0x80, 0xFF], [0x49, 0x44, 0x33], [0x80, 0x00, 0xF0], [0x82, 0xFF, 0xF0]]
        for bytes in invalidPackets {
            XCTAssertThrowsError(try ARIBCaptionPacket(payload: Data(bytes), presentationSeconds: 0))
        }
        var large = Data(repeating: 0, count: ARIBCaptionPacket.maximumBytes + 1)
        large[0] = 0x80
        large[1] = 0xFF
        XCTAssertThrowsError(try ARIBCaptionPacket(payload: large, presentationSeconds: 0))
    }

    func testNonzeroDataIndicesAndTimeBoundsAreSafe() throws {
        let bytes = Data([0, 0, 0x80, 0xFF, 0xF0]).dropFirst(2)
        XCTAssertNoThrow(try ARIBCaptionPacket(payload: bytes, presentationSeconds: 0))
        for time in [-1, Double.nan, Double.infinity, ARIBCaptionPacket.maximumSeconds + 1] {
            XCTAssertThrowsError(try ARIBCaptionPacket(payload: bytes, presentationSeconds: time))
        }
        XCTAssertEqual(ARIBCaptionPacket.milliseconds(for: ARIBCaptionPacket.maximumSeconds), 604_800_000)
    }

    func testSeekWindowRejectsOldAndUnrelatedFutureMetadata() throws {
        let packet = try ARIBCaptionPacket(payload: Data([0x80, 0xFF, 0xF0]), presentationSeconds: 100)
        XCTAssertTrue(packet.isNear(playbackSeconds: 100))
        XCTAssertTrue(packet.isNear(playbackSeconds: 102))
        XCTAssertTrue(packet.isNear(playbackSeconds: 85))
        XCTAssertFalse(packet.isNear(playbackSeconds: 103))
        XCTAssertFalse(packet.isNear(playbackSeconds: 84))
        XCTAssertFalse(packet.isNear(playbackSeconds: .nan))
    }

    func testRasterSizePreservesAspectWithinAppleTVHDMemoryBound() {
        XCTAssertEqual(ARIBCaptionRenderSize(width: 3_840, height: 2_160), ARIBCaptionRenderSize(width: 1_920, height: 1_080))
        let fourThree = ARIBCaptionRenderSize(width: 1_440, height: 1_080)
        XCTAssertEqual(fourThree.width, 1_440)
        XCTAssertEqual(fourThree.height, 1_080)
        let tall = ARIBCaptionRenderSize(width: 1_080, height: 1_920)
        XCTAssertEqual(tall.width, 607)
        XCTAssertEqual(tall.height, 1_080)
        let fallback = ARIBCaptionRenderSize(width: .nan, height: 0)
        XCTAssertEqual(fallback.width, 1_920)
        XCTAssertEqual(fallback.height, 1_080)
        let huge = ARIBCaptionRenderSize(width: Double.greatestFiniteMagnitude, height: 1)
        XCTAssertTrue((1...1_920).contains(huge.width))
        XCTAssertTrue((1...1_080).contains(huge.height))
    }
}
