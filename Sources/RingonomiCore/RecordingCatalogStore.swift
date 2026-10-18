import Combine
import Foundation

/// Identity of a complete recording-catalog request.
///
/// The revision is intentionally part of the identity so a caller can force
/// a refresh without changing the visible search keyword.
public struct RecordingCatalogRequest: Equatable, Sendable {
    public let address: String
    public let keyword: String
    public let revision: Int

    public init(address: String, keyword: String = "", revision: Int = 0) {
        self.address = address
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyword = trimmed.isEmpty ? "" : trimmed
        self.revision = revision
    }
}

private enum RecordingCatalogLoadError: Error {
    case tooManyPrograms(Int)
    case totalChanged
    case incompletePage
    case duplicateIdentifier(Int)
    case firstPageChanged
    case invalidCatalog
}

/// Main-actor state for a complete, validated recording catalog.
///
/// The server exposes recordings in pages.  This store deliberately waits
/// until every page and a final page-one consistency check succeed before
/// publishing a grouping index, so the UI never classifies a partial list.
@MainActor
public final class RecordingCatalogStore: ObservableObject {
    public static let maximumPrograms = 20_000

    @Published public private(set) var index: RecordingGroupingIndex?
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    @Published public private(set) var loadedCount = 0
    @Published public private(set) var total = 0
    @Published public private(set) var loadedRequest: RecordingCatalogRequest?

    private let fetch: RecordingLibraryFetch
    private var generation = 0

    public init(fetch: RecordingLibraryFetch? = nil) {
        if let fetch {
            self.fetch = fetch
        } else {
            self.fetch = { request in
                let client = try RingonomiClient(address: request.address)
                return try await client.recordings(query: request.query)
            }
        }
    }

    /// Loads all pages for a request and publishes the grouping index only
    /// after the response has remained internally consistent.
    public func load(_ request: RecordingCatalogRequest) async {
        guard loadedRequest != request else { return }

        generation &+= 1
        let expectedGeneration = generation
        index = nil
        loadedRequest = nil
        loadedCount = 0
        total = 0
        error = nil

        guard !request.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "接続先を設定してください。"
            loading = false
            return
        }

        loading = true
        defer {
            if expectedGeneration == generation {
                loading = false
            }
        }

        do {
            let firstResponse = try await fetchPage(
                request: request,
                page: 1,
                expectedGeneration: expectedGeneration
            )
            try Task.checkCancellation()
            guard expectedGeneration == generation else { return }

            let expectedTotal = firstResponse.total
            guard expectedTotal >= 0 else { throw RecordingCatalogLoadError.totalChanged }
            guard expectedTotal <= Self.maximumPrograms else {
                throw RecordingCatalogLoadError.tooManyPrograms(expectedTotal)
            }

            let firstExpectedCount = expectedItemCount(total: expectedTotal, page: 1)
            guard firstResponse.recordedPrograms.count == firstExpectedCount else {
                throw RecordingCatalogLoadError.incompletePage
            }

            var recordings = firstResponse.recordedPrograms
            var identifiers = Set<Int>(minimumCapacity: recordings.count)
            for recording in recordings {
                guard identifiers.insert(recording.id).inserted else {
                    throw RecordingCatalogLoadError.duplicateIdentifier(recording.id)
                }
            }
            total = expectedTotal
            loadedCount = recordings.count

            if expectedTotal > 0 {
                let pageCount = pageCount(total: expectedTotal)
                var page = 2
                while page <= pageCount {
                    try Task.checkCancellation()
                    guard expectedGeneration == generation else { return }

                    let response = try await fetchPage(
                        request: request,
                        page: page,
                        expectedGeneration: expectedGeneration
                    )
                    try Task.checkCancellation()
                    guard expectedGeneration == generation else { return }
                    guard response.total == expectedTotal else {
                        throw RecordingCatalogLoadError.totalChanged
                    }

                    let expectedCount = expectedItemCount(total: expectedTotal, page: page)
                    guard response.recordedPrograms.count == expectedCount else {
                        throw RecordingCatalogLoadError.incompletePage
                    }
                    for recording in response.recordedPrograms {
                        guard identifiers.insert(recording.id).inserted else {
                            throw RecordingCatalogLoadError.duplicateIdentifier(recording.id)
                        }
                    }
                    recordings.append(contentsOf: response.recordedPrograms)
                    loadedCount = recordings.count
                    page += 1
                }
            }

            try Task.checkCancellation()
            guard expectedGeneration == generation else { return }

            // Read page one once more.  This cannot make the server snapshot
            // atomic, but detects the common case where the catalog changed
            // while later pages were being fetched.
            let verification = try await fetchPage(
                request: request,
                page: 1,
                expectedGeneration: expectedGeneration
            )
            try Task.checkCancellation()
            guard expectedGeneration == generation else { return }
            guard verification.total == expectedTotal,
                  verification.recordedPrograms.map(\.id) == firstResponse.recordedPrograms.map(\.id) else {
                throw RecordingCatalogLoadError.firstPageChanged
            }

            let builtIndex: RecordingGroupingIndex
            do {
                builtIndex = try await buildIndex(recordings)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RecordingCatalogLoadError.invalidCatalog
            }
            try Task.checkCancellation()
            guard expectedGeneration == generation else { return }

            index = builtIndex
            loadedCount = recordings.count
            loadedRequest = request
        } catch is CancellationError {
            guard expectedGeneration == generation else { return }
            // Cancellation is an expected transition when the caller starts
            // another request.  Leave the current request with no partial
            // catalog or stale error.
            index = nil
            loadedRequest = nil
            loadedCount = 0
            total = 0
            error = nil
        } catch {
            guard expectedGeneration == generation else { return }
            guard !Task.isCancelled else {
                index = nil
                loadedRequest = nil
                loadedCount = 0
                total = 0
                self.error = nil
                return
            }
            index = nil
            loadedRequest = nil
            self.error = message(for: error)
        }
    }

    private func pageCount(total: Int) -> Int {
        guard total > 0 else { return 0 }
        // Avoid `total + pageSize - 1` overflow for untrusted totals.
        return (total - 1) / RecordingQuery.pageSize + 1
    }

    private func expectedItemCount(total: Int, page: Int) -> Int {
        guard total > 0, page > 0 else { return 0 }
        let offset = (page - 1) * RecordingQuery.pageSize
        guard offset < total else { return 0 }
        return min(RecordingQuery.pageSize, total - offset)
    }

    private func fetchPage(
        request: RecordingCatalogRequest,
        page: Int,
        expectedGeneration: Int
    ) async throws -> RecordingsResponse {
        try Task.checkCancellation()
        guard expectedGeneration == generation else { throw CancellationError() }
        let query = RecordingQuery(keyword: request.keyword, page: page, order: .newest)
        let libraryRequest = RecordingLibraryRequest(
            address: request.address,
            query: query,
            revision: request.revision
        )
        let response = try await fetch(libraryRequest)
        try Task.checkCancellation()
        guard expectedGeneration == generation else { throw CancellationError() }
        return response
    }

    private func buildIndex(_ recordings: [Recording]) async throws -> RecordingGroupingIndex {
        let task = Task.detached(priority: nil) {
            try Task.checkCancellation()
            let result = try RecordingGroupingIndex(recordings: recordings)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler(operation: {
            defer { task.cancel() }
            return try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func message(for error: Error) -> String {
        if let loadError = error as? RecordingCatalogLoadError {
            switch loadError {
            case .tooManyPrograms:
                return "録画番組が多すぎます。検索条件を狭めて再試行してください。"
            case .totalChanged, .firstPageChanged:
                return "録画一覧が更新されたため、完全な一覧を取得できませんでした。もう一度お試しください。"
            case .incompletePage:
                return "録画一覧のページ件数が不正です。もう一度お試しください。"
            case .duplicateIdentifier:
                return "録画一覧に重複した番組が含まれています。もう一度お試しください。"
            case .invalidCatalog:
                return "録画一覧の分類に失敗しました。もう一度お試しください。"
            }
        }
        if error is CancellationError { return "" }
        if error is ConnectionError || error is URLError {
            return "録画一覧を取得できませんでした。接続を確認して再試行してください。"
        }
        if error is RecordingLibraryError {
            return "録画一覧の応答を検証できませんでした。もう一度お試しください。"
        }
        return "録画一覧を取得できませんでした。もう一度お試しください。"
    }
}
