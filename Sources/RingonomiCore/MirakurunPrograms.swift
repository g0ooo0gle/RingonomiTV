import Foundation

/// A genre record from Mirakurun's EPG program response.
public struct MirakurunProgramGenre: Decodable, Equatable, Sendable {
    public let lv1: Int?
    public let lv2: Int?
    public let un1: Int?
    public let un2: Int?

    public init(
        lv1: Int? = nil,
        lv2: Int? = nil,
        un1: Int? = nil,
        un2: Int? = nil
    ) {
        self.lv1 = Self.safeNumber(lv1)
        self.lv2 = Self.safeNumber(lv2)
        self.un1 = Self.safeNumber(un1)
        self.un2 = Self.safeNumber(un2)
    }

    private enum CodingKeys: String, CodingKey {
        case lv1, lv2, un1, un2
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lv1: try? container.decodeIfPresent(Int.self, forKey: .lv1),
            lv2: try? container.decodeIfPresent(Int.self, forKey: .lv2),
            un1: try? container.decodeIfPresent(Int.self, forKey: .un1),
            un2: try? container.decodeIfPresent(Int.self, forKey: .un2)
        )
    }

    private static func safeNumber(_ value: Int?) -> Int? {
        guard let value,
              value >= 0,
              value <= MirakurunProgramLimits.maximumSafeJSONInteger else {
            return nil
        }
        return value
    }
}

/// Optional video metadata attached to a Mirakurun program.
public struct MirakurunProgramVideo: Decodable, Equatable, Sendable {
    public let type: String?
    public let resolution: String?
    public let streamContent: Int?
    public let componentType: Int?

    public init(
        type: String? = nil,
        resolution: String? = nil,
        streamContent: Int? = nil,
        componentType: Int? = nil
    ) {
        self.type = MirakurunProgramLimits.safeText(type, maximumBytes: 128)
        self.resolution = MirakurunProgramLimits.safeText(resolution, maximumBytes: 64)
        self.streamContent = MirakurunProgramLimits.safeNumber(streamContent)
        self.componentType = MirakurunProgramLimits.safeNumber(componentType)
    }

    private enum CodingKeys: String, CodingKey {
        case type, resolution, streamContent, componentType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: MirakurunProgramLimits.decodeString(container, forKey: .type, maximumBytes: 128),
            resolution: MirakurunProgramLimits.decodeString(container, forKey: .resolution, maximumBytes: 64),
            streamContent: MirakurunProgramLimits.decodeNumber(container, forKey: .streamContent),
            componentType: MirakurunProgramLimits.decodeNumber(container, forKey: .componentType)
        )
    }
}

/// Optional audio metadata attached to a Mirakurun program.
public struct MirakurunProgramAudio: Decodable, Equatable, Sendable {
    public let componentType: Int?
    public let componentTag: Int?
    public let isMain: Bool?
    public let samplingRate: Int?
    public let langs: [String]

    public init(
        componentType: Int? = nil,
        componentTag: Int? = nil,
        isMain: Bool? = nil,
        samplingRate: Int? = nil,
        langs: [String] = []
    ) {
        self.componentType = MirakurunProgramLimits.safeNumber(componentType)
        self.componentTag = MirakurunProgramLimits.safeNumber(componentTag)
        self.isMain = isMain
        self.samplingRate = MirakurunProgramLimits.safeNumber(samplingRate)
        self.langs = langs.compactMap {
            MirakurunProgramLimits.safeText($0, maximumBytes: 32, allowEmpty: false)
        }
        .prefix(MirakurunProgramLimits.maximumLanguageCount)
        .map { $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case componentType, componentTag, isMain, samplingRate, langs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawLanguages = (try? container.decodeIfPresent([String].self, forKey: .langs)) ?? nil
        self.init(
            componentType: MirakurunProgramLimits.decodeNumber(container, forKey: .componentType),
            componentTag: MirakurunProgramLimits.decodeNumber(container, forKey: .componentTag),
            isMain: try? container.decodeIfPresent(Bool.self, forKey: .isMain),
            samplingRate: MirakurunProgramLimits.decodeNumber(container, forKey: .samplingRate),
            langs: rawLanguages ?? []
        )
    }
}

/// One EPG program returned by Mirakurun's `/api/programs` endpoint.
///
/// The seven fields required by Mirakurun's Swagger definition are decoded
/// strictly. Optional descriptive and technical fields are bounded and may be
/// absent or malformed without making the whole program list unusable.
public struct MirakurunProgram: Decodable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let eventID: Int
    public let serviceID: Int
    public let networkID: Int
    /// Unix time in milliseconds.
    public let startAt: Double
    /// Duration in milliseconds.
    public let duration: Double
    public let isFree: Bool
    public let name: String?
    public let description: String?
    /// The API exposes this as an open object. String-valued fields are kept;
    /// unsupported nested values are treated as absent.
    public let extended: [String: String]?
    public let genres: [MirakurunProgramGenre]
    public let video: MirakurunProgramVideo?
    public let audios: [MirakurunProgramAudio]

    public var endAt: Double { startAt + duration }

    public init(
        id: Int,
        eventID: Int,
        serviceID: Int,
        networkID: Int,
        startAt: Double,
        duration: Double,
        isFree: Bool,
        name: String? = nil,
        description: String? = nil,
        extended: [String: String]? = nil,
        genres: [MirakurunProgramGenre] = [],
        video: MirakurunProgramVideo? = nil,
        audios: [MirakurunProgramAudio] = []
    ) throws {
        guard MirakurunProgramLimits.isValidProgramID(id),
              MirakurunProgramLimits.isValidIdentifier(eventID),
              MirakurunProgramLimits.isValidIdentifier(serviceID),
              MirakurunProgramLimits.isValidIdentifier(networkID),
              MirakurunProgramLimits.isSafeMilliseconds(startAt),
              MirakurunProgramLimits.isSafeMilliseconds(duration),
              MirakurunProgramLimits.safeEnd(startAt: startAt, duration: duration) != nil,
              MirakurunProgramLimits.isSafeOptionalText(name, maximumBytes: 64 * 1024),
              MirakurunProgramLimits.isSafeOptionalText(description, maximumBytes: 64 * 1024),
              MirakurunProgramLimits.isSafeExtended(extended),
              genres.count <= MirakurunProgramLimits.maximumGenreCount,
              audios.count <= MirakurunProgramLimits.maximumAudioCount else {
            throw MirakurunError.invalidResponse
        }
        self.id = id
        self.eventID = eventID
        self.serviceID = serviceID
        self.networkID = networkID
        self.startAt = startAt
        self.duration = duration
        self.isFree = isFree
        self.name = name
        self.description = description
        self.extended = extended
        self.genres = genres
        self.video = video
        self.audios = audios
    }

    private enum CodingKeys: String, CodingKey {
        case id, eventID = "eventId", serviceID = "serviceId", networkID = "networkId"
        case startAt, duration, isFree, name, description, extended, genres, video, audios
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = MirakurunProgramLimits.decodeString(container, forKey: .name, maximumBytes: 64 * 1024)
        let description = MirakurunProgramLimits.decodeString(
            container,
            forKey: .description,
            maximumBytes: 64 * 1024
        )
        let extended = MirakurunProgramLimits.decodeExtended(container, forKey: .extended)
        let genres = (try? container.decodeIfPresent([MirakurunProgramGenre].self, forKey: .genres)) ?? nil
        let video = (try? container.decodeIfPresent(MirakurunProgramVideo.self, forKey: .video)) ?? nil
        let audios = (try? container.decodeIfPresent([MirakurunProgramAudio].self, forKey: .audios)) ?? nil

        try self.init(
            id: container.decode(Int.self, forKey: .id),
            eventID: container.decode(Int.self, forKey: .eventID),
            serviceID: container.decode(Int.self, forKey: .serviceID),
            networkID: container.decode(Int.self, forKey: .networkID),
            startAt: container.decode(Double.self, forKey: .startAt),
            duration: container.decode(Double.self, forKey: .duration),
            isFree: container.decode(Bool.self, forKey: .isFree),
            name: name,
            description: description,
            extended: extended,
            genres: genres ?? [],
            video: video,
            audios: audios ?? []
        )
    }
}

public extension MirakurunClient {
    /// Fetch programs for one service through Mirakurun's anonymous EPG API.
    /// The query is intentionally limited to networkId and serviceId so the
    /// result can be validated against the requested service identity.
    func programs(
        for key: MirakurunServiceKey,
        using suppliedSession: URLSession? = nil
    ) async throws -> [MirakurunProgram] {
        try Task.checkCancellation()
        let queryItems = [
            URLQueryItem(name: "networkId", value: String(key.networkID)),
            URLQueryItem(name: "serviceId", value: String(key.serviceID))
        ]
        let data = try await data(
            for: endpoint(["api", "programs"], queryItems: queryItems),
            using: suppliedSession,
            maximumBytes: MirakurunClient.maximumProgramResponseBytes
        )
        try Task.checkCancellation()

        let programs: [MirakurunProgram]
        do {
            programs = try JSONDecoder().decode([MirakurunProgram].self, from: data)
        } catch let error as MirakurunError {
            throw error
        } catch {
            throw MirakurunError.invalidResponse
        }
        guard programs.count <= MirakurunClient.maximumProgramCount else {
            throw MirakurunError.invalidResponse
        }

        var identifiers = Set<Int>(minimumCapacity: programs.count)
        guard programs.allSatisfy({
            identifiers.insert($0.id).inserted &&
            $0.networkID == key.networkID &&
            $0.serviceID == key.serviceID
        }) else {
            throw MirakurunError.invalidResponse
        }
        return programs
    }
}

private enum MirakurunProgramLimits {
    static let maximumSafeJSONInteger = 9_007_199_254_740_991
    static let maximumProgramID = 655_356_553_565_535
    static let maximumGenreCount = 64
    static let maximumAudioCount = 64
    static let maximumLanguageCount = 16
    static let maximumExtendedFields = 256
    static let maximumExtendedBytes = 512 * 1024

    static func isValidIdentifier(_ value: Int) -> Bool {
        (0...65_535).contains(value)
    }

    static func isValidProgramID(_ value: Int) -> Bool {
        (0...maximumProgramID).contains(value)
    }

    static func isSafeMilliseconds(_ value: Double) -> Bool {
        value.isFinite && value.rounded() == value &&
            value >= 0 && value <= Double(maximumSafeJSONInteger)
    }

    static func safeEnd(startAt: Double, duration: Double) -> Double? {
        let end = startAt + duration
        guard end.isFinite,
              end >= startAt,
              end <= Double(maximumSafeJSONInteger) else {
            return nil
        }
        return end
    }

    static func safeText(
        _ value: String?,
        maximumBytes: Int,
        allowEmpty: Bool = true
    ) -> String? {
        guard let value,
              (allowEmpty || !value.isEmpty),
              value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        return value
    }

    static func isSafeOptionalText(_ value: String?, maximumBytes: Int) -> Bool {
        value == nil || safeText(value, maximumBytes: maximumBytes) != nil
    }

    static func safeNumber(_ value: Int?) -> Int? {
        guard let value,
              value >= 0,
              value <= maximumSafeJSONInteger else {
            return nil
        }
        return value
    }

    static func decodeString<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K,
        maximumBytes: Int
    ) -> String? {
        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return safeText(value, maximumBytes: maximumBytes)
    }

    static func decodeNumber<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> Int? {
        safeNumber(try? container.decodeIfPresent(Int.self, forKey: key))
    }

    static func decodeExtended<K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> [String: String]? {
        guard let value = try? container.decodeIfPresent([String: String].self, forKey: key) else {
            return nil
        }
        return isSafeExtended(value) ? value : nil
    }

    static func isSafeExtended(_ value: [String: String]?) -> Bool {
        guard let value else { return true }
        guard value.count <= maximumExtendedFields else { return false }
        var totalBytes = 0
        for (key, text) in value {
            guard safeText(key, maximumBytes: 16 * 1024) != nil,
                  safeText(text, maximumBytes: 64 * 1024) != nil else {
                return false
            }
            let bytes = key.utf8.count + text.utf8.count
            guard bytes <= maximumExtendedBytes - totalBytes else { return false }
            totalBytes += bytes
        }
        return true
    }
}
