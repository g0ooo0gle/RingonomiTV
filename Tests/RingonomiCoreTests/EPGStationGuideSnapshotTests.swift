import Foundation
import XCTest
@testable import RingonomiCore

final class EPGStationGuideSnapshotTests: XCTestCase {
    private let baseMilliseconds = 1_700_000_000_000.0

    func testConvertsDisplayModelAndPreservesSourceMetadata() throws {
        let channel = try channel(id: 101, remoteControlKeyID: 7)
        let program = try program(
            id: 5_001,
            channelID: 101,
            startAt: baseMilliseconds,
            endAt: baseMilliseconds + 3_600_000,
            description: "番組の説明",
            extended: "拡張された説明",
            rawExtended: ["出演者": "出演者情報"],
            genre1: 0,
            subGenre1: 2,
            genre2: 15
        )
        let schedule = try EPGStationSchedule(channel: channel, programs: [program])

        let snapshot = try EPGStationGuideSnapshot(schedules: [schedule])
        let group = try XCTUnwrap(snapshot.response.channels.first)
        let displayChannel = group.channel
        let displayProgram = try XCTUnwrap(group.programs.first)

        XCTAssertEqual(displayChannel.id, "epgstation.channel.101")
        XCTAssertEqual(displayChannel.displayChannelId, "101")
        XCTAssertEqual(displayChannel.networkId, channel.networkID)
        XCTAssertEqual(displayChannel.serviceId, channel.serviceID)
        XCTAssertEqual(displayChannel.remoconId, 7)
        XCTAssertEqual(displayChannel.channelNumber, "7")
        XCTAssertFalse(displayChannel.isWatchable)
        XCTAssertTrue(displayChannel.isDisplay)

        XCTAssertEqual(displayProgram.id, "epgstation.program.5001")
        XCTAssertEqual(displayProgram.channelId, displayChannel.id)
        XCTAssertEqual(displayProgram.title, program.name)
        XCTAssertEqual(displayProgram.description, "番組の説明")
        XCTAssertEqual(displayProgram.duration, 3_600, accuracy: 0.000_001)
        XCTAssertEqual(displayProgram.isFree, program.isFree)
        XCTAssertEqual(try XCTUnwrap(displayProgram.startDate).timeIntervalSince1970, baseMilliseconds / 1000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(displayProgram.endDate).timeIntervalSince1970, (baseMilliseconds + 3_600_000) / 1000, accuracy: 0.001)
        XCTAssertEqual(displayProgram.detail["出演者"], "出演者情報")
        XCTAssertEqual(displayProgram.detail["EPGStation:extended"], "拡張された説明")
        XCTAssertEqual(displayProgram.genres.map(\.major), ["ニュース・報道", "その他"])
        XCTAssertEqual(displayProgram.genres.first?.middle, "EPGStation subGenre 2")

        XCTAssertEqual(snapshot.sourcePrograms.count, 1)
        XCTAssertEqual(snapshot.sourcePrograms[displayProgram.id], program)
    }

    func testNamespacedIDsAvoidNumericChannelAndProgramCollision() throws {
        let firstChannel = try channel(id: 1)
        let secondChannel = try channel(id: 2)
        let firstProgram = try program(id: 1, channelID: 1, startAt: baseMilliseconds, endAt: baseMilliseconds + 1_000)
        let secondProgram = try program(id: 2, channelID: 2, startAt: baseMilliseconds, endAt: baseMilliseconds + 1_000)

        let snapshot = try EPGStationGuideSnapshot(schedules: [
            try EPGStationSchedule(channel: firstChannel, programs: [firstProgram]),
            try EPGStationSchedule(channel: secondChannel, programs: [secondProgram])
        ])

        XCTAssertEqual(snapshot.response.channels.map(\.channel.id), [
            "epgstation.channel.1", "epgstation.channel.2"
        ])
        XCTAssertEqual(Set(snapshot.sourcePrograms.keys), Set([
            "epgstation.program.1", "epgstation.program.2"
        ]))
        XCTAssertNotEqual("epgstation.channel.1", "epgstation.program.1")
    }

    func testEmptyOptionalMetadataAndExtendedAreRetainedSafely() throws {
        let channel = try channel(id: 10)
        let program = try program(
            id: 20,
            channelID: 10,
            startAt: baseMilliseconds,
            endAt: baseMilliseconds,
            description: nil,
            extended: "拡張だけ",
            rawExtended: nil
        )
        let snapshot = try EPGStationGuideSnapshot(
            schedules: [try EPGStationSchedule(channel: channel, programs: [program])]
        )
        let display = try XCTUnwrap(snapshot.response.channels.first?.programs.first)

        XCTAssertEqual(display.description, "")
        XCTAssertEqual(display.detail["EPGStation:extended"], "拡張だけ")
        XCTAssertEqual(display.startDate, display.endDate)
        XCTAssertEqual(display.duration, 0)
        XCTAssertTrue(display.genres.isEmpty)
        XCTAssertNil(snapshot.sourcePrograms[display.id]?.description)
        XCTAssertEqual(snapshot.sourcePrograms[display.id]?.extended, "拡張だけ")
    }

    func testFractionalMillisecondsRemainFractionalWhenConvertedToDate() throws {
        let channel = try channel(id: 11)
        let startAt = baseMilliseconds + 123.456
        let endAt = baseMilliseconds + 2_123.789
        let program = try program(id: 21, channelID: 11, startAt: startAt, endAt: endAt)
        let snapshot = try EPGStationGuideSnapshot(
            schedules: [try EPGStationSchedule(channel: channel, programs: [program])]
        )
        let display = try XCTUnwrap(snapshot.response.channels.first?.programs.first)

        XCTAssertEqual(try XCTUnwrap(display.startDate).timeIntervalSince1970, startAt / 1000, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(display.endDate).timeIntervalSince1970, endAt / 1000, accuracy: 0.000_001)
    }

    func testRawExtendedKeyCollisionDoesNotLoseExtendedText() throws {
        let channel = try channel(id: 12)
        let program = try program(
            id: 22,
            channelID: 12,
            startAt: baseMilliseconds,
            endAt: baseMilliseconds + 1_000,
            extended: "サーバーのextended",
            rawExtended: ["EPGStation:extended": "rawExtended側"]
        )
        let snapshot = try EPGStationGuideSnapshot(
            schedules: [try EPGStationSchedule(channel: channel, programs: [program])]
        )
        let detail = try XCTUnwrap(snapshot.response.channels.first?.programs.first?.detail)

        XCTAssertEqual(detail["EPGStation:extended"], "rawExtended側")
        XCTAssertEqual(detail["EPGStation:extended#1"], "サーバーのextended")
    }

    func testSnapshotPreservesChannelAndProgramServerOrder() throws {
        let firstChannel = try channel(id: 301)
        let secondChannel = try channel(id: 302)
        let firstProgram = try program(id: 302, channelID: 301, startAt: baseMilliseconds, endAt: baseMilliseconds + 1_000)
        let secondProgram = try program(id: 301, channelID: 301, startAt: baseMilliseconds + 1_000, endAt: baseMilliseconds + 2_000)
        let thirdProgram = try program(id: 303, channelID: 302, startAt: baseMilliseconds, endAt: baseMilliseconds + 1_000)

        let snapshot = try EPGStationGuideSnapshot(schedules: [
            try EPGStationSchedule(channel: firstChannel, programs: [firstProgram, secondProgram]),
            try EPGStationSchedule(channel: secondChannel, programs: [thirdProgram])
        ])

        XCTAssertEqual(snapshot.response.channels.map(\.channel.id), [
            "epgstation.channel.301", "epgstation.channel.302"
        ])
        XCTAssertEqual(snapshot.response.channels.first?.programs.map(\.id), [
            "epgstation.program.302", "epgstation.program.301"
        ])
    }

    func testScheduleChannelMismatchIsRejectedBeforeSnapshotConversion() throws {
        let channel = try channel(id: 401)
        let mismatched = try program(id: 402, channelID: 402, startAt: baseMilliseconds, endAt: baseMilliseconds + 1_000)

        XCTAssertThrowsError(try EPGStationSchedule(channel: channel, programs: [mismatched])) { error in
            XCTAssertEqual(error as? EPGStationError, .invalidResponse)
        }
    }

    func testSnapshotConnectsToSearchAndGridLayout() throws {
        let baseDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-18T04:00:00+09:00"))
        let start = baseDate.addingTimeInterval(600).timeIntervalSince1970 * 1000
        let end = baseDate.addingTimeInterval(1_800).timeIntervalSince1970 * 1000
        let channel = try channel(id: 30)
        let program = try program(id: 40, channelID: 30, startAt: start, endAt: end, description: "検索対象")
        let snapshot = try EPGStationGuideSnapshot(
            schedules: [try EPGStationSchedule(channel: channel, programs: [program])]
        )

        let results = searchFuturePrograms("検索対象", in: snapshot.response, now: baseDate)
        XCTAssertEqual(results.map(\.program.id), ["epgstation.program.40"])

        let layout = GuideGridLayout(response: snapshot.response, baseDate: baseDate)
        let entry = try XCTUnwrap(layout.columns.first?.entries.first)
        XCTAssertEqual(layout.columns.count, 1)
        XCTAssertEqual(entry.program.id, "epgstation.program.40")
        XCTAssertEqual(entry.startMinute, 10, accuracy: 0.001)
        XCTAssertEqual(entry.endMinute, 30, accuracy: 0.001)
    }

    func testDuplicateChannelsAreRejected() throws {
        let channel = try channel(id: 101)
        let first = try program(id: 1, channelID: 101, startAt: baseMilliseconds, endAt: baseMilliseconds + 1_000)
        let second = try program(id: 2, channelID: 101, startAt: baseMilliseconds + 1_000, endAt: baseMilliseconds + 2_000)
        let schedules = [
            try EPGStationSchedule(channel: channel, programs: [first]),
            try EPGStationSchedule(channel: channel, programs: [second])
        ]

        XCTAssertThrowsError(try EPGStationGuideSnapshot(schedules: schedules)) { error in
            XCTAssertEqual(error as? EPGStationError, .invalidResponse)
        }
    }

    func testDuplicateProgramsAcrossChannelsAreRejected() throws {
        let firstChannel = try channel(id: 201)
        let secondChannel = try channel(id: 202)
        let first = try program(id: 99, channelID: 201, startAt: baseMilliseconds, endAt: baseMilliseconds + 1_000)
        let second = try program(id: 99, channelID: 202, startAt: baseMilliseconds, endAt: baseMilliseconds + 1_000)
        let schedules = [
            try EPGStationSchedule(channel: firstChannel, programs: [first]),
            try EPGStationSchedule(channel: secondChannel, programs: [second])
        ]

        XCTAssertThrowsError(try EPGStationGuideSnapshot(schedules: schedules)) { error in
            XCTAssertEqual(error as? EPGStationError, .invalidResponse)
        }
    }

    private func channel(id: Int, remoteControlKeyID: Int? = nil) throws -> EPGStationScheduleChannel {
        try EPGStationScheduleChannel(
            id: id,
            serviceID: id + 100,
            networkID: id + 200,
            name: "チャンネル\(id)",
            remoteControlKeyID: remoteControlKeyID,
            hasLogoData: false,
            channelType: "GR"
        )
    }

    private func program(
        id: Int,
        channelID: Int,
        startAt: Double,
        endAt: Double,
        description: String? = "説明",
        extended: String? = nil,
        rawExtended: [String: String]? = nil,
        genre1: Int? = nil,
        subGenre1: Int? = nil,
        genre2: Int? = nil,
        subGenre2: Int? = nil,
        genre3: Int? = nil,
        subGenre3: Int? = nil
    ) throws -> EPGStationScheduleProgram {
        try EPGStationScheduleProgram(
            id: id,
            channelID: channelID,
            startAt: startAt,
            endAt: endAt,
            isFree: true,
            name: "番組\(id)",
            description: description,
            extended: extended,
            rawExtended: rawExtended,
            genre1: genre1,
            subGenre1: subGenre1,
            genre2: genre2,
            subGenre2: subGenre2,
            genre3: genre3,
            subGenre3: subGenre3
        )
    }
}
