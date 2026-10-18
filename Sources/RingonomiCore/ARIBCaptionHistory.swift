import Foundation

/// Keeps the recently decoded ARIB packets so a seek within the same item can
/// replay metadata that AVFoundation does not deliver a second time.
public struct ARIBCaptionHistory: Sendable {
    public static let maximumPackets = 4_096
    public static let maximumPayloadBytes = 4 * 1024 * 1024

    private var storage: [ARIBCaptionPacket] = []
    private var payloadBytes = 0
    public private(set) var evictedThroughMilliseconds: Int64?

    public init() {
        evictedThroughMilliseconds = nil
    }

    /// Inserts a packet in PTS order.  Equal PTS values keep insertion order;
    /// an identical PTS/payload pair is retained only once.
    public mutating func insert(_ packet: ARIBCaptionPacket) {
        let firstAtPTS = lowerBound(for: packet.milliseconds)
        let endAtPTS = upperBound(for: packet.milliseconds)
        if storage[firstAtPTS..<endAtPTS].contains(where: { $0.payload == packet.payload }) {
            return
        }

        storage.insert(packet, at: endAtPTS)
        payloadBytes += packet.payload.count
        evictOldestIfNeeded()
    }

    /// Reports whether the exact PTS/payload pair is already retained.
    public func contains(_ packet: ARIBCaptionPacket) -> Bool {
        let start = lowerBound(for: packet.milliseconds)
        let end = upperBound(for: packet.milliseconds)
        return storage[start..<end].contains(where: { $0.payload == packet.payload })
    }

    /// Returns every packet whose presentation timestamp is at or before the
    /// supplied timestamp, preserving stable PTS order.
    public func packets(through milliseconds: Int64) -> [ARIBCaptionPacket] {
        Array(storage.prefix(upperBound(for: milliseconds)))
    }

    /// Returns packets strictly after `after` and at or before `through`.
    /// This is the range used to replay only metadata that has not reached a
    /// renderer generation yet.
    public func packets(after milliseconds: Int64, through upperMilliseconds: Int64) -> [ARIBCaptionPacket] {
        guard upperMilliseconds > milliseconds else { return [] }
        let start = upperBound(for: milliseconds)
        let end = upperBound(for: upperMilliseconds)
        guard start < end else { return [] }
        return Array(storage[start..<end])
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        payloadBytes = 0
        evictedThroughMilliseconds = nil
    }

    private mutating func evictOldestIfNeeded() {
        while storage.count > Self.maximumPackets || payloadBytes > Self.maximumPayloadBytes {
            guard let oldest = storage.first else {
                payloadBytes = 0
                return
            }
            if let evictedThroughMilliseconds {
                self.evictedThroughMilliseconds = max(evictedThroughMilliseconds, oldest.milliseconds)
            } else {
                evictedThroughMilliseconds = oldest.milliseconds
            }
            payloadBytes -= oldest.payload.count
            storage.removeFirst()
        }
    }

    private func lowerBound(for milliseconds: Int64) -> Int {
        var lower = 0
        var upper = storage.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if storage[middle].milliseconds < milliseconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func upperBound(for milliseconds: Int64) -> Int {
        var lower = 0
        var upper = storage.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if storage[middle].milliseconds <= milliseconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
