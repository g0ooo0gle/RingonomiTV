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
}
public struct Recording: Decodable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let description: String
    public let recordedVideo: RecordedVideo
    public let isFree: Bool
}
public struct RecordedVideo: Decodable, Sendable {
    public let id: Int
    public let duration: Double
}
public struct RecordingsResponse: Decodable, Sendable {
    public let total: Int
    public let recordedPrograms: [Recording]
}
public enum ConnectionError: Error, LocalizedError {
    case invalidAddress, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "http:// または https:// で始まるサーバーURLを入力してください。"
        case .http(let code): return "サーバーがHTTP \(code)を返しました。"
        }
    }
}
public struct RingonomiClient: Sendable {
    public let baseURL: URL
    public init(address: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw ConnectionError.invalidAddress }
        // ブラウザーの視聴画面URLを貼り付けてもAPIルートへ接続する。
        // リバースプロキシのサブパスは保持し、末尾のtvだけを取り除く。
        baseURL = url.lastPathComponent == "tv" ? url.deletingLastPathComponent() : url
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
    public func keepRecordingAlive(id: Int, session: String, quality: String) async throws {
        var request = URLRequest(url: recordingKeepAliveURL(id: id, session: session, quality: quality))
        request.httpMethod = "PUT"
        request.timeoutInterval = 8
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.http(0) }
        guard (200..<300).contains(response.statusCode) else { throw ConnectionError.http(response.statusCode) }
    }
    public func fetch<T: Decodable & Sendable>(_ path: [String], as: T.Type) async throws -> T {
        var request = URLRequest(url: endpoint(path))
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.http(0) }
        guard (200..<300).contains(response.statusCode) else { throw ConnectionError.http(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
    public func channels() async throws -> [Channel] {
        let groups = try await fetch(["api", "channels"], as: [String: [Channel]].self)
        var result: [Channel] = []
        for kind in ["GR", "BS", "CS", "CATV", "SKY", "BS4K"] {
            for channel in groups[kind] ?? [] {
                if channel.isWatchable && channel.isDisplay { result.append(channel) }
            }
        }
        return result
    }
}
