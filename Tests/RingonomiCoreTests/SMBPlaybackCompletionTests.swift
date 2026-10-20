import XCTest
@testable import RingonomiCore

final class SMBPlaybackCompletionTests: XCTestCase {
    func testEarlyEOFDoesNotConfirmKnownLengthCompletion() {
        XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 100, hasPresentedCurrentPosition: true))
        XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 597.9, hasPresentedCurrentPosition: true))
    }

    func testNaturalEOFAllowsBoundedTimestampRounding() {
        XCTAssertTrue(SMBPlaybackCompletion.confirmsEnd(
            duration: 20.011, trustedSeconds: 19.846, hasPresentedCurrentPosition: true))
        XCTAssertTrue(SMBPlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 598, hasPresentedCurrentPosition: true))
        XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 603, hasPresentedCurrentPosition: true))
    }

    func testOldGenerationOrUnconfirmedSeekCannotClearBookmark() {
        XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 600, hasPresentedCurrentPosition: false))
        XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
            duration: nil, trustedSeconds: 20, hasPresentedCurrentPosition: false))
    }

    func testUnknownLengthCannotConfirmACompletedFile() {
        XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
            duration: nil, trustedSeconds: 20, hasPresentedCurrentPosition: true))
        XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
            duration: nil, trustedSeconds: nil, hasPresentedCurrentPosition: true))
    }

    func testSeparatelyVerifiedEndSeekDoesNotNeedAPreSeekBookmark() {
        XCTAssertTrue(SMBPlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: nil, hasPresentedCurrentPosition: false,
            verifiedEndSeek: true))
        XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
            duration: nil, trustedSeconds: nil, hasPresentedCurrentPosition: false,
            verifiedEndSeek: true))
    }

    func testInvalidTimingNeverConfirmsCompletion() {
        for time in [-1.0, Double.nan, Double.infinity] {
            XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
                duration: 600, trustedSeconds: time, hasPresentedCurrentPosition: true))
        }
        for duration in [0.0, -1, Double.nan, Double.infinity] {
            XCTAssertFalse(SMBPlaybackCompletion.confirmsEnd(
                duration: duration, trustedSeconds: 0, hasPresentedCurrentPosition: true))
        }
    }
}
