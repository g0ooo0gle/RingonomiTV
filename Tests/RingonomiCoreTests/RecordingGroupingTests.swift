import XCTest
@testable import RingonomiCore

final class RecordingGroupingTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func testChannelGenreWeekdayMembershipsAndCounts() throws {
        let recordings = try [
            recording(id: 1, title: "ニュース 第1話", startTime: "2026-10-18T14:59:59Z",
                      channelID: "gr011", channelName: "NHK", genres: ["ニュース", "スポーツ"]),
            recording(id: 2, title: "ニュース 第2話", startTime: "2026-10-19T00:00:00+09:00",
                      channelID: "gr011", channelName: "NHK", genres: ["ニュース", "ニュース"]),
            recording(id: 3, title: "単発", startTime: "invalid", channelID: nil, channelName: nil,
                      genres: [])
        ]
        let index = try RecordingGroupingIndex(recordings: recordings)

        XCTAssertEqual(index.groups(for: .channel).map(\.count), [2, 1])
        XCTAssertEqual(index.recordings(for: .channel, groupID: "channel:id:gr011").map(\.id), [1, 2])
        XCTAssertEqual(index.recordings(for: .channel, groupID: "channel:unknown").map(\.id), [3])

        let news = try XCTUnwrap(index.groups(for: .genre).first { $0.id == "genre:value:ニュース" })
        XCTAssertEqual(news.count, 2)
        XCTAssertEqual(index.recordings(for: .genre, groupID: "genre:value:スポーツ").map(\.id), [1])
        XCTAssertEqual(index.recordings(for: .genre, groupID: "genre:unknown").map(\.id), [3])

        XCTAssertEqual(index.recordings(for: .weekday, groupID: "weekday:sun").map(\.id), [1])
        XCTAssertEqual(index.recordings(for: .weekday, groupID: "weekday:mon").map(\.id), [2])
        XCTAssertEqual(index.recordings(for: .weekday, groupID: "weekday:unknown").map(\.id), [3])
    }

    func testSeriesUsesExplicitTitleAndConservativeFallback() throws {
        let recordings = try [
            recording(id: 1, title: "作品 第1話", startTime: nil, seriesTitle: nil),
            recording(id: 2, title: "作品 第2話", startTime: nil, seriesTitle: nil),
            recording(id: 3, title: "ニュース", startTime: nil, seriesTitle: nil),
            recording(id: 4, title: "ニュース速報", startTime: nil, seriesTitle: nil),
            recording(id: 5, title: "特別番組", startTime: nil, seriesTitle: "明示シリーズ"),
        ]
        let index = try RecordingGroupingIndex(recordings: recordings)

        XCTAssertEqual(index.recordings(for: .series, groupID: "series:value:作品").map(\.id), [1, 2])
        XCTAssertEqual(index.recordings(for: .series, groupID: "series:value:明示シリーズ").map(\.id), [5])
        XCTAssertEqual(index.recordings(for: .series, groupID: "series:other").map(\.id), [3, 4])
        XCTAssertEqual(index.recordings(for: .series, groupID: nil).map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(index.groups(for: .series).first { $0.id == "series:value:作品" }?.count, 2)
    }

    func testSpecialGroupIDsAreSeparateFromRealValues() throws {
        let recordings = try [
            recording(id: 1, title: "通常", startTime: nil, genres: []),
            recording(id: 2, title: "明示", startTime: nil, genres: ["unknown"], seriesTitle: "other")
        ]
        let index = try RecordingGroupingIndex(recordings: recordings)

        XCTAssertEqual(index.recordings(for: .genre, groupID: "genre:unknown").map(\.id), [1])
        XCTAssertEqual(index.recordings(for: .genre, groupID: "genre:value:unknown").map(\.id), [2])
        XCTAssertEqual(index.recordings(for: .series, groupID: "series:other").map(\.id), [1])
        XCTAssertEqual(index.recordings(for: .series, groupID: "series:value:other").map(\.id), [2])
    }

    func testFallbackNormalizesFullWidthEpisodeMarkersWithoutOverMerging() throws {
        let recordings = try [
            recording(id: 1, title: "ドラマＡ 第１話", startTime: nil, seriesTitle: nil),
            recording(id: 2, title: "ドラマA 第２話", startTime: nil, seriesTitle: nil),
            recording(id: 3, title: "ドラマAB 第１話", startTime: nil, seriesTitle: nil),
            recording(id: 4, title: "ドラマAB 第２話", startTime: nil, seriesTitle: nil),
            recording(id: 5, title: "Step2", startTime: nil, seriesTitle: nil),
            recording(id: 6, title: "Step3", startTime: nil, seriesTitle: nil),
        ]
        let index = try RecordingGroupingIndex(recordings: recordings)

        XCTAssertEqual(index.recordings(for: .series, groupID: "series:value:ドラマA").map(\.id), [1, 2])
        XCTAssertEqual(index.recordings(for: .series, groupID: "series:value:ドラマAB").map(\.id), [3, 4])
        XCTAssertEqual(index.recordings(for: .series, groupID: "series:value:St").map(\.id), [])
        XCTAssertEqual(index.recordings(for: .series, groupID: "series:other").map(\.id), [5, 6])
    }

    func testEmptyAndInvalidGroupLookupsAreSafe() throws {
        let index = try RecordingGroupingIndex(recordings: [])
        for grouping in RecordingGrouping.allCases {
            XCTAssertTrue(index.groups(for: grouping).isEmpty)
            XCTAssertTrue(index.recordings(for: grouping, groupID: "invalid").isEmpty)
            XCTAssertTrue(index.recordings(for: grouping).isEmpty)
        }
    }

    func testBuilderObservesCancellation() async throws {
        let recordings = try (0..<20_000).map { id in
            try recording(id: id + 1, title: "録画\(id)", startTime: nil, seriesTitle: nil)
        }
        let task = Task.detached(priority: nil) {
            try RecordingGroupingIndex(recordings: recordings)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testLargeSingleGroupPreservesEveryMember() throws {
        let recordings = try (0..<20_000).map { id in
            try recording(id: id + 1, title: "同一番組\(id)", startTime: nil,
                          channelID: "same", channelName: "同じ局", genres: ["同じ"])
        }
        let index = try RecordingGroupingIndex(recordings: recordings)

        XCTAssertEqual(index.groups(for: .channel).first?.count, recordings.count)
        XCTAssertEqual(index.recordings(for: .channel, groupID: "channel:id:same").count, recordings.count)
        XCTAssertEqual(index.groups(for: .genre).first { $0.id == "genre:value:同じ" }?.count, recordings.count)
    }

    private func recording(
        id: Int,
        title: String,
        startTime: String?,
        channelID: String? = "channel",
        channelName: String? = "局",
        genres: [String] = [],
        seriesTitle: String? = nil
    ) throws -> Recording {
        var object: [String: Any] = [
            "id": id,
            "title": title,
            "description": "",
            "is_free": true,
            "recorded_video": ["id": id + 10_000, "duration": 60.0],
            "genres": genres.map { ["major": $0, "middle": ""] }
        ]
        if let startTime { object["start_time"] = startTime }
        if let seriesTitle { object["series_title"] = seriesTitle }
        if let channelID {
            object["channel"] = [
                "id": channelID,
                "display_channel_id": channelID,
                "name": channelName ?? ""
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try decoder.decode(Recording.self, from: data)
    }
}
