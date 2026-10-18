import Foundation

/// A playback-relative clock driven by a caller-supplied monotonic timestamp.
/// Buffering and pause intervals do not advance comments across the picture.
public struct LiveCommentClock: Sendable {
    public private(set) var isPlaying = false
    private var elapsed = 0.0
    private var anchor: Double

    public init(now: Double) {
        anchor = now.isFinite && now >= 0 ? now : 0
    }

    public func seconds(at now: Double) -> Double {
        guard isPlaying, now.isFinite, now >= anchor else { return elapsed }
        return min(PlaybackComment.maximumTime, elapsed + (now - anchor))
    }

    public mutating func setPlaying(_ playing: Bool, at now: Double) {
        guard playing != isPlaying else { return }
        elapsed = seconds(at: now)
        if now.isFinite { anchor = max(anchor, now) }
        isPlaying = playing
    }

    public mutating func reset(at now: Double) {
        elapsed = 0
        if now.isFinite, now >= 0 { anchor = now }
    }
}

/// Bounds live display work independently of the duration of a viewing session.
/// A short, separate ID history also suppresses duplicates after reconnecting.
public struct LiveCommentWindow: Sendable {
    public static let maximumComments = 256
    public static let maximumRememberedIDs = 1_024
    public static let retentionSeconds = 12.0
    public static let maximumDelaySeconds = 10.0

    private var entries: [PlaybackComment] = []
    private var seenIDs: Set<String> = []
    private var idOrder: [String] = []

    public init() {}
    public var comments: [PlaybackComment] { entries }

    @discardableResult
    public mutating func append(id: String, comment: PlaybackComment, at now: Double) -> Bool {
        guard now.isFinite, now >= 0, now <= PlaybackComment.maximumTime,
              !id.isEmpty, id.utf8.count <= 256,
              comment.time >= max(0, now - 1),
              comment.time <= now + Self.maximumDelaySeconds,
              !seenIDs.contains(id) else { return false }
        prune(at: now)
        seenIDs.insert(id)
        idOrder.append(id)
        if idOrder.count > Self.maximumRememberedIDs {
            seenIDs.remove(idOrder.removeFirst())
        }
        if entries.count == Self.maximumComments { entries.removeFirst() }
        entries.append(comment)
        return true
    }

    public mutating func prune(at now: Double) {
        guard now.isFinite, now >= 0 else { return }
        entries.removeAll { $0.time + Self.retentionSeconds < now }
    }

    public mutating func removeAll(keepingSeenIDs: Bool = false) {
        entries.removeAll(keepingCapacity: true)
        if !keepingSeenIDs {
            seenIDs.removeAll(keepingCapacity: true)
            idOrder.removeAll(keepingCapacity: true)
        }
    }
}
