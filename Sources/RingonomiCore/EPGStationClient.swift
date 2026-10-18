import Foundation

/// Errors returned by the independent EPGStation connection.
///
/// The client deliberately does not share KonomiTV authentication, cookies,
/// credentials, or keep-alive state.  Error values do not include a URL or a
/// response body, so a server response cannot accidentally be exposed in UI
/// diagnostics.
public enum EPGStationError: Error, LocalizedError, Equatable, Sendable {
    case invalidAddress
    case invalidIdentifier
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case redirectRejected
    case transport

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "EPGStationの接続先が不正です。"
        case .invalidIdentifier:
            return "EPGStationの識別子が不正です。"
        case .invalidRequest:
            return "EPGStationへのリクエスト条件が不正です。"
        case .invalidResponse:
            return "EPGStationの応答形式が不正です。"
        case .responseTooLarge:
            return "EPGStationの応答が大きすぎます。"
        case .httpStatus(let status):
            return "EPGStationへの接続に失敗しました（HTTP \(status)）。"
        case .redirectRejected:
            return "EPGStationのリダイレクトは許可されていません。"
        case .transport:
            return "EPGStationへの接続に失敗しました。"
        }
    }
}

/// A playable video file belonging to one EPGStation recording.
///
/// `id` is a video-file ID.  It is intentionally separate from
/// `EPGStationRecording.id`, which identifies the recording metadata and is
/// used by the detail endpoint.
public struct EPGStationVideoFile: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let filename: String?
    /// `ts` and `encoded` are currently documented values.  Unknown values
    /// are retained so a newer server does not invalidate the recording list.
    public let type: String
    public let size: Int64

    private enum CodingKeys: String, CodingKey {
        case id, name, filename, type, size
    }

    public init(
        id: Int,
        name: String,
        filename: String? = nil,
        type: String,
        size: Int64
    ) throws {
        guard EPGStationValueRules.isPositiveIdentifier(id),
              EPGStationValueRules.isSafeText(name, maximumBytes: 16 * 1024),
              filename.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true,
              EPGStationValueRules.isSafeText(type, maximumBytes: 128, allowEmpty: false),
              size >= 0 else {
            throw EPGStationError.invalidResponse
        }
        self.id = id
        self.name = name
        self.filename = filename
        self.type = type
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(Int.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let filename = try container.decodeIfPresent(String.self, forKey: .filename)
        let type = try container.decode(String.self, forKey: .type)
        let size = try container.decode(Int64.self, forKey: .size)
        try self.init(
            id: id,
            name: name,
            filename: filename,
            type: type,
            size: size
        )
    }
}

/// A recording item returned by EPGStation.
public struct EPGStationRecording: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let channelID: Int
    /// Unix time in milliseconds, as defined by EPGStation's `UnixtimeMS`.
    public let startAt: Double
    /// Unix time in milliseconds, as defined by EPGStation's `UnixtimeMS`.
    public let endAt: Double
    public let name: String
    public let description: String?
    public let extended: String?
    public let isRecording: Bool
    public let isEncoding: Bool
    public let isProtected: Bool
    public let videoFiles: [EPGStationVideoFile]

    private enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channelId"
        case startAt, endAt, name
        case description, extended, isRecording, isEncoding, isProtected
        case videoFiles
    }

    public init(
        id: Int,
        channelID: Int,
        startAt: Double,
        endAt: Double,
        name: String,
        description: String? = nil,
        extended: String? = nil,
        isRecording: Bool,
        isEncoding: Bool,
        isProtected: Bool,
        videoFiles: [EPGStationVideoFile] = []
    ) throws {
        guard EPGStationValueRules.isPositiveIdentifier(id),
              EPGStationValueRules.isPositiveIdentifier(channelID),
              startAt.isFinite,
              endAt.isFinite,
              endAt >= startAt,
              EPGStationValueRules.isSafeText(name, maximumBytes: 16 * 1024),
              description.map({ EPGStationValueRules.isSafeHumanText($0, maximumBytes: 64 * 1024) }) ?? true,
              extended.map({ EPGStationValueRules.isSafeHumanText($0, maximumBytes: 64 * 1024) }) ?? true else {
            throw EPGStationError.invalidResponse
        }
        let fileIDs = videoFiles.map(\.id)
        guard Set(fileIDs).count == fileIDs.count else {
            throw EPGStationError.invalidResponse
        }
        self.id = id
        self.channelID = channelID
        self.startAt = startAt
        self.endAt = endAt
        self.name = name
        self.description = description
        self.extended = extended
        self.isRecording = isRecording
        self.isEncoding = isEncoding
        self.isProtected = isProtected
        self.videoFiles = videoFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(Int.self, forKey: .id)
        let channelID = try container.decode(Int.self, forKey: .channelID)
        let startAt = try container.decode(Double.self, forKey: .startAt)
        let endAt = try container.decode(Double.self, forKey: .endAt)
        let name = try container.decode(String.self, forKey: .name)
        let description = try container.decodeIfPresent(String.self, forKey: .description)
        let extended = try container.decodeIfPresent(String.self, forKey: .extended)
        let isRecording = try container.decode(Bool.self, forKey: .isRecording)
        let isEncoding = try container.decode(Bool.self, forKey: .isEncoding)
        let isProtected = try container.decode(Bool.self, forKey: .isProtected)
        let videoFiles = try container.decodeIfPresent([EPGStationVideoFile].self, forKey: .videoFiles) ?? []
        try self.init(
            id: id,
            channelID: channelID,
            startAt: startAt,
            endAt: endAt,
            name: name,
            description: description,
            extended: extended,
            isRecording: isRecording,
            isEncoding: isEncoding,
            isProtected: isProtected,
            videoFiles: videoFiles
        )
    }
}

/// A page returned by EPGStation's recorded-program list endpoint.
public struct EPGStationRecordingPage: Codable, Equatable, Sendable {
    public let records: [EPGStationRecording]
    public let total: Int

    private enum CodingKeys: String, CodingKey {
        case records, total
    }

    public init(records: [EPGStationRecording], total: Int) throws {
        guard total >= records.count,
              total <= EPGStationValueRules.maximumSafeJSONInteger else {
            throw EPGStationError.invalidResponse
        }
        var identifiers = Set<Int>(minimumCapacity: records.count)
        guard records.allSatisfy({ identifiers.insert($0.id).inserted }) else {
            throw EPGStationError.invalidResponse
        }
        self.records = records
        self.total = total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let records = try container.decode([EPGStationRecording].self, forKey: .records)
        let total = try container.decode(Int.self, forKey: .total)
        try self.init(
            records: records,
            total: total
        )
    }
}

/// A small, credential-free EPGStation client.
///
/// The initializer accepts a URLSession configuration so tests can install a
/// URLProtocol without exposing a session in the product API.  The client
/// copies and hardens that configuration into an isolated ephemeral session.
public struct EPGStationClient: @unchecked Sendable {
    public static let maximumResponseBytes = 4 * 1024 * 1024
    public static let defaultPageLimit = 50
    public static let maximumPageLimit = 200

    public let baseURL: URL
    private let session: URLSession

    public init(
        address: String,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        self.baseURL = try EPGStationURLRules.normalize(address)

        let configuration: URLSessionConfiguration
        if let sessionConfiguration,
           let copiedConfiguration = sessionConfiguration.copy() as? URLSessionConfiguration {
            configuration = copiedConfiguration
        } else {
            configuration = .ephemeral
        }
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        if var headers = configuration.httpAdditionalHeaders {
            for key in Array(headers.keys) {
                guard let keyString = key as? String else { continue }
                if keyString.caseInsensitiveCompare("Authorization") == .orderedSame ||
                    keyString.caseInsensitiveCompare("Cookie") == .orderedSame {
                    headers.removeValue(forKey: key)
                }
            }
            configuration.httpAdditionalHeaders = headers
        }
        self.session = URLSession(configuration: configuration)
    }

    /// Fetch one page of recorded programs.
    public func recordings(
        offset: Int = 0,
        limit: Int = EPGStationClient.defaultPageLimit,
        keyword: String? = nil,
        isReverse: Bool = false
    ) async throws -> EPGStationRecordingPage {
        guard (0...EPGStationValueRules.maximumSafeJSONInteger).contains(offset),
              (1...Self.maximumPageLimit).contains(limit) else {
            throw EPGStationError.invalidRequest
        }
        let normalizedKeyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedKeyword,
           (normalizedKeyword.utf8.count > 1024 ||
            normalizedKeyword.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })) {
            throw EPGStationError.invalidRequest
        }

        var queryItems = [
            URLQueryItem(name: "isHalfWidth", value: "true"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let normalizedKeyword, !normalizedKeyword.isEmpty {
            queryItems.append(URLQueryItem(name: "keyword", value: normalizedKeyword))
        }
        queryItems.append(URLQueryItem(name: "isReverse", value: isReverse ? "true" : "false"))

        let data = try await data(for: endpoint(["api", "recorded"], queryItems: queryItems))
        let page: EPGStationRecordingPage
        do {
            page = try JSONDecoder().decode(EPGStationRecordingPage.self, from: data)
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
        guard page.records.count <= limit else {
            throw EPGStationError.invalidResponse
        }
        return page
    }

    /// Fetch one recording by its recording metadata ID.
    ///
    /// This ID is deliberately not interchangeable with a video-file ID.
    public func recording(id: Int) async throws -> EPGStationRecording {
        guard EPGStationValueRules.isPositiveIdentifier(id) else {
            throw EPGStationError.invalidIdentifier
        }
        let queryItems = [URLQueryItem(name: "isHalfWidth", value: "true")]
        let data = try await data(
            for: endpoint(["api", "recorded", String(id)], queryItems: queryItems)
        )
        do {
            return try JSONDecoder().decode(EPGStationRecording.self, from: data)
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
    }

    /// Build the raw video-file endpoint.  No request is sent by this method.
    public func videoURL(fileID: Int) throws -> URL {
        guard EPGStationValueRules.isPositiveIdentifier(fileID) else {
            throw EPGStationError.invalidIdentifier
        }
        return endpoint(["api", "videos", String(fileID)])
    }

    /// Fetch the duration of one video file in seconds.
    public func videoDuration(fileID: Int) async throws -> Double {
        guard EPGStationValueRules.isPositiveIdentifier(fileID) else {
            throw EPGStationError.invalidIdentifier
        }
        let data = try await data(
            for: endpoint(["api", "videos", String(fileID), "duration"])
        )
        do {
            let response = try JSONDecoder().decode(EPGStationDurationResponse.self, from: data)
            return response.duration
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
    }

    private func endpoint(
        _ components: [String],
        queryItems: [URLQueryItem] = []
    ) -> URL {
        var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let prefix = EPGStationURLRules.canonicalBasePath(urlComponents.percentEncodedPath)
        urlComponents.percentEncodedPath = prefix + components.joined(separator: "/")
        urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems
        urlComponents.fragment = nil
        return urlComponents.url!
    }

    private func data(for requestURL: URL) async throws -> Data {
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")

        let delegate = EPGStationRedirectDelegate()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            defer { bytes.task.cancel() }
            if delegate.rejected {
                throw EPGStationError.redirectRejected
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw EPGStationError.invalidResponse
            }
            guard response.url?.absoluteString == requestURL.absoluteString else {
                throw EPGStationError.redirectRejected
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw EPGStationError.httpStatus(httpResponse.statusCode)
            }
            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let length = Int64(contentLength),
               length > Int64(Self.maximumResponseBytes) {
                throw EPGStationError.responseTooLarge
            }
            let body = try await Self.readBounded(
                bytes,
                maximumBytes: Self.maximumResponseBytes
            )
            try Task.checkCancellation()
            return body
        } catch let error as EPGStationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if delegate.rejected { throw EPGStationError.redirectRejected }
            throw EPGStationError.transport
        }
    }

    private static func readBounded(
        _ bytes: URLSession.AsyncBytes,
        maximumBytes: Int
    ) async throws -> Data {
        defer { bytes.task.cancel() }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 32 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw EPGStationError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }
}

private struct EPGStationDurationResponse: Decodable, Sendable {
    let duration: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let duration = try container.decode(Double.self, forKey: .duration)
        guard duration.isFinite, duration >= 0 else {
            throw EPGStationError.invalidResponse
        }
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case duration
    }
}

private enum EPGStationValueRules {
    // JavaScript's JSON number representation is exact through 2^53 - 1.
    static let maximumSafeJSONInteger = 9_007_199_254_740_991

    static func isPositiveIdentifier(_ value: Int) -> Bool {
        (1...maximumSafeJSONInteger).contains(value)
    }

    static func isSafeText(
        _ value: String,
        maximumBytes: Int,
        allowEmpty: Bool = true
    ) -> Bool {
        (allowEmpty || !value.isEmpty) &&
            value.utf8.count <= maximumBytes &&
            !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    /// EPGStation descriptions and extended metadata are human-authored text
    /// and may contain normal tab/newline formatting.  Keep NUL and all other
    /// control characters rejected while allowing those three characters.
    static func isSafeHumanText(
        _ value: String,
        maximumBytes: Int,
        allowEmpty: Bool = true
    ) -> Bool {
        (allowEmpty || !value.isEmpty) &&
            value.utf8.count <= maximumBytes &&
            !value.unicodeScalars.contains {
                let scalar = $0.value
                return scalar == 0x7F ||
                    (scalar < 0x20 && scalar != 0x09 && scalar != 0x0A && scalar != 0x0D)
            }
    }
}

private enum EPGStationURLRules {
    static func normalize(_ address: String) throws -> URL {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty,
              let components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              isSafePercentEncodedPath(components.percentEncodedPath) else {
            throw EPGStationError.invalidAddress
        }

        var normalized = components
        normalized.scheme = scheme
        normalized.percentEncodedPath = canonicalBasePath(components.percentEncodedPath)
        guard let result = normalized.url else {
            throw EPGStationError.invalidAddress
        }
        return result
    }

    static func canonicalBasePath(_ original: String) -> String {
        var path = original
        if path.isEmpty { path = "/" }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasPrefix("/") { path = "/" + path }
        return path == "/" ? "/" : path + "/"
    }

    static func isSafePercentEncodedPath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x20 || byte == 0x7F || byte == 0x5C { return false }
            if byte == 0x25 {
                guard index + 2 < bytes.count,
                      let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2]) else {
                    return false
                }
                let decoded = (high << 4) | low
                if decoded < 0x20 || decoded == 0x7F || decoded == 0x2E ||
                    decoded == 0x2F || decoded == 0x5C || decoded == 0x25 {
                    return false
                }
                index += 3
                continue
            }
            index += 1
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component == "." || component == ".." { return false }
        }
        return true
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

private final class EPGStationRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didRejectRedirect = false

    var rejected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRejectRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        didRejectRedirect = true
        lock.unlock()
        completionHandler(nil)
        task.cancel()
    }
}
