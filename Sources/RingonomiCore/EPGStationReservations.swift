import Foundation

/// The reservation categories supported by EPGStation.
public enum EPGStationReservationFilter: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case normal
    case conflict
    case skip
    case overlap
}

/// A reservation returned by EPGStation.
///
/// The model keeps the reservation fields needed by both the read-only list
/// and a safe edit. Unknown program metadata is ignored, while tags, save
/// settings, and encode settings are retained for a later PUT.
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
    public let tags: [Int]?
    public let parentDirectoryName: String?
    public let directory: String?
    public let recordedFormat: String?
    public let encodeMode1: String?
    public let encodeParentDirectoryName1: String?
    public let encodeDirectory1: String?
    public let encodeMode2: String?
    public let encodeParentDirectoryName2: String?
    public let encodeDirectory2: String?
    public let encodeMode3: String?
    public let encodeParentDirectoryName3: String?
    public let encodeDirectory3: String?
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
        case tags, parentDirectoryName, directory, recordedFormat
        case encodeMode1, encodeParentDirectoryName1, encodeDirectory1
        case encodeMode2, encodeParentDirectoryName2, encodeDirectory2
        case encodeMode3, encodeParentDirectoryName3, encodeDirectory3
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
        tags: [Int]? = nil,
        parentDirectoryName: String? = nil,
        directory: String? = nil,
        recordedFormat: String? = nil,
        encodeMode1: String? = nil,
        encodeParentDirectoryName1: String? = nil,
        encodeDirectory1: String? = nil,
        encodeMode2: String? = nil,
        encodeParentDirectoryName2: String? = nil,
        encodeDirectory2: String? = nil,
        encodeMode3: String? = nil,
        encodeParentDirectoryName3: String? = nil,
        encodeDirectory3: String? = nil,
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
              startAt >= 0,
              endAt >= startAt,
              endAt <= Double(EPGStationValueRules.maximumSafeJSONInteger),
              EPGStationValueRules.isSafeText(name, maximumBytes: 16 * 1024),
              description.map({ EPGStationValueRules.isSafeHumanText($0, maximumBytes: 64 * 1024) }) ?? true,
              extended.map({ EPGStationValueRules.isSafeHumanText($0, maximumBytes: 64 * 1024) }) ?? true,
              tags.map({ $0.allSatisfy(EPGStationValueRules.isPositiveIdentifier) }) ?? true,
              parentDirectoryName.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              directory.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              recordedFormat.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              encodeMode1.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              encodeParentDirectoryName1.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              encodeDirectory1.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              encodeMode2.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              encodeParentDirectoryName2.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              encodeDirectory2.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              encodeMode3.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              encodeParentDirectoryName3.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              encodeDirectory3.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true else {
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
        self.tags = tags
        self.parentDirectoryName = parentDirectoryName
        self.directory = directory
        self.recordedFormat = recordedFormat
        self.encodeMode1 = encodeMode1
        self.encodeParentDirectoryName1 = encodeParentDirectoryName1
        self.encodeDirectory1 = encodeDirectory1
        self.encodeMode2 = encodeMode2
        self.encodeParentDirectoryName2 = encodeParentDirectoryName2
        self.encodeDirectory2 = encodeDirectory2
        self.encodeMode3 = encodeMode3
        self.encodeParentDirectoryName3 = encodeParentDirectoryName3
        self.encodeDirectory3 = encodeDirectory3
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
            tags: container.decodeIfPresent([Int].self, forKey: .tags),
            parentDirectoryName: container.decodeIfPresent(String.self, forKey: .parentDirectoryName),
            directory: container.decodeIfPresent(String.self, forKey: .directory),
            recordedFormat: container.decodeIfPresent(String.self, forKey: .recordedFormat),
            encodeMode1: container.decodeIfPresent(String.self, forKey: .encodeMode1),
            encodeParentDirectoryName1: container.decodeIfPresent(String.self, forKey: .encodeParentDirectoryName1),
            encodeDirectory1: container.decodeIfPresent(String.self, forKey: .encodeDirectory1),
            encodeMode2: container.decodeIfPresent(String.self, forKey: .encodeMode2),
            encodeParentDirectoryName2: container.decodeIfPresent(String.self, forKey: .encodeParentDirectoryName2),
            encodeDirectory2: container.decodeIfPresent(String.self, forKey: .encodeDirectory2),
            encodeMode3: container.decodeIfPresent(String.self, forKey: .encodeMode3),
            encodeParentDirectoryName3: container.decodeIfPresent(String.self, forKey: .encodeParentDirectoryName3),
            encodeDirectory3: container.decodeIfPresent(String.self, forKey: .encodeDirectory3),
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
