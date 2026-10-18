import Foundation

/// A text-editable weekly time range for the keyword-condition editor.
///
/// The six fields edited by this draft are written back into the original
/// date object's raw dictionary.  Unknown server fields remain untouched.
public struct KeywordWeeklyTimeDraft: Equatable, Sendable {
    public var startDayOfWeek: Int
    public var startTime: String
    public var endDayOfWeek: Int
    public var endTime: String

    private let originalRawValues: [String: RawJSONValue]

    public init(range: ProgramSearchDate) {
        originalRawValues = range.rawValues
        startDayOfWeek = Self.dayValue(
            rawValue: range.rawValues["start_day_of_week"],
            fallback: -1
        )
        startTime = Self.timeString(
            hour: range.startHour,
            minute: range.startMinute,
            rawValues: range.rawValues,
            hourKey: "start_hour",
            minuteKey: "start_minute"
        )
        endDayOfWeek = Self.dayValue(
            rawValue: range.rawValues["end_day_of_week"],
            fallback: -1
        )
        endTime = Self.timeString(
            hour: range.endHour,
            minute: range.endMinute,
            rawValues: range.rawValues,
            hourKey: "end_hour",
            minuteKey: "end_minute"
        )
    }

    /// Validates the edited values and creates a server-compatible date.
    /// Unknown keys from the original range are preserved verbatim.
    public func validated(allowUnchangedRange: Bool = false) throws -> ProgramSearchDate {
        guard (0...6).contains(startDayOfWeek) else {
            throw KeywordSearchFilterError.invalidWeekday("開始曜日")
        }
        guard (0...6).contains(endDayOfWeek) else {
            throw KeywordSearchFilterError.invalidWeekday("終了曜日")
        }
        let start = try Self.parseTime(startTime, field: "開始時刻")
        let end = try Self.parseTime(endTime, field: "終了時刻")
        if startDayOfWeek == endDayOfWeek,
           start.hour == end.hour,
           start.minute == end.minute {
            guard allowUnchangedRange,
                  originalFieldsMatch(
                    startDay: startDayOfWeek,
                    startHour: start.hour,
                    startMinute: start.minute,
                    endDay: endDayOfWeek,
                    endHour: end.hour,
                    endMinute: end.minute
                  ) else {
                throw KeywordSearchFilterError.sameStartEnd
            }
        }

        var values = originalRawValues
        values["start_day_of_week"] = .integer(startDayOfWeek)
        values["start_hour"] = .integer(start.hour)
        values["start_minute"] = .integer(start.minute)
        values["end_day_of_week"] = .integer(endDayOfWeek)
        values["end_hour"] = .integer(end.hour)
        values["end_minute"] = .integer(end.minute)
        return ProgramSearchDate(rawValues: values)
    }

    private func originalFieldsMatch(
        startDay: Int,
        startHour: Int,
        startMinute: Int,
        endDay: Int,
        endHour: Int,
        endMinute: Int
    ) -> Bool {
        guard case .integer(let originalStartDay) = originalRawValues["start_day_of_week"],
              case .integer(let originalStartHour) = originalRawValues["start_hour"],
              case .integer(let originalStartMinute) = originalRawValues["start_minute"],
              case .integer(let originalEndDay) = originalRawValues["end_day_of_week"],
              case .integer(let originalEndHour) = originalRawValues["end_hour"],
              case .integer(let originalEndMinute) = originalRawValues["end_minute"] else {
            return false
        }
        return originalStartDay == startDay
            && originalStartHour == startHour
            && originalStartMinute == startMinute
            && originalEndDay == endDay
            && originalEndHour == endHour
            && originalEndMinute == endMinute
    }

    private static func timeString(
        hour: Int,
        minute: Int,
        rawValues: [String: RawJSONValue],
        hourKey: String,
        minuteKey: String
    ) -> String {
        guard case .integer(let rawHour) = rawValues[hourKey],
              case .integer(let rawMinute) = rawValues[minuteKey],
              rawHour == hour,
              rawMinute == minute,
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            // An invalid server value must remain visible to validation,
            // rather than silently becoming 00:00 through a getter default.
            return ""
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func dayValue(rawValue: RawJSONValue?, fallback: Int) -> Int {
        guard case .integer(let value) = rawValue else { return fallback }
        return value
    }

    private static func parseTime(_ value: String, field: String) throws -> (hour: Int, minute: Int) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(trimmed.utf8)
        guard bytes.count == 5,
              bytes[2] == 58,
              bytes[0].isASCIIDigit,
              bytes[1].isASCIIDigit,
              bytes[3].isASCIIDigit,
              bytes[4].isASCIIDigit else {
            throw KeywordSearchFilterError.invalidTime(field)
        }
        let hour = Int(bytes[0] - 48) * 10 + Int(bytes[1] - 48)
        let minute = Int(bytes[3] - 48) * 10 + Int(bytes[4] - 48)
        guard hour <= 23 else { throw KeywordSearchFilterError.invalidHour(field) }
        guard minute <= 59 else { throw KeywordSearchFilterError.invalidMinute(field) }
        return (hour, minute)
    }
}

public enum KeywordSearchFilterError: Error, LocalizedError, Equatable, Sendable {
    case emptyGenreRanges
    case emptyDateRanges
    case invalidGenre(index: Int, field: String)
    case invalidDate(index: Int, field: String)
    case invalidDateType(index: Int, field: String)
    case invalidWeekday(String)
    case invalidTime(String)
    case invalidHour(String)
    case invalidMinute(String)
    case sameStartEnd

    public var errorDescription: String? {
        switch self {
        case .emptyGenreRanges:
            return "ジャンル範囲を1件以上指定してください。"
        case .emptyDateRanges:
            return "日時範囲を1件以上指定してください。"
        case let .invalidGenre(index, field):
            return "ジャンル範囲\(index + 1)の\(field)を確認してください。"
        case let .invalidDate(index, field):
            return "日時範囲\(index + 1)の\(field)を確認してください。"
        case let .invalidDateType(index, field):
            return "日時範囲\(index + 1)の\(field)形式を確認してください。"
        case let .invalidWeekday(field):
            return "\(field)は日曜から土曜の範囲で指定してください。"
        case let .invalidTime(field):
            return "\(field)はHH:mm形式で指定してください。"
        case let .invalidHour(field):
            return "\(field)の時は00から23で指定してください。"
        case let .invalidMinute(field):
            return "\(field)の分は00から59で指定してください。"
        case .sameStartEnd:
            return "開始と終了を変えるか、すべての日時を選択してください"
        }
    }
}

public enum KeywordSearchFilters {
    private static let weekdayNames = ["日", "月", "火", "水", "木", "金", "土"]

    /// Validates editable genre and weekly-date ranges without changing the
    /// condition. Inclusion/exclusion flags and unknown fields are untouched.
    public static func validate(_ condition: ProgramSearchCondition) throws {
        try validateGenres(condition.rawValues["genre_ranges"])
        try validateDates(condition.rawValues["date_ranges"])
    }

    /// Formats a weekly range for display. Invalid server data is represented
    /// safely instead of being force-unwrapped or displayed as 00:00.
    public static func timeRangeSummary(_ range: ProgramSearchDate) -> String {
        guard let start = validDateValues(range.rawValues, prefix: "start_"),
              let end = validDateValues(range.rawValues, prefix: "end_"),
              let startDay = weekdayNames[safe: start.day],
              let endDay = weekdayNames[safe: end.day] else {
            return "日時情報を確認してください"
        }
        if start.day == end.day, start.hour == end.hour, start.minute == end.minute {
            return "全曜日・全時刻（開始と終了が同じ）"
        }
        return "\(startDay) \(String(format: "%02d:%02d", start.hour, start.minute))〜\(endDay) \(String(format: "%02d:%02d", end.hour, end.minute))"
    }

    private static func validateGenres(_ value: RawJSONValue?) throws {
        guard let value else { return }
        guard case .array(let ranges) = value else {
            if case .null = value { return }
            throw KeywordSearchFilterError.invalidGenre(index: 0, field: "形式")
        }
        guard !ranges.isEmpty else { throw KeywordSearchFilterError.emptyGenreRanges }
        for (index, value) in ranges.enumerated() {
            guard case .object(let object) = value else {
                throw KeywordSearchFilterError.invalidGenre(index: index, field: "形式")
            }
            guard case .string(let major) = object["major"], !major.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KeywordSearchFilterError.invalidGenre(index: index, field: "大分類")
            }
            guard case .string(let middle) = object["middle"], !middle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KeywordSearchFilterError.invalidGenre(index: index, field: "中分類")
            }
        }
    }

    private static func validateDates(_ value: RawJSONValue?) throws {
        guard let value else { return }
        guard case .array(let ranges) = value else {
            if case .null = value { return }
            throw KeywordSearchFilterError.invalidDate(index: 0, field: "形式")
        }
        guard !ranges.isEmpty else { throw KeywordSearchFilterError.emptyDateRanges }
        for (index, value) in ranges.enumerated() {
            guard case .object(let object) = value else {
                throw KeywordSearchFilterError.invalidDate(index: index, field: "形式")
            }
            try validateDateObject(object, index: index)
        }
    }

    private static func validateDateObject(_ object: [String: RawJSONValue], index: Int) throws {
        let fields: [(String, String, ClosedRange<Int>)] = [
            ("start_day_of_week", "開始曜日", 0...6),
            ("start_hour", "開始時", 0...23),
            ("start_minute", "開始分", 0...59),
            ("end_day_of_week", "終了曜日", 0...6),
            ("end_hour", "終了時", 0...23),
            ("end_minute", "終了分", 0...59)
        ]
        for (key, label, bounds) in fields {
            guard let value = object[key] else {
                throw KeywordSearchFilterError.invalidDateType(index: index, field: label)
            }
            guard case .integer(let integer) = value else {
                throw KeywordSearchFilterError.invalidDateType(index: index, field: label)
            }
            guard bounds.contains(integer) else {
                throw KeywordSearchFilterError.invalidDate(index: index, field: label)
            }
        }
    }

    private static func validDateValues(
        _ rawValues: [String: RawJSONValue],
        prefix: String
    ) -> (day: Int, hour: Int, minute: Int)? {
        guard case .integer(let day) = rawValues["\(prefix)day_of_week"],
              case .integer(let hour) = rawValues["\(prefix)hour"],
              case .integer(let minute) = rawValues["\(prefix)minute"],
              (0...6).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute) else { return nil }
        return (day, hour, minute)
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= 48 && self <= 57 }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
