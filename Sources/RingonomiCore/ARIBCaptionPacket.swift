import Foundation

public enum ARIBCaptionPacketError: Error, Equatable, Sendable {
    case invalidPayload
    case invalidTime
}

/// Validates the private bytes carried by an `aribb24.js` ID3 PRIV item.
/// AVFoundation has already removed the ID3 header and owner string.
public struct ARIBCaptionPacket: Hashable, Sendable {
    public enum Kind: UInt8, Sendable {
        case caption = 0x80
        case superimpose = 0x81
    }

    public static let maximumBytes = 65_536
    public static let maximumSeconds: Double = 7 * 24 * 60 * 60
    public let payload: Data
    public let kind: Kind
    public let milliseconds: Int64

    public init(payload: Data, presentationSeconds: Double) throws {
        guard (3...Self.maximumBytes).contains(payload.count),
              let first = payload.first, let kind = Kind(rawValue: first),
              payload[payload.startIndex + 1] == 0xFF else {
            throw ARIBCaptionPacketError.invalidPayload
        }
        guard let milliseconds = Self.milliseconds(for: presentationSeconds) else {
            throw ARIBCaptionPacketError.invalidTime
        }
        self.payload = payload
        self.kind = kind
        self.milliseconds = milliseconds
    }

    public static func milliseconds(for seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0, seconds <= maximumSeconds else { return nil }
        return Int64((seconds * 1_000).rounded())
    }

    /// Ignore obsolete seek callbacks while allowing normal metadata lookahead.
    public func isNear(playbackSeconds: Double) -> Bool {
        guard let current = Self.milliseconds(for: playbackSeconds) else { return false }
        return milliseconds >= max(0, current - 2_000) && milliseconds <= current + 15_000
    }
}

public struct ARIBCaptionRenderSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            self.width = 1_920
            self.height = 1_080
            return
        }
        let scale = min(1, 1_920 / width, 1_080 / height)
        self.width = max(1, Int(min(1_920, (width * scale).rounded(.down))))
        self.height = max(1, Int(min(1_080, (height * scale).rounded(.down))))
    }
}
