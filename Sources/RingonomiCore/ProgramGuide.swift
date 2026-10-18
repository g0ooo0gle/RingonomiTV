import Foundation

// MARK: - Program guide models

/// A genre attached to an EPG program.
public struct GuideGenre: Decodable, Sendable, Equatable {
    public let major: String
    public let middle: String

    public init(major: String = "", middle: String = "") {
        self.major = major
        self.middle = middle
    }

    private enum CodingKeys: String, CodingKey {
        case major, middle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        major = container.decodeLossyString(forKey: .major)
        middle = container.decodeLossyString(forKey: .middle)
    }
}

/// Reservation metadata supplied by EDCB-backed program-guide responses.
/// Unknown status strings are intentionally kept as strings so a server-side
/// addition does not make the whole guide unreadable.
public struct GuideProgramReservation: Decodable, Sendable, Equatable {
    public let id: Int?
    public let status: String
    public let recordingAvailability: String

    public init(id: Int? = nil, status: String = "", recordingAvailability: String = "") {
        self.id = id
        self.status = status
        self.recordingAvailability = recordingAvailability
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, recordingAvailability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyInt(forKey: .id)
        status = container.decodeLossyString(forKey: .status)
        recordingAvailability = container.decodeLossyString(forKey: .recordingAvailability)
    }
}

/// A channel as returned inside the timetable endpoint.
public struct GuideChannel: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let displayChannelId: String
    public let networkId: Int?
    public let serviceId: Int?
    public let transportStreamId: Int?
    public let remoconId: Int?
    public let channelNumber: String
    public let type: String
    public let name: String
    public let terrestrialRegions: [String]
    public let jikkyoForce: Int?
    public let isSubchannel: Bool
    public let isRadiochannel: Bool
    public let isWatchable: Bool
    public let isDisplay: Bool

    public init(
        id: String = "",
        displayChannelId: String = "",
        networkId: Int? = nil,
        serviceId: Int? = nil,
        transportStreamId: Int? = nil,
        remoconId: Int? = nil,
        channelNumber: String = "",
        type: String = "",
        name: String = "",
        terrestrialRegions: [String] = [],
        jikkyoForce: Int? = nil,
        isSubchannel: Bool = false,
        isRadiochannel: Bool = false,
        isWatchable: Bool = false,
        isDisplay: Bool = false
    ) {
        self.id = id
        self.displayChannelId = displayChannelId
        self.networkId = networkId
        self.serviceId = serviceId
        self.transportStreamId = transportStreamId
        self.remoconId = remoconId
        self.channelNumber = channelNumber
        self.type = type
        self.name = name
        self.terrestrialRegions = terrestrialRegions
        self.jikkyoForce = jikkyoForce
        self.isSubchannel = isSubchannel
        self.isRadiochannel = isRadiochannel
        self.isWatchable = isWatchable
        self.isDisplay = isDisplay
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayChannelId
        case networkId
        case serviceId
        case transportStreamId
        case remoconId
        case channelNumber
        case type, name
        case terrestrialRegions
        case jikkyoForce
        case isSubchannel
        case isRadiochannel
        case isWatchable
        // This field is present in /api/channels and older timetable payloads.
        case isDisplay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id)
        displayChannelId = container.decodeLossyString(forKey: .displayChannelId)
        networkId = container.decodeLossyInt(forKey: .networkId)
        serviceId = container.decodeLossyInt(forKey: .serviceId)
        transportStreamId = container.decodeLossyInt(forKey: .transportStreamId)
        remoconId = container.decodeLossyInt(forKey: .remoconId)
        channelNumber = container.decodeLossyString(forKey: .channelNumber)
        type = container.decodeLossyString(forKey: .type)
        name = container.decodeLossyString(forKey: .name)
        terrestrialRegions = container.decodeLossyStringArray(forKey: .terrestrialRegions)
        jikkyoForce = container.decodeLossyInt(forKey: .jikkyoForce)
        isSubchannel = container.decodeLossyBool(forKey: .isSubchannel)
        isRadiochannel = container.decodeLossyBool(forKey: .isRadiochannel)
        isWatchable = container.decodeLossyBool(forKey: .isWatchable)
        isDisplay = container.decodeLossyBool(forKey: .isDisplay)
    }
}

/// One EPG entry. Invalid or missing timestamps are represented by nil and do
/// not prevent the other entries in the response from being shown.
public struct GuideProgram: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let channelId: String
    public let networkId: Int?
    public let serviceId: Int?
    public let eventId: Int?
    public let title: String
    public let description: String
    public let detail: [String: String]
    public let startDate: Date?
    public let endDate: Date?
    public let duration: Double
    public let isFree: Bool
    public let genres: [GuideGenre]
    public let videoType: String?
    public let videoCodec: String?
    public let videoResolution: String?
    public let primaryAudioType: String
    public let primaryAudioLanguage: String
    public let primaryAudioSamplingRate: String
    public let secondaryAudioType: String?
    public let secondaryAudioLanguage: String?
    public let secondaryAudioSamplingRate: String?
    public let reservation: GuideProgramReservation?

    public init(
        id: String = "",
        channelId: String = "",
        networkId: Int? = nil,
        serviceId: Int? = nil,
        eventId: Int? = nil,
        title: String = "",
        description: String = "",
        detail: [String: String] = [:],
        startDate: Date? = nil,
        endDate: Date? = nil,
        duration: Double = 0,
        isFree: Bool = false,
        genres: [GuideGenre] = [],
        videoType: String? = nil,
        videoCodec: String? = nil,
        videoResolution: String? = nil,
        primaryAudioType: String = "",
        primaryAudioLanguage: String = "",
        primaryAudioSamplingRate: String = "",
        secondaryAudioType: String? = nil,
        secondaryAudioLanguage: String? = nil,
        secondaryAudioSamplingRate: String? = nil,
        reservation: GuideProgramReservation? = nil
    ) {
        self.id = id
        self.channelId = channelId
        self.networkId = networkId
        self.serviceId = serviceId
        self.eventId = eventId
        self.title = title
        self.description = description
        self.detail = detail
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.isFree = isFree
        self.genres = genres
        self.videoType = videoType
        self.videoCodec = videoCodec
        self.videoResolution = videoResolution
        self.primaryAudioType = primaryAudioType
        self.primaryAudioLanguage = primaryAudioLanguage
        self.primaryAudioSamplingRate = primaryAudioSamplingRate
        self.secondaryAudioType = secondaryAudioType
        self.secondaryAudioLanguage = secondaryAudioLanguage
        self.secondaryAudioSamplingRate = secondaryAudioSamplingRate
        self.reservation = reservation
    }

    private enum CodingKeys: String, CodingKey {
        case id, channelId, networkId, serviceId
        case eventId, title, description, detail
        case startTime, endTime, duration
        case isFree, genres
        case videoType, videoCodec, videoResolution
        case primaryAudioType, primaryAudioLanguage, primaryAudioSamplingRate
        case secondaryAudioType, secondaryAudioLanguage, secondaryAudioSamplingRate
        case reservation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyString(forKey: .id)
        channelId = container.decodeLossyString(forKey: .channelId)
        networkId = container.decodeLossyInt(forKey: .networkId)
        serviceId = container.decodeLossyInt(forKey: .serviceId)
        eventId = container.decodeLossyInt(forKey: .eventId)
        title = container.decodeLossyString(forKey: .title)
        description = container.decodeLossyString(forKey: .description)
        detail = container.decodeLossyStringDictionary(forKey: .detail)
        startDate = GuideDate.parse(container.decodeLossyStringOptional(forKey: .startTime))
        endDate = GuideDate.parse(container.decodeLossyStringOptional(forKey: .endTime))
        duration = container.decodeLossyDouble(forKey: .duration)
        isFree = container.decodeLossyBool(forKey: .isFree)
        genres = container.decodeLossyArray(forKey: .genres)
        videoType = container.decodeLossyStringOptional(forKey: .videoType)
        videoCodec = container.decodeLossyStringOptional(forKey: .videoCodec)
        videoResolution = container.decodeLossyStringOptional(forKey: .videoResolution)
        primaryAudioType = container.decodeLossyString(forKey: .primaryAudioType)
        primaryAudioLanguage = container.decodeLossyString(forKey: .primaryAudioLanguage)
        primaryAudioSamplingRate = container.decodeLossyString(forKey: .primaryAudioSamplingRate)
        secondaryAudioType = container.decodeLossyStringOptional(forKey: .secondaryAudioType)
        secondaryAudioLanguage = container.decodeLossyStringOptional(forKey: .secondaryAudioLanguage)
        secondaryAudioSamplingRate = container.decodeLossyStringOptional(forKey: .secondaryAudioSamplingRate)
        reservation = container.decodeLossyOptional(forKey: .reservation)
    }
}

/// A channel and its programs as returned by the timetable endpoint.
public struct GuideChannelPrograms: Decodable, Sendable, Equatable {
    public let channel: GuideChannel
    public let programs: [GuideProgram]
    public let subchannels: [GuideChannelPrograms]

    public init(channel: GuideChannel = GuideChannel(), programs: [GuideProgram] = [], subchannels: [GuideChannelPrograms] = []) {
        self.channel = channel
        self.programs = programs
        self.subchannels = subchannels
    }

    private enum CodingKeys: String, CodingKey {
        case channel, programs, subchannels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = container.decodeLossyValue(forKey: .channel, default: GuideChannel())
        programs = container.decodeLossyArray(forKey: .programs)
        subchannels = container.decodeLossyArray(forKey: .subchannels)
    }

    /// Returns this channel followed by any nested subchannels in display
    /// order. The API uses subchannels for one-seg/secondary services.
    public var flattenedChannels: [GuideChannelPrograms] {
        [self] + subchannels.flatMap { $0.flattenedChannels }
    }
}

public struct ProgramGuideDateRange: Decodable, Sendable, Equatable {
    public let earliest: Date?
    public let latest: Date?

    public init(earliest: Date? = nil, latest: Date? = nil) {
        self.earliest = earliest
        self.latest = latest
    }

    private enum CodingKeys: String, CodingKey { case earliest, latest }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        earliest = GuideDate.parse(container.decodeLossyStringOptional(forKey: .earliest))
        latest = GuideDate.parse(container.decodeLossyStringOptional(forKey: .latest))
    }
}

public struct ProgramGuideResponse: Decodable, Sendable, Equatable {
    public let channels: [GuideChannelPrograms]
    public let dateRange: ProgramGuideDateRange?

    public init(channels: [GuideChannelPrograms] = [], dateRange: ProgramGuideDateRange? = nil) {
        self.channels = channels
        self.dateRange = dateRange
    }

    private enum CodingKeys: String, CodingKey { case channels, dateRange }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channels = container.decodeLossyArray(forKey: .channels)
        dateRange = container.decodeLossyOptional(forKey: .dateRange)
    }

    /// A flat view for guide rows and local search while preserving the
    /// response's channel-first ordering.
    public var flattenedChannels: [GuideChannelPrograms] {
        channels.flatMap { $0.flattenedChannels }
    }
}

// MARK: - Local search

/// A search result keeps the channel alongside the program, which avoids a
/// second lookup in a tvOS focus/detail view.
public struct GuideProgramSearchResult: Sendable, Equatable {
    public let program: GuideProgram
    public let channel: GuideChannel

    public init(program: GuideProgram, channel: GuideChannel) {
        self.program = program
        self.channel = channel
    }
}

/// Searches future programs already held in memory. Comma/読点 separates OR
/// groups; whitespace inside a group is AND. Empty queries return all future
/// entries. Invalid start times are ignored safely.
public func searchFuturePrograms(
    _ query: String,
    in response: ProgramGuideResponse,
    now: Date = Date()
) -> [GuideProgramSearchResult] {
    let groups = GuideSearchTerms.groups(from: query)
    var seen = Set<String>()
    var results: [GuideProgramSearchResult] = []

    for group in response.flattenedChannels {
        for program in group.programs {
            guard let startDate = program.startDate, startDate >= now else { continue }
            let searchable = GuideSearchTerms.normalize("\(group.channel.name) \(program.title) \(program.description)")
            let matches = groups.isEmpty || groups.contains { terms in
                terms.allSatisfy { searchable.contains($0) }
            }
            guard matches else { continue }

            // A backend can repeat the same program while joining subchannels;
            // retain one result per channel/program identity.
            let identity = "\(group.channel.id)\u{1F}\(program.id)"
            guard seen.insert(identity).inserted else { continue }
            results.append(GuideProgramSearchResult(program: program, channel: group.channel))
        }
    }

    return results.sorted {
        let lhs = $0.program.startDate ?? .distantFuture
        let rhs = $1.program.startDate ?? .distantFuture
        if lhs != rhs { return lhs < rhs }
        if $0.channel.id != $1.channel.id { return $0.channel.id < $1.channel.id }
        return $0.program.id < $1.program.id
    }
}

public func searchFuturePrograms(
    query: String,
    in response: ProgramGuideResponse,
    now: Date = Date()
) -> [GuideProgramSearchResult] {
    searchFuturePrograms(query, in: response, now: now)
}

// MARK: - API client

public extension RingonomiClient {
    /// Builds the timetable URL without making a request. Keeping this public
    /// makes query construction testable without a live server.
    func programGuideURL(
        start: Date? = nil,
        end: Date? = nil,
        type: String? = nil,
        pinnedChannelIDs: [String]? = nil
    ) -> URL {
        let base = endpoint(["api", "programs", "timetable"])
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }

        var query: [URLQueryItem] = []
        if let start { query.append(URLQueryItem(name: "start_time", value: GuideDate.format(start))) }
        if let end { query.append(URLQueryItem(name: "end_time", value: GuideDate.format(end))) }
        if let type, !type.isEmpty { query.append(URLQueryItem(name: "channel_type", value: type)) }
        let pinned = pinnedChannelIDs?.filter { !$0.isEmpty }.joined(separator: ",")
        if let pinned, !pinned.isEmpty {
            query.append(URLQueryItem(name: "pinned_channel_ids", value: pinned))
        }
        components.queryItems = query.isEmpty ? nil : query
        return components.url ?? base
    }

    func programGuide(
        start: Date? = nil,
        end: Date? = nil,
        type: String? = nil,
        pinnedChannelIDs: [String]? = nil,
        using session: URLSession = .shared
    ) async throws -> ProgramGuideResponse {
        try await fetchWithQuery(
            ["api", "programs", "timetable"],
            queryItems: URLComponents(url: programGuideURL(start: start, end: end, type: type, pinnedChannelIDs: pinnedChannelIDs), resolvingAgainstBaseURL: false)?.queryItems ?? [],
            as: ProgramGuideResponse.self,
            using: session
        )
    }
}

private extension RingonomiClient {
    func fetchWithQuery<T: Decodable & Sendable>(
        _ path: [String],
        queryItems: [URLQueryItem],
        as type: T.Type,
        using session: URLSession
    ) async throws -> T {
        guard var components = URLComponents(url: endpoint(path), resolvingAgainstBaseURL: false) else {
            throw ConnectionError.invalidAddress
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw ConnectionError.invalidAddress }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await backendData(for: request, using: session)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.http(0) }
        guard (200..<300).contains(response.statusCode) else { throw ConnectionError.http(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Defensive decoding helpers

private enum GuideDate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private enum GuideSearchTerms {
    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }

    static func groups(from query: String) -> [[String]] {
        query
            .split(whereSeparator: { $0 == "," || $0 == "、" })
            .map { part in
                part.split(whereSeparator: { $0.isWhitespace })
                    .map { normalize(String($0)) }
                    .filter { !$0.isEmpty }
            }
            .filter { !$0.isEmpty }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: Key) -> String {
        decodeLossyStringOptional(forKey: key) ?? ""
    }

    func decodeLossyStringOptional(forKey key: Key) -> String? {
        do { return try decodeIfPresent(String.self, forKey: key) } catch { return nil }
    }

    func decodeLossyInt(forKey key: Key) -> Int? {
        do { return try decodeIfPresent(Int.self, forKey: key) } catch { return nil }
    }

    func decodeLossyDouble(forKey key: Key) -> Double {
        do { return try decodeIfPresent(Double.self, forKey: key) ?? 0 } catch { return 0 }
    }

    func decodeLossyBool(forKey key: Key) -> Bool {
        do { return try decodeIfPresent(Bool.self, forKey: key) ?? false } catch { return false }
    }

    func decodeLossyStringArray(forKey key: Key) -> [String] {
        do { return try decodeIfPresent([String].self, forKey: key) ?? [] } catch { return [] }
    }

    func decodeLossyStringDictionary(forKey key: Key) -> [String: String] {
        do { return try decodeIfPresent([String: String].self, forKey: key) ?? [:] } catch { return [:] }
    }

    func decodeLossyArray<T: Decodable & Sendable>(forKey key: Key) -> [T] {
        do { return try decodeIfPresent([T].self, forKey: key) ?? [] } catch { return [] }
    }

    func decodeLossyValue<T: Decodable & Sendable>(forKey key: Key, default value: T) -> T {
        do { return try decodeIfPresent(T.self, forKey: key) ?? value } catch { return value }
    }

    func decodeLossyOptional<T: Decodable & Sendable>(forKey key: Key) -> T? {
        do { return try decodeIfPresent(T.self, forKey: key) } catch { return nil }
    }
}
