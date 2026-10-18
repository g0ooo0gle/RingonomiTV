import Foundation

public enum LiveCommentsRequestError: Error, LocalizedError, Equatable {
    case invalidChannel
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidChannel: return "実況のチャンネルIDが不正です。"
        case .responseTooLarge: return "実況の接続情報が大きすぎます。"
        }
    }
}

public extension RingonomiClient {
    /// Fetches only session metadata. External WebSocket connections use their
    /// own session so backend credentials are never forwarded to NX-Jikkyo.
    func liveComments(channelID: String, using session: URLSession = .shared) async throws -> JikkyoWebSocketInfo {
        guard !channelID.isEmpty, channelID.utf8.count <= 128,
              channelID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else {
            throw LiveCommentsRequestError.invalidChannel
        }
        let limit = LiveCommentProtocol.maximumFrameBytes
        var request = URLRequest(url: endpoint(["api", "channels", channelID, "jikkyo"]))
        request.timeoutInterval = 20
        let (bytes, response) = try await backendBytes(for: request, using: session)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw ConnectionError.http(http.statusCode) }
        guard response.expectedContentLength <= limit else { throw LiveCommentsRequestError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < limit else { throw LiveCommentsRequestError.responseTooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        // The DTO owns explicit snake_case keys; no global key conversion.
        return try JSONDecoder().decode(JikkyoWebSocketInfo.self, from: data)
    }
}
