import Foundation

/// A server-generated commercial interval in a recorded program.
///
/// Both values are seconds from the beginning of the recorded video.  The
/// server may omit the list when analysis has not completed yet; callers
/// should use ``RecordingChapterTimeline`` only when the duration is known.
public struct CommercialSection: Decodable, Sendable, Equatable {
    public let startTime: Double
    public let endTime: Double

    public init(startTime: Double, endTime: Double) {
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// One seekable interval in a recording.
public struct RecordingChapter: Identifiable, Sendable, Equatable {
    /// The stable index in the deterministic boundary list.
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    public let isCommercial: Bool

    public var duration: Double { endTime - startTime }

    fileprivate init(id: Int, startTime: Double, endTime: Double, isCommercial: Bool) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.isCommercial = isCommercial
    }
}

/// Pure chapter and commercial-boundary navigation for a recorded video.
///
/// `cm_sections` is analysis metadata and can be absent or partially
/// malformed.  The initializer filters unsafe intervals, clips an interval
/// that extends past the known duration, and merges overlaps or gaps of up to
/// one second.  The player remains responsible for its final seek-to-EOF
/// clamp.
public struct RecordingChapterTimeline: Sendable, Equatable {
    /// Maximum number of server CM entries accepted by the pure timeline.
    /// This bounds both decode work and the amount of metadata used for seeks.
    public static let maximumSections = 512

    public let duration: Double
    public let commercialSections: [CommercialSection]
    public let chapters: [RecordingChapter]
    /// True when the response carried at least one CM entry, even if the
    /// entries were unusable after validation.
    public let hasCommercialSections: Bool
    /// True only when there is an internal boundary usable for chapter jumps.
    public let hasChapterBoundaries: Bool

    private let boundaries: [Double]

    /// Returns nil when the supplied duration is not a positive finite value.
    public init?(duration: Double, sections: [CommercialSection]) {
        guard duration.isFinite,
              duration > 0,
              sections.count <= Self.maximumSections else { return nil }

        let normalized = Self.normalize(sections, duration: duration)
        var rawBoundaries = [0, duration]
        for section in normalized {
            rawBoundaries.append(section.startTime)
            rawBoundaries.append(section.endTime)
        }
        let boundaries = Self.uniqueSorted(rawBoundaries)

        var chapters: [RecordingChapter] = []
        for pair in zip(boundaries, boundaries.dropFirst()) {
            let start = pair.0
            let end = pair.1
            guard end > start else { continue }
            let midpoint = start + ((end - start) / 2)
            let isCommercial = normalized.contains {
                midpoint >= $0.startTime && midpoint < $0.endTime
            }
            chapters.append(RecordingChapter(
                id: chapters.count,
                startTime: start,
                endTime: end,
                isCommercial: isCommercial
            ))
        }

        self.duration = duration
        self.commercialSections = normalized
        self.chapters = chapters
        self.hasCommercialSections = !sections.isEmpty
        self.boundaries = boundaries
        // A section covering the entire video has no internal seek boundary,
        // so it should use the normal long-seek fallback.
        self.hasChapterBoundaries = boundaries.count > 2
    }

    /// Seeks to the previous analysis boundary, or 60 seconds backwards when
    /// no internal commercial boundary exists.
    public func previous(from seconds: Double) -> Double {
        let current = clampedPosition(seconds)
        guard hasChapterBoundaries else {
            return max(0, current - 60)
        }

        let threshold = current - 1
        return boundaries.reversed().first(where: { $0 < threshold }) ?? 0
    }

    /// Seeks to the next analysis boundary, or 180 seconds forwards when no
    /// internal commercial boundary exists.  The result may equal `duration`;
    /// the playback controller must clamp an actual seek away from EOF.
    public func next(from seconds: Double) -> Double {
        let current = clampedPosition(seconds)
        guard hasChapterBoundaries else {
            return min(duration, current + 180)
        }

        let threshold = current + 1
        return boundaries.first(where: { $0 > threshold && $0 <= duration }) ?? duration
    }

    private func clampedPosition(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(0, seconds), duration)
    }

    private static func normalize(
        _ sections: [CommercialSection],
        duration: Double
    ) -> [CommercialSection] {
        let clipped = sections.compactMap { section -> CommercialSection? in
            // Negative/reversed/non-finite values are unsafe metadata.  A
            // section extending beyond the known end is safe to clip.
            guard section.startTime.isFinite,
                  section.endTime.isFinite,
                  section.startTime >= 0,
                  section.endTime > section.startTime,
                  section.startTime < duration else {
                return nil
            }

            let end = min(section.endTime, duration)
            guard end > section.startTime else { return nil }
            return CommercialSection(startTime: section.startTime, endTime: end)
        }
        .sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.endTime < $1.endTime
        }

        var merged: [CommercialSection] = []
        for section in clipped {
            guard let previous = merged.last else {
                merged.append(section)
                continue
            }

            if section.startTime <= previous.endTime + 1 {
                merged[merged.count - 1] = CommercialSection(
                    startTime: previous.startTime,
                    endTime: max(previous.endTime, section.endTime)
                )
            } else {
                merged.append(section)
            }
        }
        return merged
    }

    private static func uniqueSorted(_ values: [Double]) -> [Double] {
        let epsilon = 0.000000001
        return values.sorted().reduce(into: [Double]()) { result, value in
            guard value.isFinite else { return }
            if let previous = result.last, abs(previous - value) <= epsilon {
                return
            }
            result.append(value)
        }
    }
}
