import Foundation
import XCTest
@testable import RingonomiCore

private actor PlaybackRelayFixture: PlaybackMediaRelaying {
    let local: URL
    let waits: Bool
    let failsStartup: Bool
    nonisolated let failurePolicy: PlaybackMediaFailurePolicy
    var lastFailure: HTTPMediaRelayFailure?
    private(set) var starts = 0
    private(set) var stops = 0
    private var continuation: CheckedContinuation<URL, Error>?
    init(_ id: Int, waits: Bool = false, failsStartup: Bool = false,
         failurePolicy: PlaybackMediaFailurePolicy = .playerMayRecover) {
        local = URL(string: "http://127.0.0.1:12345/media/fixture-\(id).bin")!
        self.waits = waits
        self.failsStartup = failsStartup
        self.failurePolicy = failurePolicy
    }
    func start(source: URL, kind: HTTPMediaResourceKind) async throws -> URL {
        starts += 1
        if failsStartup { throw HLSRelayError.stopped }
        if waits { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return local
    }
    func stop() {
        stops += 1
        continuation?.resume(throwing: HLSRelayError.stopped); continuation = nil
    }
    func setFailure(_ failure: HTTPMediaRelayFailure) { lastFailure = failure }
}

private final class PlaybackRelayQueue: @unchecked Sendable {
    let lock = NSLock()
    private var relays: [PlaybackRelayFixture]
    init(_ relays: [PlaybackRelayFixture]) { self.relays = relays }
    func next() -> PlaybackRelayFixture? {
        lock.lock(); defer { lock.unlock() }
        return relays.isEmpty ? nil : relays.removeFirst()
    }
}

@MainActor
final class PlaybackMediaConnectionTests: XCTestCase {
    private let source = URL(string: "https://example.test/proxy/live.ts?session=fixture")!
    private func waitForStart(_ relay: PlaybackRelayFixture) async throws {
        for _ in 0..<100 {
            if await relay.starts > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Relay did not start")
    }

    func testAnonymousSourceDoesNotStartRelay() async throws {
        let client = try RingonomiClient(address: "https://example.test/")
        let owner = PlaybackMediaConnection(client: client)
        let result = try await owner.resolve(source: source, kind: .media) { _ in XCTFail("Unexpected failure") }
        XCTAssertEqual(result, source)
        await owner.stop()
    }

    func testReplacementStopsPreviousRelayAndReturnsNewGeneration() async throws {
        let first = PlaybackRelayFixture(1), second = PlaybackRelayFixture(2)
        let queue = PlaybackRelayQueue([first, second])
        let owner = PlaybackMediaConnection(makeRelay: { queue.next() })
        let a = try await owner.resolve(source: source, kind: .media) { _ in }
        let b = try await owner.resolve(source: source, kind: .media) { _ in }
        XCTAssertNotEqual(a, b)
        let firstStops = await first.stops; XCTAssertGreaterThan(firstStops, 0)
        await owner.stop()
        let secondStops = await second.stops; XCTAssertGreaterThan(secondStops, 0)
    }

    func testStartupFailureIsAnErrorInsteadOfSilentCancellation() async throws {
        let relay = PlaybackRelayFixture(1, failsStartup: true)
        let owner = PlaybackMediaConnection(makeRelay: { relay })
        do {
            _ = try await owner.resolve(source: source, kind: .playlist) { _ in }
            XCTFail("Expected startup failure")
        } catch { XCTAssertEqual(error as? HTTPMediaRelayFailure, .connection) }
        await owner.stop()
        let stops = await relay.stops; XCTAssertGreaterThan(stops, 0)
    }

    func testInvalidationCancelsPendingStartup() async throws {
        let relay = PlaybackRelayFixture(1, waits: true)
        let owner = PlaybackMediaConnection(makeRelay: { relay })
        let pending = Task { try await owner.resolve(source: source, kind: .playlist) { _ in } }
        try await waitForStart(relay)
        await owner.stop()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let stops = await relay.stops; XCTAssertGreaterThan(stops, 0)
    }

    func testOldTaskCancellationCannotRetireReplacement() async throws {
        let first = PlaybackRelayFixture(1, waits: true), second = PlaybackRelayFixture(2)
        let queue = PlaybackRelayQueue([first, second])
        let owner = PlaybackMediaConnection(makeRelay: { queue.next() })
        let old = Task { try await owner.resolve(source: source, kind: .media) { _ in XCTFail("Old generation failure") } }
        try await waitForStart(first)
        let replacement = try await owner.resolve(source: source, kind: .media) { _ in }
        old.cancel()
        do { _ = try await old.value; XCTFail("Old generation returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        await Task.yield()
        let secondURL = await second.local
        XCTAssertEqual(replacement, secondURL)
        let stops = await second.stops; XCTAssertEqual(stops, 0)
        await owner.stop()
    }

    func testCallerCancellationStopsPendingRelay() async throws {
        let relay = PlaybackRelayFixture(1, waits: true)
        let owner = PlaybackMediaConnection(makeRelay: { relay })
        let pending = Task { try await owner.resolve(source: source, kind: .media) { _ in } }
        try await waitForStart(relay)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await owner.stop()
        let stops = await relay.stops; XCTAssertGreaterThan(stops, 0)
    }

    func testTransientFailureRemainsWithDecoderButAuthenticationFailureIsReported() async throws {
        let relay = PlaybackRelayFixture(1)
        let owner = PlaybackMediaConnection(makeRelay: { relay }, failurePollInterval: .milliseconds(10))
        var errors: [HTTPMediaRelayFailure] = []
        _ = try await owner.resolve(source: source, kind: .media) { errors.append($0) }
        await relay.setFailure(.connection)
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertTrue(errors.isEmpty)
        await relay.setFailure(.authenticationRequired)
        for _ in 0..<100 {
            if !errors.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(errors, [.authenticationRequired])
        await owner.stop()
    }

    func testTerminalConnectionFailureIsReportedForPersistentRelay() async throws {
        let relay = PlaybackRelayFixture(1, failurePolicy: .connectionIsTerminal)
        let owner = PlaybackMediaConnection(makeRelay: { relay }, failurePollInterval: .milliseconds(10))
        var errors: [HTTPMediaRelayFailure] = []
        _ = try await owner.resolve(source: source, kind: .media) { errors.append($0) }
        await relay.setFailure(.connection)
        for _ in 0..<100 {
            if !errors.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(errors, [.connection])
        await owner.stop()
    }

    func testInvalidatedGenerationDoesNotDeliverLateFailure() async throws {
        let relay = PlaybackRelayFixture(1)
        let owner = PlaybackMediaConnection(makeRelay: { relay }, failurePollInterval: .milliseconds(10))
        _ = try await owner.resolve(source: source, kind: .playlist) { _ in XCTFail("Retired generation delivered failure") }
        await owner.stop()
        await relay.setFailure(.unsupportedPlaylist)
        try await Task.sleep(for: .milliseconds(25))
    }

    func testStoppedPersistentRelayDoesNotDeliverLateConnectionFailure() async throws {
        let relay = PlaybackRelayFixture(1, failurePolicy: .connectionIsTerminal)
        let owner = PlaybackMediaConnection(makeRelay: { relay }, failurePollInterval: .milliseconds(10))
        var errors: [HTTPMediaRelayFailure] = []
        _ = try await owner.resolve(source: source, kind: .media) { errors.append($0) }
        await owner.stop()
        await relay.setFailure(.connection)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(errors.isEmpty)
    }

    func testDescriptionsHideServerAndSession() {
        let owner = PlaybackMediaConnection(makeRelay: { nil })
        let description = [String(describing: owner), String(reflecting: owner),
                           Mirror(reflecting: owner).children.map { String(reflecting: $0.value) }.joined()].joined()
        XCTAssertFalse(description.contains("example.test"))
        XCTAssertFalse(description.contains("session=fixture"))
    }
}
