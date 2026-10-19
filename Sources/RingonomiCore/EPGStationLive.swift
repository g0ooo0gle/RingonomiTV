import Foundation

private enum EPGStationLiveLimits {
    static let maximumQualityCount = 256
}

/// A live transport exposed by EPGStation.
public enum EPGStationLiveFormat: String, Codable, CaseIterable, Sendable {
    case m2ts
    case m2tsll
    case hls
}

/// One server-configured live quality.
///
/// EPGStation uses the index within each container's configured list as the
/// `mode` query value.  The index is therefore kept separately from the
/// display name and is never compacted when an invalid display name is
/// ignored.
public struct EPGStationLiveQuality: Hashable, Sendable, Identifiable {
    public let format: EPGStationLiveFormat
    public let mode: Int
    public let name: String
    public let isUnconverted: Bool

    public var id: String { "\(format.rawValue):\(mode)" }

    public init(
        format: EPGStationLiveFormat,
        mode: Int,
        name: String,
        isUnconverted: Bool = false
    ) throws {
        guard mode >= 0,
              mode < EPGStationLiveLimits.maximumQualityCount,
              EPGStationValueRules.isSafeText(
                  name,
                  maximumBytes: 16 * 1024,
                  allowEmpty: false
              ),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EPGStationError.invalidResponse
        }
        self.format = format
        self.mode = mode
        self.name = name
        self.isUnconverted = isUnconverted
    }
}

/// A URL ready to hand to the native player.
///
/// TS qualities do not create a server stream and consequently have no
/// stream ID.  HLS qualities contain the server-assigned stream ID so the
/// caller can send periodic keep requests while the player is active.
public struct EPGStationLiveStream: Sendable, Equatable {
    public let url: URL
    public let streamID: Int?

    public init(url: URL, streamID: Int? = nil) {
        self.url = url
        self.streamID = streamID
    }
}

public extension EPGStationClient {
    /// Fetch live qualities from `/api/config`.
    ///
    /// Newer EPGStation versions expose `streamProfiles.live`.  When that
    /// field is present as an array, it is authoritative: unsupported
    /// containers are ignored and an empty/unsupported array returns no
    /// qualities instead of silently inventing legacy modes.  The legacy
    /// `streamConfig.live.ts` shape is used only when the new profile field is
    /// absent or null.
    func liveQualities() async throws -> [EPGStationLiveQuality] {
        let data = try await data(for: endpoint(["api", "config"]))
        let config: EPGStationLiveConfigResponse
        do {
            config = try JSONDecoder().decode(EPGStationLiveConfigResponse.self, from: data)
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }

        if let profiles = config.streamProfiles?.live {
            return try Self.liveQualities(from: profiles)
        }
        return try Self.liveQualities(from: config.streamConfig?.live?.ts)
    }

    /// Build a direct TS URL.  HLS qualities must be started through
    /// `startLiveStream(channelID:quality:)` because the server first assigns
    /// an HLS stream ID.
    func liveURL(channelID: Int, quality: EPGStationLiveQuality) throws -> URL {
        guard EPGStationValueRules.isPositiveIdentifier(channelID) else {
            throw EPGStationError.invalidIdentifier
        }
        guard quality.format != .hls else {
            throw EPGStationError.invalidRequest
        }
        return endpoint(
            ["api", "streams", "live", String(channelID), quality.format.rawValue],
            queryItems: [URLQueryItem(name: "mode", value: String(quality.mode))]
        )
    }

    /// Start a live stream and return the native-player URL.
    ///
    /// TS qualities are direct URLs.  HLS makes one bounded JSON request and
    /// then exposes the server-created playlist; no HLS keep request is sent
    /// until the caller actually begins playback.
    func startLiveStream(
        channelID: Int,
        quality: EPGStationLiveQuality
    ) async throws -> EPGStationLiveStream {
        guard EPGStationValueRules.isPositiveIdentifier(channelID) else {
            throw EPGStationError.invalidIdentifier
        }

        if quality.format != .hls {
            return EPGStationLiveStream(url: try liveURL(channelID: channelID, quality: quality))
        }

        let data = try await data(
            for: endpoint(
                ["api", "streams", "live", String(channelID), EPGStationLiveFormat.hls.rawValue],
                queryItems: [URLQueryItem(name: "mode", value: String(quality.mode))]
            )
        )
        let response: EPGStationLiveStartResponse
        do {
            response = try JSONDecoder().decode(EPGStationLiveStartResponse.self, from: data)
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
        guard response.streamID >= 0,
              response.streamID <= EPGStationValueRules.maximumSafeJSONInteger else {
            throw EPGStationError.invalidResponse
        }

        return EPGStationLiveStream(
            url: endpoint(["streamfiles", "stream\(response.streamID).m3u8"]),
            streamID: response.streamID
        )
    }

    /// Reset the server-side inactivity timer for an HLS stream.
    /// Stream ID zero is valid and must not be treated as a missing ID.
    func keepLiveStream(id: Int) async throws {
        guard id >= 0,
              id <= EPGStationValueRules.maximumSafeJSONInteger else {
            throw EPGStationError.invalidIdentifier
        }
        _ = try await data(
            for: endpoint(["api", "streams", String(id), "keep"]),
            method: "PUT"
        )
    }
}

private extension EPGStationClient {
    static func liveQualities(
        from profiles: [EPGStationLiveProfile]
    ) throws -> [EPGStationLiveQuality] {
        guard profiles.count <= EPGStationLiveLimits.maximumQualityCount else {
            throw EPGStationError.invalidResponse
        }
        return EPGStationLiveFormat.allCases.flatMap { format in
            var mode = 0
            var result: [EPGStationLiveQuality] = []
            for profile in profiles where profile.container == format.rawValue {
                defer { mode += 1 }
                // The mode is assigned before validation.  Dropping an unsafe
                // label must not shift later modes to a different server
                // profile.
                if profile.isValid,
                   let quality = try? EPGStationLiveQuality(
                    format: format,
                    mode: mode,
                    name: profile.name,
                    isUnconverted: profile.isUnconverted
                ) {
                    result.append(quality)
                }
            }
            return result
        }
    }

    static func liveQualities(
        from legacy: EPGStationLegacyTSConfig?
    ) throws -> [EPGStationLiveQuality] {
        guard let legacy else { return [] }
        guard legacy.m2ts.count <= EPGStationLiveLimits.maximumQualityCount,
              legacy.m2tsll.count <= EPGStationLiveLimits.maximumQualityCount,
              legacy.hls.count <= EPGStationLiveLimits.maximumQualityCount,
              legacy.m2ts.count + legacy.m2tsll.count + legacy.hls.count
                  <= EPGStationLiveLimits.maximumQualityCount else {
            throw EPGStationError.invalidResponse
        }
        var result: [EPGStationLiveQuality] = []
        result.append(contentsOf: legacy.m2ts.enumerated().compactMap { index, item in
            try? EPGStationLiveQuality(
                format: .m2ts,
                mode: index,
                name: item.name,
                isUnconverted: item.isUnconverted
            )
        })
        result.append(contentsOf: legacy.m2tsll.enumerated().compactMap { index, name in
            try? EPGStationLiveQuality(format: .m2tsll, mode: index, name: name)
        })
        result.append(contentsOf: legacy.hls.enumerated().compactMap { index, name in
            try? EPGStationLiveQuality(format: .hls, mode: index, name: name)
        })
        return result
    }
}

private struct EPGStationLiveConfigResponse: Decodable, Sendable {
    let streamConfig: EPGStationLegacyStreamConfig?
    let streamProfiles: EPGStationLiveProfiles?

    private enum CodingKeys: String, CodingKey {
        case streamConfig
        case streamProfiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamProfiles = try container.decodeIfPresent(
            EPGStationLiveProfiles.self,
            forKey: .streamProfiles
        )
        // Decode the legacy tree only when the new live array is absent or
        // null.  A malformed, unused legacy branch must not hide a valid
        // authoritative profile list.
        if streamProfiles?.live != nil {
            streamConfig = nil
        } else {
            streamConfig = try container.decodeIfPresent(
                EPGStationLegacyStreamConfig.self,
                forKey: .streamConfig
            )
        }
    }
}

private struct EPGStationLiveProfiles: Decodable, Sendable {
    let live: [EPGStationLiveProfile]?

    private enum CodingKeys: String, CodingKey {
        case live
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let profiles = try container.decodeIfPresent(
            [EPGStationLiveProfile].self,
            forKey: .live
        )
        if let profiles,
           profiles.count > EPGStationLiveLimits.maximumQualityCount {
            throw EPGStationError.invalidResponse
        }
        live = profiles
    }
}

private struct EPGStationLiveProfile: Decodable, Sendable {
    let container: String
    let name: String
    let isUnconverted: Bool
    let isValid: Bool

    private enum CodingKeys: String, CodingKey {
        case container
        case name
        case isUnconverted
    }

    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys>
        do {
            container = try decoder.container(keyedBy: CodingKeys.self)
        } catch {
            self.container = ""
            self.name = ""
            self.isUnconverted = false
            self.isValid = false
            return
        }
        let containerValue: String?
        do {
            containerValue = try container.decodeIfPresent(String.self, forKey: .container)
        } catch {
            self.container = ""
            self.name = ""
            self.isUnconverted = false
            self.isValid = false
            return
        }
        let nameValue: String?
        do {
            nameValue = try container.decodeIfPresent(String.self, forKey: .name)
        } catch {
            self.container = containerValue ?? ""
            self.name = ""
            self.isUnconverted = false
            self.isValid = false
            return
        }
        let isUnconvertedValue: Bool?
        do {
            isUnconvertedValue = try container.decodeIfPresent(Bool.self, forKey: .isUnconverted)
        } catch {
            self.container = containerValue ?? ""
            self.name = nameValue ?? ""
            self.isUnconverted = false
            self.isValid = false
            return
        }
        self.container = containerValue ?? ""
        self.name = nameValue ?? ""
        self.isUnconverted = isUnconvertedValue ?? false
        self.isValid = true
    }
}

private struct EPGStationLegacyStreamConfig: Decodable, Sendable {
    let live: EPGStationLegacyLiveConfig?

    private enum CodingKeys: String, CodingKey {
        case live
    }
}

private struct EPGStationLegacyLiveConfig: Decodable, Sendable {
    let ts: EPGStationLegacyTSConfig?

    private enum CodingKeys: String, CodingKey {
        case ts
    }
}

private struct EPGStationLegacyTSConfig: Decodable, Sendable {
    let m2ts: [EPGStationLegacyM2TS]
    let m2tsll: [String]
    let hls: [String]

    private enum CodingKeys: String, CodingKey {
        case m2ts
        case m2tsll
        case hls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let m2ts = try container.decodeIfPresent([EPGStationLegacyM2TS].self, forKey: .m2ts) ?? []
        let m2tsll = try container.decodeIfPresent([String].self, forKey: .m2tsll) ?? []
        let hls = try container.decodeIfPresent([String].self, forKey: .hls) ?? []
        guard m2ts.count <= EPGStationLiveLimits.maximumQualityCount,
              m2tsll.count <= EPGStationLiveLimits.maximumQualityCount,
              hls.count <= EPGStationLiveLimits.maximumQualityCount else {
            throw EPGStationError.invalidResponse
        }
        self.m2ts = m2ts
        self.m2tsll = m2tsll
        self.hls = hls
    }
}

private struct EPGStationLegacyM2TS: Decodable, Sendable {
    let name: String
    let isUnconverted: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case isUnconverted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isUnconverted = try container.decodeIfPresent(Bool.self, forKey: .isUnconverted) ?? false
    }
}

private struct EPGStationLiveStartResponse: Decodable, Sendable {
    let streamID: Int

    private enum CodingKeys: String, CodingKey {
        case streamID = "streamId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decode(Int.self, forKey: .streamID)
    }
}
