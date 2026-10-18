import Foundation

/// The reserve categories accepted by EPGStation's rule-list endpoint.
///
/// The endpoint still returns every rule for each category; the category
/// controls whether `reservesCnt` is calculated by the server.
public enum EPGStationRuleFilter: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case normal
    case conflict
    case skip
    case overlap
}

/// A lossless rule payload.
///
/// EPGStation adds fields to rule options over time. Keeping the complete JSON
/// object here lets the editor update one group without deleting fields that
/// this client does not know yet.
public struct EPGStationRuleOptions: Codable, Equatable, Sendable {
    public var rawValues: [String: RawJSONValue]

    public init(rawValues: [String: RawJSONValue] = [:]) {
        self.rawValues = rawValues
    }

    public var isTimeSpecification: Bool? {
        get { rawValues["isTimeSpecification"].flatMap(Self.boolValue) }
        set { rawValues["isTimeSpecification"] = newValue.map(RawJSONValue.bool) ?? .null }
    }

    /// The server's `searchOption` object, including unknown nested fields.
    public var searchValues: [String: RawJSONValue] {
        get { rawValues["searchOption"].flatMap(Self.objectValue) ?? [:] }
        set { rawValues["searchOption"] = .object(newValue) }
    }

    /// The server's `reserveOption` object, including unknown nested fields.
    public var reserveValues: [String: RawJSONValue] {
        get { rawValues["reserveOption"].flatMap(Self.objectValue) ?? [:] }
        set { rawValues["reserveOption"] = .object(newValue) }
    }

    public var enabled: Bool? {
        get { reserveValues["enable"].flatMap(Self.boolValue) }
        set {
            var values = reserveValues
            values["enable"] = newValue.map(RawJSONValue.bool) ?? .null
            reserveValues = values
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValues = try container.decode([String: RawJSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValues)
    }

    fileprivate func validateResponse() throws {
        do {
            try EPGStationRuleValidation.validate(options: self, forWrite: false)
        } catch {
            throw EPGStationError.invalidResponse
        }
    }

    fileprivate func validateForWrite() throws {
        do {
            try EPGStationRuleValidation.validate(options: self, forWrite: true)
        } catch {
            throw EPGStationWriteError.invalidRequest
        }
    }

    fileprivate static func objectValue(_ value: RawJSONValue) -> [String: RawJSONValue]? {
        guard case .object(let object) = value else { return nil }
        return object
    }

    private static func boolValue(_ value: RawJSONValue) -> Bool? {
        guard case .bool(let bool) = value else { return nil }
        return bool
    }
}

public extension EPGStationRuleOptions {
    /// Compare a submitted option set with a subsequent EPGStation readback.
    ///
    /// EPGStation stores omitted booleans as `false` and omits nullable values
    /// again when they are `null`.  Empty strings and arrays remain explicit,
    /// so they are intentionally compared separately from an omitted value.
    /// Unknown fields sent by the caller must survive; fields added only by a
    /// newer server are ignored.
    func matchesServerReadback(_ actual: EPGStationRuleOptions) -> Bool {
        EPGStationRuleReadbackComparison.matches(
            requested: EPGStationRulePayloadNormalization.normalizedOptions(rawValues),
            actual: actual.rawValues
        )
    }
}

/// A rule returned by EPGStation.
public struct EPGStationRule: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let options: EPGStationRuleOptions
    public let reservesCount: Int?

    public init(
        id: Int,
        options: EPGStationRuleOptions,
        reservesCount: Int? = nil
    ) throws {
        guard EPGStationValueRules.isPositiveIdentifier(id),
              reservesCount.map({ (0...EPGStationValueRules.maximumSafeJSONInteger).contains($0) }) ?? true else {
            throw EPGStationError.invalidResponse
        }
        try options.validateResponse()
        self.id = id
        self.options = options
        self.reservesCount = reservesCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case reservesCount = "reservesCnt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        var values = try container.decode([String: RawJSONValue].self)
        guard let idValue = values.removeValue(forKey: "id"),
              case .integer(let id) = idValue else {
            throw EPGStationError.invalidResponse
        }
        let reservesCount: Int?
        if let countValue = values.removeValue(forKey: "reservesCnt") {
            if case .null = countValue {
                reservesCount = nil
            } else {
                guard case .integer(let count) = countValue else {
                    throw EPGStationError.invalidResponse
                }
                reservesCount = count
            }
        } else {
            reservesCount = nil
        }
        self = try EPGStationRule(
            id: id,
            options: EPGStationRuleOptions(rawValues: values),
            reservesCount: reservesCount
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = options.rawValues
        values["id"] = .integer(id)
        if let reservesCount {
            values["reservesCnt"] = .integer(reservesCount)
        }
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// A page returned by EPGStation's rule-list endpoint.
public struct EPGStationRulePage: Codable, Equatable, Sendable {
    public let rules: [EPGStationRule]
    public let total: Int

    public init(rules: [EPGStationRule], total: Int) throws {
        guard total >= rules.count,
              total <= EPGStationValueRules.maximumSafeJSONInteger else {
            throw EPGStationError.invalidResponse
        }
        var ids = Set<Int>(minimumCapacity: rules.count)
        guard rules.allSatisfy({ ids.insert($0.id).inserted }) else {
            throw EPGStationError.invalidResponse
        }
        self.rules = rules
        self.total = total
    }

    private enum CodingKeys: String, CodingKey {
        case rules, total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try EPGStationRulePage(
            rules: container.decode([EPGStationRule].self, forKey: .rules),
            total: container.decode(Int.self, forKey: .total)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rules, forKey: .rules)
        try container.encode(total, forKey: .total)
    }
}

/// Merge an editor's changes into the latest rule without overwriting a
/// concurrent change. Known option groups are merged recursively so an edit
/// to `searchOption.keyword` does not erase a concurrent change to its genre
/// list or to a server-added field.
public func mergingEditedRuleOptions(
    original: EPGStationRuleOptions,
    edited: EPGStationRuleOptions,
    latest: EPGStationRuleOptions
) throws -> EPGStationRuleOptions {
    let groups = Set(["searchOption", "reserveOption", "saveOption", "encodeOption"])
    var result: [String: RawJSONValue] = [:]

    let scalarOriginal = original.rawValues.filter { !groups.contains($0.key) }
    let scalarEdited = edited.rawValues.filter { !groups.contains($0.key) }
    let scalarLatest = latest.rawValues.filter { !groups.contains($0.key) }
    result.merge(
        try mergingEditedSettings(
            original: scalarOriginal,
            edited: scalarEdited,
            latest: scalarLatest
        ),
        uniquingKeysWith: { _, new in new }
    )

    for key in groups {
        let before = original.rawValues[key]
        let after = edited.rawValues[key]
        let current = latest.rawValues[key]
        guard before != after else {
            if let current { result[key] = current }
            continue
        }

        if let beforeObject = before.flatMap(EPGStationRuleOptions.objectValue),
           let afterObject = after.flatMap(EPGStationRuleOptions.objectValue),
           let currentObject = current.flatMap(EPGStationRuleOptions.objectValue) {
            let merged = try mergingEditedSettings(
                original: beforeObject,
                edited: afterObject,
                latest: currentObject
            )
            result[key] = .object(merged)
        } else {
            guard current == before || current == after else {
                throw SettingsPatchError.conflictingChange
            }
            if let after { result[key] = after }
        }
    }
    return EPGStationRuleOptions(rawValues: result)
}

public extension EPGStationClient {
    /// Fetch a page of automatic-recording rules.
    func rules(
        offset: Int = 0,
        limit: Int = EPGStationClient.defaultPageLimit,
        filter: EPGStationRuleFilter? = nil,
        keyword: String? = nil
    ) async throws -> EPGStationRulePage {
        guard (0...EPGStationValueRules.maximumSafeJSONInteger).contains(offset),
              (1...Self.maximumPageLimit).contains(limit) else {
            throw EPGStationError.invalidRequest
        }
        let normalizedKeyword = try EPGStationRuleValidation.keyword(keyword)
        var queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let filter {
            queryItems.append(URLQueryItem(name: "type", value: filter.rawValue))
        }
        if let normalizedKeyword, !normalizedKeyword.isEmpty {
            queryItems.append(URLQueryItem(name: "keyword", value: normalizedKeyword))
        }

        let data = try await data(for: endpoint(["api", "rules"], queryItems: queryItems))
        let page = try EPGStationRuleDecoder.page(from: data)
        guard page.rules.count <= limit else {
            throw EPGStationError.invalidResponse
        }
        return page
    }

    /// Fetch one rule by its rule ID.
    func rule(id: Int) async throws -> EPGStationRule {
        guard EPGStationValueRules.isPositiveIdentifier(id) else {
            throw EPGStationError.invalidIdentifier
        }
        let data = try await data(for: endpoint(["api", "rules", String(id)]))
        let rule = try EPGStationRuleDecoder.rule(from: data)
        guard rule.id == id else { throw EPGStationError.invalidResponse }
        return rule
    }

    /// Add an automatic-recording rule. The returned ID is the only accepted
    /// success body; an ambiguous response is never retried automatically.
    func createRule(options: EPGStationRuleOptions) async throws -> Int {
        try options.validateForWrite()
        let data = try await ruleWriteData(
            endpoint(["api", "rules"]),
            method: "POST",
            body: try EPGStationRuleEncoder.data(for: options)
        )
        let values = try EPGStationRuleDecoder.object(from: data)
        guard case .integer(let id) = values["ruleId"],
              EPGStationValueRules.isPositiveIdentifier(id) else {
            throw EPGStationWriteError.outcomeUnknown
        }
        return id
    }

    /// Replace the complete rule payload. Callers should merge it with the
    /// latest GET result before invoking this method.
    func updateRule(id: Int, options: EPGStationRuleOptions) async throws {
        guard EPGStationValueRules.isPositiveIdentifier(id) else {
            throw EPGStationWriteError.invalidRequest
        }
        try options.validateForWrite()
        let data = try await ruleWriteData(
            endpoint(["api", "rules", String(id)]),
            method: "PUT",
            body: try EPGStationRuleEncoder.data(for: options)
        )
        try EPGStationRuleDecoder.validateMutationResponse(data)
    }

    /// Delete a rule. The server may finish its reservation diff after the
    /// HTTP response; callers should read the rule and reservations again.
    func deleteRule(id: Int) async throws {
        guard EPGStationValueRules.isPositiveIdentifier(id) else {
            throw EPGStationWriteError.invalidRequest
        }
        let data = try await ruleWriteData(
            endpoint(["api", "rules", String(id)]),
            method: "DELETE",
            body: nil
        )
        try EPGStationRuleDecoder.validateMutationResponse(data)
    }

    /// Enable or disable a rule without changing its other option groups.
    func setRuleEnabled(id: Int, enabled: Bool) async throws {
        guard EPGStationValueRules.isPositiveIdentifier(id) else {
            throw EPGStationWriteError.invalidRequest
        }
        let action = enabled ? "enable" : "disable"
        let data = try await ruleWriteData(
            endpoint(["api", "rules", String(id), action]),
            method: "PUT",
            body: nil
        )
        try EPGStationRuleDecoder.validateMutationResponse(data)
    }

    /// Search the schedule using rule search values. This is a read-only
    /// preview even though EPGStation exposes it as a POST endpoint.
    func previewRule(
        searchValues: [String: RawJSONValue],
        limit: Int? = nil,
        isHalfWidth: Bool = true
    ) async throws -> [EPGStationScheduleProgram] {
        guard limit.map({ (1...Self.maximumPageLimit).contains($0) }) ?? true else {
            throw EPGStationError.invalidRequest
        }
        do {
            try EPGStationRuleValidation.validateSearch(
                searchValues,
                isTimeSpecification: false,
                requireTimeValues: false
            )
        } catch {
            throw EPGStationError.invalidRequest
        }
        var body: [String: RawJSONValue] = [
            "option": .object(EPGStationRulePayloadNormalization.normalizedSearchValues(searchValues)),
            "isHalfWidth": .bool(isHalfWidth)
        ]
        if let limit { body["limit"] = .integer(limit) }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw EPGStationError.invalidRequest
        }
        let data = try await data(
            for: endpoint(["api", "schedules", "search"]),
            method: "POST",
            body: encoded
        )
        let programs: [EPGStationScheduleProgram]
        do {
            programs = try JSONDecoder().decode([EPGStationScheduleProgram].self, from: data)
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
        guard programs.count <= (limit ?? Self.maximumPageLimit) else {
            throw EPGStationError.invalidResponse
        }
        var ids = Set<Int>(minimumCapacity: programs.count)
        guard programs.allSatisfy({ ids.insert($0.id).inserted }) else {
            throw EPGStationError.invalidResponse
        }
        return programs
    }
}

private extension EPGStationClient {
    func ruleWriteData(_ requestURL: URL, method: String, body: Data?) async throws -> Data {
        do {
            return try await data(for: requestURL, method: method, body: body)
        } catch let error as EPGStationError {
            switch error {
            case .httpStatus(let status) where status >= 500:
                throw EPGStationWriteError.outcomeUnknown
            case .transport, .responseTooLarge, .redirectRejected:
                throw EPGStationWriteError.outcomeUnknown
            case .httpStatus(let status):
                throw EPGStationWriteError.httpStatus(status)
            case .invalidAddress, .invalidIdentifier, .invalidRequest:
                throw EPGStationWriteError.invalidRequest
            case .invalidResponse:
                throw EPGStationWriteError.outcomeUnknown
            }
        } catch is CancellationError {
            throw EPGStationWriteError.outcomeUnknown
        } catch {
            throw EPGStationWriteError.outcomeUnknown
        }
    }
}

private enum EPGStationRuleEncoder {
    static func data(for options: EPGStationRuleOptions) throws -> Data {
        do {
            let values = EPGStationRulePayloadNormalization.normalizedOptions(options.rawValues)
            return try JSONEncoder().encode(values)
        } catch {
            throw EPGStationWriteError.invalidRequest
        }
    }
}

private enum EPGStationRuleDecoder {
    static func object(from data: Data) throws -> [String: RawJSONValue] {
        do {
            return try JSONDecoder().decode([String: RawJSONValue].self, from: data)
        } catch {
            throw EPGStationWriteError.outcomeUnknown
        }
    }

    static func rule(from data: Data) throws -> EPGStationRule {
        do {
            return try JSONDecoder().decode(EPGStationRule.self, from: data)
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
    }

    static func page(from data: Data) throws -> EPGStationRulePage {
        do {
            return try JSONDecoder().decode(EPGStationRulePage.self, from: data)
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
    }

    static func validateMutationResponse(_ data: Data) throws {
        let values: [String: RawJSONValue]
        do {
            values = try JSONDecoder().decode([String: RawJSONValue].self, from: data)
        } catch {
            throw EPGStationWriteError.outcomeUnknown
        }
        guard case .integer(let code) = values["code"], code == 200 else {
            throw EPGStationWriteError.outcomeUnknown
        }
    }
}

private enum EPGStationRuleValidationError: Error {
    case malformed
}

/// Removes explicit nulls for fields that EPGStation treats as optional
/// properties. Unknown fields are left untouched so a newer server field is
/// still round-tripped during a full rule update.
private enum EPGStationRulePayloadNormalization {
    fileprivate static let searchBooleanKeys = [
        "keyCS", "keyRegExp", "name", "description", "extended",
        "ignoreKeyCS", "ignoreKeyRegExp", "ignoreName", "ignoreDescription", "ignoreExtended",
        "GR", "BS", "CS", "SKY", "isFree"
    ]
    fileprivate static let searchNullableKeys = [
        "keyword", "ignoreKeyword", "channelIds", "genres", "times",
        "durationMin", "durationMax", "searchPeriods"
    ]
    fileprivate static let reserveNullableKeys = ["periodToAvoidDuplicate", "tags"]
    fileprivate static let saveNullableKeys = ["parentDirectoryName", "directory", "recordedFormat"]
    fileprivate static let encodeNullableKeys = [
        "mode1", "encodeParentDirectoryName1", "directory1",
        "mode2", "encodeParentDirectoryName2", "directory2",
        "mode3", "encodeParentDirectoryName3", "directory3"
    ]

    static func normalizedOptions(_ values: [String: RawJSONValue]) -> [String: RawJSONValue] {
        var normalized = values
        if let search = object(normalized["searchOption"]) {
            normalized["searchOption"] = .object(normalizedSearchValues(search))
        }
        if let reserve = object(normalized["reserveOption"]) {
            normalized["reserveOption"] = .object(normalizedReserveValues(reserve))
        }
        normalizeOptionalObject(
            in: &normalized,
            key: "saveOption",
            nullableKeys: saveNullableKeys
        )
        normalizeOptionalObject(
            in: &normalized,
            key: "encodeOption",
            nullableKeys: encodeNullableKeys
        )
        return normalized
    }

    static func normalizedSearchValues(_ values: [String: RawJSONValue]) -> [String: RawJSONValue] {
        var normalized = removeNulls(
            from: values,
            keys: searchBooleanKeys + searchNullableKeys
        )
        if let genres = normalized["genres"] {
            normalized["genres"] = normalizeNestedOptional(
                genres,
                removing: "subGenre"
            )
        }
        if let times = normalized["times"] {
            normalized["times"] = normalizeNestedOptional(
                times,
                removing: "start",
                "range"
            )
        }
        return normalized
    }

    private static func normalizedReserveValues(_ values: [String: RawJSONValue]) -> [String: RawJSONValue] {
        removeNulls(from: values, keys: reserveNullableKeys)
    }

    private static func normalizeOptionalObject(
        in values: inout [String: RawJSONValue],
        key: String,
        nullableKeys: [String]
    ) {
        guard let value = values[key] else { return }
        if isNull(value) {
            values.removeValue(forKey: key)
        } else if let object = object(value) {
            values[key] = .object(removeNulls(from: object, keys: nullableKeys))
        }
    }

    private static func normalizeNestedOptional(
        _ value: RawJSONValue,
        removing keys: String...
    ) -> RawJSONValue {
        guard case .array(let values) = value else { return value }
        return .array(values.map { value in
            guard case .object(let object) = value else { return value }
            return .object(removeNulls(from: object, keys: keys))
        })
    }

    private static func removeNulls(
        from values: [String: RawJSONValue],
        keys: [String]
    ) -> [String: RawJSONValue] {
        var result = values
        for key in keys where isNull(result[key]) {
            result.removeValue(forKey: key)
        }
        return result
    }

    private static func object(_ value: RawJSONValue?) -> [String: RawJSONValue]? {
        guard let value, case .object(let object) = value else { return nil }
        return object
    }

    private static func isNull(_ value: RawJSONValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return true }
        return false
    }
}

private enum EPGStationRuleReadbackComparison {
    private static let searchBooleanKeys = EPGStationRulePayloadNormalization.searchBooleanKeys
    private static let searchNullableKeys = EPGStationRulePayloadNormalization.searchNullableKeys
    private static let reserveBooleanDefaults: [String: Bool] = [
        "enable": false,
        "allowEndLack": true,
        "avoidDuplicate": false
    ]
    private static let reserveNullableKeys = EPGStationRulePayloadNormalization.reserveNullableKeys
    private static let saveNullableKeys = EPGStationRulePayloadNormalization.saveNullableKeys
    private static let encodeNullableKeys = EPGStationRulePayloadNormalization.encodeNullableKeys

    static func matches(
        requested: [String: RawJSONValue],
        actual: [String: RawJSONValue]
    ) -> Bool {
        guard matchesBoolean(
            expected: requested["isTimeSpecification"],
            actual: actual["isTimeSpecification"],
            defaultValue: false
        ),
        let expectedSearch = object(requested["searchOption"]),
        let actualSearch = object(actual["searchOption"]),
        matchesSearch(expected: expectedSearch, actual: actualSearch),
        let expectedReserve = object(requested["reserveOption"]),
        let actualReserve = object(actual["reserveOption"]),
        matchesReserve(expected: expectedReserve, actual: actualReserve),
        matchesOptionalObject(
            expected: requested["saveOption"],
            actual: actual["saveOption"],
            nullableKeys: saveNullableKeys,
            booleanDefaults: [:]
        ),
        matchesOptionalObject(
            expected: requested["encodeOption"],
            actual: actual["encodeOption"],
            nullableKeys: encodeNullableKeys,
            booleanDefaults: ["isDeleteOriginalAfterEncode": false]
        ) else {
            return false
        }

        let known = Set(["isTimeSpecification", "searchOption", "reserveOption", "saveOption", "encodeOption"])
        for (key, value) in requested where !known.contains(key) {
            guard contains(actual[key], expected: value) else { return false }
        }
        return true
    }

    private static func matchesSearch(
        expected: [String: RawJSONValue],
        actual: [String: RawJSONValue]
    ) -> Bool {
        for key in searchBooleanKeys {
            guard matchesBoolean(expected: expected[key], actual: actual[key], defaultValue: false) else {
                return false
            }
        }
        for key in searchNullableKeys {
            guard matchesNullable(expected[key], actual[key]) else { return false }
        }
        let known = Set(searchBooleanKeys + searchNullableKeys)
        for (key, value) in expected where !known.contains(key) {
            guard contains(actual[key], expected: value) else { return false }
        }
        return true
    }

    private static func matchesReserve(
        expected: [String: RawJSONValue],
        actual: [String: RawJSONValue]
    ) -> Bool {
        for (key, defaultValue) in reserveBooleanDefaults {
            guard matchesBoolean(expected: expected[key], actual: actual[key], defaultValue: defaultValue) else {
                return false
            }
        }
        for key in reserveNullableKeys {
            guard matchesNullable(expected[key], actual[key]) else { return false }
        }
        let known = Set(reserveBooleanDefaults.keys).union(reserveNullableKeys)
        for (key, value) in expected where !known.contains(key) {
            guard contains(actual[key], expected: value) else { return false }
        }
        return true
    }

    private static func matchesOptionalObject(
        expected value: RawJSONValue?,
        actual actualValue: RawJSONValue?,
        nullableKeys: [String],
        booleanDefaults: [String: Bool]
    ) -> Bool {
        let expectedObject = object(value)
        let actualObject = object(actualValue)
        for key in nullableKeys {
            guard matchesNullable(expectedObject?[key], actualObject?[key]) else { return false }
        }
        for (key, defaultValue) in booleanDefaults {
            guard matchesBoolean(
                expected: expectedObject?[key],
                actual: actualObject?[key],
                defaultValue: defaultValue
            ) else { return false }
        }
        let known = Set(nullableKeys).union(booleanDefaults.keys)
        for (key, expectedValue) in expectedObject ?? [:] where !known.contains(key) {
            guard contains(actualObject?[key], expected: expectedValue) else { return false }
        }
        return true
    }

    private static func matchesBoolean(
        expected: RawJSONValue?,
        actual: RawJSONValue?,
        defaultValue: Bool
    ) -> Bool {
        let expectedValue = bool(expected) ?? defaultValue
        let actualValue = bool(actual) ?? defaultValue
        if let expected, !isNullOrBool(expected) { return false }
        if let actual, !isNullOrBool(actual) { return false }
        return expectedValue == actualValue
    }

    private static func matchesNullable(
        _ expected: RawJSONValue?,
        _ actual: RawJSONValue?
    ) -> Bool {
        guard let expected, !isNull(expected) else {
            return actual == nil || actual.map(isNull) == true
        }
        return actual == expected
    }

    private static func contains(
        _ actual: RawJSONValue?,
        expected: RawJSONValue
    ) -> Bool {
        if isNull(expected) {
            guard let actual else { return false }
            return isNull(actual)
        }
        guard let actual else { return false }
        if case .object(let expectedObject) = expected,
           case .object(let actualObject) = actual {
            return expectedObject.allSatisfy {
                contains(actualObject[$0.key], expected: $0.value)
            }
        }
        return actual == expected
    }

    private static func object(_ value: RawJSONValue?) -> [String: RawJSONValue]? {
        guard let value, case .object(let object) = value else { return nil }
        return object
    }

    private static func bool(_ value: RawJSONValue?) -> Bool? {
        guard let value, case .bool(let bool) = value else { return nil }
        return bool
    }

    private static func isNull(_ value: RawJSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private static func isNullOrBool(_ value: RawJSONValue) -> Bool {
        isNull(value) || bool(value) != nil
    }
}

private enum EPGStationRuleValidation {
    private static let searchBooleanKeys = [
        "keyCS", "keyRegExp", "name", "description", "extended",
        "ignoreKeyCS", "ignoreKeyRegExp", "ignoreName", "ignoreDescription", "ignoreExtended",
        "GR", "BS", "CS", "SKY", "isFree"
    ]
    private static let searchTextKeys = ["keyword", "ignoreKeyword"]
    private static let saveTextKeys = ["parentDirectoryName", "directory", "recordedFormat"]
    private static let encodeTextKeys = [
        "mode1", "encodeParentDirectoryName1", "directory1",
        "mode2", "encodeParentDirectoryName2", "directory2",
        "mode3", "encodeParentDirectoryName3", "directory3"
    ]

    static func keyword(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= 1024,
              EPGStationValueRules.isSafeText(normalized, maximumBytes: 1024) else {
            throw EPGStationError.invalidRequest
        }
        return normalized
    }

    static func validate(options: EPGStationRuleOptions, forWrite: Bool) throws {
        let values = options.rawValues
        guard case .bool(let isTimeSpecification) = values["isTimeSpecification"],
              case .object(let search) = values["searchOption"],
              case .object(let reserve) = values["reserveOption"] else {
            throw EPGStationRuleValidationError.malformed
        }
        guard !values.keys.contains("id"), !values.keys.contains("reservesCnt") else {
            throw EPGStationRuleValidationError.malformed
        }
        guard values.keys.allSatisfy({ EPGStationValueRules.isSafeText($0, maximumBytes: 256, allowEmpty: false) }) else {
            throw EPGStationRuleValidationError.malformed
        }
        try validateSearch(search, isTimeSpecification: isTimeSpecification, requireTimeValues: forWrite && isTimeSpecification)
        try validateReserve(reserve)
        try validateOptionalGroup(values["saveOption"], keys: saveTextKeys, requireDeleteFlag: false)
        try validateOptionalGroup(values["encodeOption"], keys: encodeTextKeys, requireDeleteFlag: true)
    }

    static func validateSearch(
        _ values: [String: RawJSONValue],
        isTimeSpecification: Bool,
        requireTimeValues: Bool
    ) throws {
        for key in searchBooleanKeys {
            guard values[key].map(isNullOrBool) ?? true else { throw EPGStationRuleValidationError.malformed }
        }
        for key in searchTextKeys {
            guard values[key].map(isNullOrSafeText) ?? true else { throw EPGStationRuleValidationError.malformed }
        }
        if let channelIDs = values["channelIds"], !isNull(channelIDs) {
            guard case .array(let rawIDs) = channelIDs else { throw EPGStationRuleValidationError.malformed }
            var ids = Set<Int>()
            for rawID in rawIDs {
                guard case .integer(let id) = rawID,
                      EPGStationValueRules.isPositiveIdentifier(id), ids.insert(id).inserted else {
                    throw EPGStationRuleValidationError.malformed
                }
            }
        }
        if let genres = values["genres"], !isNull(genres) {
            guard case .array(let rawGenres) = genres else { throw EPGStationRuleValidationError.malformed }
            for rawGenre in rawGenres {
                // ReserveOptionChecker accepts the ARIB genre nibble (0x00...0x0F).
                guard case .object(let genre) = rawGenre,
                      case .integer(let value) = genre["genre"], (0...0x0F).contains(value) else {
                    throw EPGStationRuleValidationError.malformed
                }
                if let subGenre = genre["subGenre"], !isNull(subGenre) {
                    guard case .integer(let value) = subGenre, (0...0x0F).contains(value) else {
                        throw EPGStationRuleValidationError.malformed
                    }
                }
            }
        }
        if let times = values["times"], !isNull(times) {
            guard case .array(let rawTimes) = times else { throw EPGStationRuleValidationError.malformed }
            for rawTime in rawTimes {
                guard case .object(let time) = rawTime,
                      case .integer(let week) = time["week"], (1...0x7F).contains(week) else {
                    throw EPGStationRuleValidationError.malformed
                }
                // The fixed server checker requires only non-negative start and
                // positive range for time-specification rules. Do not apply the
                // stale 20-hour limit from the API comment to valid server input.
                if let start = time["start"], !isNull(start) {
                    let validStart: (Int) -> Bool = isTimeSpecification
                        ? { $0 >= 0 && $0 <= EPGStationValueRules.maximumSafeJSONInteger }
                        : { (0...23).contains($0) }
                    guard case .integer(let value) = start, validStart(value) else {
                        throw EPGStationRuleValidationError.malformed
                    }
                } else if requireTimeValues {
                    throw EPGStationRuleValidationError.malformed
                }
                if let range = time["range"], !isNull(range) {
                    let validRange: (Int) -> Bool = isTimeSpecification
                        ? { $0 > 0 && $0 <= EPGStationValueRules.maximumSafeJSONInteger }
                        : { (1...23).contains($0) }
                    guard case .integer(let value) = range, validRange(value) else {
                        throw EPGStationRuleValidationError.malformed
                    }
                } else if requireTimeValues {
                    throw EPGStationRuleValidationError.malformed
                }
            }
        } else if requireTimeValues {
            throw EPGStationRuleValidationError.malformed
        }
        try validateNonNegativeInteger(values["durationMin"])
        try validateNonNegativeInteger(values["durationMax"])
        if let min = values["durationMin"].flatMap(integerOrNil),
           let max = values["durationMax"].flatMap(integerOrNil), min > max {
            throw EPGStationRuleValidationError.malformed
        }
        if let periods = values["searchPeriods"], !isNull(periods) {
            guard case .array(let rawPeriods) = periods else { throw EPGStationRuleValidationError.malformed }
            for rawPeriod in rawPeriods {
                guard case .object(let period) = rawPeriod,
                      case .integer(let start) = period["startAt"],
                      case .integer(let end) = period["endAt"],
                      (0...EPGStationValueRules.maximumSafeJSONInteger).contains(start),
                      (0...EPGStationValueRules.maximumSafeJSONInteger).contains(end),
                      end >= start else {
                    throw EPGStationRuleValidationError.malformed
                }
            }
        }
    }

    private static func validateReserve(_ values: [String: RawJSONValue]) throws {
        for key in ["enable", "allowEndLack", "avoidDuplicate"] {
            guard case .bool = values[key] else { throw EPGStationRuleValidationError.malformed }
        }
        try validateNonNegativeInteger(values["periodToAvoidDuplicate"])
        if let tags = values["tags"], !isNull(tags) {
            guard case .array(let rawTags) = tags else { throw EPGStationRuleValidationError.malformed }
            var ids = Set<Int>()
            for tag in rawTags {
                guard case .integer(let id) = tag,
                      EPGStationValueRules.isPositiveIdentifier(id), ids.insert(id).inserted else {
                    throw EPGStationRuleValidationError.malformed
                }
            }
        }
    }

    private static func validateOptionalGroup(
        _ value: RawJSONValue?,
        keys: [String],
        requireDeleteFlag: Bool
    ) throws {
        guard let value, !isNull(value) else { return }
        guard case .object(let values) = value else { throw EPGStationRuleValidationError.malformed }
        for key in keys {
            guard values[key].map(isNullOrSafeText) ?? true else { throw EPGStationRuleValidationError.malformed }
        }
        if requireDeleteFlag {
            guard case .bool = values["isDeleteOriginalAfterEncode"] else {
                throw EPGStationRuleValidationError.malformed
            }
        }
    }

    private static func validateNonNegativeInteger(_ value: RawJSONValue?) throws {
        guard let value, !isNull(value) else { return }
        guard case .integer(let integer) = value,
              (0...EPGStationValueRules.maximumSafeJSONInteger).contains(integer) else {
            throw EPGStationRuleValidationError.malformed
        }
    }

    private static func integerOrNil(_ value: RawJSONValue?) -> Int? {
        guard case .integer(let value) = value else { return nil }
        return value
    }

    private static func isNull(_ value: RawJSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private static func isNullOrBool(_ value: RawJSONValue) -> Bool {
        if isNull(value) { return true }
        if case .bool = value { return true }
        return false
    }

    private static func isNullOrSafeText(_ value: RawJSONValue) -> Bool {
        if isNull(value) { return true }
        guard case .string(let text) = value else { return false }
        return EPGStationValueRules.isSafeText(text, maximumBytes: 64 * 1024)
    }
}
