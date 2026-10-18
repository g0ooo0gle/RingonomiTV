import Combine
import Foundation

/// The request identity used by the recording-library store.
///
/// `revision` lets the UI explicitly reload an otherwise identical page.  It
/// is part of the identity so a refresh cannot be mistaken for an already
/// loaded result.
public struct RecordingLibraryRequest: Equatable, Sendable {
    public let address: String
    public let query: RecordingQuery
    public let revision: Int

    public init(address: String, query: RecordingQuery, revision: Int = 0) {
        self.address = address
        self.query = query
        self.revision = revision
    }
}

/// Injectable page loader used by `RecordingLibraryStore`.
///
/// The application uses the default implementation, while tests and other
/// clients can provide a deterministic loader without making network calls.
public typealias RecordingLibraryFetch = @Sendable (RecordingLibraryRequest) async throws -> RecordingsResponse

/// Main-actor state for one recording-library view.
@MainActor
public final class RecordingLibraryStore: ObservableObject {
    @Published public private(set) var items: [Recording] = []
    @Published public private(set) var total = 0
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    @Published public private(set) var loadedRequest: RecordingLibraryRequest?

    private let fetch: RecordingLibraryFetch
    private var generation = 0

    /// Creates a store.  Omitting `fetch` uses the normal Ringonomi server
    /// client; supplying it makes the state machine independently testable.
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

    /// Number of pages for the current total.  The calculation avoids
    /// `total + pageSize - 1`, which can overflow for an untrusted Int.max.
    public var pageCount: Int {
        guard total > 0 else { return 1 }
        return (total - 1) / RecordingQuery.pageSize + 1
    }

    /// Loads a page and commits it only if it is still the newest request.
    ///
    /// A new request invalidates the previous committed identity immediately.
    /// This is necessary when a caller returns to a request whose old result
    /// was cleared while another request was in flight.  Late replies and
    /// errors are ignored by the generation check.
    public func load(_ request: RecordingLibraryRequest) async {
        guard loadedRequest != request else { return }

        generation &+= 1
        let expectedGeneration = generation
        loadedRequest = nil
        items = []
        total = 0
        error = nil

        guard !request.address.isEmpty else {
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
            let response = try await fetch(request)
            try Task.checkCancellation()
            guard expectedGeneration == generation else { return }

            total = response.total
            items = response.recordedPrograms
            loadedRequest = request
        } catch is CancellationError {
            // Cancellation is expected when SwiftUI replaces a task.  The
            // defer above still closes the spinner for the current request.
            guard expectedGeneration == generation else { return }
        } catch {
            guard expectedGeneration == generation else { return }
            guard !Task.isCancelled else { return }
            self.error = "録画一覧を取得できませんでした。接続を確認して再試行してください。"
        }
    }
}
