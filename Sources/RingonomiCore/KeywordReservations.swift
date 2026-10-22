import Foundation

// MARK: - Keyword reservation search condition

/// A service range used by keyword automatic reservations.
///
/// `rawValues` keeps fields introduced by a newer server so that editing an
/// existing condition does not silently remove them.
public struct ProgramSearchConditionService: Codable, Sendable, Equatable {
    public private(set) var rawValues: [String: RawJSONValue]

    public init(
        networkId: Int = 0,
        transportStreamId: Int = 0,
        serviceId: Int = 0,
        rawValues: [String: RawJSONValue] = [:]
    ) {
        var values: [String: RawJSONValue] = [
            "network_id": .integer(networkId),
            "transport_stream_id": .integer(transportStreamId),
            "service_id": .integer(serviceId)
        ]
        for (key, value) in rawValues { values[key] = value }
        self.rawValues = values
    }

    public init(
        networkID: Int,
        transportStreamID: Int,
        serviceID: Int,
        rawValues: [String: RawJSONValue] = [:]
    ) {
        self.init(
            networkId: networkID,
            transportStreamId: transportStreamID,
            serviceId: serviceID,
            rawValues: rawValues
        )
    }

    init(rawValues: [String: RawJSONValue]) {
        self.init(rawValues: rawValues, mergingDefaults: true)
    }

    private init(rawValues: [String: RawJSONValue], mergingDefaults: Bool) {
        if mergingDefaults {
            var values: [String: RawJSONValue] = [
                "network_id": .integer(0),
                "transport_stream_id": .integer(0),
                "service_id": .integer(0)
            ]
            for (key, value) in rawValues { values[key] = value }
            self.rawValues = values
        } else {
            self.rawValues = rawValues
        }
    }

    public var networkId: Int {
        get { rawValues["network_id"]?.keywordIntValue ?? 0 }
        set { rawValues["network_id"] = .integer(newValue) }
    }

    public var transportStreamId: Int {
        get { rawValues["transport_stream_id"]?.keywordIntValue ?? 0 }
        set { rawValues["transport_stream_id"] = .integer(newValue) }
    }

    public var serviceId: Int {
        get { rawValues["service_id"]?.keywordIntValue ?? 0 }
        set { rawValues["service_id"] = .integer(newValue) }
    }

    // Uppercase-ID aliases match the terminology used by the channel picker.
    public var networkID: Int {
        get { networkId }
        set { networkId = newValue }
    }

    public var transportStreamID: Int {
        get { transportStreamId }
        set { transportStreamId = newValue }
    }

    public var serviceID: Int {
        get { serviceId }
        set { serviceId = newValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValues: try container.decode([String: RawJSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValues)
    }
}

/// A genre range used by keyword automatic reservations.
public struct ProgramSearchConditionGenre: Codable, Sendable, Equatable {
    public private(set) var rawValues: [String: RawJSONValue]

    public init(
        major: String = "",
        middle: String = "",
        rawValues: [String: RawJSONValue] = [:]
    ) {
        var values: [String: RawJSONValue] = [
            "major": .string(major),
            "middle": .string(middle)
        ]
        for (key, value) in rawValues { values[key] = value }
        self.rawValues = values
    }

    init(rawValues: [String: RawJSONValue]) {
        self.init(rawValues: rawValues, mergingDefaults: true)
    }

    private init(rawValues: [String: RawJSONValue], mergingDefaults: Bool) {
        if mergingDefaults {
            var values: [String: RawJSONValue] = [
                "major": .string(""),
                "middle": .string("")
            ]
            for (key, value) in rawValues { values[key] = value }
            self.rawValues = values
        } else {
            self.rawValues = rawValues
        }
    }

    public var major: String {
        get { rawValues["major"]?.keywordStringValue ?? "" }
        set { rawValues["major"] = .string(newValue) }
    }

    public var middle: String {
        get { rawValues["middle"]?.keywordStringValue ?? "" }
        set { rawValues["middle"] = .string(newValue) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValues: try container.decode([String: RawJSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValues)
    }
}

/// A weekly time range used by keyword automatic reservations.
public struct ProgramSearchConditionDate: Codable, Sendable, Equatable {
    public private(set) var rawValues: [String: RawJSONValue]

    public init(
        startDayOfWeek: Int = 0,
        startHour: Int = 0,
        startMinute: Int = 0,
        endDayOfWeek: Int = 0,
        endHour: Int = 0,
        endMinute: Int = 0,
        rawValues: [String: RawJSONValue] = [:]
    ) {
        var values: [String: RawJSONValue] = [
            "start_day_of_week": .integer(startDayOfWeek),
            "start_hour": .integer(startHour),
            "start_minute": .integer(startMinute),
            "end_day_of_week": .integer(endDayOfWeek),
            "end_hour": .integer(endHour),
            "end_minute": .integer(endMinute)
        ]
        for (key, value) in rawValues { values[key] = value }
        self.rawValues = values
    }

    init(rawValues: [String: RawJSONValue]) {
        self.init(rawValues: rawValues, mergingDefaults: true)
    }

    private init(rawValues: [String: RawJSONValue], mergingDefaults: Bool) {
        if mergingDefaults {
            var values: [String: RawJSONValue] = [
                "start_day_of_week": .integer(0),
                "start_hour": .integer(0),
                "start_minute": .integer(0),
                "end_day_of_week": .integer(0),
                "end_hour": .integer(0),
                "end_minute": .integer(0)
            ]
            for (key, value) in rawValues { values[key] = value }
            self.rawValues = values
        } else {
            self.rawValues = rawValues
        }
    }

    public var startDayOfWeek: Int {
        get { rawValues["start_day_of_week"]?.keywordIntValue ?? 0 }
        set { rawValues["start_day_of_week"] = .integer(newValue) }
    }

    public var startHour: Int {
        get { rawValues["start_hour"]?.keywordIntValue ?? 0 }
        set { rawValues["start_hour"] = .integer(newValue) }
    }

    public var startMinute: Int {
        get { rawValues["start_minute"]?.keywordIntValue ?? 0 }
        set { rawValues["start_minute"] = .integer(newValue) }
    }

    public var endDayOfWeek: Int {
        get { rawValues["end_day_of_week"]?.keywordIntValue ?? 0 }
        set { rawValues["end_day_of_week"] = .integer(newValue) }
    }

    public var endHour: Int {
        get { rawValues["end_hour"]?.keywordIntValue ?? 0 }
        set { rawValues["end_hour"] = .integer(newValue) }
    }

    public var endMinute: Int {
        get { rawValues["end_minute"]?.keywordIntValue ?? 0 }
        set { rawValues["end_minute"] = .integer(newValue) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValues: try container.decode([String: RawJSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValues)
    }
}

/// Short names convenient for UI code that builds service/genre/date ranges.
public typealias ProgramSearchService = ProgramSearchConditionService
public typealias ProgramSearchGenre = ProgramSearchConditionGenre
public typealias ProgramSearchDate = ProgramSearchConditionDate

/// Search criteria for one keyword automatic reservation condition.
///
/// The server currently accepts more fields than this client needs to edit.
/// All fields, including unknown nested service/genre/date values, remain in
/// `rawValues` and round-trip through Codable unchanged until a corresponding
/// typed property is edited.
public struct ProgramSearchCondition: Codable, Sendable, Equatable {
    public private(set) var rawValues: [String: RawJSONValue]

    public init(rawValues: [String: RawJSONValue] = [:]) {
        var values: [String: RawJSONValue] = [
            "is_enabled": .bool(true),
            "keyword": .string(""),
            "exclude_keyword": .string(""),
            "note": .string(""),
            "is_title_only": .bool(false),
            "is_case_sensitive": .bool(false),
            "is_fuzzy_search_enabled": .bool(false),
            "is_regex_search_enabled": .bool(false),
            "service_ranges": .null,
            "genre_ranges": .null,
            "is_exclude_genre_ranges": .bool(false),
            "date_ranges": .null,
            "is_exclude_date_ranges": .bool(false),
            "duration_range_min": .null,
            "duration_range_max": .null,
            // New rules start with free broadcasts unless the scope is edited.
            "broadcast_type": .string("FreeOnly"),
            "duplicate_title_check_scope": .string("None"),
            "duplicate_title_check_period_days": .integer(6)
        ]
        for (key, value) in rawValues { values[key] = value }
        self.rawValues = values
    }

    public var isEnabled: Bool {
        get { rawValues["is_enabled"]?.keywordBoolValue ?? true }
        set { rawValues["is_enabled"] = .bool(newValue) }
    }

    public var keyword: String {
        get { rawValues["keyword"]?.keywordStringValue ?? "" }
        set { rawValues["keyword"] = .string(newValue) }
    }

    public var excludeKeyword: String {
        get { rawValues["exclude_keyword"]?.keywordStringValue ?? "" }
        set { rawValues["exclude_keyword"] = .string(newValue) }
    }

    public var note: String {
        get { rawValues["note"]?.keywordStringValue ?? "" }
        set { rawValues["note"] = .string(newValue) }
    }

    public var isTitleOnly: Bool {
        get { rawValues["is_title_only"]?.keywordBoolValue ?? false }
        set { rawValues["is_title_only"] = .bool(newValue) }
    }

    public var isCaseSensitive: Bool {
        get { rawValues["is_case_sensitive"]?.keywordBoolValue ?? false }
        set { rawValues["is_case_sensitive"] = .bool(newValue) }
    }

    public var isFuzzySearchEnabled: Bool {
        get { rawValues["is_fuzzy_search_enabled"]?.keywordBoolValue ?? false }
        set { rawValues["is_fuzzy_search_enabled"] = .bool(newValue) }
    }

    public var isRegexSearchEnabled: Bool {
        get { rawValues["is_regex_search_enabled"]?.keywordBoolValue ?? false }
        set { rawValues["is_regex_search_enabled"] = .bool(newValue) }
    }

    public var serviceRanges: [ProgramSearchConditionService]? {
        get { objectArray(for: "service_ranges")?.map(ProgramSearchConditionService.init(rawValues:)) }
        set { rawValues["service_ranges"] = newValue.map { .array($0.map { .object($0.rawValues) }) } ?? .null }
    }

    public var genreRanges: [ProgramSearchConditionGenre]? {
        get { objectArray(for: "genre_ranges")?.map(ProgramSearchConditionGenre.init(rawValues:)) }
        set { rawValues["genre_ranges"] = newValue.map { .array($0.map { .object($0.rawValues) }) } ?? .null }
    }

    public var isExcludeGenreRanges: Bool {
        get { rawValues["is_exclude_genre_ranges"]?.keywordBoolValue ?? false }
        set { rawValues["is_exclude_genre_ranges"] = .bool(newValue) }
    }

    public var dateRanges: [ProgramSearchConditionDate]? {
        get { objectArray(for: "date_ranges")?.map(ProgramSearchConditionDate.init(rawValues:)) }
        set { rawValues["date_ranges"] = newValue.map { .array($0.map { .object($0.rawValues) }) } ?? .null }
    }

    public var isExcludeDateRanges: Bool {
        get { rawValues["is_exclude_date_ranges"]?.keywordBoolValue ?? false }
        set { rawValues["is_exclude_date_ranges"] = .bool(newValue) }
    }

    public var durationRangeMin: Int? {
        get { rawValues["duration_range_min"]?.keywordNullableIntValue }
        set { rawValues["duration_range_min"] = newValue.map(RawJSONValue.integer) ?? .null }
    }

    public var durationRangeMax: Int? {
        get { rawValues["duration_range_max"]?.keywordNullableIntValue }
        set { rawValues["duration_range_max"] = newValue.map(RawJSONValue.integer) ?? .null }
    }

    public var broadcastType: String {
        get { rawValues["broadcast_type"]?.keywordStringValue ?? "FreeOnly" }
        set { rawValues["broadcast_type"] = .string(newValue) }
    }

    public var duplicateTitleCheckScope: String {
        get { rawValues["duplicate_title_check_scope"]?.keywordStringValue ?? "None" }
        set { rawValues["duplicate_title_check_scope"] = .string(newValue) }
    }

    public var duplicateTitleCheckPeriodDays: Int {
        get { rawValues["duplicate_title_check_period_days"]?.keywordIntValue ?? 6 }
        set { rawValues["duplicate_title_check_period_days"] = .integer(newValue) }
    }

    private func objectArray(for key: String) -> [[String: RawJSONValue]]? {
        guard let value = rawValues[key] else { return nil }
        if case .null = value { return nil }
        guard case .array(let values) = value else { return nil }
        return values.compactMap { value in
            guard case .object(let object) = value else { return nil }
            return object
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        var values = try container.decode([String: RawJSONValue].self)
        // New conditions intentionally default to FreeOnly, while an older
        // server response that omitted this field means the API's historical
        // default All. Keep those two cases distinct so loading an existing
        // condition never narrows its broadcast scope silently.
        if values["broadcast_type"] == nil {
            values["broadcast_type"] = .string("All")
        }
        self.init(rawValues: values)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValues)
    }
}

// MARK: - Keyword reservation models

public struct ReservationCondition: Decodable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let reservationCount: Int
    public let programSearchCondition: ProgramSearchCondition
    public let recordSettings: RecordSettings

    public init(
        id: Int,
        reservationCount: Int,
        programSearchCondition: ProgramSearchCondition,
        recordSettings: RecordSettings
    ) {
        self.id = id
        self.reservationCount = reservationCount
        self.programSearchCondition = programSearchCondition
        self.recordSettings = recordSettings
    }

    private enum CodingKeys: String, CodingKey {
        case id, reservationCount, programSearchCondition, recordSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(Int.self, forKey: .id)
        guard decodedID > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Reservation condition id must be greater than zero"
            )
        }
        let count = try container.decode(Int.self, forKey: .reservationCount)
        guard count >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .reservationCount,
                in: container,
                debugDescription: "Reservation condition count must not be negative"
            )
        }
        id = decodedID
        reservationCount = count
        programSearchCondition = try container.decode(ProgramSearchCondition.self, forKey: .programSearchCondition)
        recordSettings = try container.decode(RecordSettings.self, forKey: .recordSettings)
    }
}

public struct ReservationConditions: Decodable, Sendable, Equatable {
    public let total: Int
    public let reservationConditions: [ReservationCondition]

    public init(total: Int = 0, reservationConditions: [ReservationCondition] = []) {
        self.total = total
        self.reservationConditions = reservationConditions
    }

    private enum CodingKeys: String, CodingKey { case total, reservationConditions }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTotal = try container.decode(Int.self, forKey: .total)
        guard decodedTotal >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .total,
                in: container,
                debugDescription: "Reservation condition total must not be negative"
            )
        }
        total = decodedTotal
        reservationConditions = try container.decode([ReservationCondition].self, forKey: .reservationConditions)
    }
}

/// Descriptive alias used by the keyword-reservation client API.
public typealias KeywordReservationsResponse = ReservationConditions

/// Results returned by the read-only program search used to preview a
/// keyword condition before saving it.
public struct ProgramSearchResponse: Decodable, Sendable, Equatable {
    public let total: Int
    public let programs: [GuideProgram]

    public init(total: Int = 0, programs: [GuideProgram] = []) {
        self.total = total
        self.programs = programs
    }

    private enum CodingKeys: String, CodingKey { case total, programs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTotal = try container.decode(Int.self, forKey: .total)
        guard decodedTotal >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .total,
                in: container,
                debugDescription: "Program search total must not be negative"
            )
        }
        total = decodedTotal
        programs = try container.decode([GuideProgram].self, forKey: .programs)
    }
}

private struct KeywordReservationRequest: Encodable, Sendable {
    let programSearchCondition: ProgramSearchCondition
    let recordSettings: RecordSettings

    private enum CodingKeys: String, CodingKey {
        case programSearchCondition = "program_search_condition"
        case recordSettings = "record_settings"
    }
}

public extension RingonomiClient {
    func searchPrograms(
        condition: ProgramSearchCondition,
        using session: URLSession = .shared
    ) async throws -> ProgramSearchResponse {
        try await request(
            path: ["api", "programs", "search"],
            method: "POST",
            body: try encodeRequest(condition),
            using: session,
            decode: ProgramSearchResponse.self
        )
    }

    func keywordReservations(using session: URLSession = .shared) async throws -> KeywordReservationsResponse {
        try await request(
            path: ["api", "recording", "conditions"],
            method: "GET",
            body: nil,
            using: session,
            decode: KeywordReservationsResponse.self
        )
    }

    func keywordReservation(id: Int, using session: URLSession = .shared) async throws -> ReservationCondition {
        try await request(
            path: ["api", "recording", "conditions", String(id)],
            method: "GET",
            body: nil,
            using: session,
            decode: ReservationCondition.self
        )
    }

    func addKeywordReservation(
        search: ProgramSearchCondition,
        settings: RecordSettings = RecordSettings(),
        using session: URLSession = .shared
    ) async throws -> ReservationCondition {
        let request = KeywordReservationRequest(programSearchCondition: search, recordSettings: settings)
        let response = try await requestRaw(
            path: ["api", "recording", "conditions"],
            method: "POST",
            body: try encodeRequest(request),
            using: session
        )
        if !Self.isEmptyResponseBody(response.data) {
            return try decodeResponse(ReservationCondition.self, from: response.data)
        }

        // A 201 response is allowed to contain no object. Resolve it only if
        // exactly one list entry has the same complete search condition. A
        // duplicate match cannot identify the newly-created condition safely.
        let list: KeywordReservationsResponse
        do {
            list = try await keywordReservations(using: session)
        } catch {
            // The list request follows a successful POST. Its HTTP status
            // cannot prove that the original write was rejected.
            throw ReservationError.outcomeUnknown
        }
        let matches = list.reservationConditions.filter {
            $0.programSearchCondition == search && $0.recordSettings == settings
        }
        guard !matches.isEmpty else {
            throw ReservationError.emptyCreatedReservation
        }
        guard matches.count == 1 else {
            // A matching search/settings pair can still be duplicated by a
            // concurrent client; do not guess which condition this POST made.
            throw ReservationError.outcomeUnknown
        }
        return matches[0]
    }

    func updateKeywordReservation(
        id: Int,
        search: ProgramSearchCondition,
        settings: RecordSettings,
        using session: URLSession = .shared
    ) async throws -> ReservationCondition {
        let request = KeywordReservationRequest(programSearchCondition: search, recordSettings: settings)
        let response = try await requestRaw(
            path: ["api", "recording", "conditions", String(id)],
            method: "PUT",
            body: try encodeRequest(request),
            using: session
        )
        if Self.isEmptyResponseBody(response.data) {
            do {
                return try await keywordReservation(id: id, using: session)
            } catch {
                // The PUT may already have been applied; keep the write in
                // the recovery journal when verification cannot complete.
                throw ReservationError.outcomeUnknown
            }
        }
        return try decodeResponse(ReservationCondition.self, from: response.data)
    }

    func deleteKeywordReservation(id: Int, using session: URLSession = .shared) async throws {
        _ = try await requestRaw(
            path: ["api", "recording", "conditions", String(id)],
            method: "DELETE",
            body: nil,
            using: session
        )
    }
}

private extension RawJSONValue {
    var keywordStringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var keywordBoolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var keywordIntValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value) where value.isFinite && value.rounded() == value:
            return Int(exactly: value)
        default: return nil
        }
    }

    var keywordNullableIntValue: Int? {
        if case .null = self { return nil }
        return keywordIntValue
    }
}
