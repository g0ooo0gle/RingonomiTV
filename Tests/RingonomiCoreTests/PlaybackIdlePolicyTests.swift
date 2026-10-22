import XCTest
@testable import RingonomiCore

final class PlaybackIdlePolicyTests: XCTestCase {
    func testUnrelatedScreenCannotReleasePlayingScreen() {
        var policy = PlaybackIdlePolicy()
        let playing = UUID()
        policy.setNeedsContinuousDisplay(true, for: playing)
        policy.setNeedsContinuousDisplay(false, for: UUID())
        XCTAssertTrue(policy.preventsSleep(applicationIsActive: true))
        XCTAssertEqual(policy.requestCount, 1)
        policy.setNeedsContinuousDisplay(false, for: playing)
        XCTAssertFalse(policy.preventsSleep(applicationIsActive: true))
    }

    func testHandoffRetainsNewRequestWhenOldScreenCloses() {
        var policy = PlaybackIdlePolicy()
        let old = UUID(), next = UUID()
        policy.setNeedsContinuousDisplay(true, for: old)
        policy.setNeedsContinuousDisplay(true, for: next)
        policy.setNeedsContinuousDisplay(false, for: old)
        policy.setNeedsContinuousDisplay(false, for: old)
        XCTAssertTrue(policy.preventsSleep(applicationIsActive: true))
        XCTAssertEqual(policy.requestCount, 1)
        policy.setNeedsContinuousDisplay(false, for: next)
        XCTAssertFalse(policy.preventsSleep(applicationIsActive: true))
    }

    func testRepeatedRequestsAreIdempotent() {
        var policy = PlaybackIdlePolicy()
        let owner = UUID()
        for _ in 0..<10 { policy.setNeedsContinuousDisplay(true, for: owner) }
        XCTAssertEqual(policy.requestCount, 1)
        policy.setNeedsContinuousDisplay(false, for: owner)
        XCTAssertEqual(policy.requestCount, 0)
    }

    func testBackgroundDisablesWithoutLosingForegroundRequest() {
        var policy = PlaybackIdlePolicy()
        let owner = UUID()
        XCTAssertFalse(policy.preventsSleep(applicationIsActive: true))
        policy.setNeedsContinuousDisplay(true, for: owner)
        XCTAssertFalse(policy.preventsSleep(applicationIsActive: false))
        XCTAssertTrue(policy.preventsSleep(applicationIsActive: true))
        policy.setNeedsContinuousDisplay(false, for: owner)
        XCTAssertFalse(policy.preventsSleep(applicationIsActive: true))
    }

    func testPauseWhileInactiveDoesNotPreventSleepAfterReturn() {
        var policy = PlaybackIdlePolicy()
        let owner = UUID()
        policy.setNeedsContinuousDisplay(true, for: owner)
        XCTAssertFalse(policy.preventsSleep(applicationIsActive: false))
        policy.setNeedsContinuousDisplay(false, for: owner)
        XCTAssertFalse(policy.preventsSleep(applicationIsActive: false))
        XCTAssertFalse(policy.preventsSleep(applicationIsActive: true))
    }
}
