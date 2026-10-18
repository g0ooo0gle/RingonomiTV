import Foundation
import XCTest
@testable import RingonomiCore

final class KeywordSearchFilterTests: XCTestCase {
    private func date(
        startDay: Int = 1,
        startHour: Int = 9,
        startMinute: Int = 5,
        endDay: Int = 1,
        endHour: Int = 10,
        endMinute: Int = 30,
        extra: [String: RawJSONValue] = [:]
    ) -> ProgramSearchDate {
        ProgramSearchDate(
            startDayOfWeek: startDay,
            startHour: startHour,
            startMinute: startMinute,
            endDayOfWeek: endDay,
            endHour: endHour,
            endMinute: endMinute,
            rawValues: extra
        )
    }

    private func condition(
        genres: RawJSONValue? = nil,
        dates: RawJSONValue? = nil,
        excludeGenres: Bool = false,
        excludeDates: Bool = false,
        extra: [String: RawJSONValue] = [:]
    ) -> ProgramSearchCondition {
        var values = extra
        values["genre_ranges"] = genres ?? .null
        values["date_ranges"] = dates ?? .null
        values["is_exclude_genre_ranges"] = .bool(excludeGenres)
        values["is_exclude_date_ranges"] = .bool(excludeDates)
        return ProgramSearchCondition(rawValues: values)
    }

    func testDraftParsesHHMMAndPreservesUnknownFields() throws {
        let original = date(extra: [
            "future_date": .object(["keep": .bool(true)]),
            "start_hour": .integer(9)
        ])
        var draft = KeywordWeeklyTimeDraft(range: original)
        XCTAssertEqual(draft.startDayOfWeek, 1)
        XCTAssertEqual(draft.startTime, "09:05")
        XCTAssertEqual(draft.endTime, "10:30")

        draft.startDayOfWeek = 6
        draft.startTime = " 23:59 "
        draft.endDayOfWeek = 0
        draft.endTime = "00:00"
        let updated = try draft.validated()

        XCTAssertEqual(updated.startDayOfWeek, 6)
        XCTAssertEqual(updated.startHour, 23)
        XCTAssertEqual(updated.startMinute, 59)
        XCTAssertEqual(updated.endDayOfWeek, 0)
        XCTAssertEqual(updated.endHour, 0)
        XCTAssertEqual(updated.endMinute, 0)
        XCTAssertEqual(updated.rawValues["future_date"], .object(["keep": .bool(true)]))
    }

    func testDraftRejectsMalformedTimesAndAcceptsBounds() throws {
        let original = date(startDay: 0, startHour: 0, startMinute: 0, endDay: 6, endHour: 23, endMinute: 59)
        var draft = KeywordWeeklyTimeDraft(range: original)

        draft.startTime = "9:00"
        XCTAssertThrowsError(try draft.validated())
        draft.startTime = "25:00"
        XCTAssertThrowsError(try draft.validated())
        draft.startTime = "23:60"
        XCTAssertThrowsError(try draft.validated())
        draft.startTime = "１２:００"
        XCTAssertThrowsError(try draft.validated())

        draft.startDayOfWeek = 0
        draft.startTime = "00:00"
        draft.endDayOfWeek = 6
        draft.endTime = "23:59"
        XCTAssertNoThrow(try draft.validated())
    }

    func testWeeklyWrapAndSummaryAreSafe() throws {
        let weekly = date(startDay: 5, startHour: 23, startMinute: 59, endDay: 0, endHour: 0, endMinute: 1)
        XCTAssertEqual(KeywordSearchFilters.timeRangeSummary(weekly), "金 23:59〜日 00:01")
        XCTAssertNoThrow(try KeywordSearchFilters.validate(condition(
            genres: .array([.object(["major": .string("ニュース"), "middle": .string("定時")])]),
            dates: .array([.object(weekly.rawValues)])
        )))

        let malformed = ProgramSearchDate(rawValues: [
            "start_day_of_week": .integer(1),
            "start_hour": .string("bad"),
            "start_minute": .integer(0),
            "end_day_of_week": .integer(1),
            "end_hour": .integer(1),
            "end_minute": .integer(0)
        ])
        XCTAssertEqual(KeywordSearchFilters.timeRangeSummary(malformed), "日時情報を確認してください")
    }

    func testExistingEqualBoundaryMeansAllWeekButNewDraftRejectsIt() throws {
        let equal = date(
            startDay: 2,
            startHour: 8,
            startMinute: 30,
            endDay: 2,
            endHour: 8,
            endMinute: 30,
            extra: ["future_date": .object(["keep": .bool(true)])]
        )
        XCTAssertNoThrow(try KeywordSearchFilters.validate(condition(
            dates: .array([.object(equal.rawValues)])
        )))
        XCTAssertEqual(
            KeywordSearchFilters.timeRangeSummary(equal),
            "全曜日・全時刻（開始と終了が同じ）"
        )

        let draft = KeywordWeeklyTimeDraft(range: equal)
        XCTAssertThrowsError(try draft.validated()) { error in
            XCTAssertEqual(error as? KeywordSearchFilterError, .sameStartEnd)
            XCTAssertEqual((error as? KeywordSearchFilterError)?.errorDescription, "開始と終了を変えるか、すべての日時を選択してください")
        }
        let unchanged = try draft.validated(allowUnchangedRange: true)
        XCTAssertEqual(unchanged.rawValues["future_date"], .object(["keep": .bool(true)]))

        var partiallyEdited = KeywordWeeklyTimeDraft(range: equal)
        partiallyEdited.startTime = "08:31"
        partiallyEdited.endTime = "08:31"
        XCTAssertThrowsError(try partiallyEdited.validated(allowUnchangedRange: true)) { error in
            XCTAssertEqual(error as? KeywordSearchFilterError, .sameStartEnd)
        }
    }

    func testValidateRejectsNilOnlyWhenRangeIsNonNilEmpty() throws {
        XCTAssertNoThrow(try KeywordSearchFilters.validate(ProgramSearchCondition()))
        XCTAssertThrowsError(try KeywordSearchFilters.validate(condition(
            genres: .array([]),
            dates: .null
        ))) { error in
            XCTAssertEqual(error as? KeywordSearchFilterError, .emptyGenreRanges)
        }
        XCTAssertThrowsError(try KeywordSearchFilters.validate(condition(
            genres: .null,
            dates: .array([])
        ))) { error in
            XCTAssertEqual(error as? KeywordSearchFilterError, .emptyDateRanges)
        }
    }

    func testValidateRejectsEmptyGenreAndOutOfBoundsDate() throws {
        XCTAssertThrowsError(try KeywordSearchFilters.validate(condition(
            genres: .array([.object(["major": .string(""), "middle": .string("定時")])])
        ))) { error in
            XCTAssertEqual(error as? KeywordSearchFilterError, .invalidGenre(index: 0, field: "大分類"))
        }

        let invalidDate: RawJSONValue = .array([.object([
            "start_day_of_week": .integer(7),
            "start_hour": .integer(0),
            "start_minute": .integer(0),
            "end_day_of_week": .integer(0),
            "end_hour": .integer(0),
            "end_minute": .integer(0)
        ])])
        XCTAssertThrowsError(try KeywordSearchFilters.validate(condition(dates: invalidDate))) { error in
            XCTAssertEqual(error as? KeywordSearchFilterError, .invalidDate(index: 0, field: "開始曜日"))
        }
    }

    func testRawRoundTripKeepsUnknownValuesAndExclusionFlags() throws {
        let original = condition(
            genres: .array([.object([
                "major": .string("ニュース"),
                "middle": .string("定時"),
                "future_genre": .object(["keep": .bool(true)])
            ])]),
            dates: .array([.object([
                "start_day_of_week": .integer(1),
                "start_hour": .integer(12),
                "start_minute": .integer(0),
                "end_day_of_week": .integer(1),
                "end_hour": .integer(12),
                "end_minute": .integer(10),
                "future_date": .array([.string("keep")])
            ])]),
            excludeGenres: true,
            excludeDates: true,
            extra: ["future_condition": .object(["keep": .string("yes")])]
        )

        try KeywordSearchFilters.validate(original)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProgramSearchCondition.self, from: encoded)
        XCTAssertEqual(decoded.rawValues, original.rawValues)
        XCTAssertTrue(decoded.isExcludeGenreRanges)
        XCTAssertTrue(decoded.isExcludeDateRanges)
        XCTAssertEqual(decoded.rawValues["future_condition"], .object(["keep": .string("yes")]))
    }

    func testValidationRejectsWrongNestedTypesInsteadOfGetterDefaults() throws {
        let wrongGenre = condition(genres: .array([.object([
            "major": .integer(1),
            "middle": .string("定時")
        ])]))
        XCTAssertThrowsError(try KeywordSearchFilters.validate(wrongGenre))

        let wrongDate = condition(dates: .array([.object([
            "start_day_of_week": .string("月"),
            "start_hour": .integer(12),
            "start_minute": .integer(0),
            "end_day_of_week": .integer(1),
            "end_hour": .integer(12),
            "end_minute": .integer(10)
        ])]))
        XCTAssertThrowsError(try KeywordSearchFilters.validate(wrongDate))
    }

    func testDraftDoesNotTurnWrongWeekdayTypeIntoSunday() throws {
        let malformed = ProgramSearchDate(rawValues: [
            "start_day_of_week": .string("月"),
            "start_hour": .integer(12),
            "start_minute": .integer(0),
            "end_day_of_week": .integer(1),
            "end_hour": .integer(12),
            "end_minute": .integer(10),
            "future_date": .bool(true)
        ])
        let draft = KeywordWeeklyTimeDraft(range: malformed)
        XCTAssertEqual(draft.startDayOfWeek, -1)
        XCTAssertThrowsError(try draft.validated()) { error in
            XCTAssertEqual(error as? KeywordSearchFilterError, .invalidWeekday("開始曜日"))
        }
        XCTAssertEqual(malformed.rawValues["future_date"], .bool(true))
    }

    func testValidationRejectsMissingRequiredDateField() throws {
        let missingEndMinute: RawJSONValue = .array([.object([
            "start_day_of_week": .integer(1),
            "start_hour": .integer(12),
            "start_minute": .integer(0),
            "end_day_of_week": .integer(1),
            "end_hour": .integer(12)
        ])])
        XCTAssertThrowsError(try KeywordSearchFilters.validate(condition(dates: missingEndMinute))) { error in
            XCTAssertEqual(error as? KeywordSearchFilterError, .invalidDateType(index: 0, field: "終了分"))
        }
    }
}
