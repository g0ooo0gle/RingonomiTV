import XCTest
@testable import RingonomiCore

final class GuideGridLayoutTests: XCTestCase {
    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func channel(_ id: String, name: String = "局") -> GuideChannel {
        GuideChannel(id: id, displayChannelId: id, type: "GR", name: name, isWatchable: true)
    }

    private func program(
        _ id: String,
        title: String = "番組",
        start: String,
        end: String
    ) -> GuideProgram {
        GuideProgram(
            id: id,
            channelId: "main",
            title: title,
            startDate: date(start),
            endDate: date(end)
        )
    }

    func testTelevisionDayUsesFourAMJSTBoundaryAndOffset() {
        let beforeBoundary = GuideGridLayout.televisionDay(containing: date("2026-10-18T03:59:59+09:00"))
        let atBoundary = GuideGridLayout.televisionDay(containing: date("2026-10-18T04:00:00+09:00"))
        let nextDay = GuideGridLayout.televisionDay(containing: date("2026-10-18T04:00:00+09:00"), offset: 1)

        let calendar = Calendar(identifier: .gregorian)
        var japan = calendar
        japan.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(japan.component(.hour, from: beforeBoundary), 4)
        XCTAssertEqual(japan.component(.day, from: beforeBoundary), 17)
        XCTAssertEqual(japan.component(.day, from: atBoundary), 18)
        XCTAssertEqual(japan.component(.day, from: nextDay), 19)
    }

    func testLayoutClipsTimesDeduplicatesChannelsAndPrograms() {
        let first = channel("main", name: "主局")
        let duplicateChannel = channel("main", name: "重複局")
        let before = program("before", start: "2026-10-18T03:00:00+09:00", end: "2026-10-18T05:00:00+09:00")
        let inside = program("inside", start: "2026-10-18T05:30:00+09:00", end: "2026-10-18T06:00:00+09:00")
        let duplicate = program("inside", start: "2026-10-18T05:40:00+09:00", end: "2026-10-18T06:10:00+09:00")
        let reversed = program("reversed", start: "2026-10-18T07:00:00+09:00", end: "2026-10-18T06:00:00+09:00")
        let outside = program("outside", start: "2026-10-19T04:00:00+09:00", end: "2026-10-19T05:00:00+09:00")
        let merged = program("merged", start: "2026-10-18T06:00:00+09:00", end: "2026-10-18T06:30:00+09:00")
        let response = ProgramGuideResponse(channels: [
            GuideChannelPrograms(channel: first, programs: [inside, before, duplicate, reversed, outside]),
            GuideChannelPrograms(channel: duplicateChannel, programs: [merged])
        ])

        let layout = GuideGridLayout(response: response, baseDate: date("2026-10-18T05:00:00+09:00"))
        XCTAssertEqual(layout.columns.map(\.id), ["main"])
        XCTAssertEqual(layout.columns[0].entries.map(\.id), ["before", "inside", "merged"])
        XCTAssertEqual(layout.columns[0].entries[0].startMinute, 0, accuracy: 0.001)
        XCTAssertEqual(layout.columns[0].entries[0].endMinute, 60, accuracy: 0.001)
        XCTAssertEqual(layout.columns[0].entries[1].startMinute, 90, accuracy: 0.001)
        XCTAssertEqual(layout.columns[0].entries[2].endMinute, 150, accuracy: 0.001)
    }

    func testNestedSubchannelsPreserveOrderAndDeduplicateByChannelID() {
        let main = channel("main")
        let sub = channel("sub")
        let response = ProgramGuideResponse(channels: [
            GuideChannelPrograms(
                channel: main,
                programs: [],
                subchannels: [GuideChannelPrograms(channel: sub, programs: [
                    program("sub-program", start: "2026-10-18T04:00:00+09:00", end: "2026-10-18T05:00:00+09:00")
                ])]
            ),
            GuideChannelPrograms(channel: sub, programs: [
                program("sub-program-2", start: "2026-10-18T05:00:00+09:00", end: "2026-10-18T06:00:00+09:00")
            ])
        ])

        let layout = GuideGridLayout(response: response, baseDate: date("2026-10-18T04:00:00+09:00"))
        XCTAssertEqual(layout.columns.map(\.id), ["main", "sub"])
        XCTAssertEqual(layout.columns[1].entries.map(\.id), ["sub-program", "sub-program-2"])
    }

    func testFocusedEntryPrefersNextGapThenPreviousAndClampsInvalidFocus() {
        let response = ProgramGuideResponse(channels: [GuideChannelPrograms(channel: channel("main"), programs: [
            program("first", start: "2026-10-18T04:00:00+09:00", end: "2026-10-18T04:20:00+09:00"),
            program("second", start: "2026-10-18T04:40:00+09:00", end: "2026-10-18T05:00:00+09:00")
        ])])
        let layout = GuideGridLayout(response: response, baseDate: date("2026-10-18T04:00:00+09:00"))

        XCTAssertEqual(layout.focusedEntry(GuideGridFocus(column: 0, minute: 30))?.id, "second")
        XCTAssertEqual(layout.focusedEntry(GuideGridFocus(column: 0, minute: 90))?.id, "second")
        XCTAssertEqual(layout.focusedEntry(GuideGridFocus(column: -10, minute: .nan))?.id, "first")
        XCTAssertEqual(layout.focusedEntry(GuideGridFocus(column: 99, minute: 10))?.id, "first")
    }

    func testMoveUsesProgramBoundariesAndThirtyMinuteStepForEmptyColumn() {
        let programs = [
            program("first", start: "2026-10-18T04:00:00+09:00", end: "2026-10-18T04:30:00+09:00"),
            program("second", start: "2026-10-18T05:00:00+09:00", end: "2026-10-18T05:30:00+09:00"),
            program("third", start: "2026-10-18T06:00:00+09:00", end: "2026-10-18T06:30:00+09:00")
        ]
        let response = ProgramGuideResponse(channels: [
            GuideChannelPrograms(channel: channel("main"), programs: programs),
            GuideChannelPrograms(channel: channel("empty"), programs: [])
        ])
        let layout = GuideGridLayout(response: response, baseDate: date("2026-10-18T04:00:00+09:00"))

        let downToSecond = layout.move(GuideGridFocus(column: 0, minute: 10), direction: .down)
        XCTAssertEqual(downToSecond, GuideGridFocus(column: 0, minute: 60))
        XCTAssertEqual(layout.move(downToSecond, direction: .down), GuideGridFocus(column: 0, minute: 120))
        XCTAssertEqual(layout.move(GuideGridFocus(column: 0, minute: 120), direction: .down).minute, 1440)
        XCTAssertEqual(layout.move(GuideGridFocus(column: 0, minute: 1440), direction: .up).minute, 60)

        XCTAssertEqual(layout.move(GuideGridFocus(column: 1, minute: 100), direction: .down), GuideGridFocus(column: 1, minute: 130))
        XCTAssertEqual(layout.move(GuideGridFocus(column: 1, minute: 0), direction: .up), GuideGridFocus(column: 1, minute: 0))
        XCTAssertEqual(layout.move(GuideGridFocus(column: 99, minute: 200), direction: .right), GuideGridFocus(column: 1, minute: 200))
        XCTAssertEqual(layout.move(GuideGridFocus(column: -1, minute: -50), direction: .left), GuideGridFocus(column: 0, minute: 0))
    }

    func testEmptyLayoutAndOutOfRangeFocusAreSafe() {
        let layout = GuideGridLayout(response: ProgramGuideResponse(), baseDate: date("2026-10-18T04:00:00+09:00"))
        XCTAssertNil(layout.focusedEntry(GuideGridFocus(column: 999, minute: 999)))
        XCTAssertEqual(layout.move(GuideGridFocus(column: -2, minute: .infinity), direction: .down), GuideGridFocus(column: 0, minute: 0))
    }

    func testSubchannelWithoutProgramsDoesNotConsumeAColumn() {
        let emptySub = GuideChannel(id: "empty-sub", isSubchannel: true)
        let activeSub = GuideChannel(id: "active-sub", isSubchannel: true)
        let response = ProgramGuideResponse(channels: [
            GuideChannelPrograms(channel: channel("main"), programs: [], subchannels: [
                GuideChannelPrograms(channel: emptySub),
                GuideChannelPrograms(channel: activeSub, programs: [
                    program("different-program", start: "2026-10-18T10:00:00+09:00", end: "2026-10-18T11:00:00+09:00")
                ])
            ])
        ])
        let layout = GuideGridLayout(response: response, baseDate: date("2026-10-18T04:00:00+09:00"))
        XCTAssertEqual(layout.columns.map(\.id), ["main", "active-sub"])
        let mainOnly = GuideGridLayout(response: response, baseDate: layout.baseDate, includeSubchannels: false)
        XCTAssertEqual(mainOnly.columns.map(\.id), ["main"])
    }
}
