import Foundation

/// Errors returned by the independent Mirakurun connection.
///
/// This transport intentionally does not reuse KonomiTV authentication or
/// keep-alive state.  Error values also avoid including a server URL or body.
public enum MirakurunError: Error, LocalizedError, Equatable, Sendable {
    case invalidAddress
    case invalidIdentifier
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case redirectRejected
    case transport

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Mirakurunの接続先が不正です。"
        case .invalidIdentifier:
            return "Mirakurunのサービス識別子が不正です。"
        case .invalidResponse:
            return "Mirakurunの応答形式が不正です。"
        case .responseTooLarge:
            return "Mirakurunの応答が大きすぎます。"
        case .httpStatus(let status):
            return "Mirakurunへの接続に失敗しました（HTTP \(status)）。"
        case .redirectRejected:
            return "Mirakurunのリダイレクトは許可されていません。"
        case .transport:
            return "Mirakurunへの接続に失敗しました。"
        }
    }
}

/// Mirakurun's service identity, plus the transport-stream identifier used by
/// clients that also keep EDCB-style channel metadata.
///
/// Mirakurun's public service API identifies a service by its service-item ID.
/// The conventional ID used by the API client is `networkID * 100000 +
/// serviceID`; the calculation is checked for overflow before it is used in a
/// URL.  `transportStreamID` is optional because it is not part of Mirakurun's
/// required `Service` response fields.
public struct MirakurunServiceKey: Codable, Hashable, Sendable, Equatable {
    public static let maximumIdentifier = Int(UInt16.max)
    public static let maximumServiceItemID = maximumIdentifier * 100_000 + maximumIdentifier

    public let networkID: Int
    public let serviceID: Int
    public let transportStreamID: Int?

    private enum CodingKeys: String, CodingKey {
        case networkID
        case serviceID
        case transportStreamID
    }

    public init(
        networkID: Int,
        serviceID: Int,
        transportStreamID: Int? = nil
    ) throws {
        guard Self.isValidIdentifier(networkID),
              Self.isValidIdentifier(serviceID),
              transportStreamID.map(Self.isValidIdentifier) ?? true else {
            throw MirakurunError.invalidIdentifier
        }
        guard Self.serviceItemID(networkID: networkID, serviceID: serviceID) != nil else {
            throw MirakurunError.invalidIdentifier
        }
        self.networkID = networkID
        self.serviceID = serviceID
        self.transportStreamID = transportStreamID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let networkID = try container.decode(Int.self, forKey: .networkID)
        let serviceID = try container.decode(Int.self, forKey: .serviceID)
        let transportStreamID = try container.decodeIfPresent(Int.self, forKey: .transportStreamID)
        try self.init(
            networkID: networkID,
            serviceID: serviceID,
            transportStreamID: transportStreamID
        )
    }

    /// The service-item ID used by `/api/services/{id}`.
    public var serviceItemID: Int {
        // The initializer checks this operation, so this force unwrap cannot
        // be reached with an overflowing key.
        Self.serviceItemID(networkID: networkID, serviceID: serviceID)!
    }

    public static func serviceItemID(networkID: Int, serviceID: Int) -> Int? {
        guard isValidIdentifier(networkID), isValidIdentifier(serviceID) else { return nil }
        let (scaled, scaleOverflowed) = networkID.multipliedReportingOverflow(by: 100_000)
        guard !scaleOverflowed else { return nil }
        let (combined, addOverflowed) = scaled.addingReportingOverflow(serviceID)
        return addOverflowed ? nil : combined
    }

    private static func isValidIdentifier(_ value: Int) -> Bool {
        (0...maximumIdentifier).contains(value)
    }
}

/// The channel information nested in a Mirakurun `Service` response.
public struct MirakurunChannel: Decodable, Equatable, Sendable {
    public let type: String
    public let channel: String
    public let name: String?

    private enum CodingKeys: String, CodingKey {
        case type, channel, name
    }

    public init(type: String, channel: String, name: String? = nil) throws {
        guard Self.isValid(type: type, maximumBytes: 32),
              Self.isValid(type: channel, maximumBytes: 128),
              name.map({ Self.isValid(type: $0, maximumBytes: 1024) }) ?? true else {
            throw MirakurunError.invalidResponse
        }
        self.type = type
        self.channel = channel
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let channel = try container.decode(String.self, forKey: .channel)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        try self.init(type: type, channel: channel, name: name)
    }

    private static func isValid(type value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes &&
            !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

/// A service returned by Mirakurun's `/api/services` endpoint.
public struct MirakurunService: Decodable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let serviceID: Int
    public let networkID: Int
    public let name: String
    public let type: Int
    public let logoID: Int?
    public let hasLogoData: Bool?
    public let remoteControlKeyID: Int?
    public let epgReady: Bool?
    public let epgUpdatedAt: Int?
    public let channel: MirakurunChannel?
    /// Optional compatibility metadata; Mirakurun's official `Service`
    /// definition does not require this field.
    public let transportStreamID: Int?
    private let validatedKey: MirakurunServiceKey

    private enum CodingKeys: String, CodingKey {
        case id, serviceId, networkId, name, type
        case logoId, hasLogoData, remoteControlKeyId, epgReady, epgUpdatedAt
        case channel, transportStreamId
    }

    public init(
        id: Int,
        serviceID: Int,
        networkID: Int,
        name: String,
        type: Int,
        logoID: Int? = nil,
        hasLogoData: Bool? = nil,
        remoteControlKeyID: Int? = nil,
        epgReady: Bool? = nil,
        epgUpdatedAt: Int? = nil,
        channel: MirakurunChannel? = nil,
        transportStreamID: Int? = nil
    ) throws {
        // Mirakurun uses -1 for a service without an assigned logo.  Keep
        // that sentinel out of the public model; other negative values are
        // still invalid identifiers.
        let normalizedLogoID: Int? = logoID == -1 ? nil : logoID
        guard id >= 0 && id <= MirakurunServiceKey.maximumServiceItemID,
              Self.isValidName(name),
              normalizedLogoID.map({ $0 >= 0 }) ?? true,
              remoteControlKeyID.map({ $0 >= 0 }) ?? true,
              transportStreamID.map({ MirakurunServiceKey.maximumIdentifier >= $0 && $0 >= 0 }) ?? true else {
            throw MirakurunError.invalidIdentifier
        }
        let validatedKey = try MirakurunServiceKey(
            networkID: networkID,
            serviceID: serviceID,
            transportStreamID: transportStreamID
        )
        guard id == validatedKey.serviceItemID else {
            throw MirakurunError.invalidIdentifier
        }
        self.id = id
        self.serviceID = serviceID
        self.networkID = networkID
        self.name = name
        self.type = type
        self.logoID = normalizedLogoID
        self.hasLogoData = hasLogoData
        self.remoteControlKeyID = remoteControlKeyID
        self.epgReady = epgReady
        self.epgUpdatedAt = epgUpdatedAt
        self.channel = channel
        self.transportStreamID = transportStreamID
        self.validatedKey = validatedKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(Int.self, forKey: .id)
        let serviceID = try container.decode(Int.self, forKey: .serviceId)
        let networkID = try container.decode(Int.self, forKey: .networkId)
        let name = try container.decode(String.self, forKey: .name)
        let type = try container.decode(Int.self, forKey: .type)
        let logoID = try container.decodeIfPresent(Int.self, forKey: .logoId)
        let hasLogoData = try container.decodeIfPresent(Bool.self, forKey: .hasLogoData)
        let remoteControlKeyID = try container.decodeIfPresent(Int.self, forKey: .remoteControlKeyId)
        let epgReady = try container.decodeIfPresent(Bool.self, forKey: .epgReady)
        let epgUpdatedAt = try container.decodeIfPresent(Int.self, forKey: .epgUpdatedAt)
        let channel = try container.decodeIfPresent(MirakurunChannel.self, forKey: .channel)
        let transportStreamID = try container.decodeIfPresent(Int.self, forKey: .transportStreamId)
        try self.init(
            id: id,
            serviceID: serviceID,
            networkID: networkID,
            name: name,
            type: type,
            logoID: logoID,
            hasLogoData: hasLogoData,
            remoteControlKeyID: remoteControlKeyID,
            epgReady: epgReady,
            epgUpdatedAt: epgUpdatedAt,
            channel: channel,
            transportStreamID: transportStreamID
        )
    }

    public var key: MirakurunServiceKey {
        validatedKey
    }

    private static func isValidName(_ value: String) -> Bool {
        value.utf8.count <= 1024 &&
            !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

/// A small, credential-free Mirakurun client.  `using` is an explicit test
/// hook; the default path always uses a private ephemeral URLSession.
public struct MirakurunClient: Sendable {
    public static let maximumServiceResponseBytes = 4 * 1024 * 1024

    public let baseURL: URL

    public init(address: String) throws {
        self.baseURL = try MirakurunURLRules.normalize(address)
    }

    /// Build the raw TS service endpoint.  No request is sent by this method.
    public func streamURL(for key: MirakurunServiceKey) -> URL {
        endpoint(["api", "services", String(key.serviceItemID), "stream"])
    }

    public func streamURL(for service: MirakurunService) -> URL {
        endpoint(["api", "services", String(service.id), "stream"])
    }

    /// Build the service logo endpoint.  No request is sent by this method.
    public func logoURL(for key: MirakurunServiceKey) -> URL {
        endpoint(["api", "services", String(key.serviceItemID), "logo"])
    }

    public func logoURL(for service: MirakurunService) -> URL {
        endpoint(["api", "services", String(service.id), "logo"])
    }

    /// Fetch the service list with an anonymous GET.
    ///
    /// The optional session exists for URLProtocol-based tests.  Passing
    /// `nil` or `URLSession.shared` selects the client's isolated ephemeral
    /// session; no KonomiTV bearer token, cookie, credential store, cache, or
    /// keep-alive route is involved.
    public func services(using suppliedSession: URLSession? = nil) async throws -> [MirakurunService] {
        let requestURL = endpoint(["api", "services"])
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")

        let session = Self.transportSession(for: suppliedSession)
        let delegate = MirakurunRedirectDelegate()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            if delegate.rejected {
                bytes.task.cancel()
                throw MirakurunError.redirectRejected
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw MirakurunError.invalidResponse
            }
            guard response.url?.absoluteString == requestURL.absoluteString else {
                bytes.task.cancel()
                throw MirakurunError.redirectRejected
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                bytes.task.cancel()
                throw MirakurunError.httpStatus(httpResponse.statusCode)
            }
            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let length = Int64(contentLength),
               length > Int64(Self.maximumServiceResponseBytes) {
                bytes.task.cancel()
                throw MirakurunError.responseTooLarge
            }
            let data = try await Self.readBounded(
                bytes,
                maximumBytes: Self.maximumServiceResponseBytes
            )
            try Task.checkCancellation()
            do {
                let services = try JSONDecoder().decode([MirakurunService].self, from: data)
                var identifiers = Set<Int>(minimumCapacity: services.count)
                guard services.allSatisfy({ identifiers.insert($0.id).inserted }) else {
                    throw MirakurunError.invalidResponse
                }
                return services
            } catch {
                if let error = error as? MirakurunError { throw error }
                throw MirakurunError.invalidResponse
            }
        } catch let error as MirakurunError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if delegate.rejected { throw MirakurunError.redirectRejected }
            throw MirakurunError.transport
        }
    }

    private func endpoint(_ components: [String]) -> URL {
        var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let prefix = MirakurunURLRules.canonicalBasePath(urlComponents.percentEncodedPath)
        urlComponents.percentEncodedPath = prefix + components.joined(separator: "/")
        urlComponents.query = nil
        urlComponents.fragment = nil
        return urlComponents.url!
    }

    private static func transportSession(for supplied: URLSession?) -> URLSession {
        guard let suppliedSession = supplied,
              suppliedSession !== URLSession.shared else {
            return MirakurunTransportSession.secureShared
        }
        return suppliedSession
    }

    private static func readBounded(
        _ bytes: URLSession.AsyncBytes,
        maximumBytes: Int
    ) async throws -> Data {
        defer { bytes.task.cancel() }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 32 * 1024))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw MirakurunError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }
}

private enum MirakurunURLRules {
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
            throw MirakurunError.invalidAddress
        }

        var normalized = components
        normalized.scheme = scheme
        normalized.percentEncodedPath = canonicalBasePath(components.percentEncodedPath)
        guard let result = normalized.url else { throw MirakurunError.invalidAddress }
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
                // Reject separators, dot segments, backslashes, and a second
                // percent decode pass before URLSession can normalize them.
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

private enum MirakurunTransportSession {
    static let secureShared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

private final class MirakurunRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
