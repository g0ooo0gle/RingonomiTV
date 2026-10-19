import Foundation

public struct Program: Decodable, Sendable {
    public let id: String
    public let title: String
    public let description: String
}
public struct Channel: Decodable, Identifiable, Sendable {
    public let id: String
    public let displayChannelId: String
    public let name: String
    public let isWatchable: Bool
    public let isDisplay: Bool
    public let programPresent: Program?
    /// Optional metadata retained for local broadcast-family filtering. Older
    /// channel responses may omit both fields.
    public let type: String?
    public let channelNumber: String?
}
/// Channel metadata embedded in a recorded-program response.
///
/// This is intentionally separate from the live `Channel` model because the
/// recorded-program API does not include the live-only display/program fields.
public struct RecordingChannel: Decodable, Identifiable, Sendable {
    public let id: String
    public let displayChannelId: String
    public let networkId: Int?
    public let serviceId: Int?
    public let transportStreamId: Int?
    public let remoconId: Int?
    public let channelNumber: String
    public let type: String
    public let name: String
    public let terrestrialRegions: [String]?
    public let jikkyoForce: Int?
    public let isSubchannel: Bool
    public let isRadiochannel: Bool
    public let isWatchable: Bool

    private enum CodingKeys: String, CodingKey {
        case id, displayChannelId, networkId, serviceId, transportStreamId
        case remoconId, channelNumber, type, name, terrestrialRegions
        case jikkyoForce, isSubchannel, isRadiochannel, isWatchable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "recording channel id must not be empty"
            )
        }
        self.id = id
        displayChannelId = (try? container.decode(String.self, forKey: .displayChannelId)) ?? ""
        networkId = try? container.decode(Int.self, forKey: .networkId)
        serviceId = try? container.decode(Int.self, forKey: .serviceId)
        transportStreamId = try? container.decode(Int.self, forKey: .transportStreamId)
        remoconId = try? container.decode(Int.self, forKey: .remoconId)
        channelNumber = (try? container.decode(String.self, forKey: .channelNumber)) ?? ""
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        terrestrialRegions = try? container.decode([String].self, forKey: .terrestrialRegions)
        jikkyoForce = try? container.decode(Int.self, forKey: .jikkyoForce)
        isSubchannel = (try? container.decode(Bool.self, forKey: .isSubchannel)) ?? false
        isRadiochannel = (try? container.decode(Bool.self, forKey: .isRadiochannel)) ?? false
        isWatchable = (try? container.decode(Bool.self, forKey: .isWatchable)) ?? false
    }
}

public struct Recording: Decodable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let description: String
    public let recordedVideo: RecordedVideo
    public let isFree: Bool
    /// Program start time, used to distinguish reused recorded-video IDs.
    /// Older server responses may omit this field.
    public let startTime: String?
    /// True when the source recording did not cover the complete program.
    /// Older server responses may omit this field.
    public let isPartiallyRecorded: Bool?
    public let endTime: String?
    public let channel: RecordingChannel?
    public let networkId: Int?
    public let serviceId: Int?
    public let eventId: Int?
    public let seriesId: Int?
    public let seriesBroadcastPeriodId: Int?
    public let seriesTitle: String?
    public let episodeNumber: String?
    public let subtitle: String?
    public let detail: [String: String]?
    public let genres: [GuideGenre]

    private enum CodingKeys: String, CodingKey {
        case id, title, description, recordedVideo, isFree
        case startTime, endTime, isPartiallyRecorded, channel
        case networkId, serviceId, eventId, seriesId, seriesBroadcastPeriodId
        case seriesTitle, episodeNumber, subtitle, detail, genres
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(Int.self, forKey: .id)
        guard id > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "recording id must be positive"
            )
        }
        self.id = id
        // The media object and the basic program classification are required
        // for playback and access-control decisions.  Additional metadata
        // below is intentionally defensive because older list responses can
        // omit it.
        recordedVideo = try container.decode(RecordedVideo.self, forKey: .recordedVideo)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        isFree = try container.decode(Bool.self, forKey: .isFree)
        startTime = try? container.decode(String.self, forKey: .startTime)
        endTime = try? container.decode(String.self, forKey: .endTime)
        isPartiallyRecorded = try? container.decode(Bool.self, forKey: .isPartiallyRecorded)
        channel = try? container.decode(RecordingChannel.self, forKey: .channel)
        networkId = try? container.decode(Int.self, forKey: .networkId)
        serviceId = try? container.decode(Int.self, forKey: .serviceId)
        eventId = try? container.decode(Int.self, forKey: .eventId)
        seriesId = try? container.decode(Int.self, forKey: .seriesId)
        seriesBroadcastPeriodId = try? container.decode(Int.self, forKey: .seriesBroadcastPeriodId)
        seriesTitle = try? container.decode(String.self, forKey: .seriesTitle)
        episodeNumber = try? container.decode(String.self, forKey: .episodeNumber)
        subtitle = try? container.decode(String.self, forKey: .subtitle)
        detail = try? container.decode([String: String].self, forKey: .detail)
        genres = (try? container.decode([GuideGenre].self, forKey: .genres)) ?? []
    }

    /// RecordedProgram ID expected by the stream and detail routes.
    /// This is distinct from `recordedVideo.id`, which identifies the media
    /// metadata object used for local resume identity.
    public var playbackID: Int { id }
}
public struct RecordedVideo: Decodable, Sendable {
    public let id: Int
    public let duration: Double
    /// Server lifecycle state, for example `Recording` or `Recorded`.
    /// Older server responses may omit this field.
    public let status: String?
    /// Server-generated commercial intervals in seconds from video start.
    /// The field is omitted or null until analysis produces usable metadata.
    public let cmSections: [CommercialSection]?

    private enum CodingKeys: String, CodingKey {
        case id, duration, status, cmSections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(Int.self, forKey: .id)
        guard id > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "recorded video id must be positive"
            )
        }
        self.id = id
        duration = try container.decode(Double.self, forKey: .duration)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        cmSections = Self.decodeCommercialSections(from: container)
    }

    private static func decodeCommercialSections(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [CommercialSection]? {
        guard container.contains(.cmSections),
              (try? container.decodeNil(forKey: .cmSections)) != true,
              var nested = try? container.nestedUnkeyedContainer(forKey: .cmSections) else {
            return nil
        }

        if let count = nested.count, count > RecordingChapterTimeline.maximumSections {
            return nil
        }

        var sections: [CommercialSection] = []
        var processedCount = 0
        while !nested.isAtEnd {
            // Some decoders cannot provide `count`; keep the same bound while
            // consuming such a stream so an untrusted response cannot cause
            // unbounded work or a partial chapter list.
            guard processedCount < RecordingChapterTimeline.maximumSections else {
                return nil
            }
            processedCount += 1
            // `superDecoder()` advances the unkeyed container even when the
            // individual value is not a valid CM object, so malformed entries
            // cannot trap the loop or invalidate the rest of the recording.
            guard let itemDecoder = try? nested.superDecoder() else { break }
            if let section = try? CommercialSection(from: itemDecoder) {
                sections.append(section)
            }
        }
        return sections
    }
}
public struct RecordingsResponse: Decodable, Sendable {
    public let total: Int
    public let recordedPrograms: [Recording]

    private enum CodingKeys: String, CodingKey {
        case total, recordedPrograms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let total = try container.decode(Int.self, forKey: .total)
        guard total >= 0 else { throw RecordingLibraryError.negativeTotal }
        let programs = try container.decode([Recording].self, forKey: .recordedPrograms)
        guard programs.count <= RecordingQuery.pageSize else {
            throw RecordingLibraryError.pageTooLarge
        }
        guard programs.count <= total || (total == 0 && programs.isEmpty) else {
            throw RecordingLibraryError.listExceedsTotal
        }
        var identifiers = Set<Int>(minimumCapacity: programs.count)
        guard programs.allSatisfy({ identifiers.insert($0.id).inserted }) else {
            throw RecordingLibraryError.invalidResponse
        }
        self.total = total
        recordedPrograms = programs
    }
}
public enum ConnectionError: Error, LocalizedError, Equatable, Sendable {
    case invalidAddress
    case http(Int)
    case invalidToken
    case invalidResponse
    case redirectRejected
    case tokenScopeViolation
    case insecureAuthentication
    case notAuthenticated
    case authenticationAlreadyConfigured
    case invalidCredentials

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "http:// または https:// で始まるサーバーURLを入力してください。"
        case .http(let code):
            switch code {
            case 401: return "認証できませんでした（HTTP 401）。設定でアカウント情報を確認し、もう一度ログインしてください。"
            case 403: return "この操作を行う権限がありません（HTTP 403）。"
            default: return "サーバーがHTTP \(code)を返しました。"
            }
        case .invalidToken: return "サーバーから無効な認証トークンが返されました。"
        case .invalidResponse: return "サーバーから正しい応答を受け取れませんでした。"
        case .redirectRejected: return "安全のため、許可されていないリダイレクトを拒否しました。"
        case .tokenScopeViolation: return "認証トークンをこのURLには送信できません。"
        case .insecureAuthentication: return "アカウント認証にはHTTPS接続が必要です。"
        case .notAuthenticated: return "先にサーバーへログインしてください。"
        case .authenticationAlreadyConfigured: return "この接続には既に認証情報が設定されています。"
        case .invalidCredentials: return "ユーザー名とパスワードを確認してください。"
        }
    }
}
public struct RingonomiClient: Sendable {
    public let baseURL: URL
    public let accessToken: BackendAccessToken?

    public init(address: String, accessToken: BackendAccessToken? = nil) throws {
        baseURL = try BackendURLRules.normalize(address)
        self.accessToken = accessToken
    }
    public func endpoint(_ components: [String]) -> URL {
        components.reduce(baseURL) { $0.appendingPathComponent($1) }
    }
    public func liveURL(channel: Channel, quality: String) -> URL {
        endpoint(["api", "streams", "live", channel.displayChannelId, quality, "mpegts"])
    }
    public func recordingURL(id: Int, session: String, quality: String) -> URL {
        var url = URLComponents(url: endpoint(["api", "streams", "video", String(id), quality, "playlist"]), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "session_id", value: session)]
        return url.url!
    }
    public func recordingKeepAliveURL(id: Int, session: String, quality: String) -> URL {
        var components = URLComponents(url: endpoint(["api", "streams", "video", String(id), quality, "keep-alive"]), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "session_id", value: session)]
        return components.url!
    }
    public func keepRecordingAlive(
        id: Int,
        session: String,
        quality: String,
        using urlSession: URLSession = .shared
    ) async throws {
        var request = URLRequest(url: recordingKeepAliveURL(id: id, session: session, quality: quality))
        request.httpMethod = "PUT"
        request.timeoutInterval = 8
        let (_, response) = try await backendData(for: request, using: urlSession)
        try Self.validateSuccessResponse(response)
    }
    public func fetch<T: Decodable & Sendable>(
        _ path: [String],
        as: T.Type,
        using urlSession: URLSession = .shared
    ) async throws -> T {
        var request = URLRequest(url: endpoint(path))
        request.timeoutInterval = 20
        let (data, response) = try await backendData(for: request, using: urlSession)
        try Self.validateSuccessResponse(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
    public func channels(using urlSession: URLSession = .shared) async throws -> [Channel] {
        var request = URLRequest(url: endpoint(["api", "channels"]))
        request.timeoutInterval = 20
        let responseData: (URLSession.AsyncBytes, URLResponse)
        do {
            responseData = try await backendBytes(for: request, using: urlSession)
        } catch let error as ConnectionError where error == .http(0) {
            // The shared transport uses HTTP 0 for a non-HTTP response. A
            // channel list must report that as malformed data rather than a
            // server status.
            throw ConnectionError.invalidResponse
        }
        let bytes = responseData.0
        let response = responseData.1
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectionError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if (200..<300).contains(http.statusCode) {
                throw ConnectionError.invalidResponse
            }
            throw ConnectionError.http(http.statusCode)
        }

        let maximumBytes = 4 * 1024 * 1024
        guard response.expectedContentLength <= Int64(maximumBytes) || response.expectedContentLength < 0 else {
            throw ConnectionError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw ConnectionError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let groups: [String: [Channel]]
        do {
            groups = try decoder.decode([String: [Channel]].self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConnectionError.invalidResponse
        }
        let totalChannels = groups.values.reduce(into: 0) { total, group in
            total += group.count
        }
        guard totalChannels <= 4096 else { throw ConnectionError.invalidResponse }
        var result: [Channel] = []
        for kind in ["GR", "BS", "CS", "CATV", "SKY", "BS4K"] {
            for channel in groups[kind] ?? [] {
                guard channel.isWatchable && channel.isDisplay else { continue }
                let identifier = channel.displayChannelId.utf8
                guard !identifier.isEmpty, identifier.count <= 128,
                      identifier.allSatisfy({ byte in
                          (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) ||
                          (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
                      }) else { throw ConnectionError.invalidResponse }
                result.append(channel)
            }
        }
        return result
    }
}
