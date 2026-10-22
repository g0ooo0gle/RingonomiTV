import XCTest
@testable import RingonomiCore

final class PlaybackStartupProgressTests: XCTestCase {
    func testOldPlayerStopDoesNotConsumeDecoderRequestBudget() {
        var deadline = LivePlaybackStartupDeadline()
        deadline.begin(generation: 1, at: 0)
        deadline.observe(.init(phase: .waitingForRequest), generation: 1, at: 1)
        XCTAssertEqual(deadline.currentPhase, .preparingPlayer)
        XCTAssertNil(deadline.timedOutPhase(generation: 1, at: 20))
        deadline.playerStarted(generation: 1, usesRelay: true, at: 20)
        XCTAssertNil(deadline.timedOutPhase(generation: 1, at: 34.9))
        XCTAssertEqual(deadline.timedOutPhase(generation: 1, at: 35), .waitingForRequest)
    }

    func testEveryStartupWaitHasAnActionableFiniteDeadline() {
        for phase in [PlaybackStartupPhase.waitingForMedia, .preparingPlayer,
                      .waitingForRequest, .waitingForResponse, .waitingForData, .decoding, .buffering] {
            var deadline = LivePlaybackStartupDeadline()
            deadline.begin(generation: 1, phase: phase, at: 100)
            let seconds = phase == .waitingForMedia || phase == .waitingForRequest ? 15.0 : 30.0
            XCTAssertNil(deadline.timedOutPhase(generation: 1, at: 100 + seconds - 0.01))
            XCTAssertEqual(deadline.timedOutPhase(generation: 1, at: 100 + seconds), phase)
            XCTAssertFalse(phase.timeoutMessage.isEmpty)
        }
    }

    func testHeaderAndDataProgressGetTheirOwnWaitButCannotExtendOverallLimit() {
        var deadline = LivePlaybackStartupDeadline()
        deadline.begin(generation: 1, at: 0)
        deadline.playerStarted(generation: 1, usesRelay: true, at: 2)
        deadline.observe(.init(phase: .waitingForResponse, attempt: 1), generation: 1, at: 3)
        XCTAssertNil(deadline.timedOutPhase(generation: 1, at: 32.9))
        deadline.observe(.init(phase: .waitingForData, attempt: 1), generation: 1, at: 32.9)
        XCTAssertNil(deadline.timedOutPhase(generation: 1, at: 44.9))
        XCTAssertEqual(deadline.timedOutPhase(generation: 1, at: 45), .waitingForData)
    }

    func testPollingSameProgressDoesNotKeepAStalledRequestAlive() {
        var deadline = LivePlaybackStartupDeadline()
        deadline.begin(generation: 1, at: 0)
        deadline.playerStarted(generation: 1, usesRelay: true, at: 0)
        for second in 0..<31 {
            deadline.observe(.init(phase: .waitingForResponse, attempt: 1), generation: 1, at: Double(second))
        }
        XCTAssertEqual(deadline.timedOutPhase(generation: 1, at: 30), .waitingForResponse)
    }

    func testRepeatedGETAttemptsCannotKeepStartupAliveForever() {
        var deadline = LivePlaybackStartupDeadline()
        deadline.begin(generation: 1, at: 0)
        deadline.playerStarted(generation: 1, usesRelay: true, at: 0)
        for attempt in 1...4 {
            deadline.observe(.init(phase: .waitingForResponse, attempt: UInt64(attempt)),
                             generation: 1, at: Double(attempt * 10))
        }
        XCTAssertEqual(deadline.timedOutPhase(generation: 1, at: 45), .waitingForResponse)
    }

    func testOldLoadAndOldGETCannotChangeCurrentDeadlineOrFinishIt() {
        var deadline = LivePlaybackStartupDeadline()
        deadline.begin(generation: 1, at: 0)
        deadline.begin(generation: 2, at: 10)
        deadline.playerStarted(generation: 2, usesRelay: true, at: 11)
        deadline.observe(.init(phase: .waitingForData, attempt: 2), generation: 2, at: 12)
        deadline.observe(.init(phase: .decoding, attempt: 1), generation: 2, at: 20)
        deadline.observe(.init(phase: .waitingForResponse, attempt: 99), generation: 1, at: 30)
        deadline.finish(generation: 1)
        XCTAssertEqual(deadline.currentPhase, .waitingForData)
        XCTAssertNil(deadline.timedOutPhase(generation: 1, at: 100))
        XCTAssertEqual(deadline.timedOutPhase(generation: 2, at: 42), .waitingForData)
    }

    func testBufferingIgnoresCachedInitialTransportProgress() {
        var deadline = LivePlaybackStartupDeadline()
        deadline.begin(generation: 1, at: 0)
        deadline.finish(generation: 1)
        deadline.begin(generation: 1, phase: .buffering, at: 100)
        deadline.observe(.init(phase: .decoding, attempt: 1), generation: 1, at: 120)
        deadline.playerStarted(generation: 1, usesRelay: true, at: 125)
        XCTAssertNil(deadline.timedOutPhase(generation: 1, at: 129.9))
        XCTAssertEqual(deadline.timedOutPhase(generation: 1, at: 130), .buffering)
    }

    func testStopSuspendAndReadyRetireTheDeadlineUntilNextLoad() {
        var deadline = LivePlaybackStartupDeadline()
        deadline.begin(generation: 1, at: 0)
        deadline.invalidate()
        deadline.observe(.init(phase: .decoding, attempt: 1), generation: 1, at: 10)
        XCTAssertNil(deadline.timedOutPhase(generation: 1, at: 100))
        deadline.begin(generation: 2, at: 101)
        deadline.playerStarted(generation: 2, usesRelay: false, at: 102)
        XCTAssertEqual(deadline.currentPhase, .decoding)
        deadline.finish(generation: 2)
        XCTAssertNil(deadline.currentPhase)
        XCTAssertNil(deadline.timedOutPhase(generation: 2, at: 200))
    }
}
