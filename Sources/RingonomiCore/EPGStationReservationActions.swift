import Foundation

/// Errors returned by an EPGStation reservation write.
///
/// outcomeUnknown means that the server may have applied the request. The
/// caller must refresh the reservation list before offering another submit.
public enum EPGStationWriteError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case outcomeUnknown

    public var isOutcomeUnknown: Bool {
        if case .outcomeUnknown = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "予約操作の入力が不正です。"
        case .invalidResponse:
            return "予約操作の応答を確認できません。"
        case .httpStatus(let status):
            return "予約操作に失敗しました（HTTP \(status)）。"
        case .outcomeUnknown:
            return "予約操作の結果を確認できません。先に一覧を更新してください。"
        }
    }
}

/// The save settings accepted by EPGStation's manual-reserve API.
public struct EPGStationReservationSaveOption: Codable, Equatable, Sendable {
    public let parentDirectoryName: String?
    public let directory: String?
    public let recordedFormat: String?

    private enum CodingKeys: String, CodingKey {
        case parentDirectoryName, directory, recordedFormat
    }

    public init(
        parentDirectoryName: String? = nil,
        directory: String? = nil,
        recordedFormat: String? = nil
    ) {
        self.parentDirectoryName = parentDirectoryName
        self.directory = directory
        self.recordedFormat = recordedFormat
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The API schema declares these fields as strings, not nullable
        // strings.  EPGStation's DB update maps an omitted field to null, so
        // encode nil as omission while retaining the clear-on-edit behavior.
        try container.encodeIfPresent(parentDirectoryName, forKey: .parentDirectoryName)
        try container.encodeIfPresent(directory, forKey: .directory)
        try container.encodeIfPresent(recordedFormat, forKey: .recordedFormat)
    }

    fileprivate func validate() throws {
        guard parentDirectoryName.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              directory.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              recordedFormat.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true else {
            throw EPGStationWriteError.invalidRequest
        }
    }
}

/// The optional encode settings accepted by EPGStation's manual-reserve API.
public struct EPGStationReservationEncodeOption: Codable, Equatable, Sendable {
    public let mode1: String?
    public let encodeParentDirectoryName1: String?
    public let directory1: String?
    public let mode2: String?
    public let encodeParentDirectoryName2: String?
    public let directory2: String?
    public let mode3: String?
    public let encodeParentDirectoryName3: String?
    public let directory3: String?
    public let isDeleteOriginalAfterEncode: Bool

    private enum CodingKeys: String, CodingKey {
        case mode1, encodeParentDirectoryName1, directory1
        case mode2, encodeParentDirectoryName2, directory2
        case mode3, encodeParentDirectoryName3, directory3
        case isDeleteOriginalAfterEncode
    }

    public init(
        mode1: String? = nil,
        encodeParentDirectoryName1: String? = nil,
        directory1: String? = nil,
        mode2: String? = nil,
        encodeParentDirectoryName2: String? = nil,
        directory2: String? = nil,
        mode3: String? = nil,
        encodeParentDirectoryName3: String? = nil,
        directory3: String? = nil,
        isDeleteOriginalAfterEncode: Bool = false
    ) {
        self.mode1 = mode1
        self.encodeParentDirectoryName1 = encodeParentDirectoryName1
        self.directory1 = directory1
        self.mode2 = mode2
        self.encodeParentDirectoryName2 = encodeParentDirectoryName2
        self.directory2 = directory2
        self.mode3 = mode3
        self.encodeParentDirectoryName3 = encodeParentDirectoryName3
        self.directory3 = directory3
        self.isDeleteOriginalAfterEncode = isDeleteOriginalAfterEncode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The manual-reserve checker tests typeof(value) against undefined.
        // JSON null therefore looks like a supplied encode mode/directory and
        // can be rejected.  Omission is also the server's clear-on-edit
        // representation, so only configured values belong in the payload.
        try container.encodeIfPresent(mode1, forKey: .mode1)
        try container.encodeIfPresent(encodeParentDirectoryName1, forKey: .encodeParentDirectoryName1)
        try container.encodeIfPresent(directory1, forKey: .directory1)
        try container.encodeIfPresent(mode2, forKey: .mode2)
        try container.encodeIfPresent(encodeParentDirectoryName2, forKey: .encodeParentDirectoryName2)
        try container.encodeIfPresent(directory2, forKey: .directory2)
        try container.encodeIfPresent(mode3, forKey: .mode3)
        try container.encodeIfPresent(encodeParentDirectoryName3, forKey: .encodeParentDirectoryName3)
        try container.encodeIfPresent(directory3, forKey: .directory3)
        try container.encode(isDeleteOriginalAfterEncode, forKey: .isDeleteOriginalAfterEncode)
    }

    fileprivate func validate() throws {
        let strings = [
            mode1, encodeParentDirectoryName1, directory1,
            mode2, encodeParentDirectoryName2, directory2,
            mode3, encodeParentDirectoryName3, directory3
        ]
        guard strings.allSatisfy({
            $0.map { EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) } ?? true
        }) else {
            throw EPGStationWriteError.invalidRequest
        }
    }
}

/// The edit fields shared by create and update operations.
public struct EPGStationReservationEditOptions: Codable, Equatable, Sendable {
    public let allowEndLack: Bool
    public let tags: [Int]?
    public let saveOption: EPGStationReservationSaveOption?
    public let encodeOption: EPGStationReservationEncodeOption?

    public init(
        allowEndLack: Bool = false,
        tags: [Int]? = nil,
        saveOption: EPGStationReservationSaveOption? = nil,
        encodeOption: EPGStationReservationEncodeOption? = nil
    ) {
        self.allowEndLack = allowEndLack
        self.tags = tags
        self.saveOption = saveOption
        self.encodeOption = encodeOption
    }

    /// Preserve every editable value from the latest reservation response,
    /// changing only allowEndLack when requested.
    public init(
        preserving reservation: EPGStationReservation,
        allowEndLack: Bool? = nil
    ) {
        let saveOption: EPGStationReservationSaveOption?
        if reservation.parentDirectoryName != nil ||
            reservation.directory != nil ||
            reservation.recordedFormat != nil {
            saveOption = EPGStationReservationSaveOption(
                parentDirectoryName: reservation.parentDirectoryName,
                directory: reservation.directory,
                recordedFormat: reservation.recordedFormat
            )
        } else {
            saveOption = nil
        }

        let encodeOption: EPGStationReservationEncodeOption?
        if reservation.encodeMode1 != nil ||
            reservation.encodeParentDirectoryName1 != nil ||
            reservation.encodeDirectory1 != nil ||
            reservation.encodeMode2 != nil ||
            reservation.encodeParentDirectoryName2 != nil ||
            reservation.encodeDirectory2 != nil ||
            reservation.encodeMode3 != nil ||
            reservation.encodeParentDirectoryName3 != nil ||
            reservation.encodeDirectory3 != nil ||
            reservation.isDeleteOriginalAfterEncode {
            encodeOption = EPGStationReservationEncodeOption(
                mode1: reservation.encodeMode1,
                encodeParentDirectoryName1: reservation.encodeParentDirectoryName1,
                directory1: reservation.encodeDirectory1,
                mode2: reservation.encodeMode2,
                encodeParentDirectoryName2: reservation.encodeParentDirectoryName2,
                directory2: reservation.encodeDirectory2,
                mode3: reservation.encodeMode3,
                encodeParentDirectoryName3: reservation.encodeParentDirectoryName3,
                directory3: reservation.encodeDirectory3,
                isDeleteOriginalAfterEncode: reservation.isDeleteOriginalAfterEncode
            )
        } else {
            encodeOption = nil
        }

        self.init(
            allowEndLack: allowEndLack ?? reservation.allowEndLack,
            tags: reservation.tags,
            saveOption: saveOption,
            encodeOption: encodeOption
        )
    }

    fileprivate func validate() throws {
        guard tags.map({ $0.allSatisfy(EPGStationValueRules.isPositiveIdentifier) }) ?? true else {
            throw EPGStationWriteError.invalidRequest
        }
        try saveOption?.validate()
        try encodeOption?.validate()
    }
}

public extension EPGStationReservation {
    /// Build a safe edit payload from the latest reservation response.
    func editOptions(allowEndLack: Bool? = nil) -> EPGStationReservationEditOptions {
        EPGStationReservationEditOptions(
            preserving: self,
            allowEndLack: allowEndLack
        )
    }
}

/// A time range used when creating a time-specified reservation.
public struct EPGStationReservationTimeSpecifiedOption: Codable, Equatable, Sendable {
    public let name: String
    public let channelID: Int
    public let startAt: Double
    public let endAt: Double

    private enum CodingKeys: String, CodingKey {
        case name
        case channelID = "channelId"
        case startAt, endAt
    }

    public init(
        name: String,
        channelID: Int,
        startAt: Double,
        endAt: Double
    ) {
        self.name = name
        self.channelID = channelID
        self.startAt = startAt
        self.endAt = endAt
    }

    fileprivate func validate() throws {
        guard EPGStationValueRules.isPositiveIdentifier(channelID),
              startAt.isFinite,
              endAt.isFinite,
              startAt >= 0,
              endAt >= startAt,
              startAt.rounded() == startAt,
              endAt.rounded() == endAt,
              endAt <= Double(EPGStationValueRules.maximumSafeJSONInteger),
              EPGStationValueRules.isSafeText(name, maximumBytes: 16 * 1024, allowEmpty: false) else {
            throw EPGStationWriteError.invalidRequest
        }
    }
}

/// The config fields needed to present EPGStation's save and encode choices.
public struct EPGStationConfig: Codable, Equatable, Sendable {
    public let recordedDirectories: [String]
    public let encodeModes: [String]

    private enum CodingKeys: String, CodingKey {
        case recorded
        case encode
    }

    public init(
        recordedDirectories: [String],
        encodeModes: [String]
    ) throws {
        guard Self.isSafeList(recordedDirectories),
              Self.isSafeList(encodeModes) else {
            throw EPGStationError.invalidResponse
        }
        self.recordedDirectories = recordedDirectories
        self.encodeModes = encodeModes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordedDirectories: container.decode([String].self, forKey: .recorded),
            encodeModes: container.decode([String].self, forKey: .encode)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordedDirectories, forKey: .recorded)
        try container.encode(encodeModes, forKey: .encode)
    }

    private static func isSafeList(_ values: [String]) -> Bool {
        values.allSatisfy {
            EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024)
        }
    }
}

/// A channel entry included in a schedule response.
public struct EPGStationScheduleChannel: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let serviceID: Int
    public let networkID: Int
    public let name: String
    public let remoteControlKeyID: Int?
    public let hasLogoData: Bool
    public let channelType: String
    public let type: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case serviceID = "serviceId"
        case networkID = "networkId"
        case name
        case remoteControlKeyID = "remoteControlKeyId"
        case hasLogoData, channelType, type
    }

    public init(
        id: Int,
        serviceID: Int,
        networkID: Int,
        name: String,
        remoteControlKeyID: Int? = nil,
        hasLogoData: Bool,
        channelType: String,
        type: Int? = nil
    ) throws {
        guard EPGStationValueRules.isPositiveIdentifier(id),
              EPGStationValueRules.isPositiveIdentifier(serviceID),
              EPGStationValueRules.isPositiveIdentifier(networkID),
              EPGStationValueRules.isSafeText(name, maximumBytes: 16 * 1024, allowEmpty: false),
              remoteControlKeyID.map({ $0 >= 0 }) ?? true,
              EPGStationValueRules.isSafeText(channelType, maximumBytes: 64, allowEmpty: false) else {
            throw EPGStationError.invalidResponse
        }
        self.id = id
        self.serviceID = serviceID
        self.networkID = networkID
        self.name = name
        self.remoteControlKeyID = remoteControlKeyID
        self.hasLogoData = hasLogoData
        self.channelType = channelType
        self.type = type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(Int.self, forKey: .id),
            serviceID: container.decode(Int.self, forKey: .serviceID),
            networkID: container.decode(Int.self, forKey: .networkID),
            name: container.decode(String.self, forKey: .name),
            remoteControlKeyID: container.decodeIfPresent(Int.self, forKey: .remoteControlKeyID),
            hasLogoData: container.decode(Bool.self, forKey: .hasLogoData),
            channelType: container.decode(String.self, forKey: .channelType),
            type: container.decodeIfPresent(Int.self, forKey: .type)
        )
    }
}

/// A program entry returned for a channel schedule.
public struct EPGStationScheduleProgram: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let channelID: Int
    public let startAt: Double
    public let endAt: Double
    public let isFree: Bool
    public let name: String
    public let description: String?
    public let extended: String?
    /// Structured metadata returned when the schedule request asks for the
    /// raw extended fields.  Unknown fields are deliberately ignored by the
    /// decoder; this value only retains the server's string pairs.
    public let rawExtended: [String: String]?
    public let genre1: Int?
    public let subGenre1: Int?
    public let genre2: Int?
    public let subGenre2: Int?
    public let genre3: Int?
    public let subGenre3: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channelId"
        case startAt, endAt, isFree, name, description, extended
        case rawExtended
        case genre1, subGenre1, genre2, subGenre2, genre3, subGenre3
    }

    public init(
        id: Int,
        channelID: Int,
        startAt: Double,
        endAt: Double,
        isFree: Bool,
        name: String,
        description: String? = nil,
        extended: String? = nil,
        rawExtended: [String: String]? = nil,
        genre1: Int? = nil,
        subGenre1: Int? = nil,
        genre2: Int? = nil,
        subGenre2: Int? = nil,
        genre3: Int? = nil,
        subGenre3: Int? = nil
    ) throws {
        guard EPGStationValueRules.isPositiveIdentifier(id),
              EPGStationValueRules.isPositiveIdentifier(channelID),
              startAt.isFinite,
              endAt.isFinite,
              startAt >= 0,
              endAt >= startAt,
              endAt <= Double(EPGStationValueRules.maximumSafeJSONInteger),
              EPGStationValueRules.isSafeText(name, maximumBytes: 16 * 1024, allowEmpty: false),
              description.map({ EPGStationValueRules.isSafeHumanText($0, maximumBytes: 64 * 1024) }) ?? true,
              extended.map({ EPGStationValueRules.isSafeHumanText($0, maximumBytes: 64 * 1024) }) ?? true,
              rawExtended.map(Self.isValidRawExtended) ?? true,
              Self.isValidGenre(genre1),
              Self.isValidGenre(subGenre1),
              Self.isValidGenre(genre2),
              Self.isValidGenre(subGenre2),
              Self.isValidGenre(genre3),
              Self.isValidGenre(subGenre3) else {
            throw EPGStationError.invalidResponse
        }
        self.id = id
        self.channelID = channelID
        self.startAt = startAt
        self.endAt = endAt
        self.isFree = isFree
        self.name = name
        self.description = description
        self.extended = extended
        self.rawExtended = rawExtended
        self.genre1 = genre1
        self.subGenre1 = subGenre1
        self.genre2 = genre2
        self.subGenre2 = subGenre2
        self.genre3 = genre3
        self.subGenre3 = subGenre3
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(Int.self, forKey: .id),
            channelID: container.decode(Int.self, forKey: .channelID),
            startAt: container.decode(Double.self, forKey: .startAt),
            endAt: container.decode(Double.self, forKey: .endAt),
            isFree: container.decode(Bool.self, forKey: .isFree),
            name: container.decode(String.self, forKey: .name),
            description: container.decodeIfPresent(String.self, forKey: .description),
            extended: container.decodeIfPresent(String.self, forKey: .extended),
            rawExtended: container.decodeIfPresent([String: String].self, forKey: .rawExtended),
            genre1: container.decodeIfPresent(Int.self, forKey: .genre1),
            subGenre1: container.decodeIfPresent(Int.self, forKey: .subGenre1),
            genre2: container.decodeIfPresent(Int.self, forKey: .genre2),
            subGenre2: container.decodeIfPresent(Int.self, forKey: .subGenre2),
            genre3: container.decodeIfPresent(Int.self, forKey: .genre3),
            subGenre3: container.decodeIfPresent(Int.self, forKey: .subGenre3)
        )
    }

    private static func isValidGenre(_ value: Int?) -> Bool {
        value.map { (0...15).contains($0) } ?? true
    }

    private static func isValidRawExtended(_ value: [String: String]) -> Bool {
        // The endpoint is already bounded to 4 MiB.  These per-field and
        // aggregate limits additionally prevent an unexpectedly large
        // dictionary from making the UI or diagnostics expensive while
        // allowing normal EPG text.
        guard value.count <= 256 else { return false }
        let maximumTotalBytes = 512 * 1024
        var totalBytes = 0
        for (heading, text) in value {
            guard EPGStationValueRules.isSafeText(
                heading,
                maximumBytes: 16 * 1024,
                allowEmpty: true
            ),
            EPGStationValueRules.isSafeHumanText(
                text,
                maximumBytes: 64 * 1024
            ) else {
                return false
            }
            let fieldBytes = heading.utf8.count + text.utf8.count
            guard fieldBytes <= maximumTotalBytes - totalBytes else {
                return false
            }
            totalBytes += fieldBytes
        }
        return true
    }
}

/// One channel and its programs from EPGStation's schedule endpoint.
public struct EPGStationSchedule: Codable, Equatable, Sendable {
    public let channel: EPGStationScheduleChannel
    public let programs: [EPGStationScheduleProgram]

    private enum CodingKeys: String, CodingKey {
        case channel, programs
    }

    public init(
        channel: EPGStationScheduleChannel,
        programs: [EPGStationScheduleProgram]
    ) throws {
        var identifiers = Set<Int>(minimumCapacity: programs.count)
        guard programs.allSatisfy({
            $0.channelID == channel.id && identifiers.insert($0.id).inserted
        }) else {
            throw EPGStationError.invalidResponse
        }
        self.channel = channel
        self.programs = programs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            channel: container.decode(EPGStationScheduleChannel.self, forKey: .channel),
            programs: container.decode([EPGStationScheduleProgram].self, forKey: .programs)
        )
    }
}

private struct EPGStationAddedReservationResponse: Decodable {
    let reserveID: Int

    private enum CodingKeys: String, CodingKey {
        case reserveID = "reserveId"
    }
}

private struct EPGStationUpdatedReservationResponse: Decodable {
    let code: Int
    let message: String
}

private struct EPGStationReservationCreateBody: Encodable {
    let programID: Int?
    let timeSpecifiedOption: EPGStationReservationTimeSpecifiedOption?
    let options: EPGStationReservationEditOptions

    private enum CodingKeys: String, CodingKey {
        case programID = "programId"
        case timeSpecifiedOption
        case allowEndLack, tags, saveOption, encodeOption
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(programID, forKey: .programID)
        try container.encodeIfPresent(timeSpecifiedOption, forKey: .timeSpecifiedOption)
        try container.encode(options.allowEndLack, forKey: .allowEndLack)
        try container.encodeIfPresent(options.tags, forKey: .tags)
        try container.encodeIfPresent(options.saveOption, forKey: .saveOption)
        try container.encodeIfPresent(options.encodeOption, forKey: .encodeOption)
    }
}

public extension EPGStationClient {
    /// Create a program-based manual reservation.
    func createReservation(
        programID: Int,
        options: EPGStationReservationEditOptions? = nil
    ) async throws -> Int {
        guard EPGStationValueRules.isPositiveIdentifier(programID) else {
            throw EPGStationWriteError.invalidRequest
        }
        let options = options ?? EPGStationReservationEditOptions()
        try options.validate()
        let body = EPGStationReservationCreateBody(
            programID: programID,
            timeSpecifiedOption: nil,
            options: options
        )
        let data = try await writeJSON(
            endpoint(["api", "reserves"]),
            method: "POST",
            body: body
        )
        do {
            let response = try JSONDecoder().decode(EPGStationAddedReservationResponse.self, from: data)
            guard EPGStationValueRules.isPositiveIdentifier(response.reserveID) else {
                throw EPGStationWriteError.outcomeUnknown
            }
            return response.reserveID
        } catch let error as EPGStationWriteError {
            throw error
        } catch {
            throw EPGStationWriteError.outcomeUnknown
        }
    }

    /// Create a time-specified manual reservation.
    func createTimeSpecifiedReservation(
        name: String,
        channelID: Int,
        startAt: Double,
        endAt: Double,
        options: EPGStationReservationEditOptions? = nil
    ) async throws -> Int {
        let timeOption = EPGStationReservationTimeSpecifiedOption(
            name: name,
            channelID: channelID,
            startAt: startAt,
            endAt: endAt
        )
        try timeOption.validate()
        let options = options ?? EPGStationReservationEditOptions()
        try options.validate()
        let body = EPGStationReservationCreateBody(
            programID: nil,
            timeSpecifiedOption: timeOption,
            options: options
        )
        let data = try await writeJSON(
            endpoint(["api", "reserves"]),
            method: "POST",
            body: body
        )
        do {
            let response = try JSONDecoder().decode(EPGStationAddedReservationResponse.self, from: data)
            guard EPGStationValueRules.isPositiveIdentifier(response.reserveID) else {
                throw EPGStationWriteError.outcomeUnknown
            }
            return response.reserveID
        } catch let error as EPGStationWriteError {
            throw error
        } catch {
            throw EPGStationWriteError.outcomeUnknown
        }
    }

    /// Update only the editable fields of an existing manual reservation.
    func updateReservation(
        id: Int,
        options: EPGStationReservationEditOptions
    ) async throws {
        guard EPGStationValueRules.isPositiveIdentifier(id) else {
            throw EPGStationWriteError.invalidRequest
        }
        try options.validate()
        let data = try await writeJSON(
            endpoint(["api", "reserves", String(id)]),
            method: "PUT",
            body: options
        )
        do {
            let response = try JSONDecoder().decode(EPGStationUpdatedReservationResponse.self, from: data)
            guard response.code == 201,
                  EPGStationValueRules.isSafeText(response.message, maximumBytes: 1024, allowEmpty: false) else {
                throw EPGStationWriteError.outcomeUnknown
            }
        } catch let error as EPGStationWriteError {
            throw error
        } catch {
            throw EPGStationWriteError.outcomeUnknown
        }
    }

    /// Cancel an existing manual reservation.  The server has returned both
    /// empty and JSON success bodies across versions; the caller performs a
    /// readback when it needs to confirm the resulting state.
    func deleteReservation(id: Int) async throws {
        guard EPGStationValueRules.isPositiveIdentifier(id) else {
            throw EPGStationWriteError.invalidRequest
        }
        _ = try await writeData(
            endpoint(["api", "reserves", String(id)]),
            method: "DELETE",
            body: nil
        )
    }

    /// Fetch save-directory and encode-mode choices from EPGStation.
    func config() async throws -> EPGStationConfig {
        let data = try await data(for: endpoint(["api", "config"]))
        do {
            return try JSONDecoder().decode(EPGStationConfig.self, from: data)
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
    }

    /// Fetch a channel's programs for the program chooser.
    func channelSchedule(
        channelID: Int,
        startAt: Double,
        days: Int = 1,
        isHalfWidth: Bool = true,
        needsRawExtended: Bool = false,
        isFree: Bool? = nil
    ) async throws -> [EPGStationSchedule] {
        guard EPGStationValueRules.isPositiveIdentifier(channelID),
              startAt.isFinite,
              startAt >= 0,
              startAt.rounded() == startAt,
              startAt <= Double(EPGStationValueRules.maximumSafeJSONInteger),
              (1...31).contains(days) else {
            throw EPGStationError.invalidRequest
        }
        var queryItems = [
            URLQueryItem(name: "startAt", value: String(Int(startAt))),
            URLQueryItem(name: "days", value: String(days)),
            URLQueryItem(name: "isHalfWidth", value: isHalfWidth ? "true" : "false"),
            URLQueryItem(name: "needsRawExtended", value: needsRawExtended ? "true" : "false")
        ]
        if let isFree {
            queryItems.append(URLQueryItem(name: "isFree", value: isFree ? "true" : "false"))
        }
        let data = try await data(
            for: endpoint(["api", "schedules", String(channelID)], queryItems: queryItems)
        )
        do {
            let schedules = try JSONDecoder().decode([EPGStationSchedule].self, from: data)
            var programIDs = Set<Int>()
            for schedule in schedules {
                guard schedule.channel.id == channelID else {
                    throw EPGStationError.invalidResponse
                }
                for program in schedule.programs {
                    guard programIDs.insert(program.id).inserted else {
                        throw EPGStationError.invalidResponse
                    }
                }
            }
            return schedules
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
    }
}

private extension EPGStationClient {
    func writeJSON(
        _ requestURL: URL,
        method: String,
        body: some Encodable
    ) async throws -> Data {
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(body)
        } catch {
            throw EPGStationWriteError.invalidRequest
        }
        return try await writeData(requestURL, method: method, body: encodedBody)
    }

    func writeData(
        _ requestURL: URL,
        method: String,
        body: Data?
    ) async throws -> Data {
        do {
            return try await data(for: requestURL, method: method, body: body)
        } catch let error as EPGStationError {
            switch error {
            case .httpStatus(let status) where status >= 500:
                throw EPGStationWriteError.outcomeUnknown
            case .transport, .responseTooLarge:
                throw EPGStationWriteError.outcomeUnknown
            case .httpStatus(let status):
                throw EPGStationWriteError.httpStatus(status)
            case .invalidAddress, .invalidIdentifier, .invalidRequest:
                throw EPGStationWriteError.invalidRequest
            case .invalidResponse:
                throw EPGStationWriteError.outcomeUnknown
            case .redirectRejected:
                throw EPGStationWriteError.outcomeUnknown
            }
        } catch is CancellationError {
            throw EPGStationWriteError.outcomeUnknown
        } catch {
            throw EPGStationWriteError.outcomeUnknown
        }
    }
}
