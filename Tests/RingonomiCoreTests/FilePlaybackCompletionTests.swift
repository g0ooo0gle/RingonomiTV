import XCTest
@testable import RingonomiCore

final class FilePlaybackCompletionTests: XCTestCase {
    func testEarlyEOFDoesNotConfirmKnownLengthCompletion() {
        // A dropped recording stream must retain its watched position even
        // when the server still reports the full completed-file duration.
        XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
            duration: 600.309333, trustedSeconds: 61.938, hasPresentedCurrentPosition: true))
        XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 100, hasPresentedCurrentPosition: true))
        XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 597.9, hasPresentedCurrentPosition: true))
    }

    func testNaturalEOFAllowsBoundedTimestampRounding() {
        XCTAssertTrue(FilePlaybackCompletion.confirmsEnd(
            duration: 20.011, trustedSeconds: 19.846, hasPresentedCurrentPosition: true))
        XCTAssertTrue(FilePlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 598, hasPresentedCurrentPosition: true))
        XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 603, hasPresentedCurrentPosition: true))
    }

    func testOldGenerationOrUnconfirmedSeekCannotClearBookmark() {
        XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: 600, hasPresentedCurrentPosition: false))
        XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
            duration: nil, trustedSeconds: 20, hasPresentedCurrentPosition: false))
    }

    func testUnknownLengthCannotConfirmACompletedFile() {
        XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
            duration: nil, trustedSeconds: 20, hasPresentedCurrentPosition: true))
        XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
            duration: nil, trustedSeconds: nil, hasPresentedCurrentPosition: true))
    }

    func testSeparatelyVerifiedEndSeekDoesNotNeedAPreSeekBookmark() {
        XCTAssertTrue(FilePlaybackCompletion.confirmsEnd(
            duration: 600, trustedSeconds: nil, hasPresentedCurrentPosition: false,
            verifiedEndSeek: true))
        XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
            duration: nil, trustedSeconds: nil, hasPresentedCurrentPosition: false,
            verifiedEndSeek: true))
    }

    func testInvalidTimingNeverConfirmsCompletion() {
        for time in [-1.0, Double.nan, Double.infinity] {
            XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
                duration: 600, trustedSeconds: time, hasPresentedCurrentPosition: true))
        }
        for duration in [0.0, -1, Double.nan, Double.infinity] {
            XCTAssertFalse(FilePlaybackCompletion.confirmsEnd(
                duration: duration, trustedSeconds: 0, hasPresentedCurrentPosition: true))
        }
    }
}
