import XCTest
@testable import RingonomiCore

final class RecordingSeekPolicyTests: XCTestCase {
    func testCompletedRecordingDistinguishesTailFromNormalSeek() {
        XCTAssertTrue(RecordingSeekPolicy.isEndTarget(seconds: 120, duration: 100, status: "Recorded"))
        XCTAssertTrue(RecordingSeekPolicy.isEndTarget(seconds: 100, duration: 100, status: "Recorded"))
        XCTAssertTrue(RecordingSeekPolicy.isEndTarget(seconds: 99.75, duration: 100, status: "Recorded"))
        XCTAssertFalse(RecordingSeekPolicy.isEndTarget(seconds: 99.7, duration: 100, status: "Recorded"))
        XCTAssertFalse(RecordingSeekPolicy.isEndTarget(seconds: 50, duration: 100, status: "Recorded"))
    }

    func testGrowingAndUnknownStatusCannotEndFromDurationAlone() {
        for status in [nil, "Recording", "Unknown"] {
            XCTAssertFalse(RecordingSeekPolicy.isEndTarget(seconds: 120, duration: 100, status: status))
        }
    }

    func testInvalidPositionAndUnknownDurationCannotEndPlayback() {
        for seconds in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertFalse(RecordingSeekPolicy.isEndTarget(seconds: seconds, duration: 100, status: "Recorded"))
        }
        for duration in [nil, Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertFalse(RecordingSeekPolicy.isEndTarget(seconds: 120, duration: duration, status: "Recorded"))
        }
    }

    func testShortClipStartsNormallyAndCanSeekToEnd() {
        XCTAssertFalse(RecordingSeekPolicy.isEndTarget(seconds: 0, duration: 0.1, status: "Recorded"))
        XCTAssertTrue(RecordingSeekPolicy.isEndTarget(seconds: 0.1, duration: 0.1, status: "Recorded"))
    }
}
