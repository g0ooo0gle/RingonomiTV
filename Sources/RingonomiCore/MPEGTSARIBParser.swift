import Foundation

public struct MPEGTSARIBCaption: Sendable {
    public let payload: Data
    public let presentationTicks: Int64
    public let discontinuitySequence: UInt64

    public init(payload: Data, presentationTicks: Int64, discontinuitySequence: UInt64) {
        self.payload = payload
        self.presentationTicks = presentationTicks
        self.discontinuitySequence = discontinuitySequence
    }
}

/// Extracts ARIB caption metadata from an MPEG-TS stream.
///
/// The parser is intentionally a small, fail-closed transport parser.  It
/// never throws while consuming live data: malformed transport, PSI, PES, and
/// ID3 input is discarded and the next synchronization point is used.  Video
/// bytes are never rewritten or exposed by this type.
public struct MPEGTSARIBParser: Sendable {
    public private(set) var firstVideoTicks: Int64?
    /// The first accepted PCR or PTS in the current stream generation.
    /// This gives renderers a stable zero-point even when no video PES has
    /// arrived yet.
    public private(set) var firstClockTicks: Int64?
    public private(set) var currentClockTicks: Int64?
    public private(set) var discontinuitySequence: UInt64

    private static let packetBytes = 188
    private static let maximumInputBytes = 1 * 1024 * 1024
    private static let maximumSectionBytes = 4 * 1024
    private static let maximumPESBytes = 65_536
    private static let maximumMetadataPIDs = 8
    private static let clockModulo: Int64 = 1 << 33
    private static let clockHalf: Int64 = 1 << 32
    private static let clockMask: UInt64 = (1 << 33) - 1

    private struct PSIState: Sendable {
        var bytes: [UInt8] = []
        var expectedLength: Int? = nil

        mutating func clear() {
            bytes.removeAll(keepingCapacity: true)
            expectedLength = nil
        }
    }

    private struct PESState: Sendable {
        var bytes: [UInt8] = []
        var expectedLength: Int? = nil

        mutating func clear() {
            bytes.removeAll(keepingCapacity: true)
            expectedLength = nil
        }
    }

    private struct Continuity: Sendable {
        var counter: UInt8
        var hasPayload: Bool
    }

    private struct MetadataPID: Sendable, Equatable {
        var timedID3 = false
        var aribPayload = false
        var pcrFallback = false
    }

    private struct StreamDescription: Sendable {
        var videoPIDs: Set<UInt16> = []
        var metadata: [UInt16: MetadataPID] = [:]
        var pcrPID: UInt16? = nil
    }

    private let requestedServiceID: Int?
    private var transportBuffer: [UInt8] = []
    private var psiStates: [UInt16: PSIState] = [:]
    private var pesStates: [UInt16: PESState] = [:]
    private var continuity: [UInt16: Continuity] = [:]
    private var pmtPID: UInt16?
    private var selectedProgram: UInt16?
    private var pmtVersion: UInt8?
    private var streamDescription = StreamDescription()
    private var clockReference: Int64?
    private var lastPATVersion: UInt8?

    public init(serviceID: Int? = nil) {
        requestedServiceID = serviceID.flatMap { (0...65_535).contains($0) ? $0 : nil }
        firstVideoTicks = nil
        firstClockTicks = nil
        currentClockTicks = nil
        discontinuitySequence = 0
    }

    public mutating func reset() {
        transportBuffer.removeAll(keepingCapacity: false)
        psiStates.removeAll(keepingCapacity: false)
        pesStates.removeAll(keepingCapacity: false)
        continuity.removeAll(keepingCapacity: false)
        pmtPID = nil
        selectedProgram = nil
        pmtVersion = nil
        streamDescription = StreamDescription()
        clockReference = nil
        lastPATVersion = nil
        firstVideoTicks = nil
        firstClockTicks = nil
        currentClockTicks = nil
        discontinuitySequence = 0
    }

    /// Appends at most one bounded input chunk and returns newly decoded
    /// caption packets in transport order.
    public mutating func append(_ data: Data) -> [MPEGTSARIBCaption] {
        guard !data.isEmpty else { return [] }
        let boundedCount = min(data.count, Self.maximumInputBytes)
        transportBuffer.append(contentsOf: data.prefix(boundedCount))
        if transportBuffer.count > Self.maximumInputBytes + Self.packetBytes {
            transportBuffer.removeFirst(transportBuffer.count - (Self.maximumInputBytes + Self.packetBytes))
        }

        var output: [MPEGTSARIBCaption] = []
        var cursor = 0
        while transportBuffer.count - cursor >= Self.packetBytes {
            guard let sync = findSync(in: transportBuffer, from: cursor) else {
                cursor = max(cursor, transportBuffer.count - (Self.packetBytes - 1))
                break
            }
            cursor = sync
            guard transportBuffer.count - cursor >= Self.packetBytes else { break }
            if cursor + Self.packetBytes < transportBuffer.count,
               transportBuffer[cursor + Self.packetBytes] != 0x47 {
                cursor += 1
                continue
            }
            let packetEnd = cursor + Self.packetBytes
            // ArraySlice keeps the packet view on the transport buffer. The
            // parser copies only payload bytes for PSI/PES consumers that
            // actually need them.
            let packet = transportBuffer[cursor..<packetEnd]
            cursor = packetEnd
            process(packet: packet, output: &output)
        }
        if cursor > 0 {
            transportBuffer.removeFirst(cursor)
        }
        if transportBuffer.count > Self.packetBytes - 1 {
            transportBuffer.removeFirst(transportBuffer.count - (Self.packetBytes - 1))
        }
        return output
    }

    private func findSync(in bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        var index = max(0, start)
        while index < bytes.count {
            if bytes[index] == 0x47 {
                let remaining = bytes.count - index
                if remaining < Self.packetBytes || remaining < Self.packetBytes * 2 {
                    return index
                }
                if bytes[index + Self.packetBytes] == 0x47 {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private mutating func process(packet: ArraySlice<UInt8>, output: inout [MPEGTSARIBCaption]) {
        guard packet.count == Self.packetBytes else { return }
        let base = packet.startIndex
        guard packet[base] == 0x47 else { return }
        let transportError = (packet[base + 1] & 0x80) != 0
        let payloadUnitStart = (packet[base + 1] & 0x40) != 0
        let pid = UInt16(packet[base + 1] & 0x1F) << 8 | UInt16(packet[base + 2])
        let scrambling = (packet[base + 3] & 0xC0) >> 6
        let adaptationControl = (packet[base + 3] & 0x30) >> 4
        let counter = packet[base + 3] & 0x0F
        guard adaptationControl != 0 else { return }

        var payloadOffset = 4
        var hasDiscontinuityFlag = false
        var pcr: UInt64?
        if adaptationControl == 2 || adaptationControl == 3 {
            guard payloadOffset < packet.count else { return }
            let length = Int(packet[base + payloadOffset])
            guard length <= packet.count - payloadOffset - 1 else { return }
            if length > 0 {
                let flags = packet[base + payloadOffset + 1]
                hasDiscontinuityFlag = (flags & 0x80) != 0
                if (flags & 0x10) != 0, length >= 7 {
                    pcr = parsePCR(packet, at: payloadOffset + 2)
                }
            }
            payloadOffset += 1 + length
        }

        // Only the PCR PID declared by the selected PMT is a clock source.
        // Before PMT selection, video PTS is the fallback baseline; accepting
        // an arbitrary adaptation-field PCR could mix clocks from another
        // service in a multi-program transport stream.
        let selectedPCR = pcr != nil && streamDescription.pcrPID == pid
        var resetForDiscontinuity = false
        if hasDiscontinuityFlag && isRelevantPID(pid, hasPCR: selectedPCR) {
            beginDiscontinuity()
            resetForDiscontinuity = true
        }
        if transportError || scrambling != 0 {
            if isRelevantPID(pid, hasPCR: selectedPCR) && !resetForDiscontinuity {
                beginDiscontinuity()
            }
            return
        }
        if selectedPCR, let pcr {
            currentClockTicks = unwrap(pcr)
            if firstClockTicks == nil { firstClockTicks = currentClockTicks }
            clockReference = currentClockTicks
        }

        let isPSI = pid == 0 || pid == pmtPID
        let isVideo = streamDescription.videoPIDs.contains(pid)
        let isMetadata = streamDescription.metadata[pid] != nil
        // Once the first video PTS is known, the remainder of a video PES is
        // intentionally ignored. This preserves clock/adaptation handling
        // while avoiding a payload allocation and parser work for every frame.
        guard isPSI || isMetadata || (isVideo && firstVideoTicks == nil) else { return }
        let carriesPayload = adaptationControl == 1 || adaptationControl == 3
        guard carriesPayload, payloadOffset <= packet.count else { return }
        if !acceptContinuity(pid: pid, counter: counter) { return }
        let payload = Array(packet[(base + payloadOffset)..<(base + packet.count)])
        guard !payload.isEmpty else { return }

        if isPSI {
            let completed = consumePSI(pid: pid, payload: payload, startsSection: payloadUnitStart)
            for section in completed {
                processPSI(section, pid: pid)
            }
            return
        }

        if isVideo {
            consumeVideoPrefix(pid: pid, payload: payload, startsPacket: payloadUnitStart)
            return
        }
        let decoded = consumePES(pid: pid, payload: payload, startsPacket: payloadUnitStart)
        for pes in decoded {
            processPES(pes, pid: pid, output: &output)
        }
    }

    private mutating func acceptContinuity(pid: UInt16, counter: UInt8) -> Bool {
        guard tracksContinuity(pid) else { return true }
        var accepted = true
        if let previous = continuity[pid], previous.hasPayload {
            if previous.counter == counter {
                return false
            }
            let expected = (previous.counter + 1) & 0x0F
            if counter != expected {
                clearPID(pid)
                accepted = false
            }
        }
        continuity[pid] = Continuity(counter: counter, hasPayload: true)
        return accepted
    }

    private func tracksContinuity(_ pid: UInt16) -> Bool {
        guard pid != 0x1FFF else { return false }
        return isRelevantPID(pid, hasPCR: false)
    }

    private func isRelevantPID(_ pid: UInt16, hasPCR: Bool) -> Bool {
        hasPCR || pid == 0 || pid == pmtPID || pid == streamDescription.pcrPID
            || streamDescription.videoPIDs.contains(pid)
            || streamDescription.metadata[pid] != nil
    }

    private mutating func clearPID(_ pid: UInt16) {
        psiStates[pid]?.clear()
        pesStates[pid]?.clear()
        continuity[pid] = nil
    }

    private mutating func consumePSI(pid: UInt16, payload: [UInt8], startsSection: Bool) -> [[UInt8]] {
        var state = psiStates[pid] ?? PSIState()
        var completed: [[UInt8]] = []
        var index = 0

        if startsSection {
            guard let pointer = payload.first, Int(pointer) <= payload.count - 1 else {
                state.clear()
                psiStates[pid] = state
                return []
            }
            let pointerEnd = 1 + Int(pointer)
            if !state.bytes.isEmpty, pointer > 0 {
                appendPSIBytes(Array(payload[1..<pointerEnd]), state: &state, completed: &completed)
            }
            if !state.bytes.isEmpty {
                state.clear()
            }
            index = pointerEnd
        }
        if index < payload.count {
            appendPSIBytes(Array(payload[index..<payload.count]), state: &state, completed: &completed)
        }
        psiStates[pid] = state
        return completed
    }

    private func appendPSIBytes(_ bytes: [UInt8], state: inout PSIState, completed: inout [[UInt8]]) {
        var index = 0
        while index < bytes.count {
            if state.bytes.isEmpty, bytes[index] == 0xFF { break }
            if state.bytes.isEmpty {
                let remaining = bytes.count - index
                if remaining < 3 {
                    state.bytes.append(contentsOf: bytes[index..<bytes.count])
                    break
                }
                let sectionLength = Int(bytes[index + 1] & 0x0F) << 8 | Int(bytes[index + 2])
                let total = sectionLength + 3
                guard sectionLength >= 4, total <= Self.maximumSectionBytes else {
                    state.clear()
                    index += 1
                    continue
                }
                state.expectedLength = total
            }
            guard let expected = state.expectedLength else {
                state.clear()
                continue
            }
            let needed = expected - state.bytes.count
            let take = min(needed, bytes.count - index)
            state.bytes.append(contentsOf: bytes[index..<(index + take)])
            index += take
            if state.bytes.count == expected {
                completed.append(state.bytes)
                state.clear()
            }
        }
    }

    private mutating func processPSI(_ section: [UInt8], pid: UInt16) {
        guard section.count >= 12, section.count <= Self.maximumSectionBytes,
              mpegCRC(section) == 0 else { return }
        let tableID = section[0]
        if pid == 0, tableID == 0x00 {
            processPAT(section)
        } else if pid == pmtPID, tableID == 0x02 {
            processPMT(section)
        }
    }

    private mutating func processPAT(_ section: [UInt8]) {
        guard section.count >= 12,
              section[1] & 0x80 != 0,
              section[6] == 0,
              section[7] == 0 else { return }
        let transportID = UInt16(section[3]) << 8 | UInt16(section[4])
        _ = transportID
        let version = (section[5] >> 1) & 0x1F
        let end = section.count - 4
        var chosenProgram: UInt16?
        var chosenPMT: UInt16?
        var index = 8
        while index + 4 <= end {
            let program = UInt16(section[index]) << 8 | UInt16(section[index + 1])
            let value = UInt16(section[index + 2] & 0x1F) << 8 | UInt16(section[index + 3])
            if program != 0, (requestedServiceID == nil || requestedServiceID == Int(program)) {
                if chosenProgram == nil {
                    chosenProgram = program
                    chosenPMT = value
                }
            }
            index += 4
        }
        guard let chosenProgram, let chosenPMT else { return }
        let hadProgram = selectedProgram != nil || pmtPID != nil
        let changed = selectedProgram != chosenProgram || pmtPID != chosenPMT
        selectedProgram = chosenProgram
        if changed && hadProgram {
            beginProgramChange(resetFirstVideo: true)
        }
        pmtPID = chosenPMT
        lastPATVersion = version
    }

    private mutating func processPMT(_ section: [UInt8]) {
        guard section.count >= 16,
              section[1] & 0x80 != 0,
              section[6] == 0,
              section[7] == 0 else { return }
        let program = UInt16(section[3]) << 8 | UInt16(section[4])
        guard program == selectedProgram else { return }
        let version = (section[5] >> 1) & 0x1F
        let pcrPID = UInt16(section[8] & 0x1F) << 8 | UInt16(section[9])
        let programInfoLength = Int(section[10] & 0x0F) << 8 | Int(section[11])
        let streamsStart = 12 + programInfoLength
        let end = section.count - 4
        guard streamsStart <= end else { return }

        var description = StreamDescription(pcrPID: pcrPID)
        var index = streamsStart
        while index + 5 <= end {
            let streamType = section[index]
            let elementaryPID = UInt16(section[index + 1] & 0x1F) << 8 | UInt16(section[index + 2])
            let infoLength = Int(section[index + 3] & 0x0F) << 8 | Int(section[index + 4])
            let descriptorStart = index + 5
            let next = descriptorStart + infoLength
            guard next <= end else { return }
            var componentTag: UInt8?
            var descriptorIndex = descriptorStart
            while descriptorIndex + 2 <= next {
                let tag = section[descriptorIndex]
                let length = Int(section[descriptorIndex + 1])
                let descriptorEnd = descriptorIndex + 2 + length
                guard descriptorEnd <= next else { return }
                if tag == 0x52, length >= 1 {
                    componentTag = section[descriptorIndex + 2]
                }
                descriptorIndex = descriptorEnd
            }

            if isVideoStream(streamType) {
                description.videoPIDs.insert(elementaryPID)
            }
            if streamType == 0x15 {
                if description.metadata.count < Self.maximumMetadataPIDs {
                    description.metadata[elementaryPID] = MetadataPID(timedID3: true, aribPayload: false, pcrFallback: true)
                }
            } else if streamType == 0x06, let componentTag, isARIBComponentTag(componentTag) {
                if description.metadata.count < Self.maximumMetadataPIDs {
                    description.metadata[elementaryPID] = MetadataPID(timedID3: false, aribPayload: true, pcrFallback: true)
                }
            }
            index = next
        }

        let versionChanged = pmtVersion != nil && pmtVersion != version
        let descriptionChanged = description.videoPIDs != streamDescription.videoPIDs
            || description.metadata != streamDescription.metadata
            || description.pcrPID != streamDescription.pcrPID
        if versionChanged || (pmtVersion != nil && descriptionChanged) {
            beginProgramChange(resetFirstVideo: true)
        }
        streamDescription = description
        pmtVersion = version
    }

    private mutating func consumePES(pid: UInt16, payload: [UInt8], startsPacket: Bool) -> [[UInt8]] {
        var state = pesStates[pid] ?? PESState()
        var completed: [[UInt8]] = []
        if startsPacket {
            if !state.bytes.isEmpty {
                completed.append(state.bytes)
            }
            state.clear()
        }
        guard startsPacket || !state.bytes.isEmpty else {
            pesStates[pid] = state
            return []
        }
        guard state.bytes.count + payload.count <= Self.maximumPESBytes else {
            state.clear()
            pesStates[pid] = state
            return completed
        }
        state.bytes.append(contentsOf: payload)
        if state.expectedLength == nil, state.bytes.count >= 6 {
            guard state.bytes[0] == 0, state.bytes[1] == 0, state.bytes[2] == 1 else {
                state.clear()
                pesStates[pid] = state
                return completed
            }
            let length = Int(state.bytes[4]) << 8 | Int(state.bytes[5])
            if length > 0 {
                let total = 6 + length
                guard total <= Self.maximumPESBytes else {
                    state.clear()
                    pesStates[pid] = state
                    return completed
                }
                state.expectedLength = total
            }
        }
        if let expected = state.expectedLength, state.bytes.count >= expected {
            completed.append(Array(state.bytes.prefix(expected)))
            state.clear()
        }
        pesStates[pid] = state
        return completed
    }

    private mutating func consumeVideoPrefix(pid: UInt16, payload: [UInt8], startsPacket: Bool) {
        var state = pesStates[pid] ?? PESState()
        if startsPacket { state.clear() }
        guard startsPacket || !state.bytes.isEmpty else {
            pesStates[pid] = state
            return
        }
        guard state.bytes.count < 14 else { return }
        let needed = 14 - state.bytes.count
        state.bytes.append(contentsOf: payload.prefix(needed))
        if state.bytes.count >= 14 {
            observeVideoPTS(from: state.bytes)
            state.clear()
        }
        pesStates[pid] = state
    }

    private mutating func processPES(_ pes: [UInt8], pid: UInt16, output: inout [MPEGTSARIBCaption]) {
        // Keep one append bounded even when a chunk contains many complete
        // metadata PES packets. Transport and clock parsing continues after
        // this point; only newly decoded caption values are dropped.
        guard output.count < 128 else { return }
        guard pes.count >= 6, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return }
        let streamID = pes[3]
        let packetLength = Int(pes[4]) << 8 | Int(pes[5])
        guard packetLength == 0 || packetLength + 6 == pes.count,
              packetLength == 0 || packetLength >= 3 else { return }
        var rawPTS: UInt64?
        let payloadStart: Int
        if streamID == 0xBF {
            // private_stream_2 is emitted by some ARIB producers without the
            // MPEG-2 optional PES header. Its payload begins directly after
            // the six-byte envelope and is timed from the current PCR.
            payloadStart = 6
        } else {
            guard pes.count >= 9, pes[6] & 0xC0 == 0x80 else { return }
            let flags = pes[7]
            let headerLength = Int(pes[8])
            guard packetLength == 0 || headerLength <= packetLength - 3 else { return }
            payloadStart = 9 + headerLength
            guard payloadStart <= pes.count else { return }
            let ptsDTSFlags = (flags >> 6) & 0x03
            if ptsDTSFlags == 2 || ptsDTSFlags == 3 {
                guard payloadStart >= 14,
                      let parsed = parsePTS(pes, at: 9),
                      (ptsDTSFlags == 2 || payloadStart >= 19) else { return }
                rawPTS = parsed
            } else if ptsDTSFlags != 0 {
                return
            }
        }
        let payload = Array(pes[payloadStart..<pes.count])
        guard let metadata = streamDescription.metadata[pid] else {
            if streamDescription.videoPIDs.contains(pid), let rawPTS {
                let ticks = unwrap(rawPTS)
                if firstVideoTicks == nil { firstVideoTicks = ticks }
                if firstClockTicks == nil { firstClockTicks = ticks }
                clockReference = ticks
            }
            return
        }

        var presentationTicks: Int64?
        if let rawPTS {
            presentationTicks = unwrap(rawPTS)
            clockReference = presentationTicks
        } else if metadata.pcrFallback {
            presentationTicks = currentClockTicks
        } else {
            presentationTicks = nil
        }
        guard let presentationTicks else { return }

        var payloads: [Data] = []
        if metadata.timedID3 || metadata.aribPayload || payload.count >= 10 {
            payloads.append(contentsOf: ID3ARIBFrames.payloads(in: payload))
        }
        if metadata.aribPayload || streamID == 0xBD || streamID == 0xBF {
            if isValidARIBPayload(payload) {
                payloads.append(Data(payload))
            }
        }
        for captionPayload in payloads {
            guard output.count < 128 else { return }
            guard isValidARIBPayload(Array(captionPayload)) else { continue }
            output.append(MPEGTSARIBCaption(
                payload: captionPayload,
                presentationTicks: presentationTicks,
                discontinuitySequence: discontinuitySequence
            ))
            if output.count >= 128 { return }
        }
    }

    private mutating func observeVideoPTS(from bytes: [UInt8]?) {
        guard firstVideoTicks == nil, let bytes, bytes.count >= 14,
              bytes[0] == 0, bytes[1] == 0, bytes[2] == 1,
              (Int(bytes[4]) << 8 | Int(bytes[5])) == 0
                  || (Int(bytes[4]) << 8 | Int(bytes[5])) >= 8,
              bytes[6] & 0xC0 == 0x80,
              ((bytes[7] >> 6) & 0x03) == 2 || ((bytes[7] >> 6) & 0x03) == 3,
              bytes[8] >= 5,
              let raw = parsePTS(bytes, at: 9) else { return }
        let ticks = unwrap(raw)
        firstVideoTicks = ticks
        if firstClockTicks == nil { firstClockTicks = ticks }
        clockReference = ticks
    }

    private func parsePCR(_ packet: ArraySlice<UInt8>, at index: Int) -> UInt64? {
        guard index >= 0, index + 6 <= packet.count else { return nil }
        let baseIndex = packet.startIndex + index
        let base = UInt64(packet[baseIndex]) << 25
            | UInt64(packet[baseIndex + 1]) << 17
            | UInt64(packet[baseIndex + 2]) << 9
            | UInt64(packet[baseIndex + 3]) << 1
            | UInt64(packet[baseIndex + 4] >> 7)
        return base & Self.clockMask
    }

    private func parsePTS(_ bytes: [UInt8], at index: Int) -> UInt64? {
        guard index >= 0, index + 5 <= bytes.count else { return nil }
        let first = bytes[index]
        let prefix = first >> 4
        guard prefix == 2 || prefix == 3,
              (first & 1) == 1,
              (bytes[index + 2] & 1) == 1,
              (bytes[index + 4] & 1) == 1 else { return nil }
        let value = (UInt64(first & 0x0E) << 29)
            | (UInt64(bytes[index + 1]) << 22)
            | (UInt64(bytes[index + 2] & 0xFE) << 14)
            | (UInt64(bytes[index + 3]) << 7)
            | UInt64(bytes[index + 4] >> 1)
        return value & Self.clockMask
    }

    private mutating func unwrap(_ raw: UInt64) -> Int64 {
        let value = Int64(raw & Self.clockMask)
        guard let reference = clockReference else { return value }
        let referenceRaw = reference & (Self.clockModulo - 1)
        var delta = value - referenceRaw
        if delta > Self.clockHalf { delta -= Self.clockModulo }
        if delta < -Self.clockHalf { delta += Self.clockModulo }
        return reference + delta
    }

    private mutating func beginDiscontinuity() {
        discontinuitySequence &+= 1
        for key in Array(psiStates.keys) { psiStates[key]?.clear() }
        for key in Array(pesStates.keys) { pesStates[key]?.clear() }
        continuity.removeAll(keepingCapacity: true)
        clockReference = nil
        firstClockTicks = nil
        currentClockTicks = nil
    }

    private mutating func beginProgramChange(resetFirstVideo: Bool) {
        beginDiscontinuity()
        if resetFirstVideo { firstVideoTicks = nil }
        pmtVersion = nil
        streamDescription = StreamDescription()
    }

    private func isVideoStream(_ streamType: UInt8) -> Bool {
        switch streamType {
        case 0x01, 0x02, 0x10, 0x1B, 0x24, 0x80, 0x81:
            return true
        default:
            return false
        }
    }

    private func isARIBComponentTag(_ componentTag: UInt8) -> Bool {
        (0x30...0x3F).contains(componentTag) || componentTag == 0x87 || componentTag == 0x88
    }

    private func isValidARIBPayload(_ payload: [UInt8]) -> Bool {
        guard (3...ARIBCaptionPacket.maximumBytes).contains(payload.count),
              let first = payload.first, first == 0x80 || first == 0x81,
              payload[1] == 0xFF else { return false }
        return true
    }

    private func mpegCRC(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0
                    ? (crc << 1) ^ 0x04C1_1DB7
                    : crc << 1
            }
        }
        return crc
    }
}
