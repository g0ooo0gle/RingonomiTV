import Foundation
import XCTest
@testable import RingonomiCore

final class ARIBCaptionHistoryTests: XCTestCase {
    func testInsertSortsByPTSAndDeduplicatesSamePayload() throws {
        let late = try packet(seconds: 3, payload: [0x03])
        let early = try packet(seconds: 1, payload: [0x01])
        let middle = try packet(seconds: 2, payload: [0x02])
        var history = ARIBCaptionHistory()

        history.insert(late)
        history.insert(early)
        history.insert(middle)
        history.insert(middle)

        let result = history.packets(through: Int64.max)
        XCTAssertEqual(result.map(\.milliseconds), [1_000, 2_000, 3_000])
        XCTAssertEqual(result.map(\.payload), [early.payload, middle.payload, late.payload])
    }

    func testContainsMatchesOnlyTheSamePTSAndPayload() throws {
        let retained = try packet(milliseconds: 2_000, payload: [0x20])
        let samePayloadAtAnotherPTS = try packet(milliseconds: 3_000, payload: [0x20])
        let differentPayloadAtSamePTS = try packet(milliseconds: 2_000, payload: [0x21])
        var history = ARIBCaptionHistory()
        history.insert(retained)

        XCTAssertTrue(history.contains(retained))
        XCTAssertFalse(history.contains(samePayloadAtAnotherPTS))
        XCTAssertFalse(history.contains(differentPayloadAtSamePTS))
    }

    func testEqualPTSUsesStableInsertionOrderAndKeepsCaptionKinds() throws {
        let caption = try packet(seconds: 5, kind: .caption, payload: [0x10])
        let superimpose = try packet(seconds: 5, kind: .superimpose, payload: [0x10])
        var history = ARIBCaptionHistory()

        history.insert(caption)
        history.insert(superimpose)

        let result = history.packets(through: 5_000)
        XCTAssertEqual(result, [caption, superimpose])
        XCTAssertEqual(result.map(\.kind), [.caption, .superimpose])
    }

    func testThroughIsInclusiveAndExcludesFuturePackets() throws {
        let first = try packet(milliseconds: 1_000, payload: [0x01])
        let second = try packet(milliseconds: 2_000, payload: [0x02])
        var history = ARIBCaptionHistory()
        history.insert(first)
        history.insert(second)

        XCTAssertEqual(history.packets(through: 999), [])
        XCTAssertEqual(history.packets(through: 1_000), [first])
        XCTAssertEqual(history.packets(through: 2_000), [first, second])
        XCTAssertEqual(history.packets(through: -1), [])
    }

    func testAfterIsExclusiveAndThroughIsInclusive() throws {
        let first = try packet(milliseconds: 1_000, payload: [0x01])
        let second = try packet(milliseconds: 2_000, payload: [0x02])
        let third = try packet(milliseconds: 3_000, payload: [0x03])
        var history = ARIBCaptionHistory()
        history.insert(first)
        history.insert(second)
        history.insert(third)

        XCTAssertEqual(history.packets(after: 1_000, through: 2_000), [second])
        XCTAssertEqual(history.packets(after: 2_000, through: 2_000), [])
        XCTAssertEqual(history.packets(after: 3_000, through: 2_000), [])
        XCTAssertEqual(history.packets(after: -1, through: 1_000), [first])
    }

    func testMaximumPacketCountEvictsOldestAndKeepsNewest() throws {
        var history = ARIBCaptionHistory()
        for second in 0...ARIBCaptionHistory.maximumPackets {
            history.insert(try packet(seconds: Double(second), payload: [UInt8(second & 0xFF)]))
        }

        let result = history.packets(through: Int64.max)
        XCTAssertEqual(result.count, ARIBCaptionHistory.maximumPackets)
        XCTAssertEqual(result.first?.milliseconds, 1_000)
        XCTAssertEqual(result.last?.milliseconds, Int64(ARIBCaptionHistory.maximumPackets) * 1_000)
        XCTAssertEqual(history.evictedThroughMilliseconds, 0)
    }

    func testMaximumPayloadBytesEvictsOldestButRetainsLatestPacket() throws {
        var history = ARIBCaptionHistory()
        for second in 0...64 {
            var payload = Data(repeating: 0x55, count: ARIBCaptionPacket.maximumBytes)
            payload[0] = 0x80
            payload[1] = 0xFF
            history.insert(try ARIBCaptionPacket(payload: payload, presentationSeconds: Double(second)))
        }

        let result = history.packets(through: Int64.max)
        XCTAssertEqual(result.count, 64)
        XCTAssertEqual(result.first?.milliseconds, 1_000)
        XCTAssertEqual(result.last?.milliseconds, 64_000)
        XCTAssertEqual(result.last?.payload.count, ARIBCaptionPacket.maximumBytes)
        XCTAssertEqual(history.evictedThroughMilliseconds, 0)
    }

    func testRemoveAllClearsPacketsAndPayloadAccounting() throws {
        var history = ARIBCaptionHistory()
        history.insert(try packet(seconds: 1, payload: [0x01]))
        history.removeAll()

        XCTAssertEqual(history.packets(through: Int64.max), [])
        XCTAssertNil(history.evictedThroughMilliseconds)
        history.insert(try packet(seconds: 2, payload: [0x02]))
        XCTAssertEqual(history.packets(through: Int64.max).map(\.milliseconds), [2_000])
    }

    private func packet(
        seconds: Double,
        kind: ARIBCaptionPacket.Kind = .caption,
        payload: [UInt8]
    ) throws -> ARIBCaptionPacket {
        try packet(
            seconds: seconds,
            kind: kind,
            payload: Data(payload)
        )
    }

    private func packet(
        seconds: Double,
        kind: ARIBCaptionPacket.Kind = .caption,
        payload: Data
    ) throws -> ARIBCaptionPacket {
        try packet(
            milliseconds: Int64((seconds * 1_000).rounded()),
            kind: kind,
            payload: payload
        )
    }

    private func packet(
        milliseconds: Int64,
        kind: ARIBCaptionPacket.Kind = .caption,
        payload: [UInt8]
    ) throws -> ARIBCaptionPacket {
        try packet(milliseconds: milliseconds, kind: kind, payload: Data(payload))
    }

    private func packet(
        milliseconds: Int64,
        kind: ARIBCaptionPacket.Kind = .caption,
        payload: Data
    ) throws -> ARIBCaptionPacket {
        var bytes = Data([kind.rawValue, 0xFF, 0xF0])
        bytes.append(payload)
        return try ARIBCaptionPacket(
            payload: bytes,
            presentationSeconds: Double(milliseconds) / 1_000
        )
    }
}
