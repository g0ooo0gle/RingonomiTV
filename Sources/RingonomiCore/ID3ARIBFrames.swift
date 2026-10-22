import Foundation

/// The small part of ID3 that is needed by the live ARIB caption path.
///
/// This deliberately does not try to be a general purpose ID3 decoder.  A
/// transport stream is an untrusted, continuously growing input, so the
/// decoder only accepts bounded v2.3/v2.4 tags and PRIV frames whose owner is
/// one of the ARIB caption producers used by KonomiTV.
enum ID3ARIBFrames {
    static let maximumTagBytes = 65_536
    static let allowedOwners: Set<[UInt8]> = [
        Array("aribb24.js".utf8),
        Array("aribb24".utf8),
        Array("B24".utf8)
    ]

    struct Frame: Sendable {
        let payload: Data
    }

    /// Returns every valid ARIB payload in the input.  Invalid tags and
    /// frames are ignored; the caller can continue with the next ID3 tag.
    static func payloads(in input: [UInt8]) -> [Data] {
        guard input.count >= 10 else { return [] }
        var result: [Data] = []
        result.reserveCapacity(2)
        var index = 0

        while index + 10 <= input.count {
            guard let candidate = findTag(in: input, from: index) else { break }
            index = candidate
            let major = input[index + 3]
            guard major == 3 || major == 4,
                  let tagSize = synchsafe(input, at: index + 6),
                  tagSize <= maximumTagBytes - 10,
                  index <= input.count - 10 - tagSize else {
                index += 1
                continue
            }

            let flags = input[index + 5]
            // Unsynchronisation changes frame offsets.  A live caption tag
            // with this flag is uncommon; rejecting it avoids guessing at a
            // potentially attacker-controlled rewrite.
            guard flags & 0x80 == 0 else {
                let skip = 10 + tagSize
                guard skip <= input.count - index else { break }
                index += skip
                continue
            }
            let tagEnd = index + 10 + tagSize
            let frameEnd = tagEnd
            let footerBytes = major == 4 && (flags & 0x10) != 0 ? 10 : 0
            guard footerBytes <= input.count - tagEnd else { break }
            if footerBytes > 0 {
                let footer = Array(input[tagEnd..<(tagEnd + 10)])
                guard footer.prefix(3).elementsEqual([0x33, 0x44, 0x49]),
                      footer.suffix(7).elementsEqual(input[(index + 3)..<(index + 10)]) else {
                    index = tagEnd + footerBytes
                    continue
                }
            }

            var frameIndex = index + 10
            // Extended headers are optional.  Their size representation is
            // version-specific and is skipped before scanning frames.
            if (flags & 0x40) != 0 {
                guard let extended = extendedHeaderLength(input, at: frameIndex, major: major),
                      extended <= frameEnd - frameIndex else {
                    index = tagEnd + footerBytes
                    continue
                }
                frameIndex += extended
            }

            while frameIndex < frameEnd {
                let frameHeaderBytes = major == 3 ? 10 : 10
                guard frameEnd - frameIndex >= frameHeaderBytes else { break }
                if input[frameIndex] == 0 && input[frameIndex + 1] == 0 {
                    break
                }
                let frameID = Array(input[frameIndex..<(frameIndex + 4)])
                guard frameID.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
                    break
                }
                let frameSize: Int?
                if major == 3 {
                    frameSize = bigEndianUInt32(input, at: frameIndex + 4)
                } else {
                    frameSize = synchsafe(input, at: frameIndex + 4)
                }
                guard let frameSize, frameSize <= maximumTagBytes,
                      frameSize <= frameEnd - frameIndex - frameHeaderBytes else {
                    break
                }
                let frameFlags = UInt16(input[frameIndex + 8]) << 8 | UInt16(input[frameIndex + 9])
                let bodyStart = frameIndex + frameHeaderBytes
                let bodyEnd = bodyStart + frameSize
                if frameID == [0x50, 0x52, 0x49, 0x56], frameFlags == 0,
                   let payload = validPrivatePayload(input, start: bodyStart, end: bodyEnd) {
                    result.append(payload)
                    if result.count >= 32 { return result }
                }
                frameIndex = bodyEnd
            }

            // A malformed frame must not make the scanner wander through an
            // unbounded input.  Move to the next tag only when the envelope is
            // complete; otherwise the current metadata packet is discarded.
            guard tagEnd > index else { break }
            index = tagEnd + footerBytes
            if index + 3 > input.count { break }
        }
        return result
    }

    private static func findTag(in bytes: [UInt8], from start: Int) -> Int? {
        guard start >= 0, start <= bytes.count - 3 else { return nil }
        var index = start
        while index <= bytes.count - 3 {
            if bytes[index] == 0x49, bytes[index + 1] == 0x44, bytes[index + 2] == 0x33 {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func synchsafe(_ bytes: [UInt8], at index: Int) -> Int? {
        guard index >= 0, index <= bytes.count - 4 else { return nil }
        let b0 = bytes[index], b1 = bytes[index + 1]
        let b2 = bytes[index + 2], b3 = bytes[index + 3]
        guard (b0 | b1 | b2 | b3) & 0x80 == 0 else { return nil }
        return Int(b0) << 21 | Int(b1) << 14 | Int(b2) << 7 | Int(b3)
    }

    private static func bigEndianUInt32(_ bytes: [UInt8], at index: Int) -> Int? {
        guard index >= 0, index <= bytes.count - 4 else { return nil }
        let value = UInt64(bytes[index]) << 24
            | UInt64(bytes[index + 1]) << 16
            | UInt64(bytes[index + 2]) << 8
            | UInt64(bytes[index + 3])
        guard value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }

    private static func extendedHeaderLength(_ bytes: [UInt8], at index: Int, major: UInt8) -> Int? {
        guard index >= 0, index + 4 <= bytes.count else { return nil }
        if major == 3 {
            guard let length = bigEndianUInt32(bytes, at: index), length >= 6,
                  length <= maximumTagBytes - 4 else { return nil }
            return length + 4
        }
        guard let length = synchsafe(bytes, at: index), length >= 6 else { return nil }
        return length
    }

    private static func validPrivatePayload(_ bytes: [UInt8], start: Int, end: Int) -> Data? {
        guard start >= 0, end >= start, end <= bytes.count else { return nil }
        guard let terminator = bytes[start..<end].firstIndex(of: 0) else { return nil }
        let owner = Array(bytes[start..<terminator])
        guard allowedOwners.contains(owner) else { return nil }
        let payloadStart = terminator + 1
        let payloadCount = end - payloadStart
        guard (3...ARIBCaptionPacket.maximumBytes).contains(payloadCount) else { return nil }
        let payload = Array(bytes[payloadStart..<end])
        guard let first = payload.first, (first == 0x80 || first == 0x81),
              payload.count >= 2, payload[1] == 0xFF else { return nil }
        return Data(payload)
    }
}
