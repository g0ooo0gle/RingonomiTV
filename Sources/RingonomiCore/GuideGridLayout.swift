import Foundation

/// A position in the 24-hour television-day grid.
public struct GuideGridFocus: Sendable, Equatable {
    public var column: Int
    public var minute: Double

    public init(column: Int = 0, minute: Double = 0) {
        self.column = column
        self.minute = minute
    }
}

public enum GuideGridDirection: Sendable, Equatable {
    case left, right, up, down
}

/// A program positioned relative to the 04:00 television-day boundary.
public struct GuideGridEntry: Identifiable, Sendable, Equatable {
    public let program: GuideProgram
    public let startMinute: Double
    public let endMinute: Double
    public let id: String

    public init(program: GuideProgram, startMinute: Double, endMinute: Double, id: String? = nil) {
        self.program = program
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.id = id ?? program.id
    }
}

public struct GuideGridColumn: Identifiable, Sendable, Equatable {
    public let channel: GuideChannel
    public var entries: [GuideGridEntry]
    public let id: String

    public init(channel: GuideChannel, entries: [GuideGridEntry] = [], id: String? = nil) {
        self.channel = channel
        self.entries = entries
        self.id = id ?? (channel.id.isEmpty ? channel.displayChannelId : channel.id)
    }
}

/// Pure layout and focus navigation for the TV-style EPG.
///
/// The server's timetable is grouped by channel, while the tvOS grid uses a
/// Japanese television day beginning at 04:00. This type performs all date
/// conversion once and leaves SwiftUI/UIKit with simple coordinates to draw.
public struct GuideGridLayout: Sendable, Equatable {
    public static let dayMinutes = 24.0 * 60.0

    public let baseDate: Date
    public let columns: [GuideGridColumn]

    public init(response: ProgramGuideResponse, baseDate: Date, includeSubchannels: Bool = true) {
        let dayStart = Self.televisionDay(containing: baseDate)
        self.baseDate = dayStart

        var builtColumns: [GuideGridColumn] = []
        var columnIndexes: [String: Int] = [:]
        var seenPrograms: [String: Set<String>] = [:]

        // flattenedChannels includes one-seg/subchannels and preserves API order.
        for wrapper in response.flattenedChannels {
            if !includeSubchannels && wrapper.channel.isSubchannel { continue }
            let channelID = wrapper.channel.id.isEmpty ? wrapper.channel.displayChannelId : wrapper.channel.id
            guard !channelID.isEmpty else { continue }

            let columnIndex: Int
            if let existing = columnIndexes[channelID] {
                columnIndex = existing
            } else {
                columnIndex = builtColumns.count
                columnIndexes[channelID] = columnIndex
                builtColumns.append(GuideGridColumn(channel: wrapper.channel, entries: [], id: channelID))
                seenPrograms[channelID] = []
            }

            for program in wrapper.programs {
                guard !program.id.isEmpty,
                      let start = program.startDate,
                      let end = program.endDate,
                      end > start else { continue }

                guard seenPrograms[channelID, default: []].insert(program.id).inserted else { continue }

                let rawStart = start.timeIntervalSince(dayStart) / 60.0
                let rawEnd = end.timeIntervalSince(dayStart) / 60.0
                let startMinute = min(Self.dayMinutes, max(0, rawStart))
                let endMinute = min(Self.dayMinutes, max(0, rawEnd))
                guard endMinute > startMinute else { continue }

                builtColumns[columnIndex].entries.append(
                    GuideGridEntry(program: program, startMinute: startMinute, endMinute: endMinute)
                )
            }
        }

        for index in builtColumns.indices {
            builtColumns[index].entries.sort {
                if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
                if $0.endMinute != $1.endMinute { return $0.endMinute < $1.endMinute }
                return $0.id < $1.id
            }
        }
        // 同時放送だけの副チャンネルは、その日の番組があるときだけ独立列にする。
        self.columns = builtColumns.filter { !$0.channel.isSubchannel || !$0.entries.isEmpty }
    }

    /// Returns the entry under a focus position. If the position is in a gap,
    /// the next entry is preferred; after the final entry, the previous one is
    /// returned. This makes a sparse grid reliable with D-pad focus movement.
    public func focusedEntry(_ focus: GuideGridFocus) -> GuideGridEntry? {
        guard !columns.isEmpty else { return nil }
        let column = columns[clampedColumn(focus.column)]
        guard !column.entries.isEmpty else { return nil }
        let minute = Self.clampedMinute(focus.minute)

        if let active = column.entries.first(where: { minute >= $0.startMinute && minute < $0.endMinute }) {
            return active
        }
        if let next = column.entries.first(where: { $0.startMinute >= minute }) {
            return next
        }
        return column.entries.last
    }

    /// Moves focus while keeping the minute during horizontal navigation.
    /// Vertical navigation targets the previous/next program in the same
    /// column. Empty columns use a 30-minute step, and every result is safely
    /// clamped to the available grid bounds.
    public func move(_ focus: GuideGridFocus, direction: GuideGridDirection) -> GuideGridFocus {
        guard !columns.isEmpty else { return GuideGridFocus(column: 0, minute: Self.clampedMinute(focus.minute)) }
        let columnIndex = clampedColumn(focus.column)
        let minute = Self.clampedMinute(focus.minute)

        switch direction {
        case .left:
            return GuideGridFocus(column: max(0, columnIndex - 1), minute: minute)
        case .right:
            return GuideGridFocus(column: min(columns.count - 1, columnIndex + 1), minute: minute)
        case .up, .down:
            let entries = columns[columnIndex].entries
            guard !entries.isEmpty else {
                let delta = direction == .up ? -30.0 : 30.0
                return GuideGridFocus(column: columnIndex, minute: Self.clampedMinute(minute + delta))
            }

            let currentIndex = entryIndex(for: minute, in: entries)
            if direction == .up {
                let target = currentIndex > 0 ? entries[currentIndex - 1].startMinute : 0
                return GuideGridFocus(column: columnIndex, minute: Self.clampedMinute(target))
            }

            let target = currentIndex + 1 < entries.count ? entries[currentIndex + 1].startMinute : Self.dayMinutes
            return GuideGridFocus(column: columnIndex, minute: Self.clampedMinute(target))
        }
    }

    /// Returns the television date at 04:00 JST which contains `date`.
    /// `offset` is applied in local Japanese calendar days, so callers can
    /// request adjacent guide pages without doing UTC arithmetic themselves.
    public static func televisionDay(containing date: Date, offset: Int = 0) -> Date {
        let calendar = japaneseCalendar()
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return date
        }

        var dayStartComponents = DateComponents()
        dayStartComponents.calendar = calendar
        dayStartComponents.timeZone = calendar.timeZone
        dayStartComponents.year = year
        dayStartComponents.month = month
        dayStartComponents.day = day
        dayStartComponents.hour = 4
        dayStartComponents.minute = 0
        dayStartComponents.second = 0
        dayStartComponents.nanosecond = 0

        guard var dayStart = calendar.date(from: dayStartComponents) else { return date }
        if (components.hour ?? 0) < 4 {
            dayStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        }
        return calendar.date(byAdding: .day, value: offset, to: dayStart) ?? dayStart
    }

    private func clampedColumn(_ value: Int) -> Int {
        guard !columns.isEmpty else { return 0 }
        return min(columns.count - 1, max(0, value))
    }

    private func entryIndex(for minute: Double, in entries: [GuideGridEntry]) -> Int {
        if let active = entries.firstIndex(where: { minute >= $0.startMinute && minute < $0.endMinute }) {
            return active
        }
        if let next = entries.firstIndex(where: { $0.startMinute >= minute }) {
            return next
        }
        return entries.count - 1
    }

    private static func clampedMinute(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(dayMinutes, max(0, value))
    }

    private static func japaneseCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        return calendar
    }
}
