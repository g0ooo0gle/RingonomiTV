import Foundation

/// The dimensions available in the recorded-program library.
public enum RecordingGrouping: String, CaseIterable, Sendable {
    case channel
    case genre
    case weekday
    case series
}

/// One visible group in a recording-library navigation dimension.
public struct RecordingGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let count: Int

    public init(id: String, title: String, count: Int) {
        self.id = id
        self.title = title
        self.count = count
    }
}

/// A precomputed, order-preserving index for the recording library.
///
/// Building the index is synchronous so callers can move it to a detached
/// task without sharing mutable state.  The initializer checks cancellation
/// while it walks the input, which keeps a superseded catalog request cheap to
/// abandon.  Group membership is stored as input indexes, so a group lookup
/// never reclassifies or reorders the recordings.
public struct RecordingGroupingIndex: Sendable {
    public let recordings: [Recording]

    private struct Assignment: Sendable {
        let id: String
        let title: String
        let isUnknown: Bool
        let titleIsFallback: Bool
    }

    private struct GroupBuilder: Sendable {
        let id: String
        var title: String
        var isUnknown: Bool
        var titleIsFallback: Bool
        var members: [Int]
    }

    private struct GroupingData: Sendable {
        let groups: [RecordingGroup]
        let memberIndexes: [String: [Int]]
    }

    private let dataByGrouping: [String: GroupingData]

    public init(recordings: [Recording]) throws {
        try Task.checkCancellation()

        var channelBuilders: [String: GroupBuilder] = [:]
        var genreBuilders: [String: GroupBuilder] = [:]
        var weekdayBuilders: [String: GroupBuilder] = [:]
        var seriesBuilders: [String: GroupBuilder] = [:]

        // The two formatters are local to the build.  Keeping Foundation
        // formatter instances out of the Sendable index also avoids sharing
        // their mutable configuration with a later lookup.
        let fractionalISO8601 = ISO8601DateFormatter()
        fractionalISO8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO8601 = ISO8601DateFormatter()
        plainISO8601.formatOptions = [.withInternetDateTime]
        var jstCalendar = Calendar(identifier: .gregorian)
        jstCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")
            ?? TimeZone(secondsFromGMT: 9 * 60 * 60)!

        var fallbackSeriesKeys: [String?] = Array(repeating: nil, count: recordings.count)
        var fallbackSeriesCounts: [String: Int] = [:]

        for (index, recording) in recordings.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard Self.normalizedNonEmpty(recording.seriesTitle) == nil else { continue }
            guard let candidate = Self.fallbackSeriesTitle(recording.title) else { continue }
            fallbackSeriesKeys[index] = candidate
            fallbackSeriesCounts[candidate, default: 0] += 1
        }

        for (index, recording) in recordings.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }

            Self.append(Self.channelAssignment(for: recording), index: index, to: &channelBuilders)

            var genreAssignments = Set<String>()
            if recording.genres.isEmpty {
                let assignment = Assignment(
                    id: "genre:unknown",
                    title: "不明なジャンル",
                    isUnknown: true,
                    titleIsFallback: false
                )
                Self.append(assignment, index: index, to: &genreBuilders)
            } else {
                for genre in recording.genres {
                    try Task.checkCancellation()
                    let major = Self.normalizedNonEmpty(genre.major)
                    let assignment: Assignment
                    if let major {
                        assignment = Assignment(
                            id: "genre:value:\(major)",
                            title: major,
                            isUnknown: false,
                            titleIsFallback: false
                        )
                    } else {
                        assignment = Assignment(
                            id: "genre:unknown",
                            title: "不明なジャンル",
                            isUnknown: true,
                            titleIsFallback: false
                        )
                    }
                    guard genreAssignments.insert(assignment.id).inserted else { continue }
                    Self.append(assignment, index: index, to: &genreBuilders)
                }
            }

            Self.append(Self.weekdayAssignment(for: recording, fractionalISO8601: fractionalISO8601,
                                               plainISO8601: plainISO8601, calendar: jstCalendar),
                        index: index, to: &weekdayBuilders)

            if let explicitSeries = Self.normalizedNonEmpty(recording.seriesTitle) {
                Self.append(Assignment(id: "series:value:\(explicitSeries)", title: explicitSeries,
                                       isUnknown: false, titleIsFallback: false),
                            index: index, to: &seriesBuilders)
            } else if let fallbackSeriesKey = fallbackSeriesKeys[index],
                      fallbackSeriesCounts[fallbackSeriesKey, default: 0] >= 2 {
                Self.append(Assignment(id: "series:value:\(fallbackSeriesKey)", title: fallbackSeriesKey,
                                       isUnknown: false, titleIsFallback: false),
                            index: index, to: &seriesBuilders)
            } else {
                // Single fallback titles are intentionally kept visible in a
                // catch-all bucket.  A grouping view must never make a
                // recording disappear merely because it lacks series data.
                Self.append(Assignment(id: "series:other", title: "単発・その他",
                                       isUnknown: true, titleIsFallback: false),
                            index: index, to: &seriesBuilders)
            }
        }

        self.recordings = recordings
        self.dataByGrouping = [
            RecordingGrouping.channel.rawValue: Self.makeData(from: channelBuilders),
            RecordingGrouping.genre.rawValue: Self.makeData(from: genreBuilders),
            RecordingGrouping.weekday.rawValue: Self.makeData(from: weekdayBuilders),
            RecordingGrouping.series.rawValue: Self.makeData(from: seriesBuilders)
        ]
    }

    /// Returns groups in deterministic Japanese collation order.  Unknown
    /// and catch-all groups are placed after known values.
    public func groups(for grouping: RecordingGrouping) -> [RecordingGroup] {
        dataByGrouping[grouping.rawValue]?.groups ?? []
    }

    /// A nil group means the complete input list in its original order.
    /// Unknown group identifiers deliberately return an empty list.
    public func recordings(for grouping: RecordingGrouping, groupID: String? = nil) -> [Recording] {
        guard let groupID else { return recordings }
        guard let indexes = dataByGrouping[grouping.rawValue]?.memberIndexes[groupID] else {
            return []
        }
        return indexes.map { recordings[$0] }
    }

    private static let unknownChannelAssignment = Assignment(
        id: "channel:unknown", title: "不明なチャンネル", isUnknown: true, titleIsFallback: false
    )

    private static func append(
        _ assignment: Assignment,
        index: Int,
        to builders: inout [String: GroupBuilder]
    ) {
        guard !assignment.id.isEmpty else { return }
        guard builders[assignment.id] != nil else {
            builders[assignment.id] = GroupBuilder(
                id: assignment.id,
                title: assignment.title,
                isUnknown: assignment.isUnknown,
                titleIsFallback: assignment.titleIsFallback,
                members: [index]
            )
            return
        }

        // Mutate the dictionary value through its modify accessor.  Taking a
        // whole GroupBuilder into a local `var` and assigning it back would
        // make Array's copy-on-write buffer look shared on every append,
        // turning a large single group into quadratic work.
        builders[assignment.id]?.members.append(index)
        let existingIsFallback = builders[assignment.id]?.titleIsFallback == true
        if existingIsFallback && !assignment.titleIsFallback {
            builders[assignment.id]?.title = assignment.title
            builders[assignment.id]?.titleIsFallback = false
        } else if existingIsFallback == assignment.titleIsFallback,
                  let existingTitle = builders[assignment.id]?.title,
                  Self.compareJapanese(assignment.title, existingTitle) == .orderedAscending {
            builders[assignment.id]?.title = assignment.title
        }
    }

    private static func makeData(from builders: [String: GroupBuilder]) -> GroupingData {
        let ordered = builders.values.sorted { lhs, rhs in
            if lhs.isUnknown != rhs.isUnknown { return !lhs.isUnknown }
            if let lhsWeekday = Self.weekdayRank(for: lhs.id),
               let rhsWeekday = Self.weekdayRank(for: rhs.id),
               lhsWeekday != rhsWeekday {
                return lhsWeekday < rhsWeekday
            }
            let titleOrder = Self.compareJapanese(lhs.title, rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
        let groups = ordered.map { RecordingGroup(id: $0.id, title: $0.title, count: $0.members.count) }
        let memberIndexes = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.members) })
        return GroupingData(groups: groups, memberIndexes: memberIndexes)
    }

    private static func weekdayRank(for id: String) -> Int? {
        switch id {
        case "weekday:mon": return 0
        case "weekday:tue": return 1
        case "weekday:wed": return 2
        case "weekday:thu": return 3
        case "weekday:fri": return 4
        case "weekday:sat": return 5
        case "weekday:sun": return 6
        default: return nil
        }
    }

    private static func channelAssignment(for recording: Recording) -> Assignment {
        guard let channel = recording.channel else { return unknownChannelAssignment }
        let channelID = Self.normalizedNonEmpty(channel.id)
        let channelName = Self.normalizedNonEmpty(channel.name)
        if let channelID {
            return Assignment(
                id: "channel:id:\(channelID)",
                title: channelName ?? channelID,
                isUnknown: false,
                titleIsFallback: channelName == nil
            )
        }
        if let channelName {
            return Assignment(id: "channel:name:\(channelName)", title: channelName,
                              isUnknown: false, titleIsFallback: false)
        }
        return unknownChannelAssignment
    }

    private static func weekdayAssignment(
        for recording: Recording,
        fractionalISO8601: ISO8601DateFormatter,
        plainISO8601: ISO8601DateFormatter,
        calendar: Calendar
    ) -> Assignment {
        guard let raw = recording.startTime,
              let date = fractionalISO8601.date(from: raw) ?? plainISO8601.date(from: raw) else {
            return Assignment(id: "weekday:unknown", title: "曜日不明", isUnknown: true, titleIsFallback: false)
        }

        let calendarWeekday = calendar.component(.weekday, from: date)
        let value: (id: String, title: String)?
        switch calendarWeekday {
        case 2: value = ("mon", "月曜日")
        case 3: value = ("tue", "火曜日")
        case 4: value = ("wed", "水曜日")
        case 5: value = ("thu", "木曜日")
        case 6: value = ("fri", "金曜日")
        case 7: value = ("sat", "土曜日")
        case 1: value = ("sun", "日曜日")
        default: value = nil
        }
        guard let value else {
            return Assignment(id: "weekday:unknown", title: "曜日不明", isUnknown: true, titleIsFallback: false)
        }
        return Assignment(id: "weekday:\(value.id)", title: value.title,
                          isUnknown: false, titleIsFallback: false)
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizeWhitespace(value.precomposedStringWithCompatibilityMapping)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A bounded subset of the Android TitleNormalizer.  NFKC and explicit
    /// episode markers are useful for grouping, while broad prefix, bracket,
    /// and subtitle removal would merge unrelated programs.  Fallback series
    /// groups are only accepted when at least two records share the result.
    private static func fallbackSeriesTitle(_ title: String) -> String? {
        guard var candidate = Self.normalizedNonEmpty(title) else { return nil }

        // Japanese episode markers may be attached to the title.  English
        // markers require a word-like boundary so titles such as "Step2" and
        // "Section3" are never truncated at the embedded "ep"/"sec".
        let episodePattern = #"(?i)(?:第\s*[0-9０-９一二三四五六七八九十百千万]+\s*(?:話|回|期|シリーズ|シーズン)|[#＃]\s*[0-9０-９]+|(?:^|[\s\(\[\{（［【「『])(?:season|episode|ep|sec)\.?\s*[0-9０-９]+).*"#
        if let range = candidate.range(of: episodePattern, options: .regularExpression) {
            candidate = String(candidate[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return Self.normalizedNonEmpty(candidate)
    }

    private static func compareJapanese(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive], range: nil,
                    locale: Locale(identifier: "ja_JP"))
    }
}
