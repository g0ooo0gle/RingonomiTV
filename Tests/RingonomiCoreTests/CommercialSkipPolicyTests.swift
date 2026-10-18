import XCTest
@testable import RingonomiCore

final class CommercialSkipPolicyTests: XCTestCase {
    private func timeline(
        duration: Double = 100,
        sections: [CommercialSection]
    ) throws -> RecordingChapterTimeline {
        try XCTUnwrap(RecordingChapterTimeline(duration: duration, sections: sections))
    }

    func testNaturalEntryAndMiddleOfCommercialReturnEndOnlyOnce() throws {
        let timeline = try timeline(sections: [CommercialSection(startTime: 10, endTime: 20)])
        var policy = CommercialSkipPolicy()

        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 9.99, enabled: true, isPlayingReady: true
        ))
        XCTAssertEqual(policy.automaticSeekTarget(
            timeline: timeline, at: 10, enabled: true, isPlayingReady: true
        ), 20)
        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 10.25, enabled: true, isPlayingReady: true
        ))
        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 19.99, enabled: true, isPlayingReady: true
        ))
    }

    func testDisabledPausedLoadingAndFailureGatesDoNotMarkIntervalHandled() throws {
        let timeline = try timeline(sections: [CommercialSection(startTime: 10, endTime: 20)])
        var policy = CommercialSkipPolicy()

        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 12, enabled: false, isPlayingReady: true
        ))
        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 12, enabled: true, isPlayingReady: false
        ))
        XCTAssertNil(policy.handledInterval)

        XCTAssertEqual(policy.automaticSeekTarget(
            timeline: timeline, at: 12, enabled: true, isPlayingReady: true
        ), 20)
    }

    func testManualSeekResetAllowsTheSameCommercialIntervalAgain() throws {
        let timeline = try timeline(sections: [CommercialSection(startTime: 10, endTime: 20)])
        var policy = CommercialSkipPolicy()

        XCTAssertEqual(policy.automaticSeekTarget(
            timeline: timeline, at: 11, enabled: true, isPlayingReady: true
        ), 20)
        policy.resetAfterManualSeek()
        XCTAssertNil(policy.handledInterval)
        XCTAssertEqual(policy.automaticSeekTarget(
            timeline: timeline, at: 11, enabled: true, isPlayingReady: true
        ), 20)
    }

    func testUndoSuppressionLastsUntilTheIntervalEnds() throws {
        let timeline = try timeline(sections: [CommercialSection(startTime: 10, endTime: 20)])
        var policy = CommercialSkipPolicy()
        policy.suppressCurrentInterval(in: timeline, at: 12)

        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 15, enabled: true, isPlayingReady: true
        ))
        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 20, enabled: true, isPlayingReady: true
        ))
        XCTAssertEqual(policy.automaticSeekTarget(
            timeline: timeline, at: 11, enabled: true, isPlayingReady: true
        ), 20)
    }

    func testEmptyTimelineDoesNotProduceAnAutomaticTarget() throws {
        let timeline = try timeline(sections: [])
        var policy = CommercialSkipPolicy()

        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 20, enabled: true, isPlayingReady: true
        ))
        XCTAssertNil(policy.handledInterval)
    }

    func testSeparateCommercialIntervalsCanEachBeHandledOnce() throws {
        let timeline = try timeline(sections: [
            CommercialSection(startTime: 10, endTime: 20),
            CommercialSection(startTime: 22, endTime: 30)
        ])
        var policy = CommercialSkipPolicy()

        XCTAssertEqual(policy.automaticSeekTarget(
            timeline: timeline, at: 12, enabled: true, isPlayingReady: true
        ), 20)
        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 12.5, enabled: true, isPlayingReady: true
        ))
        XCTAssertEqual(policy.automaticSeekTarget(
            timeline: timeline, at: 24, enabled: true, isPlayingReady: true
        ), 30)
        XCTAssertNil(policy.automaticSeekTarget(
            timeline: timeline, at: 24.5, enabled: true, isPlayingReady: true
        ))
    }

    func testInvalidTimesAndPositionsNeverProduceTargets() throws {
        let timeline = try timeline(sections: [CommercialSection(startTime: 10, endTime: 20)])
        var policy = CommercialSkipPolicy()

        let invalidPositions: [Double] = [-1, 20, 100, .nan, .infinity, -.infinity]
        for seconds in invalidPositions {
            XCTAssertNil(policy.automaticSeekTarget(
                timeline: timeline, at: seconds, enabled: true, isPlayingReady: true
            ))
        }
        XCTAssertNil(policy.handledInterval)
    }

    func testTrailingAndWholeVideoCommercialsNeverSeekToEOF() throws {
        let trailing = try timeline(
            sections: [CommercialSection(startTime: 80, endTime: 100)]
        )
        var trailingPolicy = CommercialSkipPolicy()
        XCTAssertNil(trailingPolicy.automaticSeekTarget(
            timeline: trailing, at: 90, enabled: true, isPlayingReady: true
        ))

        let wholeVideo = try timeline(
            sections: [CommercialSection(startTime: 0, endTime: 100)]
        )
        var wholePolicy = CommercialSkipPolicy()
        XCTAssertNil(wholePolicy.automaticSeekTarget(
            timeline: wholeVideo, at: 10, enabled: true, isPlayingReady: true
        ))
    }

    func testSafeTailMarginAllowsOnlyTargetsAtLeastHalfSecondBeforeEOF() throws {
        let safe = try timeline(
            sections: [CommercialSection(startTime: 80, endTime: 99.5)]
        )
        var safePolicy = CommercialSkipPolicy()
        XCTAssertEqual(safePolicy.automaticSeekTarget(
            timeline: safe, at: 90, enabled: true, isPlayingReady: true
        ), 99.5)

        let tooClose = try timeline(
            sections: [CommercialSection(startTime: 80, endTime: 99.51)]
        )
        var tooClosePolicy = CommercialSkipPolicy()
        XCTAssertNil(tooClosePolicy.automaticSeekTarget(
            timeline: tooClose, at: 90, enabled: true, isPlayingReady: true
        ))
    }
}
