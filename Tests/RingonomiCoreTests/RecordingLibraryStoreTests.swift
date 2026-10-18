import Foundation
import XCTest
@testable import RingonomiCore

private actor RecordingLibraryFetchGate {
    private var requests: [RecordingLibraryRequest] = []
    private var continuations: [CheckedContinuation<RecordingsResponse, Error>?] = []

    func fetch(_ request: RecordingLibraryRequest) async throws -> RecordingsResponse {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(request)
            continuations.append(continuation)
        }
    }

    func waitForRequestCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests.count < count {
            guard ContinuousClock.now < deadline else {
                let pending = continuations.compactMap { $0 }
                continuations = Array(repeating: nil, count: continuations.count)
                for continuation in pending {
                    continuation.resume(throwing: URLError(.timedOut))
                }
                return false
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    func requestCount() -> Int { requests.count }

    func finish(
        requestAt index: Int,
        with result: Result<RecordingsResponse, Error>
    ) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else {
            return
        }
        continuations[index] = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class RecordingLibraryStoreTests: XCTestCase {
    private func waitForRequestCount(
        _ gate: RecordingLibraryFetchGate,
        _ count: Int
    ) async {
        let reached = await gate.waitForRequestCount(count)
        XCTAssertTrue(reached, "timed out waiting for fetch request \(count)")
    }

    private func request(
        keyword: String,
        address: String = "https://example.invalid/tv",
        revision: Int = 0
    ) -> RecordingLibraryRequest {
        RecordingLibraryRequest(
            address: address,
            query: RecordingQuery(keyword: keyword),
            revision: revision
        )
    }

    private func response(total: Int, recordingID: Int) throws -> RecordingsResponse {
        let data = Data(
            """
            {
              "total": \(total),
              "recorded_programs": [{
                "id": \(recordingID),
                "title": "番組\(recordingID)",
                "description": "説明",
                "is_free": true,
                "recorded_video": {"id": \(recordingID + 100), "duration": 120.0}
              }]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RecordingsResponse.self, from: data)
    }

    func testReturningToEarlierRequestRefetchesAfterIntermediateRequest() async throws {
        let gate = RecordingLibraryFetchGate()
        let store = RecordingLibraryStore(fetch: { request in
            try await gate.fetch(request)
        })
        let requestA = request(keyword: "A")
        let requestB = request(keyword: "B")
        let responseA = try response(total: 1, recordingID: 1)
        let responseB = try response(total: 1, recordingID: 2)

        let initial = Task { @MainActor in await store.load(requestA) }
        await waitForRequestCount(gate, 1)
        await gate.finish(requestAt: 0, with: .success(responseA))
        await initial.value
        XCTAssertEqual(store.loadedRequest, requestA)
        XCTAssertEqual(store.items.first?.id, 1)

        let intermediate = Task { @MainActor in await store.load(requestB) }
        await waitForRequestCount(gate, 2)
        XCTAssertNil(store.loadedRequest)
        XCTAssertTrue(store.items.isEmpty)

        let returned = Task { @MainActor in await store.load(requestA) }
        await waitForRequestCount(gate, 3)
        XCTAssertNil(store.loadedRequest)

        await gate.finish(requestAt: 2, with: .success(responseA))
        await returned.value
        XCTAssertEqual(store.loadedRequest, requestA)
        XCTAssertEqual(store.items.first?.id, 1)

        // The older B response arrives after the returned A request and must
        // not clear or replace the data that is currently on screen.
        await gate.finish(requestAt: 1, with: .success(responseB))
        await intermediate.value
        XCTAssertEqual(store.loadedRequest, requestA)
        XCTAssertEqual(store.items.first?.id, 1)
        XCTAssertFalse(store.loading)
    }

    func testLateSuccessCannotOverwriteLatestSuccess() async throws {
        let gate = RecordingLibraryFetchGate()
        let store = RecordingLibraryStore(fetch: { request in
            try await gate.fetch(request)
        })
        let oldRequest = request(keyword: "old")
        let latestRequest = request(keyword: "latest")
        let oldResponse = try response(total: 1, recordingID: 11)
        let latestResponse = try response(total: 1, recordingID: 22)

        let oldTask = Task { @MainActor in await store.load(oldRequest) }
        await waitForRequestCount(gate, 1)
        let latestTask = Task { @MainActor in await store.load(latestRequest) }
        await waitForRequestCount(gate, 2)

        await gate.finish(requestAt: 1, with: .success(latestResponse))
        await latestTask.value
        XCTAssertEqual(store.loadedRequest, latestRequest)
        XCTAssertEqual(store.items.first?.id, 22)

        await gate.finish(requestAt: 0, with: .success(oldResponse))
        await oldTask.value
        XCTAssertEqual(store.loadedRequest, latestRequest)
        XCTAssertEqual(store.items.first?.id, 22)
        XCTAssertNil(store.error)
    }

    func testLateErrorAndCancellationDoNotClearLatestState() async throws {
        let gate = RecordingLibraryFetchGate()
        let store = RecordingLibraryStore(fetch: { request in
            try await gate.fetch(request)
        })
        let oldErrorRequest = request(keyword: "old-error")
        let oldCancellationRequest = request(keyword: "old-cancel")
        let latestRequest = request(keyword: "latest")
        let latestResponse = try response(total: 1, recordingID: 33)

        let oldErrorTask = Task { @MainActor in await store.load(oldErrorRequest) }
        await waitForRequestCount(gate, 1)
        let latestTask = Task { @MainActor in await store.load(latestRequest) }
        await waitForRequestCount(gate, 2)
        await gate.finish(
            requestAt: 0,
            with: .failure(URLError(.cannotConnectToHost))
        )
        await oldErrorTask.value

        // A newer request is still in flight, so the old error cannot become
        // the visible state or stop its loading indicator.
        XCTAssertTrue(store.loading)
        XCTAssertNil(store.error)

        await gate.finish(requestAt: 1, with: .success(latestResponse))
        await latestTask.value
        XCTAssertEqual(store.items.first?.id, 33)
        XCTAssertEqual(store.loadedRequest, latestRequest)

        let oldCancellationTask = Task { @MainActor in await store.load(oldCancellationRequest) }
        await waitForRequestCount(gate, 3)
        let newestRequest = request(keyword: "newest")
        let newestResponse = try response(total: 1, recordingID: 34)
        let newestTask = Task { @MainActor in await store.load(newestRequest) }
        await waitForRequestCount(gate, 4)
        await gate.finish(requestAt: 3, with: .success(newestResponse))
        await newestTask.value

        // The cancellation is delivered after a newer success and must not
        // clear the data from that request.
        oldCancellationTask.cancel()
        await gate.finish(requestAt: 2, with: .failure(CancellationError()))
        await oldCancellationTask.value

        XCTAssertEqual(store.items.first?.id, 34)
        XCTAssertEqual(store.loadedRequest, newestRequest)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
    }

    func testLoadedRequestSkipsRefetchAndKeepsItems() async throws {
        let gate = RecordingLibraryFetchGate()
        let store = RecordingLibraryStore(fetch: { request in
            try await gate.fetch(request)
        })
        let loaded = request(keyword: "same")
        let loadedResponse = try response(total: 1, recordingID: 44)

        let first = Task { @MainActor in await store.load(loaded) }
        await waitForRequestCount(gate, 1)
        await gate.finish(requestAt: 0, with: .success(loadedResponse))
        await first.value

        await store.load(loaded)

        let requestCount = await gate.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(store.loadedRequest, loaded)
        XCTAssertEqual(store.items.first?.id, 44)
    }

    func testEmptyAddressClearsStateWithoutFetching() async throws {
        let gate = RecordingLibraryFetchGate()
        let store = RecordingLibraryStore(fetch: { request in
            try await gate.fetch(request)
        })
        let loaded = request(keyword: "loaded")
        let loadedResponse = try response(total: 1, recordingID: 55)

        let first = Task { @MainActor in await store.load(loaded) }
        await waitForRequestCount(gate, 1)
        await gate.finish(requestAt: 0, with: .success(loadedResponse))
        await first.value

        await store.load(request(keyword: "empty", address: ""))

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.total, 0)
        XCTAssertNil(store.error)
        XCTAssertNil(store.loadedRequest)
        XCTAssertFalse(store.loading)
        let requestCount = await gate.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testPageCountUsesOverflowSafePageSizeCalculation() async throws {
        let largeResponse = try response(total: Int.max, recordingID: 66)
        let store = RecordingLibraryStore(fetch: { _ in largeResponse })
        let request = request(keyword: "large")

        await store.load(request)

        XCTAssertEqual(
            store.pageCount,
            (Int.max - 1) / RecordingQuery.pageSize + 1
        )
        XCTAssertEqual(store.loadedRequest, request)
        XCTAssertEqual(store.items.first?.id, 66)
    }
}
