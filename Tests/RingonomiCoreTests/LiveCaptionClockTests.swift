import Foundation
import XCTest
@testable import RingonomiCore

final class LiveCaptionClockTests: XCTestCase {
    private func caption(_ ticks: Int64, sequence: UInt64 = 0) -> MPEGTSARIBCaption {
        .init(payload: Data([0x80, 0xFF, 0]), presentationTicks: ticks, discontinuitySequence: sequence)
    }

    func testTransportOriginPreservesPresentationDelay() {
        var clock = LiveCaptionClock()
        clock.observe(firstTicks: 900_000, currentTicks: 900_000, sequence: 0)
        XCTAssertEqual(clock.packet(caption(1_035_000))?.milliseconds, 1_500)
        clock.observe(firstTicks: 950_000, currentTicks: 950_000, sequence: 0)
        XCTAssertEqual(clock.packet(caption(1_035_000))?.milliseconds, 1_500)
    }

    func testContinuousClockAfterPacketLossKeepsOriginButRejectsOldGeneration() {
        var clock = LiveCaptionClock()
        clock.observe(firstTicks: 900_000, currentTicks: 990_000, sequence: 0)
        clock.observe(firstTicks: 1_000_000, currentTicks: 1_080_000, sequence: 1)
        XCTAssertTrue(clock.isSynchronized)
        XCTAssertNil(clock.packet(caption(1_100_000)))
        XCTAssertEqual(clock.packet(caption(1_125_000, sequence: 1))?.milliseconds, 2_500)
    }

    func testClockResetCannotDisplayAnUnrelatedCaption() {
        var clock = LiveCaptionClock()
        clock.observe(firstTicks: 9_000_000, currentTicks: 9_900_000, sequence: 0)
        clock.observe(firstTicks: 0, currentTicks: 90_000, sequence: 1)
        XCTAssertFalse(clock.isSynchronized)
        XCTAssertNil(clock.packet(caption(180_000, sequence: 1)))
    }

    func testWrapUsesUnwrappedTicksAndInvalidTimesAreDropped() {
        var clock = LiveCaptionClock()
        let wrap: Int64 = 1 << 33
        clock.observe(firstTicks: wrap - 90_000, currentTicks: wrap, sequence: 0)
        XCTAssertEqual(clock.packet(caption(wrap + 45_000))?.milliseconds, 1_500)
        XCTAssertNil(clock.packet(caption(-1)))
        XCTAssertNil(clock.packet(caption(.max)))
        var overflow = LiveCaptionClock()
        overflow.observe(firstTicks: .min, currentTicks: .min, sequence: 0)
        XCTAssertNil(overflow.packet(caption(.max)))
    }

    func testDelayedPCRAfterDiscontinuityStillRejectsClockReset() {
        var clock = LiveCaptionClock()
        clock.observe(firstTicks: 9_000_000, currentTicks: 9_900_000, sequence: 0)
        clock.observe(firstTicks: nil, currentTicks: nil, sequence: 1)
        clock.observe(firstTicks: 0, currentTicks: 90_000, sequence: 1)
        XCTAssertFalse(clock.isSynchronized)
        XCTAssertNil(clock.packet(caption(180_000, sequence: 1)))
    }

    func testWaitsForAnAnchorAndRejectsMalformedPayload() {
        var clock = LiveCaptionClock()
        clock.observe(firstTicks: nil, currentTicks: nil, sequence: 0)
        XCTAssertNil(clock.packet(caption(90_000)))
        clock.observe(firstTicks: 0, currentTicks: 0, sequence: 0)
        XCTAssertNil(clock.packet(.init(payload: Data([0]), presentationTicks: 90_000, discontinuitySequence: 0)))
    }
}
