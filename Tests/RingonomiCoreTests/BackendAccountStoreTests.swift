import Foundation
import XCTest
@testable import RingonomiCore

@MainActor
final class BackendAccountStoreTests: XCTestCase {
    private let address = "https://example.invalid/proxy/tv/"
    private var session: URLSession!
    private var storage: MemoryAccountStorage!

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountStoreURLProtocol.self]
        session = URLSession(configuration: configuration)
        storage = MemoryAccountStorage()
        AccountStoreURLProtocol.requests = []
        AccountStoreURLProtocol.handler = nil
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        AccountStoreURLProtocol.handler = nil
    }

    func testLoginVerifiesUserBeforeSavingAndChangesRevision() async throws {
        AccountStoreURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "token" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, Data(#"{"access_token":"fixture-token","token_type":"bearer"}"#.utf8), 0)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            return (200, Data(#"{"id":1,"name":"viewer","is_admin":false}"#.utf8), 0)
        }
        let store = BackendAccountStore(storage: storage, session: session)
        await store.login(address: address, username: "viewer", password: "fixture-password")
        XCTAssertEqual(store.user?.name, "viewer")
        XCTAssertTrue(store.hasSavedCredential)
        XCTAssertEqual(store.revision, 1)
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.error)
        let key = try RingonomiClient(address: address).accountKeyString
        XCTAssertEqual(try storage.load(for: key)?.rawValue, "fixture-token")
    }

    func testLoginFailureDoesNotPersistTokenOrExposeServerDetail() async {
        for failingProfile in [false, true] {
            AccountStoreURLProtocol.handler = { request in
                if failingProfile && request.url?.lastPathComponent == "token" {
                    return (200, Data(#"{"access_token":"fixture-token","token_type":"bearer"}"#.utf8), 0)
                }
                return (failingProfile ? 403 : 401, Data(#"{"detail":"private-response-detail"}"#.utf8), 0)
            }
            let store = BackendAccountStore(storage: storage, session: session)
            await store.login(address: address, username: "viewer", password: "wrong")
            XCTAssertNil(store.user)
            XCTAssertFalse(store.hasSavedCredential)
            XCTAssertEqual(store.revision, 0)
            XCTAssertNotNil(store.error)
            XCTAssertFalse(store.error?.contains("private-response-detail") ?? true)
            XCTAssertTrue(storage.values.isEmpty)
        }
    }

    func testKeychainWriteFailureDoesNotClaimLoginSucceeded() async {
        AccountStoreURLProtocol.handler = { request in
            request.url?.lastPathComponent == "token"
                ? (200, Data(#"{"access_token":"fixture-token","token_type":"bearer"}"#.utf8), 0)
                : (200, Data(#"{"id":1,"name":"viewer","is_admin":false}"#.utf8), 0)
        }
        storage.failWrites = true
        let store = BackendAccountStore(storage: storage, session: session)
        await store.login(address: address, username: "viewer", password: "fixture")
        XCTAssertNil(store.user)
        XCTAssertFalse(store.hasSavedCredential)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.revision, 0)
    }

    func testRestoreUsesSavedTokenWithoutSendingPassword() async throws {
        let key = try RingonomiClient(address: address).accountKeyString
        try storage.save(BackendAccessToken(rawValue: "saved-token"), for: key)
        AccountStoreURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/proxy/api/users/me")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer saved-token")
            return (200, Data(#"{"id":2,"name":"restored","is_admin":false}"#.utf8), 0)
        }
        let store = BackendAccountStore(storage: storage, session: session)
        await store.restore(address: address)
        XCTAssertEqual(store.user?.name, "restored")
        XCTAssertTrue(store.hasSavedCredential)
        XCTAssertEqual(store.revision, 0)
    }

    func testExpiredTokenRemovesOnlyCurrentServerCredential() async throws {
        let key = try RingonomiClient(address: address).accountKeyString
        try storage.save(BackendAccessToken(rawValue: "expired-token"), for: key)
        try storage.save(BackendAccessToken(rawValue: "other-token"), for: "https://other.invalid/")
        AccountStoreURLProtocol.handler = { _ in (401, Data(), 0) }
        let store = BackendAccountStore(storage: storage, session: session)
        await store.restore(address: address)
        XCTAssertNil(store.user)
        XCTAssertFalse(store.hasSavedCredential)
        XCTAssertNil(try storage.load(for: key))
        XCTAssertNotNil(try storage.load(for: "https://other.invalid/"))
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.revision, 1)
    }

    func testDeletionFailureRetiresCredentialAndOffersRetry() async throws {
        let key = try RingonomiClient(address: address).accountKeyString
        try storage.save(BackendAccessToken(rawValue: "old-token"), for: key)
        AccountStoreURLProtocol.handler = { _ in
            (200, Data(#"{"id":1,"name":"viewer","is_admin":false}"#.utf8), 0)
        }
        let store = BackendAccountStore(storage: storage, session: session)
        await store.restore(address: address)
        XCTAssertNotNil(store.user)
        storage.failRemovals = true
        store.logout(address: address)
        XCTAssertNil(store.user)
        XCTAssertFalse(store.hasSavedCredential)
        XCTAssertNil(try storage.load(for: key))
        XCTAssertTrue(store.removalPending)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.revision, 1)
        storage.failRemovals = false
        store.logout(address: address)
        XCTAssertFalse(store.removalPending)
        XCTAssertNil(store.error)
        XCTAssertTrue(storage.values.isEmpty)
    }

    func testExpiredCredentialIsRetiredEvenWhenDeletionFails() async throws {
        let key = try RingonomiClient(address: address).accountKeyString
        try storage.save(BackendAccessToken(rawValue: "expired-token"), for: key)
        storage.failRemovals = true
        AccountStoreURLProtocol.handler = { _ in (401, Data(), 0) }
        let store = BackendAccountStore(storage: storage, session: session)
        await store.restore(address: address)
        XCTAssertNil(store.user)
        XCTAssertFalse(store.hasSavedCredential)
        XCTAssertNil(try storage.load(for: key))
        XCTAssertTrue(store.removalPending)
        XCTAssertEqual(store.revision, 1)
    }

    func testPendingDeletionCanBeRetriedAfterStoreRecreation() async throws {
        let key = try RingonomiClient(address: address).accountKeyString
        try storage.save(BackendAccessToken(rawValue: "retired-token"), for: key)
        storage.failRemovals = true
        try? storage.remove(for: key)
        AccountStoreURLProtocol.handler = { _ in
            XCTFail("a retired token must not reach the network")
            return (500, Data(), 0)
        }
        let store = BackendAccountStore(storage: storage, session: session)
        await store.restore(address: address)
        XCTAssertTrue(store.removalPending)
        XCTAssertFalse(store.hasSavedCredential)
        XCTAssertNotNil(store.error)
        storage.failRemovals = false
        store.logout(address: address)
        XCTAssertFalse(store.removalPending)
        XCTAssertNil(store.error)
    }

    func testMissingCredentialInvalidatesPreviouslyLoadedStateOnlyOnce() async throws {
        let key = try RingonomiClient(address: address).accountKeyString
        try storage.save(BackendAccessToken(rawValue: "saved-token"), for: key)
        AccountStoreURLProtocol.handler = { _ in
            (200, Data(#"{"id":1,"name":"viewer","is_admin":false}"#.utf8), 0)
        }
        let store = BackendAccountStore(storage: storage, session: session)
        await store.restore(address: address)
        XCTAssertNotNil(store.user)
        try storage.remove(for: key)
        await store.restore(address: address)
        XCTAssertNil(store.user)
        XCTAssertFalse(store.hasSavedCredential)
        XCTAssertEqual(store.revision, 1)
        await store.restore(address: address)
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(AccountStoreURLProtocol.requests.count, 1)
    }

    func testLateRestoreCannotOverwriteNewServerState() async throws {
        for host in ["old", "new"] {
            let key = try RingonomiClient(address: "https://\(host).invalid").accountKeyString
            try storage.save(BackendAccessToken(rawValue: host + "-token"), for: key)
        }
        AccountStoreURLProtocol.handler = { request in
            let old = request.url?.host == "old.invalid"
            return (200, Data("{\"id\":1,\"name\":\"\(old ? "old" : "new")\",\"is_admin\":false}".utf8), old ? 0.15 : 0)
        }
        let store = BackendAccountStore(storage: storage, session: session)
        let pending = Task { await store.restore(address: "https://old.invalid") }
        await waitForRequests(1)
        await store.restore(address: "https://new.invalid")
        await pending.value
        XCTAssertEqual(store.user?.name, "new")
        XCTAssertTrue(store.hasSavedCredential)
        XCTAssertFalse(store.isBusy)
    }

    func testLogoutInvalidatesPendingLoginBeforeItCanPersist() async throws {
        AccountStoreURLProtocol.handler = { _ in
            (200, Data(#"{"access_token":"fixture-token","token_type":"bearer"}"#.utf8), 0.15)
        }
        let store = BackendAccountStore(storage: storage, session: session)
        let pending = Task { await store.login(address: address, username: "viewer", password: "fixture") }
        await waitForRequests(1)
        store.logout(address: address)
        await pending.value
        XCTAssertNil(store.user)
        XCTAssertFalse(store.hasSavedCredential)
        XCTAssertTrue(storage.values.isEmpty)
        XCTAssertEqual(AccountStoreURLProtocol.requests.count, 1)
    }

    func testCancelledLoginDoesNotPersistOrShowFailure() async {
        AccountStoreURLProtocol.handler = { _ in
            (200, Data(#"{"access_token":"fixture-token","token_type":"bearer"}"#.utf8), 0.15)
        }
        let store = BackendAccountStore(storage: storage, session: session)
        let pending = Task { await store.login(address: address, username: "viewer", password: "fixture") }
        await waitForRequests(1)
        pending.cancel()
        await pending.value
        XCTAssertNil(store.user)
        XCTAssertFalse(store.hasSavedCredential)
        XCTAssertTrue(storage.values.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isBusy)
    }

    private func waitForRequests(_ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while AccountStoreURLProtocol.requests.count < count && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertGreaterThanOrEqual(AccountStoreURLProtocol.requests.count, count)
    }
}

private final class MemoryAccountStorage: BackendCredentialStorage, @unchecked Sendable {
    // Access is confined to the main-actor account store and its test methods.
    var values: [String: BackendAccessToken] = [:]
    var failWrites = false
    var failRemovals = false
    private var retired = Set<String>()
    func load(for account: String) throws -> BackendAccessToken? {
        retired.contains(account) ? nil : values[account]
    }
    func save(_ token: BackendAccessToken, for account: String) throws {
        if failWrites { throw URLError(.cannotWriteToFile) }
        values[account] = token
        retired.remove(account)
    }
    func remove(for account: String) throws {
        retired.insert(account)
        if failRemovals { throw URLError(.cannotWriteToFile) }
        values[account] = nil
        retired.remove(account)
    }
    func isRemovalPending(for account: String) -> Bool { retired.contains(account) }
}

private final class AccountStoreURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data, Double))?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] {
        get { lock.lock(); defer { lock.unlock() }; return recorded }
        set { lock.lock(); recorded = newValue; lock.unlock() }
    }
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.recorded.append(request); Self.lock.unlock()
        guard let handler = Self.handler, let url = request.url else { return }
        let (code, data, delay) = handler(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            stateLock.lock(); defer { stateLock.unlock() }
            guard !stopped else { return }
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}
