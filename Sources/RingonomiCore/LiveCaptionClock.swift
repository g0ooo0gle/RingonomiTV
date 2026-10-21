import Foundation

/// Maps the transport clock of the exact TS input to the player's elapsed time.
/// Large clock jumps are rejected until a new input is opened: a missing
/// caption is preferable to displaying stale text over an unrelated scene.
public struct LiveCaptionClock: Sendable {
    private var origin: Int64?
    private var previousClock: Int64?
    private var sequence: UInt64?
    public private(set) var isSynchronized = true

    public init() {}

    public mutating func observe(firstTicks: Int64?, currentTicks: Int64?, sequence: UInt64) {
        if let previousClock, let currentTicks {
            let (difference, overflow) = currentTicks.subtractingReportingOverflow(previousClock)
            if overflow || difference < -90_000 || difference > 30 * 90_000 {
                isSynchronized = false
            }
        }
        self.sequence = sequence
        if origin == nil { origin = firstTicks }
        if let currentTicks { previousClock = currentTicks }
    }

    public func packet(_ caption: MPEGTSARIBCaption) -> ARIBCaptionPacket? {
        guard isSynchronized, sequence == caption.discontinuitySequence, let origin else { return nil }
        let (ticks, overflow) = caption.presentationTicks.subtractingReportingOverflow(origin)
        guard !overflow, ticks >= 0 else { return nil }
        return try? ARIBCaptionPacket(payload: caption.payload,
                                      presentationSeconds: Double(ticks) / 90_000)
    }
}
