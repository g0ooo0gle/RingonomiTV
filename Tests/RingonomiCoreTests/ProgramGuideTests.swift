import XCTest
@testable import RingonomiCore

final class ProgramGuideTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func testDecodesOffsetFractionalDatesAndMissingOptionalFields() throws {
        let data = Data("""
        {
          "channels": [{
            "channel": {
              "id": "NID1-SID2",
              "display_channel_id": "gr011",
              "name": "テスト放送",
              "type": "GR",
              "is_watchable": true
            },
            "programs": [{
              "id": "event-1",
              "channel_id": "NID1-SID2",
              "title": "朝のニュース",
              "description": "今日の主なニュース",
              "start_time": "2026-10-18T12:30:45.123+09:00",
              "end_time": "2026-10-18T13:00:45.123+09:00",
              "duration": 1800,
              "is_free": true,
              "detail": {"出演者": "司会"},
              "genres": [{"major": "ニュース", "middle": "定時"}],
              "secondary_audio_type": null
            }]
          }],
          "date_range": {
            "earliest": "2026-10-18T00:00:00Z",
            "latest": "2026-10-19T00:00:00.5Z"
          }
        }
        """.utf8)

        let response = try decoder.decode(ProgramGuideResponse.self, from: data)
        let wrapper = try XCTUnwrap(response.channels.first)
        XCTAssertEqual(wrapper.channel.displayChannelId, "gr011")
        XCTAssertEqual(wrapper.channel.name, "テスト放送")
        XCTAssertTrue(wrapper.channel.isWatchable)

        let program = try XCTUnwrap(wrapper.programs.first)
        XCTAssertEqual(program.title, "朝のニュース")
        XCTAssertEqual(program.detail["出演者"], "司会")
        XCTAssertEqual(program.genres.first?.major, "ニュース")
        XCTAssertNotNil(program.startDate)
        XCTAssertNotNil(program.endDate)
        XCTAssertNil(program.videoResolution)
        XCTAssertEqual(program.primaryAudioType, "")
        let latest = try XCTUnwrap(response.dateRange?.latest)
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedLatest = try XCTUnwrap(dateFormatter.date(from: "2026-10-19T00:00:00.5Z"))
        XCTAssertEqual(latest.timeIntervalSince1970, expectedLatest.timeIntervalSince1970, accuracy: 0.001)
    }

    func testInvalidProgramTimesAreKeptAsNilWithoutRejectingOtherPrograms() throws {
        let data = Data("""
        {
          "channels": [{
            "channel": {"id": "ch", "display_channel_id": "gr001", "name": "局"},
            "programs": [
              {"id": "bad", "title": "壊れた時刻", "start_time": "not-a-date", "end_time": "also-bad"},
              {"id": "good", "title": "正常", "start_time": "2026-10-18T04:00:00+09:00", "end_time": "2026-10-18T05:00:00+09:00"}
            ]
          }]
        }
        """.utf8)

        let response = try decoder.decode(ProgramGuideResponse.self, from: data)
        XCTAssertEqual(response.channels.first?.programs.count, 2)
        XCTAssertNil(response.channels.first?.programs.first?.startDate)
        XCTAssertNotNil(response.channels.first?.programs.last?.startDate)
    }

    func testSubchannelsAreFlattenedForRowsAndSearch() throws {
        let data = Data("""
        {
          "channels": [{
            "channel": {"id": "main", "display_channel_id": "gr001", "name": "主局"},
            "programs": [],
            "subchannels": [{
              "channel": {"id": "sub", "display_channel_id": "gr001-2", "name": "副局"},
              "programs": [{"id": "sub-program", "title": "副局スポーツ", "start_time": "2026-10-18T04:00:00Z"}]
            }]
          }]
        }
        """.utf8)

        let response = try decoder.decode(ProgramGuideResponse.self, from: data)
        XCTAssertEqual(response.flattenedChannels.map(\.channel.id), ["main", "sub"])
        let results = searchFuturePrograms("スポーツ", in: response, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(results.map(\.program.id), ["sub-program"])
    }

    func testSearchJapaneseORAndANDSortsFutureEntriesAndDeduplicates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let channel = GuideChannel(id: "ch", displayChannelId: "gr001", type: "GR", name: "ニュース局", isWatchable: true)
        let first = GuideProgram(id: "first", channelId: "ch", title: "朝のニュース", description: "国内", startDate: now.addingTimeInterval(60))
        let duplicate = GuideProgram(id: "first", channelId: "ch", title: "朝のニュース", description: "国内", startDate: now.addingTimeInterval(60))
        let second = GuideProgram(id: "second", channelId: "ch", title: "スポーツ速報", description: "結果", startDate: now.addingTimeInterval(120))
        let past = GuideProgram(id: "past", channelId: "ch", title: "朝のニュース", startDate: now.addingTimeInterval(-1))
        let response = ProgramGuideResponse(channels: [
            GuideChannelPrograms(channel: channel, programs: [second, first, duplicate, past])
        ])

        let orResults = searchFuturePrograms("朝,スポーツ", in: response, now: now)
        XCTAssertEqual(orResults.map(\.program.id), ["first", "second"])

        let andResults = searchFuturePrograms("朝 ニュース", in: response, now: now)
        XCTAssertEqual(andResults.map(\.program.id), ["first"])
    }

    func testSearchAcceptsJapaneseWhitespaceAndExcludesInvalidFutureDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let channel = GuideChannel(id: "ch", name: "放送局")
        let program = GuideProgram(id: "japanese", channelId: "ch", title: "音楽 特集", description: "今夜の番組", startDate: now.addingTimeInterval(1))
        let invalid = GuideProgram(id: "invalid", channelId: "ch", title: "音楽 特集", startDate: nil)
        let response = ProgramGuideResponse(channels: [GuideChannelPrograms(channel: channel, programs: [invalid, program])])

        let results = searchFuturePrograms("音楽　特集", in: response, now: now)
        XCTAssertEqual(results.map(\.program.id), ["japanese"])
    }

    func testProgramGuideURLEncodesDateTypeAndPinnedChannels() throws {
        let client = try RingonomiClient(address: "https://example.invalid/proxy/tv")
        let start = Date(timeIntervalSince1970: 1_800_000_000.123)
        let url = client.programGuideURL(
            start: start,
            end: start.addingTimeInterval(3600),
            type: "GR",
            pinnedChannelIDs: ["NID1&SID2", "gr011"]
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/proxy/api/programs/timetable")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "channel_type" })?.value, "GR")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "pinned_channel_ids" })?.value, "NID1&SID2,gr011")
        XCTAssertTrue(url.absoluteString.contains("NID1%26SID2"))
        XCTAssertNotNil(components.queryItems?.first(where: { $0.name == "start_time" })?.value)
    }
}
