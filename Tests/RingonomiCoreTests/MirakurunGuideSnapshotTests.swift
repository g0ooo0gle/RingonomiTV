import Foundation
import XCTest
@testable import RingonomiCore

final class MirakurunGuideSnapshotTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testSnapshotConvertsDisplayMetadataAndKeepsSourceLookup() throws {
        let firstService = try service(networkID: 1, serviceID: 2, name: "第一局");
        let secondService = try service(networkID: 2, serviceID: 3, name: "第二局")
        let first = try program(
            id: 1001,
            networkID: 1,
            serviceID: 2,
            offset: 600,
            duration: 1_800,
            name: "番組一",
            description: "説明一",
            extended: ["出演者": "出演者一"],
            genres: [MirakurunProgramGenre(lv1: 3, lv2: 1)],
            video: MirakurunProgramVideo(type: "MPEG2", resolution: "1080i"),
            audios: [MirakurunProgramAudio(componentType: 2, isMain: true, samplingRate: 48000, langs: ["jpn"])]
        )
        let second = try program(
            id: 1002,
            networkID: 2,
            serviceID: 3,
            offset: 1_200,
            duration: 600,
            name: nil,
            description: nil
        )

        let snapshot = try MirakurunGuideSnapshot(
            services: [firstService, secondService],
            programs: [first, second],
            startDate: baseDate,
            endDate: baseDate.addingTimeInterval(3_600)
        )

        XCTAssertEqual(snapshot.response.channels.map(\.channel.id), [
            "mirakurun.service.100002", "mirakurun.service.200003"
        ])
        XCTAssertEqual(snapshot.response.channels.map(\.programs.count), [1, 1])
        XCTAssertEqual(snapshot.servicesByChannelID["mirakurun.service.100002"], firstService)
        XCTAssertEqual(snapshot.programsByID["mirakurun.program.1001"], first)
        XCTAssertEqual(snapshot.programsByID["mirakurun.program.1002"], second)

        let displayChannel = try XCTUnwrap(snapshot.response.channels.first?.channel)
        XCTAssertEqual(displayChannel.networkId, 1)
        XCTAssertEqual(displayChannel.serviceId, 2)
        XCTAssertEqual(displayChannel.name, "第一局")
        XCTAssertEqual(displayChannel.type, "GR")
        XCTAssertTrue(displayChannel.isWatchable)
        XCTAssertTrue(displayChannel.isDisplay)

        let display = try XCTUnwrap(snapshot.response.channels.first?.programs.first)
        XCTAssertEqual(display.id, "mirakurun.program.1001")
        XCTAssertEqual(display.title, "番組一")
        XCTAssertEqual(display.description, "説明一")
        XCTAssertEqual(display.detail["出演者"], "出演者一")
        XCTAssertEqual(display.duration, 1_800, accuracy: 0.000_001)
        XCTAssertEqual(display.genres.map(\.major), ["ドラマ"])
        XCTAssertEqual(display.genres.first?.middle, "Mirakurun subGenre 1")
        XCTAssertEqual(display.videoType, "MPEG2")
        XCTAssertEqual(display.videoResolution, "1080i")
        XCTAssertEqual(display.primaryAudioType, "2")
        XCTAssertEqual(display.primaryAudioLanguage, "jpn")
        XCTAssertEqual(display.primaryAudioSamplingRate, "48000")
        XCTAssertEqual(
            try XCTUnwrap(display.startDate).timeIntervalSince1970,
            baseDate.timeIntervalSince1970 + 600,
            accuracy: 0.000_001
        )
    }

    func testSnapshotFiltersDayBoundariesAndRetainsZeroDurationSource() throws {
        let service = try service(networkID: 1, serviceID: 2, name: "局")
        let before = try program(id: 1, networkID: 1, serviceID: 2, offset: -60, duration: 60)
        let crossing = try program(id: 2, networkID: 1, serviceID: 2, offset: -30, duration: 90)
        let atEnd = try program(id: 3, networkID: 1, serviceID: 2, offset: 3_600, duration: 60)
        let zero = try program(id: 4, networkID: 1, serviceID: 2, offset: 300, duration: 0)

        let snapshot = try MirakurunGuideSnapshot(
            services: [service],
            programs: [before, crossing, atEnd, zero],
            startDate: baseDate,
            endDate: baseDate.addingTimeInterval(3_600)
        )

        XCTAssertEqual(snapshot.programs.map(\.id), [2])
        XCTAssertEqual(snapshot.response.channels.first?.programs.map(\.id), ["mirakurun.program.2"])
        XCTAssertEqual(Set(snapshot.programsByID.keys), Set([
            "mirakurun.program.1", "mirakurun.program.2", "mirakurun.program.3", "mirakurun.program.4"
        ]))
        XCTAssertEqual(snapshot.programsByID["mirakurun.program.4"], zero)
    }

    func testSnapshotRejectsDuplicateServicesProgramsAndServiceMismatch() throws {
        let service = try service(networkID: 1, serviceID: 2, name: "局")
        let program = try program(id: 10, networkID: 1, serviceID: 2, offset: 1, duration: 10)

        XCTAssertThrowsError(
            try MirakurunGuideSnapshot(
                services: [service, service], programs: [program],
                startDate: baseDate, endDate: baseDate.addingTimeInterval(60)
            )
        ) { XCTAssertEqual($0 as? MirakurunError, .invalidResponse) }

        XCTAssertThrowsError(
            try MirakurunGuideSnapshot(
                services: [service], programs: [program, program],
                startDate: baseDate, endDate: baseDate.addingTimeInterval(60)
            )
        ) { XCTAssertEqual($0 as? MirakurunError, .invalidResponse) }

        let otherServiceProgram = try self.program(id: 11, networkID: 9, serviceID: 9, offset: 1, duration: 10)
        XCTAssertThrowsError(
            try MirakurunGuideSnapshot(
                services: [service], programs: [otherServiceProgram],
                startDate: baseDate, endDate: baseDate.addingTimeInterval(60)
            )
        ) { XCTAssertEqual($0 as? MirakurunError, .invalidResponse) }
    }

    func testSnapshotConnectsToSearchAndGridLayout() throws {
        let dayStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-18T04:00:00+09:00"))
        let service = try service(networkID: 1, serviceID: 2, name: "局")
        let program = try MirakurunProgram(
            id: 20,
            eventID: 21,
            serviceID: 2,
            networkID: 1,
            startAt: dayStart.timeIntervalSince1970 * 1000 + 600_000,
            duration: 1_200_000,
            isFree: true,
            name: "検索対象",
            description: "説明"
        )
        let snapshot = try MirakurunGuideSnapshot(
            services: [service], programs: [program],
            startDate: dayStart, endDate: dayStart.addingTimeInterval(3_600)
        )

        let results = searchFuturePrograms("検索対象", in: snapshot.response, now: dayStart)
        XCTAssertEqual(results.map(\.program.id), ["mirakurun.program.20"])

        let layout = GuideGridLayout(response: snapshot.response, baseDate: dayStart)
        XCTAssertEqual(layout.columns.count, 1)
        let entry = try XCTUnwrap(layout.columns.first?.entries.first)
        XCTAssertEqual(entry.program.id, "mirakurun.program.20")
        XCTAssertEqual(entry.startMinute, 10, accuracy: 0.001)
        XCTAssertEqual(entry.endMinute, 30, accuracy: 0.001)
    }

    func testInvalidDateRangeIsRejected() throws {
        let service = try service(networkID: 1, serviceID: 2, name: "局")
        XCTAssertThrowsError(
            try MirakurunGuideSnapshot(
                services: [service], programs: [],
                startDate: baseDate, endDate: baseDate
            )
        ) { XCTAssertEqual($0 as? MirakurunError, .invalidResponse) }
    }

    private func service(networkID: Int, serviceID: Int, name: String) throws -> MirakurunService {
        try MirakurunService(
            id: try XCTUnwrap(MirakurunServiceKey.serviceItemID(networkID: networkID, serviceID: serviceID)),
            serviceID: serviceID,
            networkID: networkID,
            name: name,
            type: 1,
            remoteControlKeyID: 1,
            channel: try MirakurunChannel(type: "GR", channel: "13", name: name),
            transportStreamID: 15
        )
    }

    private func program(
        id: Int,
        networkID: Int,
        serviceID: Int,
        offset: TimeInterval,
        duration: TimeInterval,
        name: String? = "番組",
        description: String? = "説明",
        extended: [String: String]? = nil,
        genres: [MirakurunProgramGenre] = [],
        video: MirakurunProgramVideo? = nil,
        audios: [MirakurunProgramAudio] = []
    ) throws -> MirakurunProgram {
        try MirakurunProgram(
            id: id,
            eventID: id + 100,
            serviceID: serviceID,
            networkID: networkID,
            startAt: baseDate.timeIntervalSince1970 * 1000 + offset * 1000,
            duration: duration * 1000,
            isFree: true,
            name: name,
            description: description,
            extended: extended,
            genres: genres,
            video: video,
            audios: audios
        )
    }
}
