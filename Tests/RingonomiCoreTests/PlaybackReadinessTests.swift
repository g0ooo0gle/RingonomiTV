import XCTest
@testable import RingonomiCore
final class PlaybackReadinessTests: XCTestCase {
    func testAudioAndInitialBurstDoNotRevealUntilSteadyVideo() {
        var gate = PlaybackReadinessGate()
        XCTAssertFalse(gate.update(hasVideo: false, pictures: 0, audioReady: true, at: 0))
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 1, audioReady: true, at: 0))
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 20, audioReady: true, at: 0.1))
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 35, audioReady: true, at: 0.6))
        XCTAssertTrue(gate.update(hasVideo: true, pictures: 50, audioReady: true, at: 1.1))
    }
    func testStallAndMissingAudioRequireFreshPreparation() {
        var gate = PlaybackReadinessGate()
        _ = gate.update(hasVideo: true, pictures: 10, audioReady: true, at: 0)
        _ = gate.update(hasVideo: true, pictures: 20, audioReady: true, at: 0.5)
        XCTAssertTrue(gate.update(hasVideo: true, pictures: 30, audioReady: true, at: 1))
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 30, audioReady: true, at: 2))
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 35, audioReady: false, at: 2.1))
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 40, audioReady: true, at: 2.2))
        _ = gate.update(hasVideo: true, pictures: 50, audioReady: true, at: 2.7)
        XCTAssertTrue(gate.update(hasVideo: true, pictures: 60, audioReady: true, at: 3.2))
        gate.reset()
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 65, audioReady: true, at: 3.3))
    }
    func testUninitialisedStatisticsCannotOpenGate() {
        var gate = PlaybackReadinessGate()
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 1_800_000_000, audioReady: true, at: 0))
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 2, audioReady: true, at: 0.5))
        XCTAssertFalse(gate.update(hasVideo: true, pictures: 0, audioReady: true, at: 1))
    }
}
