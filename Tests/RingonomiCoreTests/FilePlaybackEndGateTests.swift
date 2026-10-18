import XCTest
@testable import RingonomiCore

final class FilePlaybackEndGateTests: XCTestCase {
    private let duration = 600.0
    private let nearEnd = 599.8

    private func sample(
        _ gate: inout FilePlaybackEndGate,
        at: TimeInterval,
        currentSeconds: Double? = 599.8,
        duration: Double? = 600.0,
        position: Double = 1,
        remainingSeconds: Double? = -0.0,
        isPaused: Bool = false,
        hasPendingSeek: Bool = false,
        displayedPictures: Int = 1_310,
        playedAudioBuffers: Int = 1_024
    ) -> Bool {
        gate.update(
            currentSeconds: currentSeconds,
            duration: duration,
            position: position,
            remainingSeconds: remainingSeconds,
            isPaused: isPaused,
            hasPendingSeek: hasPendingSeek,
            displayedPictures: displayedPictures,
            playedAudioBuffers: playedAudioBuffers,
            at: at
        )
    }

    func testUnknownOrInvalidEndEvidenceNeverOpens() {
        var gate = FilePlaybackEndGate()
        XCTAssertFalse(sample(&gate, at: 0, duration: nil))
        XCTAssertFalse(sample(&gate, at: 1, currentSeconds: nil))
        XCTAssertFalse(sample(&gate, at: 2, duration: .nan))
        XCTAssertFalse(sample(&gate, at: 3, currentSeconds: .infinity))
        XCTAssertFalse(sample(&gate, at: 4, remainingSeconds: nil))
        XCTAssertFalse(sample(&gate, at: 5, remainingSeconds: .infinity))
        XCTAssertFalse(sample(&gate, at: 6, position: .nan))
        XCTAssertFalse(sample(&gate, at: 7, remainingSeconds: 0.06))
        XCTAssertFalse(sample(&gate, at: .nan))
    }

    func testNearEndUsesBoundedDurationTolerance() {
        var gate = FilePlaybackEndGate()
        XCTAssertFalse(sample(&gate, at: 0, currentSeconds: duration - 1.99))
        XCTAssertFalse(sample(&gate, at: 1.99, currentSeconds: duration - 1.99))
        XCTAssertTrue(sample(&gate, at: 2, currentSeconds: duration - 1.99))

        gate.reset()
        XCTAssertFalse(sample(&gate, at: 3, currentSeconds: duration - 2.01))
        XCTAssertFalse(sample(&gate, at: 6, currentSeconds: duration - 2.01))
    }

    func testPositionPauseAndPendingSeekAreRequired() {
        var gate = FilePlaybackEndGate()
        XCTAssertFalse(sample(&gate, at: 0, position: 0.999))
        XCTAssertFalse(sample(&gate, at: 2, position: 0.999))

        XCTAssertFalse(sample(&gate, at: 3, isPaused: true))
        XCTAssertFalse(sample(&gate, at: 5, isPaused: true))

        XCTAssertFalse(sample(&gate, at: 6, hasPendingSeek: true))
        XCTAssertFalse(sample(&gate, at: 8, hasPendingSeek: true))

        XCTAssertFalse(sample(&gate, at: 9))
        XCTAssertTrue(sample(&gate, at: 11))
    }

    func testVideoOrAudioProgressRestartsTheStallWindow() {
        var gate = FilePlaybackEndGate()
        XCTAssertFalse(sample(&gate, at: 0))
        XCTAssertFalse(sample(&gate, at: 1, displayedPictures: 1_311))
        XCTAssertFalse(sample(&gate, at: 2.5, displayedPictures: 1_311, playedAudioBuffers: 1_025))
        XCTAssertFalse(sample(&gate, at: 3.5, displayedPictures: 1_311, playedAudioBuffers: 1_025))
        XCTAssertTrue(sample(&gate, at: 4.5, displayedPictures: 1_311, playedAudioBuffers: 1_025))
    }

    func testTimeProgressRestartsTheStallWindow() {
        var gate = FilePlaybackEndGate()
        XCTAssertFalse(sample(&gate, at: 0))
        XCTAssertFalse(sample(&gate, at: 1, currentSeconds: nearEnd - 0.01))
        XCTAssertFalse(sample(&gate, at: 2.9, currentSeconds: nearEnd - 0.01))
        XCTAssertTrue(sample(&gate, at: 3, currentSeconds: nearEnd - 0.01))
    }

    func testNonMonotonicClockResetsStability() {
        var gate = FilePlaybackEndGate()
        XCTAssertFalse(sample(&gate, at: 10))
        XCTAssertFalse(sample(&gate, at: 11))
        XCTAssertFalse(sample(&gate, at: 10.5))
        XCTAssertFalse(sample(&gate, at: 12.5))
        XCTAssertTrue(sample(&gate, at: 14.5))
    }

    func testResetClearsAPreviouslyStableSample() {
        var gate = FilePlaybackEndGate()
        XCTAssertFalse(sample(&gate, at: 0))
        XCTAssertTrue(sample(&gate, at: 2))
        gate.reset()
        XCTAssertFalse(sample(&gate, at: 2.1))
        XCTAssertFalse(sample(&gate, at: 4.09))
        XCTAssertTrue(sample(&gate, at: 4.2))
    }

    func testNegativeCountersAreRejectedAndReset() {
        var gate = FilePlaybackEndGate()
        XCTAssertFalse(sample(&gate, at: 0, displayedPictures: -1))
        XCTAssertFalse(sample(&gate, at: 1, playedAudioBuffers: -1))
        XCTAssertFalse(sample(&gate, at: 2))
        XCTAssertFalse(sample(&gate, at: 3.99))
        XCTAssertTrue(sample(&gate, at: 4))
    }

    func testZeroDisplayedPicturesCannotOpenUntilVideoAppears() {
        var gate = FilePlaybackEndGate()
        XCTAssertFalse(sample(&gate, at: 0, displayedPictures: 0, playedAudioBuffers: 0))
        XCTAssertFalse(sample(&gate, at: 2, displayedPictures: 0, playedAudioBuffers: 0))
        XCTAssertFalse(sample(&gate, at: 3, displayedPictures: 1, playedAudioBuffers: 0))
        XCTAssertTrue(sample(&gate, at: 5.2, displayedPictures: 1, playedAudioBuffers: 0))
    }
}
