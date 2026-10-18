import XCTest
@testable import RingonomiCore

final class LiveCommentWindowTests: XCTestCase {
    func testClockExcludesPausedAndBufferingIntervals() {
        var clock = LiveCommentClock(now: 100)
        XCTAssertEqual(clock.seconds(at: 120), 0)
        clock.setPlaying(true, at: 120)
        XCTAssertEqual(clock.seconds(at: 125), 5)
        clock.setPlaying(false, at: 125)
        XCTAssertEqual(clock.seconds(at: 200), 5)
        clock.setPlaying(true, at: 200)
        XCTAssertEqual(clock.seconds(at: 207), 12)
        clock.reset(at: 207)
        XCTAssertEqual(clock.seconds(at: 210), 3)
    }

    func testClockIgnoresInvalidOrRegressingInputAndCapsDuration() {
        var clock = LiveCommentClock(now: .nan)
        clock.setPlaying(true, at: 100)
        XCTAssertEqual(clock.seconds(at: .nan), 0)
        XCTAssertEqual(clock.seconds(at: .infinity), 0)
        XCTAssertEqual(clock.seconds(at: 90), 0)
        XCTAssertEqual(clock.seconds(at: 110), 10)
        clock.setPlaying(false, at: 110)
        clock.setPlaying(true, at: 90)
        XCTAssertEqual(clock.seconds(at: 100), 10)
        XCTAssertEqual(clock.seconds(at: 120), 20)
        XCTAssertEqual(clock.seconds(at: 1_000_000), PlaybackComment.maximumTime)
    }

    func testWindowAcceptsOnlyBoundedCurrentOrScheduledComments() throws {
        var window = LiveCommentWindow()
        XCTAssertTrue(window.append(id: "current", comment: try comment(at: 10), at: 10))
        XCTAssertTrue(window.append(id: "delayed", comment: try comment(at: 20), at: 10))
        XCTAssertFalse(window.append(id: "old", comment: try comment(at: 8.9), at: 10))
        XCTAssertFalse(window.append(id: "future", comment: try comment(at: 20.1), at: 10))
        XCTAssertFalse(window.append(id: "", comment: try comment(at: 10), at: 10))
        XCTAssertFalse(window.append(id: String(repeating: "a", count: 257), comment: try comment(at: 10), at: 10))
        XCTAssertFalse(window.append(id: "invalid", comment: try comment(at: 10), at: .nan))
        XCTAssertEqual(window.comments.count, 2)
    }

    func testDuplicateSuppressionCanSurviveClearingTheScreen() throws {
        var window = LiveCommentWindow()
        XCTAssertTrue(window.append(id: "thread:1", comment: try comment(at: 0), at: 0))
        XCTAssertFalse(window.append(id: "thread:1", comment: try comment(at: 1), at: 1))
        window.removeAll(keepingSeenIDs: true)
        XCTAssertTrue(window.comments.isEmpty)
        XCTAssertFalse(window.append(id: "thread:1", comment: try comment(at: 1), at: 1))
        window.removeAll()
        XCTAssertTrue(window.append(id: "thread:1", comment: try comment(at: 1), at: 1))
    }

    func testDisplayAndDuplicateHistoriesStayBounded() throws {
        var window = LiveCommentWindow()
        for index in 0...LiveCommentWindow.maximumRememberedIDs {
            XCTAssertTrue(window.append(id: String(index), comment: try comment(at: 0), at: 0))
        }
        XCTAssertEqual(window.comments.count, LiveCommentWindow.maximumComments)
        XCTAssertTrue(window.append(id: "0", comment: try comment(at: 0), at: 0))
        XCTAssertFalse(window.append(id: String(LiveCommentWindow.maximumRememberedIDs),
                                     comment: try comment(at: 0), at: 0))
    }

    func testPruneRetainsBoundaryAndHandlesDelayChanges() throws {
        var window = LiveCommentWindow()
        window.append(id: "later", comment: try comment(at: 10), at: 0)
        window.append(id: "earlier", comment: try comment(at: 0), at: 0)
        window.prune(at: 12)
        XCTAssertEqual(window.comments.map(\.time), [10, 0])
        window.prune(at: 12.01)
        XCTAssertEqual(window.comments.map(\.time), [10])
        window.prune(at: 23)
        XCTAssertTrue(window.comments.isEmpty)
    }

    private func comment(at time: Double) throws -> PlaybackComment {
        try PlaybackComment(time: time, position: .right, size: .medium,
                            colorRGB: 0xFFFFFF, text: "test")
    }
}
