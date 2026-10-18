import XCTest
@testable import RingonomiCore

final class PlaybackCommentTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func comment(
        _ time: Double,
        type: PlaybackCommentPosition = .right,
        size: PlaybackCommentSize = .medium,
        text: String = "コメント"
    ) throws -> PlaybackComment {
        try PlaybackComment(
            time: time,
            position: type,
            size: size,
            colorRGB: 0xFFFFFF,
            text: text
        )
    }

    func testCommentNormalizesControlCharactersAndDecodesColor() throws {
        let data = Data(##"{"time":2.5,"type":"right","size":"big","color":"#12aBcD","text":"  速報\n\tテスト\u0000  "}"##.utf8)
        let value = try decoder.decode(PlaybackComment.self, from: data)

        XCTAssertEqual(value.time, 2.5)
        XCTAssertEqual(value.position, .right)
        XCTAssertEqual(value.size, .big)
        XCTAssertEqual(value.colorRGB, 0x12ABCD)
        XCTAssertEqual(value.text, "速報 テスト")
        let signedColor = Data(##"{"time":0,"type":"right","size":"medium","color":"#+00000","text":"x"}"##.utf8)
        XCTAssertThrowsError(try decoder.decode(PlaybackComment.self, from: signedColor))
    }

    func testCommentRejectsInvalidTimeColorAndText() {
        XCTAssertThrowsError(try comment(-1))
        XCTAssertThrowsError(try comment(PlaybackComment.maximumTime + 0.1))
        XCTAssertThrowsError(try PlaybackComment(time: .nan, position: .right, size: .medium, colorRGB: 0, text: "x"))
        XCTAssertThrowsError(try PlaybackComment(time: 0, position: .right, size: .medium, colorRGB: 0x1_00_00_00, text: "x"))
        XCTAssertThrowsError(try PlaybackComment(time: 0, position: .right, size: .medium, colorRGB: 0, text: "\n\t"))
        XCTAssertThrowsError(try PlaybackComment(time: 0, position: .right, size: .medium, colorRGB: 0, text: String(repeating: "長", count: PlaybackComment.maximumTextLength + 1)))
        let combiningText = "a" + String(repeating: "\u{0301}", count: PlaybackComment.maximumTextUTF8Length)
        XCTAssertLessThanOrEqual(combiningText.count, PlaybackComment.maximumTextLength)
        XCTAssertGreaterThan(combiningText.utf8.count, PlaybackComment.maximumTextUTF8Length)
        XCTAssertThrowsError(try PlaybackComment(time: 0, position: .right, size: .medium, colorRGB: 0, text: combiningText))
    }

    func testResponseSkipsInvalidEntriesAndBoundsDetail() throws {
        let longDetail = String(repeating: "詳細", count: 3_000)
        let json = """
        {
          "is_success": true,
          "comments": [
            {"time":1,"type":"right","size":"small","color":"#000001","text":"有効"},
            {"time":2,"type":"unknown","size":"small","color":"#000001","text":"無効位置"},
            {"time":3,"type":"top","size":"unknown","color":"#000001","text":"無効サイズ"},
            {"time":4,"type":"bottom","size":"medium","color":"bad","text":"無効色"},
            {"time":-1,"type":"right","size":"medium","color":"#ffffff","text":"無効時刻"},
            {"time":5,"type":"bottom","size":"medium","color":"#ffffff","text":"有効2"}
          ],
          "detail": "\(longDetail)"
        }
        """

        let response = try decoder.decode(RecordedCommentsResponse.self, from: Data(json.utf8))

        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.comments.map(\.text), ["有効", "有効2"])
        XCTAssertEqual(response.detail.count, RecordedCommentsResponse.maximumDetailLength)
    }

    func testResponseRejectsOversizedCommentArrayWithoutPartialDecode() {
        let item = ##"{"time":1,"type":"right","size":"small","color":"#ffffff","text":"x"}"##
        let json = """
        {"is_success":true,"comments":[\(Array(repeating: item, count: RecordedCommentsResponse.maximumComments + 1).joined(separator: ","))],"detail":""}
        """

        XCTAssertThrowsError(try decoder.decode(RecordedCommentsResponse.self, from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? PlaybackCommentError, .tooManyComments)
        }
    }

    func testFlowMovesFromRightOutsideToLeftOutsideAndEndsAfterEightSeconds() throws {
        let value = try comment(10)
        let timeline = RecordedCommentTimeline(
            comments: [value],
            metrics: [PlaybackCommentMetric(width: 100, height: 30)],
            viewportWidth: 1_000,
            viewportHeight: 800,
            topInset: 100,
            bottomInset: 100
        )

        let atStart = try XCTUnwrap(timeline.visible(at: 10).first)
        let halfway = try XCTUnwrap(timeline.visible(at: 14).first)
        let nearEnd = try XCTUnwrap(timeline.visible(at: 17.99).first)
        XCTAssertEqual(atStart.x, 1_000, accuracy: 0.001)
        XCTAssertEqual(halfway.x, 450, accuracy: 0.001)
        XCTAssertEqual(nearEnd.x, -99, accuracy: 2)
        XCTAssertTrue(timeline.visible(at: 18).isEmpty)
    }

    func testTopAndBottomUseFourSecondFixedWindowAndSeparateRows() throws {
        let comments = [
            try comment(5, type: .top, text: "上"),
            try comment(5, type: .bottom, text: "下")
        ]
        let timeline = RecordedCommentTimeline(
            comments: comments,
            metrics: [
                PlaybackCommentMetric(width: 100, height: 30),
                PlaybackCommentMetric(width: 100, height: 30)
            ],
            viewportWidth: 1_000,
            viewportHeight: 800,
            topInset: 100,
            bottomInset: 100
        )

        let frames = timeline.visible(at: 6)
        XCTAssertEqual(frames.count, 2)
        XCTAssertNotEqual(frames[0].y, frames[1].y)
        XCTAssertEqual(timeline.visible(at: 9).count, 0)
    }

    func testSameTimeFlowCommentsUseDifferentLanesAndVelocityDifferenceDoesNotOverlap() throws {
        let comments = [try comment(0, text: "短"), try comment(0, text: "長")]
        let timeline = RecordedCommentTimeline(
            comments: comments,
            metrics: [
                PlaybackCommentMetric(width: 80, height: 30),
                PlaybackCommentMetric(width: 400, height: 30)
            ],
            viewportWidth: 1_000,
            viewportHeight: 400,
            topInset: 20,
            bottomInset: 20
        )

        let frames = timeline.visible(at: 4)
        XCTAssertEqual(frames.count, 2)
        XCTAssertNotEqual(frames[0].y, frames[1].y)
        XCTAssertTrue(frames[0].y + frames[0].height <= frames[1].y || frames[1].y + frames[1].height <= frames[0].y)
    }

    func testOvercrowdedFixedLaneIsDroppedAndSeekDoesNotAdvanceLayout() throws {
        var comments: [PlaybackComment] = []
        var metrics: [PlaybackCommentMetric] = []
        for index in 0..<20 {
            comments.append(try comment(0, type: .top, text: "\(index)"))
            metrics.append(PlaybackCommentMetric(width: 100, height: 50))
        }
        let timeline = RecordedCommentTimeline(
            comments: comments,
            metrics: metrics,
            viewportWidth: 800,
            viewportHeight: 300,
            topInset: 10,
            bottomInset: 10
        )

        XCTAssertLessThan(timeline.visible(at: 0).count, comments.count)
        XCTAssertEqual(timeline.visible(at: 0), timeline.visible(at: 0))
        XCTAssertTrue(timeline.visible(at: -1).isEmpty)
    }

    func testSparseLongFlowHistoryKeepsTheCollisionWorkingSetBounded() throws {
        let count = 50_000
        var comments: [PlaybackComment] = []
        comments.reserveCapacity(count)
        for index in 0..<count {
            comments.append(try comment(Double(index) * 10, text: "履歴"))
        }
        let metrics = Array(
            repeating: PlaybackCommentMetric(width: 100, height: 20),
            count: count
        )
        let timeline = RecordedCommentTimeline(
            comments: comments,
            metrics: metrics,
            viewportWidth: 1_000,
            viewportHeight: 500
        )

        let lastTime = Double(count - 1) * 10
        XCTAssertEqual(timeline.visible(at: lastTime).map(\.commentIndex), [count - 1])
    }

    func testFasterFollowerIsRejectedEvenWhenThereIsRoomAtItsEntry() throws {
        let comments = [try comment(0), try comment(1)]
        func timeline(followerWidth: Double) -> RecordedCommentTimeline {
            RecordedCommentTimeline(
                comments: comments,
                metrics: [.init(width: 100, height: 20), .init(width: followerWidth, height: 20)],
                viewportWidth: 1_000, viewportHeight: 24, topInset: 0, bottomInset: 0
            )
        }
        // Both fit at t=1, but the wider follower moves faster and would
        // overtake the first comment before it leaves the screen.
        XCTAssertEqual(timeline(followerWidth: 800).visible(at: 2).map(\.commentIndex), [0])
        // Equal speeds keep the entry gap, so the same lane can be reused.
        let admitted = timeline(followerWidth: 100).visible(at: 2)
        XCTAssertEqual(admitted.map(\.commentIndex), [0, 1])
        XCTAssertLessThan(admitted[0].x + admitted[0].width, admitted[1].x)
    }

    func testInvalidGeometryAndMismatchedMetricsAreSafe() throws {
        let value = try comment(0)
        let invalid = RecordedCommentTimeline(
            comments: [value],
            metrics: [PlaybackCommentMetric(width: -.infinity, height: .nan)],
            viewportWidth: .nan,
            viewportHeight: -.infinity
        )
        XCTAssertTrue(invalid.visible(at: 0).isEmpty)

        let missingMetric = RecordedCommentTimeline(
            comments: [value],
            metrics: [],
            viewportWidth: 1_000,
            viewportHeight: 800
        )
        XCTAssertTrue(missingMetric.visible(at: 0).isEmpty)
    }

    func testVisibleUsesStableInputIndexForSameTimeOrdering() throws {
        let comments = [
            try comment(1, text: "first"),
            try comment(1, text: "second")
        ]
        let timeline = RecordedCommentTimeline(
            comments: comments,
            metrics: [
                PlaybackCommentMetric(width: 100, height: 20),
                PlaybackCommentMetric(width: 100, height: 20)
            ],
            viewportWidth: 1_000,
            viewportHeight: 500
        )
        XCTAssertEqual(timeline.visible(at: 1).map(\.commentIndex), [0, 1])
    }
}
