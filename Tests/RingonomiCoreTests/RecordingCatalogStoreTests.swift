import Foundation
import XCTest
@testable import RingonomiCore

private actor CatalogFetchGate {
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

    func requestCount() -> Int { requests.count }
}

private actor CatalogScript {
    private var responses: [Result<RecordingsResponse, Error>]
    private var requests: [RecordingLibraryRequest] = []

    init(_ responses: [Result<RecordingsResponse, Error>]) {
        self.responses = responses
    }

    func fetch(_ request: RecordingLibraryRequest) throws -> RecordingsResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        return try responses.removeFirst().get()
    }

    func allRequests() -> [RecordingLibraryRequest] { requests }
}

@MainActor
final class RecordingCatalogStoreTests: XCTestCase {
    private let address = "https://example.invalid/tv"

    private func request(
        keyword: String = "",
        revision: Int = 0
    ) -> RecordingCatalogRequest {
        RecordingCatalogRequest(address: address, keyword: keyword, revision: revision)
    }

    private func response(total: Int, ids: [Int]) throws -> RecordingsResponse {
        let rows = ids.map { id in
            """
            {"id":\(id),"title":"番組\(id)","description":"説明","is_free":true,"recorded_video":{"id":\(id + 100_000),"duration":60.0}}
            """
        }.joined(separator: ",")
        let data = Data(
            "{\"total\":\(total),\"recorded_programs\":[\(rows)]}".utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RecordingsResponse.self, from: data)
    }

    private func waitForRequest(
        _ gate: CatalogFetchGate,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let reached = await gate.waitForRequestCount(count)
        XCTAssertTrue(reached, "timed out waiting for request \(count)", file: file, line: line)
    }

    func testStaleAThenBThenAOnlyLatestCompleteCatalogCommits() async throws {
        let gate = CatalogFetchGate()
        let store = RecordingCatalogStore(fetch: { request in
            try await gate.fetch(request)
        })
        let requestA = request(keyword: "A")
        let requestB = request(keyword: "B")
        let responseA = try response(total: 1, ids: [3])

        let firstA = Task { @MainActor in await store.load(requestA) }
        await waitForRequest(gate, count: 1)
        let b = Task { @MainActor in await store.load(requestB) }
        await waitForRequest(gate, count: 2)
        let secondA = Task { @MainActor in await store.load(requestA) }
        await waitForRequest(gate, count: 3)

        await gate.finish(requestAt: 2, with: .success(responseA))
        await waitForRequest(gate, count: 4)
        await gate.finish(requestAt: 3, with: .success(responseA))
        await secondA.value
        XCTAssertEqual(store.loadedRequest, requestA)
        XCTAssertEqual(store.index?.recordings.map(\.id), [3])

        await gate.finish(requestAt: 0, with: .success(try response(total: 1, ids: [1])))
        await gate.finish(requestAt: 1, with: .success(try response(total: 1, ids: [2])))
        await firstA.value
        await b.value

        XCTAssertEqual(store.loadedRequest, requestA)
        XCTAssertEqual(store.index?.recordings.map(\.id), [3])
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
    }

    func testCancellationLeavesNoPartialCatalog() async throws {
        let gate = CatalogFetchGate()
        let store = RecordingCatalogStore(fetch: { request in
            try await gate.fetch(request)
        })
        let task = Task { @MainActor in await store.load(request(keyword: "cancel")) }
        await waitForRequest(gate, count: 1)
        task.cancel()
        await gate.finish(requestAt: 0, with: .success(try response(total: 1, ids: [8])))
        await task.value

        XCTAssertNil(store.index)
        XCTAssertNil(store.loadedRequest)
        XCTAssertEqual(store.loadedCount, 0)
        XCTAssertEqual(store.total, 0)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
    }

    func testDuplicateAcrossPagesIsRejectedWithoutPartialIndex() async throws {
        let script = CatalogScript([
            .success(try response(total: 31, ids: Array(1...30))),
            .success(try response(total: 31, ids: [30]))
        ])
        let store = RecordingCatalogStore(fetch: { request in
            try await script.fetch(request)
        })

        await store.load(request(keyword: "duplicate"))

        XCTAssertNil(store.index)
        XCTAssertNil(store.loadedRequest)
        XCTAssertEqual(store.loadedCount, 30)
        XCTAssertTrue(store.error?.contains("重複") == true)
    }

    func testTotalChangeAndMissingPageRowsAreRejected() async throws {
        let changedScript = CatalogScript([
            .success(try response(total: 31, ids: Array(1...30))),
            .success(try response(total: 32, ids: [31]))
        ])
        let changedStore = RecordingCatalogStore(fetch: { request in
            try await changedScript.fetch(request)
        })
        await changedStore.load(request(keyword: "changed"))
        XCTAssertNil(changedStore.index)
        XCTAssertTrue(changedStore.error?.contains("更新") == true)

        let missingScript = CatalogScript([
            .success(try response(total: 61, ids: Array(1...30))),
            .success(try response(total: 61, ids: Array(31...59)))
        ])
        let missingStore = RecordingCatalogStore(fetch: { request in
            try await missingScript.fetch(request)
        })
        await missingStore.load(request(keyword: "missing"))
        XCTAssertNil(missingStore.index)
        XCTAssertTrue(missingStore.error?.contains("ページ件数") == true)
    }

    func testFinalPageOneChangeIsDetectedAfterAllPages() async throws {
        let script = CatalogScript([
            .success(try response(total: 31, ids: Array(1...30))),
            .success(try response(total: 31, ids: [31])),
            .success(try response(total: 31, ids: Array(1...29) + [99]))
        ])
        let store = RecordingCatalogStore(fetch: { request in
            try await script.fetch(request)
        })

        await store.load(request(keyword: "verify"))

        XCTAssertNil(store.index)
        XCTAssertNil(store.loadedRequest)
        XCTAssertEqual(store.loadedCount, 31)
        XCTAssertTrue(store.error?.contains("更新") == true)
    }

    func testStableAllPagesUsesCanonicalThirtyPageQueriesAndCommits() async throws {
        let pageOne = try response(total: 61, ids: Array(1...30))
        let pageTwo = try response(total: 61, ids: Array(31...60))
        let pageThree = try response(total: 61, ids: [61])
        let script = CatalogScript([
            .success(pageOne), .success(pageTwo), .success(pageThree), .success(pageOne)
        ])
        let store = RecordingCatalogStore(fetch: { request in
            try await script.fetch(request)
        })
        let catalogRequest = request(keyword: "  news  ", revision: 4)

        await store.load(catalogRequest)

        XCTAssertNotNil(store.index)
        XCTAssertEqual(store.loadedRequest, request(keyword: "news", revision: 4))
        XCTAssertEqual(store.loadedCount, 61)
        XCTAssertEqual(store.total, 61)
        let requests = await script.allRequests()
        XCTAssertEqual(requests.map { $0.query.page }, [1, 2, 3, 1])
        XCTAssertTrue(requests.allSatisfy { $0.query.order == .newest })
        XCTAssertTrue(requests.allSatisfy { $0.query.keyword == "news" })
        XCTAssertTrue(requests.allSatisfy { $0.address == address })
        XCTAssertTrue(requests.allSatisfy { $0.revision == 4 })
        XCTAssertEqual(store.index?.recordings.count, 61)
    }

    func testMaximumLimitRejectsIntMaxWithoutPageArithmeticOverflow() async throws {
        let script = CatalogScript([
            .success(try response(total: Int.max, ids: Array(1...30)))
        ])
        let store = RecordingCatalogStore(fetch: { request in
            try await script.fetch(request)
        })

        await store.load(request(keyword: "too broad"))

        XCTAssertNil(store.index)
        XCTAssertEqual(store.total, 0)
        XCTAssertEqual(store.loadedCount, 0)
        XCTAssertTrue(store.error?.contains("検索条件") == true)
        let requests = await script.allRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testNetworkFailureUsesFriendlyJapaneseError() async throws {
        let store = RecordingCatalogStore(fetch: { _ in
            throw ConnectionError.http(503)
        })

        await store.load(request(keyword: "network"))

        XCTAssertNil(store.index)
        XCTAssertTrue(store.error?.contains("接続") == true)
        XCTAssertFalse(store.loading)
    }
}
