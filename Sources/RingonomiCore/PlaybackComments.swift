import Foundation

/// The position requested by the NicoNico/KonomiTV comment format.
public enum PlaybackCommentPosition: String, Codable, Sendable {
    case right
    case top
    case bottom
}

/// The display size requested by the comment format.
public enum PlaybackCommentSize: String, Codable, Sendable {
    case big
    case medium
    case small
}

/// Validation failures for one playback comment.
public enum PlaybackCommentError: Error, Equatable, Sendable, LocalizedError {
    case invalidTime
    case invalidPosition
    case invalidSize
    case invalidColor
    case emptyText
    case textTooLong
    case tooManyComments

    public var errorDescription: String? {
        switch self {
        case .invalidTime: return "実況コメントの時刻が不正です。"
        case .invalidPosition: return "実況コメントの表示位置が不正です。"
        case .invalidSize: return "実況コメントのサイズが不正です。"
        case .invalidColor: return "実況コメントの色が不正です。"
        case .emptyText: return "実況コメントの本文が空です。"
        case .textTooLong: return "実況コメントの本文が長すぎます。"
        case .tooManyComments: return "実況コメントが多すぎます。"
        }
    }
}

/// One archived or live playback comment after safe normalization.
public struct PlaybackComment: Decodable, Equatable, Sendable {
    public static let maximumTime: Double = 7 * 24 * 60 * 60
    public static let maximumTextLength = 1_024
    public static let maximumTextUTF8Length = 4_096

    public let time: Double
    public let position: PlaybackCommentPosition
    public let size: PlaybackCommentSize
    public let colorRGB: UInt32
    public let text: String

    public init(
        time: Double,
        position: PlaybackCommentPosition,
        size: PlaybackCommentSize,
        colorRGB: UInt32,
        text: String
    ) throws {
        guard time.isFinite, time >= 0, time <= Self.maximumTime else {
            throw PlaybackCommentError.invalidTime
        }
        guard colorRGB <= 0xFF_FF_FF else {
            throw PlaybackCommentError.invalidColor
        }
        guard text.count <= Self.maximumTextLength else {
            throw PlaybackCommentError.textTooLong
        }
        guard text.utf8.count <= Self.maximumTextUTF8Length else {
            throw PlaybackCommentError.textTooLong
        }

        let normalizedText = Self.normalizeText(text)
        guard !normalizedText.isEmpty else {
            throw PlaybackCommentError.emptyText
        }
        guard normalizedText.count <= Self.maximumTextLength else {
            throw PlaybackCommentError.textTooLong
        }
        guard normalizedText.utf8.count <= Self.maximumTextUTF8Length else {
            throw PlaybackCommentError.textTooLong
        }

        self.time = time
        self.position = position
        self.size = size
        self.colorRGB = colorRGB
        self.text = normalizedText
    }

    private enum CodingKeys: String, CodingKey {
        case time
        case type
        case size
        case color
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let time = try container.decode(Double.self, forKey: .time)
        let type = try container.decode(String.self, forKey: .type)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let position = PlaybackCommentPosition(rawValue: type) else {
            throw PlaybackCommentError.invalidPosition
        }

        let sizeValue = try container.decode(String.self, forKey: .size)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let size = PlaybackCommentSize(rawValue: sizeValue) else {
            throw PlaybackCommentError.invalidSize
        }

        let color = try container.decode(String.self, forKey: .color)
        guard let colorRGB = Self.parseColor(color) else {
            throw PlaybackCommentError.invalidColor
        }
        let text = try container.decode(String.self, forKey: .text)
        try self.init(time: time, position: position, size: size, colorRGB: colorRGB, text: text)
    }

    private static func parseColor(_ rawValue: String) -> UInt32? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#" else { return nil }
        let digits = String(value.dropFirst())
        guard digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return UInt32(digits, radix: 16)
    }

    /// Converts all whitespace and control characters to one safe ASCII space.
    /// This prevents a server-provided comment from changing the overlay layout
    /// into multiple lines or embedding terminal/control output.
    private static func normalizeText(_ value: String) -> String {
        var result = String()
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                pendingSpace = true
                continue
            }
            if pendingSpace, !result.isEmpty {
                result.append(" ")
            }
            result.append(contentsOf: String(scalar))
            pendingSpace = false
        }
        return result
    }
}

/// The archived-comment response returned by KonomiTV.
///
/// Invalid individual comments are ignored so one malformed server entry does
/// not remove all useful comments.  The response is rejected if its array is
/// too large; this avoids presenting a partial timeline after an untrusted
/// response has exceeded the work bound.
public struct RecordedCommentsResponse: Decodable, Sendable {
    public static let maximumComments = 100_000
    public static let maximumDetailLength = 4_096

    public let isSuccess: Bool
    public let comments: [PlaybackComment]
    public let detail: String

    private enum CodingKeys: String, CodingKey {
        case isSuccess
        case comments
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSuccess = try container.decode(Bool.self, forKey: .isSuccess)
        var nested = try container.nestedUnkeyedContainer(forKey: .comments)
        if let count = nested.count, count > Self.maximumComments {
            throw PlaybackCommentError.tooManyComments
        }

        var decodedComments: [PlaybackComment] = []
        if let count = nested.count {
            decodedComments.reserveCapacity(min(count, Self.maximumComments))
        }
        var processed = 0
        while !nested.isAtEnd {
            guard processed < Self.maximumComments else {
                throw PlaybackCommentError.tooManyComments
            }
            processed += 1
            // superDecoder advances the unkeyed container even when the
            // individual object fails PlaybackComment validation.
            let itemDecoder = try nested.superDecoder()
            if let comment = try? PlaybackComment(from: itemDecoder) {
                decodedComments.append(comment)
            }
        }
        comments = decodedComments

        let rawDetail = try container.decode(String.self, forKey: .detail)
        detail = String(Self.normalizeDetail(rawDetail).prefix(Self.maximumDetailLength))
    }

    private static func normalizeDetail(_ value: String) -> String {
        var result = String()
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                pendingSpace = true
                continue
            }
            if pendingSpace, !result.isEmpty {
                result.append(" ")
            }
            result.append(contentsOf: String(scalar))
            pendingSpace = false
        }
        return result
    }
}

/// The measured size of one rendered comment.
public struct PlaybackCommentMetric: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width.isFinite && width >= 0 ? width : 0
        self.height = height.isFinite && height >= 0 ? height : 0
    }
}

/// A frame for one comment at a particular playback time.
public struct PlaybackCommentFrame: Identifiable, Equatable, Sendable {
    public let commentIndex: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var id: Int { commentIndex }
}

/// Pure, deterministic positioning for recorded comments.
///
/// Flow comments travel from just outside the right edge to just outside the
/// left edge over eight seconds.  Top and bottom comments stay in a lane for
/// four seconds.  Lane assignment is performed once in start-time order, so a
/// pause, seek, or quality switch never advances any mutable animation state.
public struct RecordedCommentTimeline: Sendable {
    public static let flowDuration: Double = 8
    public static let fixedDuration: Double = 4
    public static let maximumFlowLanes = 16
    public static let maximumFixedLanesPerSide = 4

    private static let laneSpacing: Double = 4
    private static let maximumDimension: Double = 1_000_000

    private enum PlacementKind: Sendable, Equatable {
        case flow
        case fixed
    }

    private struct Placement: Sendable {
        let commentIndex: Int
        let comment: PlaybackComment
        let metric: PlaybackCommentMetric
        let start: Double
        let end: Double
        let y: Double
        let fixedX: Double
        let kind: PlacementKind
    }

    private struct Candidate: Sendable {
        let commentIndex: Int
        let comment: PlaybackComment
        let metric: PlaybackCommentMetric
    }

    private let viewportWidth: Double
    private let placements: [Placement]
    private let startTimes: [Double]

    public init(
        comments: [PlaybackComment],
        metrics: [PlaybackCommentMetric],
        viewportWidth: Double,
        viewportHeight: Double,
        topInset: Double = 140,
        bottomInset: Double = 160
    ) {
        let safeViewportWidth = Self.safeDimension(viewportWidth)
        let safeViewportHeight = Self.safeDimension(viewportHeight)
        let safeTopInset = Self.safeInset(topInset, extent: safeViewportHeight)
        let safeBottomInset = Self.safeInset(bottomInset, extent: safeViewportHeight)
        let contentTop = safeTopInset
        let contentBottom = max(contentTop, safeViewportHeight - safeBottomInset)
        let contentHeight = max(0, contentBottom - contentTop)

        let candidates = comments.enumerated().compactMap { index, comment -> Candidate? in
            guard index < metrics.count else { return nil }
            let metric = metrics[index]
            let width = Self.safeDimension(metric.width)
            let height = Self.safeDimension(metric.height)
            guard width > 0, height > 0 else { return nil }
            return Candidate(
                commentIndex: index,
                comment: comment,
                metric: PlaybackCommentMetric(width: width, height: height)
            )
        }.sorted {
            if $0.comment.time != $1.comment.time {
                return $0.comment.time < $1.comment.time
            }
            return $0.commentIndex < $1.commentIndex
        }

        var result: [Placement] = []
        guard safeViewportWidth > 0, safeViewportHeight > 0, contentHeight > 0 else {
            self.viewportWidth = safeViewportWidth
            self.placements = []
            self.startTimes = []
            return
        }

        let topCandidates = candidates.filter { $0.comment.position == .top }
        let bottomCandidates = candidates.filter { $0.comment.position == .bottom }
        let flowCandidates = candidates.filter { $0.comment.position == .right }
        let fixedHeight = max(
            1,
            (topCandidates + bottomCandidates).map { $0.metric.height }.max() ?? 1
        ) + Self.laneSpacing
        let flowHeight = max(1, flowCandidates.map { $0.metric.height }.max() ?? 1) + Self.laneSpacing
        let availableFixedRows = max(0, Int(floor(contentHeight / fixedHeight)))

        var topLaneCount = 0
        var bottomLaneCount = 0
        if !topCandidates.isEmpty, !bottomCandidates.isEmpty {
            let each = min(Self.maximumFixedLanesPerSide, availableFixedRows / 2)
            if each > 0 {
                topLaneCount = each
                bottomLaneCount = each
            } else if availableFixedRows > 0 {
                // Keep the top side deterministic when the viewport is too
                // short to reserve one row for both sides.
                topLaneCount = 1
            }
        } else if !topCandidates.isEmpty {
            topLaneCount = min(Self.maximumFixedLanesPerSide, availableFixedRows)
        } else if !bottomCandidates.isEmpty {
            bottomLaneCount = min(Self.maximumFixedLanesPerSide, availableFixedRows)
        }

        func addFixed(
            _ source: [Candidate],
            capacity: Int,
            isBottom: Bool
        ) {
            guard capacity > 0 else { return }
            var laneEnd = Array(repeating: -Double.infinity, count: capacity)
            for candidate in source {
                guard let lane = laneEnd.firstIndex(where: { $0 <= candidate.comment.time }) else {
                    continue
                }
                let y = isBottom
                    ? contentBottom - Double(lane + 1) * fixedHeight
                    : contentTop + Double(lane) * fixedHeight
                let width = candidate.metric.width
                let centeredX = (safeViewportWidth - width) / 2
                let x = centeredX.isFinite ? centeredX : 0
                result.append(Placement(
                    commentIndex: candidate.commentIndex,
                    comment: candidate.comment,
                    metric: candidate.metric,
                    start: candidate.comment.time,
                    end: candidate.comment.time + Self.fixedDuration,
                    y: y,
                    fixedX: x,
                    kind: .fixed
                ))
                laneEnd[lane] = candidate.comment.time + Self.fixedDuration
            }
        }

        addFixed(topCandidates, capacity: topLaneCount, isBottom: false)
        addFixed(bottomCandidates, capacity: bottomLaneCount, isBottom: true)

        let flowTop = contentTop + Double(topLaneCount) * fixedHeight
        let flowBottom = max(flowTop, contentBottom - Double(bottomLaneCount) * fixedHeight)
        let flowAreaHeight = max(0, flowBottom - flowTop)
        let flowLaneCount = min(
            Self.maximumFlowLanes,
            max(0, Int(floor(flowAreaHeight / flowHeight)))
        )
        if flowLaneCount > 0 {
            var flowLanes = Array(repeating: [Placement](), count: flowLaneCount)
            for candidate in flowCandidates {
                // Keep only placements whose eight-second animation can still
                // overlap this candidate. Accepted placements remain in the
                // result array, while each lane's collision working set stays
                // bounded instead of growing with the whole recording.
                for lane in flowLanes.indices {
                    flowLanes[lane].removeAll { $0.end <= candidate.comment.time }
                }
                var selectedLane: Int?
                for lane in 0..<flowLaneCount {
                    let overlaps = flowLanes[lane].contains {
                        Self.flowPlacementsCollide(
                            start: candidate.comment.time,
                            width: candidate.metric.width,
                            end: candidate.comment.time + Self.flowDuration,
                            old: $0,
                            viewportWidth: safeViewportWidth
                        )
                    }
                    if !overlaps {
                        selectedLane = lane
                        break
                    }
                }
                guard let lane = selectedLane else { continue }
                let y = flowTop + Double(lane) * flowHeight
                let placement = Placement(
                    commentIndex: candidate.commentIndex,
                    comment: candidate.comment,
                    metric: candidate.metric,
                    start: candidate.comment.time,
                    end: candidate.comment.time + Self.flowDuration,
                    y: y,
                    fixedX: 0,
                    kind: .flow
                )
                flowLanes[lane].append(placement)
                result.append(placement)
            }
        }

        result.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.commentIndex < $1.commentIndex
        }
        self.viewportWidth = safeViewportWidth
        self.placements = result
        self.startTimes = result.map(\.start)
    }

    /// Returns the frames active at the supplied playback time.
    public func visible(at seconds: Double) -> [PlaybackCommentFrame] {
        guard seconds.isFinite, !placements.isEmpty else { return [] }
        let lower = lowerBound(seconds - Self.flowDuration)
        let upper = upperBound(seconds)
        guard lower < upper else { return [] }

        var frames: [PlaybackCommentFrame] = []
        frames.reserveCapacity(upper - lower)
        for placement in placements[lower..<upper] {
            guard seconds >= placement.start, seconds < placement.end else { continue }
            let width = Self.safeDimension(placement.metric.width)
            let height = Self.safeDimension(placement.metric.height)
            guard width > 0, height > 0 else { continue }

            let x: Double
            switch placement.kind {
            case .fixed:
                x = placement.fixedX
            case .flow:
                let progress = min(max((seconds - placement.start) / Self.flowDuration, 0), 1)
                let distance = Self.safeDimension(viewportWidth + width)
                let candidateX = viewportWidth - distance * progress
                x = candidateX.isFinite ? candidateX : 0
            }
            guard x.isFinite, placement.y.isFinite else { continue }
            frames.append(PlaybackCommentFrame(
                commentIndex: placement.commentIndex,
                x: x,
                y: placement.y,
                width: width,
                height: height
            ))
        }
        return frames
    }

    private func lowerBound(_ value: Double) -> Int {
        var low = 0
        var high = startTimes.count
        while low < high {
            let middle = low + (high - low) / 2
            if startTimes[middle] < value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func upperBound(_ value: Double) -> Int {
        var low = 0
        var high = startTimes.count
        while low < high {
            let middle = low + (high - low) / 2
            if startTimes[middle] <= value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func safeDimension(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, maximumDimension)
    }

    private static func safeInset(_ value: Double, extent: Double) -> Double {
        guard value.isFinite, value >= 0 else { return 0 }
        return min(value, extent)
    }

    private static func flowPlacementsCollide(
        start: Double,
        width: Double,
        end: Double,
        old: Placement,
        viewportWidth: Double
    ) -> Bool {
        guard old.kind == .flow else { return false }
        let overlapStart = max(start, old.start)
        let overlapEnd = min(end, old.end)
        guard overlapStart < overlapEnd else { return false }

        let newSlope = -(viewportWidth + width) / flowDuration
        let oldSlope = -(viewportWidth + old.metric.width) / flowDuration
        let newIntercept = viewportWidth - newSlope * start
        let oldIntercept = viewportWidth - oldSlope * old.start
        let slopeDifference = newSlope - oldSlope

        // A < 0 means the new left edge has crossed the old right edge.
        let aConstant = newIntercept - (oldIntercept + old.metric.width) - laneSpacing
        // B > 0 means the new right edge has crossed the old left edge.
        let bConstant = (newIntercept + width) - oldIntercept - laneSpacing

        var points = [overlapStart, overlapEnd]
        func addRoot(constant: Double) {
            guard slopeDifference != 0 else { return }
            let root = -constant / slopeDifference
            if root > overlapStart, root < overlapEnd, root.isFinite {
                points.append(root)
            }
        }
        addRoot(constant: aConstant)
        addRoot(constant: bConstant)
        points.sort()

        for pair in zip(points, points.dropFirst()) {
            let sample = (pair.0 + pair.1) / 2
            let a = slopeDifference * sample + aConstant
            let b = slopeDifference * sample + bConstant
            if a < 0, b > 0 {
                return true
            }
        }
        return false
    }
}
