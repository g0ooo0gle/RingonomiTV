import Foundation

/// The sort orders verified by the recorded-program list and search APIs.
public enum RecordingSortOrder: String, Codable, CaseIterable, Sendable {
    case newest = "desc"
    case oldest = "asc"
}

/// Query for one server page of recorded programs.
///
/// The backend page size is fixed at 30 by the current API contract.  Search
/// is routed to `/api/videos/search` and the server receives the keyword as a
/// single `query` parameter; this type deliberately does not invent local
/// AND/OR semantics.
public struct RecordingQuery: Sendable, Equatable {
    public static let pageSize = 30

    public let page: Int
    public let order: RecordingSortOrder
    public let keyword: String

    public init(
        keyword: String = "",
        page: Int = 1,
        order: RecordingSortOrder = .newest
    ) {
        self.page = max(1, page)
        self.order = order
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyword = trimmed.isEmpty ? "" : trimmed
    }

}

public enum RecordingLibraryError: Error, LocalizedError, Equatable {
    case invalidIdentifier
    case invalidResponse
    case negativeTotal
    case pageTooLarge
    case listExceedsTotal

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            return "録画番組IDが不正です。"
        case .invalidResponse:
            return "録画番組一覧の応答形式が不正です。"
        case .negativeTotal:
            return "録画番組一覧の件数が不正です。"
        case .pageTooLarge:
            return "録画番組一覧の1ページ件数が上限を超えています。"
        case .listExceedsTotal:
            return "録画番組一覧の総件数と明細件数が一致しません。"
        }
    }
}

public extension RingonomiClient {
    /// Fetch one page from `/api/videos` or `/api/videos/search`.
    func recordings(
        query: RecordingQuery = RecordingQuery(),
        using session: URLSession = .shared
    ) async throws -> RecordingsResponse {
        let path = query.keyword.isEmpty
            ? ["api", "videos"]
            : ["api", "videos", "search"]
        var queryItems = [
            URLQueryItem(name: "page", value: String(query.page)),
            URLQueryItem(name: "order", value: query.order.rawValue)
        ]
        if !query.keyword.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query.keyword))
        }
        return try await fetchLibrary(path: path, queryItems: queryItems, as: RecordingsResponse.self, using: session)
    }

    /// Fetch one recorded program detail.  The route expects the
    /// `RecordedProgram.id`, not `RecordedVideo.id`.
    func recording(
        id: Int,
        using session: URLSession = .shared
    ) async throws -> Recording {
        guard id > 0 else { throw RecordingLibraryError.invalidIdentifier }
        let recording = try await fetchLibrary(
            path: ["api", "videos", String(id)],
            queryItems: [],
            as: Recording.self,
            using: session
        )
        guard recording.id == id else { throw RecordingLibraryError.invalidResponse }
        return recording
    }
}

private extension RingonomiClient {
    func fetchLibrary<T: Decodable & Sendable>(
        path: [String],
        queryItems: [URLQueryItem],
        as type: T.Type,
        using session: URLSession
    ) async throws -> T {
        guard var components = URLComponents(
            url: endpoint(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ConnectionError.invalidAddress
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw ConnectionError.invalidAddress }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        do {
            let (data, response) = try await backendData(for: request, using: session)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw ConnectionError.http(0)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ConnectionError.http(response.statusCode)
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
