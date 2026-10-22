import Foundation

public enum RecordedCommentsRequestError: Error, LocalizedError, Equatable {
    case invalidIdentifier
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "録画番組IDが不正です。"
        case .responseTooLarge: return "実況のデータ量が多すぎるため表示できません。"
        }
    }
}

public extension RingonomiClient {
    /// Comments use the recorded-program ID, with times relative to file start.
    /// Stop the transfer at the limit instead of first buffering an arbitrary
    /// response in memory on Apple TV HD.
    func recordedComments(recordingID: Int, using session: URLSession = .shared) async throws -> RecordedCommentsResponse {
        guard recordingID > 0 else { throw RecordedCommentsRequestError.invalidIdentifier }
        let maximumBytes = 20 * 1024 * 1024
        var request = URLRequest(url: endpoint(["api", "videos", String(recordingID), "jikkyo"]))
        request.timeoutInterval = 25
        let (bytes, response) = try await backendBytes(for: request, using: session)
        defer { bytes.cancel() }
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.http(0) }
        guard (200..<300).contains(response.statusCode) else { throw ConnectionError.http(response.statusCode) }
        guard response.expectedContentLength <= maximumBytes else {
            throw RecordedCommentsRequestError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw RecordedCommentsRequestError.responseTooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RecordedCommentsResponse.self, from: data)
    }
}
