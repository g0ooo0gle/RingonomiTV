import Foundation

/// The read-only reservation categories supported by EPGStation.
public enum EPGStationReservationFilter: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case normal
    case conflict
    case skip
    case overlap
}

/// A reservation returned by EPGStation.
///
/// The model intentionally keeps only the stable read fields needed by the
/// Apple TV client. Unknown save, encode, tag, and program metadata fields
/// are ignored so a newer EPGStation response does not invalidate the list.
public struct EPGStationReservation: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let channelID: Int
    public let ruleID: Int?
    public let programID: Int?
    /// Unix time in milliseconds, as defined by EPGStation's UnixtimeMS.
    public let startAt: Double
    /// Unix time in milliseconds, as defined by EPGStation's UnixtimeMS.
    public let endAt: Double
    public let name: String
    public let description: String?
    public let extended: String?
    public let isSkip: Bool
    public let isConflict: Bool
    public let isOverlap: Bool
    public let allowEndLack: Bool
    public let isTimeSpecified: Bool
    public let isDeleteOriginalAfterEncode: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channelId"
        case ruleID = "ruleId"
        case programID = "programId"
        case startAt, endAt, name
        case description, extended
        case isSkip, isConflict, isOverlap
        case allowEndLack, isTimeSpecified, isDeleteOriginalAfterEncode
    }

    public init(
        id: Int,
        channelID: Int,
        ruleID: Int? = nil,
        programID: Int? = nil,
        startAt: Double,
        endAt: Double,
        name: String,
        description: String? = nil,
        extended: String? = nil,
        isSkip: Bool,
        isConflict: Bool,
        isOverlap: Bool,
        allowEndLack: Bool,
        isTimeSpecified: Bool,
        isDeleteOriginalAfterEncode: Bool
    ) throws {
        guard EPGStationValueRules.isPositiveIdentifier(id),
              EPGStationValueRules.isPositiveIdentifier(channelID),
              ruleID.map(EPGStationValueRules.isPositiveIdentifier) ?? true,
              programID.map(EPGStationValueRules.isPositiveIdentifier) ?? true,
              startAt.isFinite,
              endAt.isFinite,
              endAt >= startAt,
              EPGStationValueRules.isSafeText(name, maximumBytes: 16 * 1024),
              description.map({ EPGStationValueRules.isSafeHumanText($0, maximumBytes: 64 * 1024) }) ?? true,
              extended.map({ EPGStationValueRules.isSafeHumanText($0, maximumBytes: 64 * 1024) }) ?? true else {
            throw EPGStationError.invalidResponse
        }
        self.id = id
        self.channelID = channelID
        self.ruleID = ruleID
        self.programID = programID
        self.startAt = startAt
        self.endAt = endAt
        self.name = name
        self.description = description
        self.extended = extended
        self.isSkip = isSkip
        self.isConflict = isConflict
        self.isOverlap = isOverlap
        self.allowEndLack = allowEndLack
        self.isTimeSpecified = isTimeSpecified
        self.isDeleteOriginalAfterEncode = isDeleteOriginalAfterEncode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(Int.self, forKey: .id),
            channelID: container.decode(Int.self, forKey: .channelID),
            ruleID: container.decodeIfPresent(Int.self, forKey: .ruleID),
            programID: container.decodeIfPresent(Int.self, forKey: .programID),
            startAt: container.decode(Double.self, forKey: .startAt),
            endAt: container.decode(Double.self, forKey: .endAt),
            name: container.decode(String.self, forKey: .name),
            description: container.decodeIfPresent(String.self, forKey: .description),
            extended: container.decodeIfPresent(String.self, forKey: .extended),
            isSkip: container.decode(Bool.self, forKey: .isSkip),
            isConflict: container.decode(Bool.self, forKey: .isConflict),
            isOverlap: container.decode(Bool.self, forKey: .isOverlap),
            allowEndLack: container.decode(Bool.self, forKey: .allowEndLack),
            isTimeSpecified: container.decode(Bool.self, forKey: .isTimeSpecified),
            isDeleteOriginalAfterEncode: container.decode(Bool.self, forKey: .isDeleteOriginalAfterEncode)
        )
    }
}

/// A page returned by EPGStation's reservation list endpoint.
public struct EPGStationReservationPage: Codable, Equatable, Sendable {
    public let reservations: [EPGStationReservation]
    public let total: Int

    private enum CodingKeys: String, CodingKey {
        case reservations = "reserves"
        case total
    }

    public init(reservations: [EPGStationReservation], total: Int) throws {
        guard total >= reservations.count,
              total <= EPGStationValueRules.maximumSafeJSONInteger else {
            throw EPGStationError.invalidResponse
        }
        var identifiers = Set<Int>(minimumCapacity: reservations.count)
        guard reservations.allSatisfy({ identifiers.insert($0.id).inserted }) else {
            throw EPGStationError.invalidResponse
        }
        self.reservations = reservations
        self.total = total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reservations: container.decode([EPGStationReservation].self, forKey: .reservations),
            total: container.decode(Int.self, forKey: .total)
        )
    }
}
