import Foundation
import XCTest
@testable import RingonomiCore

final class MPEGTSARIBParserTests: XCTestCase {
    func testFragmentedPATPMTVideoAndID3Caption() {
        let stream = FixtureStream()
        let caption = Data([0x80, 0xFF, 0xF0, 0x01, 0x02])
        let packets = stream.bootstrap() + stream.pes(pid: stream.timedID3PID, streamID: 0xBD,
                                                       payload: stream.id3v24(payload: caption), pts: 90_000)
        let input = Data(packets.flatMap { $0 })
        var parser = MPEGTSARIBParser(serviceID: 1)
        var output: [MPEGTSARIBCaption] = []
        for byte in input {
            output.append(contentsOf: parser.append(Data([byte])))
        }

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.payload, caption)
        XCTAssertEqual(output.first?.presentationTicks, 90_000)
        XCTAssertEqual(output.first?.discontinuitySequence, 0)
        XCTAssertEqual(parser.firstVideoTicks, 45_000)
        XCTAssertEqual(parser.firstClockTicks, 45_000)
    }

    func testPrivateARIBCaptionUsesComponentDescriptorAndDropsUnknownOwner() {
        let stream = FixtureStream()
        let valid = Data([0x80, 0xFF, 0x01, 0x02])
        let unknownOwner = stream.id3v24(payload: valid, owner: "other")
        let packets = stream.bootstrap()
            + stream.pes(pid: stream.privateCaptionPID, streamID: 0xBD, payload: unknownOwner, pts: 100)
            + stream.pes(pid: stream.privateCaptionPID, streamID: 0xBD,
                         payload: stream.id3v24(payload: valid), pts: 200, continuityStart: 1)
        var parser = MPEGTSARIBParser()
        let output = parser.append(Data(packets.flatMap { $0 }))
        XCTAssertEqual(output.map(\.payload), [valid])
        XCTAssertEqual(output.first?.presentationTicks, 200)
    }

    func testTimedID3AllowsBoundedPrefixAndPaddingAroundTag() {
        let stream = FixtureStream()
        let caption = Data([0x80, 0xFF, 0x06, 0x07])
        let tagged = Data([0, 0, 0, 0, 0])
            + stream.id3v24(payload: caption)
            + Data(repeating: 0xFF, count: 7)
        let packets = stream.bootstrap()
            + stream.pes(pid: stream.timedID3PID, streamID: 0xBD, payload: tagged, pts: 300)
        var parser = MPEGTSARIBParser()
        let output = parser.append(Data(packets.flatMap { $0 }))
        XCTAssertEqual(output.map(\.payload), [caption])
    }

    func test33BitPTSWrapIsUnwrappedNearPreviousVideoClock() {
        let stream = FixtureStream()
        let modulo: UInt64 = 1 << 33
        let videoPTS = modulo - 10
        let captionPTS: UInt64 = 5
        let packets = stream.bootstrapWithoutVideo()
            + stream.pes(pid: stream.videoPID, streamID: 0xE0, payload: Data([0x00]), pts: videoPTS)
            + stream.pes(pid: stream.timedID3PID, streamID: 0xBD,
                         payload: stream.id3v23(payload: Data([0x80, 0xFF, 0x01])), pts: captionPTS)
        var parser = MPEGTSARIBParser()
        let output = parser.append(Data(packets.flatMap { $0 }))
        XCTAssertEqual(parser.firstVideoTicks, Int64(videoPTS))
        XCTAssertEqual(output.first?.presentationTicks, Int64(modulo + captionPTS))
    }

    func testContinuityGapAndExplicitDiscontinuityDiscardStalePES() {
        let stream = FixtureStream()
        let first = stream.pes(pid: stream.timedID3PID, streamID: 0xBD,
                               payload: stream.id3v24(payload: Data([0x80, 0xFF, 0x01])), pts: 1,
                               continuityStart: 0)
        let gap = stream.pes(pid: stream.timedID3PID, streamID: 0xBD,
                             payload: stream.id3v24(payload: Data([0x80, 0xFF, 0x02])), pts: 2,
                             continuityStart: 5)
        var parser = MPEGTSARIBParser()
        let before = parser.append(Data((stream.bootstrap() + first).flatMap { $0 }))
        let after = parser.append(Data(gap.flatMap { $0 }))
        XCTAssertTrue(before.isEmpty || before.count == 1)
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(parser.discontinuitySequence, 0)
    }

    func testPrivateStream2WithoutOptionalPESHeaderUsesCurrentPCR() {
        let stream = FixtureStream()
        let caption = Data([0x80, 0xFF, 0x04, 0x05])
        let packets = stream.bootstrap()
            + stream.pcrPacket(pid: stream.videoPID, ticks: 123_456)
            + stream.pesWithoutOptionalHeader(pid: stream.privateCaptionPID, streamID: 0xBF,
                                               payload: caption, continuityStart: 1)
        var parser = MPEGTSARIBParser()
        let output = parser.append(Data(packets.flatMap { $0 }))
        XCTAssertEqual(output.first?.payload, caption)
        XCTAssertEqual(output.first?.presentationTicks, 123_456)
    }

    func testBadPSICRCDoesNotSelectMetadataPID() {
        let stream = FixtureStream()
        var badPAT = stream.pat()
        badPAT[badPAT.count - 1] ^= 0x01
        let input = Data((stream.psiPacket(pid: 0, section: badPAT)
            + stream.pes(pid: stream.timedID3PID, streamID: 0xBD,
                         payload: stream.id3v24(payload: Data([0x80, 0xFF, 0x01])), pts: 1)).flatMap { $0 })
        var parser = MPEGTSARIBParser()
        XCTAssertTrue(parser.append(input).isEmpty)
    }

    func testOversizedInputIsBoundedAndResetClearsClockAndSequence() {
        var parser = MPEGTSARIBParser()
        _ = parser.append(Data(repeating: 0xA5, count: 2 * 1024 * 1024))
        parser.reset()
        XCTAssertNil(parser.firstVideoTicks)
        XCTAssertNil(parser.currentClockTicks)
        XCTAssertEqual(parser.discontinuitySequence, 0)
    }

    func testUnrelatedPIDLossDoesNotDiscardFragmentedCaption() {
        let stream = FixtureStream()
        let caption = Data([0x80, 0xFF, 0x01]) + Data(repeating: 0, count: 500)
        let fragments = stream.pes(pid: stream.timedID3PID, streamID: 0xBD,
                                   payload: stream.id3v24(payload: caption), pts: 90_000)
        XCTAssertGreaterThan(fragments.count, 1)
        let unrelated = stream.pes(pid: 0x1FFF, streamID: 0xBD, payload: Data([0]), pts: 0)
            + stream.pes(pid: 0x1FFF, streamID: 0xBD, payload: Data([0]), pts: 0, continuityStart: 8)
        var parser = MPEGTSARIBParser()
        let before = parser.append(Data((stream.bootstrap() + [fragments[0]] + unrelated).flatMap { $0 }))
        let after = parser.append(Data(fragments.dropFirst().flatMap { $0 }))
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(after.map(\.payload), [caption])
        XCTAssertEqual(parser.discontinuitySequence, 0)
    }

    func testUnrelatedPCRDoesNotChangeSelectedProgramClock() {
        let stream = FixtureStream()
        let caption = Data([0x80, 0xFF, 0x01])
        let packets = stream.bootstrap()
            + stream.pcrPacket(pid: stream.videoPID, ticks: 123_456)
            + stream.pcrPacket(pid: 0x1234, ticks: 8_000_000)
            + stream.pesWithoutOptionalHeader(pid: stream.privateCaptionPID, streamID: 0xBF,
                                             payload: caption, continuityStart: 1)
        var parser = MPEGTSARIBParser()
        let output = parser.append(Data(packets.flatMap { $0 }))
        XCTAssertEqual(output.first?.presentationTicks, 123_456)
        XCTAssertEqual(parser.currentClockTicks, 123_456)
    }

    func testCaptionOutputIsBoundedPerAppend() {
        let stream = FixtureStream()
        let caption = Data([0x80, 0xFF, 0x11])
        var packets = stream.bootstrap()
        for index in 0..<129 {
            packets += stream.pes(
                pid: stream.timedID3PID,
                streamID: 0xBD,
                payload: stream.id3v24(payload: caption),
                pts: UInt64(index + 1),
                continuityStart: UInt8(index & 0x0F)
            )
        }

        var parser = MPEGTSARIBParser()
        let output = parser.append(Data(packets.flatMap { $0 }))
        XCTAssertEqual(output.count, 128)
    }
}

private struct FixtureStream {
    let videoPID: UInt16 = 0x0100
    let timedID3PID: UInt16 = 0x0103
    let privateCaptionPID: UInt16 = 0x0104
    private let pmtPID: UInt16 = 0x0101

    func bootstrap() -> [[UInt8]] {
        psiPacket(pid: 0, section: pat())
            + psiPacket(pid: pmtPID, section: pmt())
            + pes(pid: videoPID, streamID: 0xE0, payload: Data([0x00]), pts: 45_000)
    }

    func bootstrapWithoutVideo() -> [[UInt8]] {
        psiPacket(pid: 0, section: pat()) + psiPacket(pid: pmtPID, section: pmt())
    }

    func pat() -> [UInt8] {
        makeSection(tableID: 0x00, body: [
            0x00, 0x01, 0xC1, 0x00, 0x00,
            0x00, 0x01, 0xE1, 0x01
        ])
    }

    func pmt() -> [UInt8] {
        var body: [UInt8] = [
            0x00, 0x01, 0xC1, 0x00, 0x00,
            0xE1, 0x00, 0xF0, 0x00
        ]
        body += [0x1B, 0xE1, 0x00, 0xF0, 0x00]
        body += [0x15, 0xE1, 0x03, 0xF0, 0x00]
        body += [0x06, 0xE1, 0x04, 0xF0, 0x03, 0x52, 0x01, 0x30]
        return makeSection(tableID: 0x02, body: body)
    }

    func id3v24(payload: Data, owner: String = "aribb24.js") -> Data {
        id3(payload: payload, owner: owner, major: 4)
    }

    func id3v23(payload: Data, owner: String = "aribb24.js") -> Data {
        id3(payload: payload, owner: owner, major: 3)
    }

    func id3(payload: Data, owner: String, major: UInt8) -> Data {
        let body = Array(owner.utf8) + [0] + Array(payload)
        let size: [UInt8]
        if major == 3 {
            let n = UInt32(body.count)
            size = [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
        } else {
            size = [UInt8(truncatingIfNeeded: body.count >> 21), UInt8(truncatingIfNeeded: body.count >> 14), UInt8(truncatingIfNeeded: body.count >> 7), UInt8(truncatingIfNeeded: body.count)]
                .map { $0 & 0x7F }
        }
        var frame = Array("PRIV".utf8)
        frame += size
        frame += [0, 0]
        frame += body
        let tagSize = frame.count
        let tagHeader = [UInt8]([0x49, 0x44, 0x33, major, 0, 0,
                                 UInt8(truncatingIfNeeded: tagSize >> 21) & 0x7F,
                                 UInt8(truncatingIfNeeded: tagSize >> 14) & 0x7F,
                                 UInt8(truncatingIfNeeded: tagSize >> 7) & 0x7F,
                                 UInt8(truncatingIfNeeded: tagSize) & 0x7F])
        return Data(tagHeader + frame)
    }

    func pes(pid: UInt16, streamID: UInt8, payload: Data, pts: UInt64,
             continuityStart: UInt8 = 0) -> [[UInt8]] {
        var bytes: [UInt8] = [0, 0, 1, streamID, 0, 0, 0x80, 0x80, 0x05]
        bytes[4] = UInt8(truncatingIfNeeded: (3 + 5 + payload.count) >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: 3 + 5 + payload.count)
        bytes += encodePTS(pts)
        bytes += payload
        return packetize(pid: pid, payload: bytes, continuityStart: continuityStart)
    }

    func pesWithoutOptionalHeader(pid: UInt16, streamID: UInt8, payload: Data,
                                  continuityStart: UInt8 = 0) -> [[UInt8]] {
        let length = payload.count
        let bytes: [UInt8] = [0, 0, 1, streamID, UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)] + Array(payload)
        return packetize(pid: pid, payload: bytes, continuityStart: continuityStart)
    }

    func pcrPacket(pid: UInt16, ticks: UInt64) -> [[UInt8]] {
        var packet = [UInt8](repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8(truncatingIfNeeded: (pid >> 8) & 0x1F)
        packet[2] = UInt8(truncatingIfNeeded: pid & 0xFF)
        packet[3] = 0x20
        packet[4] = 7
        packet[5] = 0x10
        let value = ticks & ((1 << 33) - 1)
        packet[6] = UInt8(truncatingIfNeeded: value >> 25)
        packet[7] = UInt8(truncatingIfNeeded: value >> 17)
        packet[8] = UInt8(truncatingIfNeeded: value >> 9)
        packet[9] = UInt8(truncatingIfNeeded: value >> 1)
        packet[10] = UInt8(truncatingIfNeeded: (value & 1) << 7) | 0x7E
        packet[11] = 0
        return [packet]
    }

    func psiPacket(pid: UInt16, section: [UInt8]) -> [[UInt8]] {
        packetize(pid: pid, payload: [0] + section)
    }

    private func makeSection(tableID: UInt8, body: [UInt8]) -> [UInt8] {
        let sectionLength = body.count + 4
        var result = [tableID,
                      0xB0 | UInt8(truncatingIfNeeded: (sectionLength >> 8) & 0x0F),
                      UInt8(truncatingIfNeeded: sectionLength & 0xFF)] + body
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in result {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        result += [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
        return result
    }

    private func packetize(pid: UInt16, payload: [UInt8], continuityStart: UInt8 = 0) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var index = 0
        var cc = continuityStart & 0x0F
        while index < payload.count {
            let count = min(184, payload.count - index)
            var packet = [UInt8](repeating: 0xFF, count: 188)
            packet[0] = 0x47
            packet[1] = UInt8(truncatingIfNeeded: (pid >> 8) & 0x1F) | (index == 0 ? 0x40 : 0)
            packet[2] = UInt8(truncatingIfNeeded: pid & 0xFF)
            if count == 184 {
                packet[3] = 0x10 | cc
                packet.replaceSubrange(4..<(4 + count), with: payload[index..<(index + count)])
            } else {
                packet[3] = 0x30 | cc
                let adaptationLength = 183 - count
                packet[4] = UInt8(truncatingIfNeeded: adaptationLength)
                packet[5] = 0
                if adaptationLength > 1 {
                    packet.replaceSubrange(6..<(5 + adaptationLength), with: repeatElement(0, count: adaptationLength - 1))
                }
                packet.replaceSubrange((5 + adaptationLength)..<(5 + adaptationLength + count),
                                       with: payload[index..<(index + count)])
            }
            result.append(packet)
            index += count
            cc = (cc + 1) & 0x0F
        }
        return result
    }

    private func encodePTS(_ value: UInt64) -> [UInt8] {
        let pts = value & ((1 << 33) - 1)
        return [UInt8(truncatingIfNeeded: 0x21 | ((pts >> 29) & 0x0E)),
                UInt8(truncatingIfNeeded: pts >> 22),
                UInt8(truncatingIfNeeded: 0x01 | ((pts >> 14) & 0xFE)),
                UInt8(truncatingIfNeeded: pts >> 7),
                UInt8(truncatingIfNeeded: 0x01 | (pts << 1) & 0xFE)]
    }
}
