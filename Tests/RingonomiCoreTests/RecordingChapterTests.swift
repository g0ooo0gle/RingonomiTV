import XCTest
@testable import RingonomiCore

final class RecordingChapterTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func testRecordedVideoKeepsValidCMEntriesWhenOneEntryIsMalformed() throws {
        let data = Data(#"""
        {
          "id": 7,
          "title": "録画",
          "description": "番組",
          "is_free": true,
          "recorded_video": {
            "id": 42,
            "duration": 180.5,
            "cm_sections": [
              {"start_time": 10.5, "end_time": 20.25},
              {"start_time": "不正", "end_time": 30},
              null,
              {"start_time": 40, "end_time": 50}
            ]
          }
        }
        """#.utf8)

        let recording = try decoder.decode(Recording.self, from: data)

        XCTAssertEqual(recording.recordedVideo.cmSections, [
            CommercialSection(startTime: 10.5, endTime: 20.25),
            CommercialSection(startTime: 40, endTime: 50)
        ])
    }

    func testMissingNullAndWrongTypeCMSectionsAreSafe() throws {
        let missing = Data(#"{"id":1,"duration":10}"#.utf8)
        let null = Data(#"{"id":2,"duration":10,"cm_sections":null}"#.utf8)
        let wrongType = Data(#"{"id":3,"duration":10,"cm_sections":{"start_time":1,"end_time":2}}"#.utf8)

        XCTAssertNil(try decoder.decode(RecordedVideo.self, from: missing).cmSections)
        XCTAssertNil(try decoder.decode(RecordedVideo.self, from: null).cmSections)
        XCTAssertNil(try decoder.decode(RecordedVideo.self, from: wrongType).cmSections)
    }

    func testPlaybackIDUsesRecordedProgramIDForStreamRoutes() throws {
        let data = Data(#"""
        {
          "id": 7,
          "title": "録画",
          "description": "番組",
          "is_free": true,
          "recorded_video": {"id": 42, "duration": 75.5}
        }
        """#.utf8)
        let recording = try decoder.decode(Recording.self, from: data)
        let client = try RingonomiClient(address: "https://localhost/proxy")

        XCTAssertEqual(recording.playbackID, 7)
        XCTAssertEqual(
            client.recordingURL(id: recording.playbackID, session: "session", quality: "720p").path,
            "/proxy/api/streams/video/7/720p/playlist"
        )
    }

    func testTimelineFiltersClipsAndMergesCMSections() throws {
        let timeline = try XCTUnwrap(RecordingChapterTimeline(
            duration: 100,
            sections: [
                CommercialSection(startTime: -1, endTime: 5),
                CommercialSection(startTime: 10, endTime: 20),
                CommercialSection(startTime: 20.5, endTime: 30),
                CommercialSection(startTime: 29.5, endTime: 120),
                CommercialSection(startTime: 60, endTime: 50),
                CommercialSection(startTime: .nan, endTime: 80)
            ]
        ))

        XCTAssertEqual(timeline.commercialSections, [
            CommercialSection(startTime: 10, endTime: 100)
        ])
        XCTAssertTrue(timeline.hasCommercialSections)
        XCTAssertTrue(timeline.hasChapterBoundaries)
        XCTAssertEqual(timeline.chapters.count, 2)
        XCTAssertEqual(timeline.chapters[0].startTime, 0)
        XCTAssertEqual(timeline.chapters[0].endTime, 10)
        XCTAssertFalse(timeline.chapters[0].isCommercial)
        XCTAssertEqual(timeline.chapters[1].startTime, 10)
        XCTAssertEqual(timeline.chapters[1].endTime, 100)
        XCTAssertTrue(timeline.chapters[1].isCommercial)
    }

    func testTimelineKeepsGapsOverOneSecondAndClassifiesByMidpoint() throws {
        let timeline = try XCTUnwrap(RecordingChapterTimeline(
            duration: 100,
            sections: [
                CommercialSection(startTime: 10, endTime: 20),
                CommercialSection(startTime: 20.5, endTime: 30),
                CommercialSection(startTime: 32, endTime: 40)
            ]
        ))

        XCTAssertEqual(timeline.commercialSections, [
            CommercialSection(startTime: 10, endTime: 30),
            CommercialSection(startTime: 32, endTime: 40)
        ])
        XCTAssertTrue(timeline.hasChapterBoundaries)
        XCTAssertEqual(timeline.chapters.count, 5)
        let expected = [
            (start: 0.0, end: 10.0, commercial: false),
            (start: 10.0, end: 30.0, commercial: true),
            (start: 30.0, end: 32.0, commercial: false),
            (start: 32.0, end: 40.0, commercial: true),
            (start: 40.0, end: 100.0, commercial: false)
        ]
        for (chapter, expected) in zip(timeline.chapters, expected) {
            XCTAssertEqual(chapter.startTime, expected.start)
            XCTAssertEqual(chapter.endTime, expected.end)
            XCTAssertEqual(chapter.isCommercial, expected.commercial)
        }
    }

    func testNavigationUsesStrictOneSecondBoundaryAndFallback() throws {
        let timeline = try XCTUnwrap(RecordingChapterTimeline(
            duration: 100,
            sections: [CommercialSection(startTime: 10, endTime: 20)]
        ))

        XCTAssertEqual(timeline.next(from: 0), 10)
        XCTAssertEqual(timeline.next(from: 9), 20)
        XCTAssertEqual(timeline.next(from: 19), 100)
        XCTAssertEqual(timeline.previous(from: 11), 0)
        XCTAssertEqual(timeline.previous(from: 12), 10)
        XCTAssertEqual(timeline.previous(from: 100), 20)
        XCTAssertEqual(timeline.next(from: .nan), 10)
        XCTAssertEqual(timeline.previous(from: -.infinity), 0)
    }

    func testNavigationFallsBackToLongSeekWithoutInternalCMBoundary() throws {
        let timeline = try XCTUnwrap(RecordingChapterTimeline(duration: 500, sections: []))

        XCTAssertFalse(timeline.hasCommercialSections)
        XCTAssertFalse(timeline.hasChapterBoundaries)
        XCTAssertEqual(timeline.previous(from: 100), 40)
        XCTAssertEqual(timeline.next(from: 100), 280)
        XCTAssertEqual(timeline.next(from: 450), 500)
        XCTAssertEqual(timeline.previous(from: 10), 0)
    }

    func testInvalidDurationDoesNotInventTimeline() {
        XCTAssertNil(RecordingChapterTimeline(duration: 0, sections: []))
        XCTAssertNil(RecordingChapterTimeline(duration: -.infinity, sections: []))
        XCTAssertNil(RecordingChapterTimeline(duration: .nan, sections: []))
    }

    func testTooManyCMEntriesAreRejectedWithoutBreakingRecordingDecode() throws {
        let entries = Array(repeating: #"{"start_time":1,"end_time":2}"#, count: RecordingChapterTimeline.maximumSections + 1)
            .joined(separator: ",")
        let json = #"{"id":7,"title":"録画","description":"番組","is_free":true,"recorded_video":{"id":42,"duration":10,"cm_sections":["# + entries + #"]}}"#
        let data = Data(json.utf8)

        let recording = try decoder.decode(Recording.self, from: data)

        XCTAssertEqual(recording.id, 7)
        XCTAssertNil(recording.recordedVideo.cmSections)
    }

    func testTimelineRejectsTooManySectionsAndWholeVideoCMUsesFallback() throws {
        let oversized = Array(repeating: CommercialSection(startTime: 1, endTime: 2), count: RecordingChapterTimeline.maximumSections + 1)
        XCTAssertNil(RecordingChapterTimeline(duration: 100, sections: oversized))

        let wholeVideo = try XCTUnwrap(RecordingChapterTimeline(
            duration: 100,
            sections: [CommercialSection(startTime: 0, endTime: 100)]
        ))
        XCTAssertTrue(wholeVideo.hasCommercialSections)
        XCTAssertFalse(wholeVideo.hasChapterBoundaries)
        XCTAssertEqual(wholeVideo.previous(from: 80), 20)
        XCTAssertEqual(wholeVideo.next(from: 20), 100)
    }
}
