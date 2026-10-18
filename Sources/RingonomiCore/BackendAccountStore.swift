import Combine
import Foundation

public protocol BackendCredentialStorage: Sendable {
    func load(for account: String) throws -> BackendAccessToken?
    func save(_ token: BackendAccessToken, for account: String) throws
    /// A failed physical deletion must still prevent subsequent `load` calls
    /// from reusing the credential. The caller can then offer a cleanup retry.
    func remove(for account: String) throws
    func isRemovalPending(for account: String) -> Bool
}

public extension BackendCredentialStorage {
    func isRemovalPending(for account: String) -> Bool { false }
}

/// Coordinates account operations without allowing a late reply to sign in to
/// a server that the user has already left or logged out of.
@MainActor
public final class BackendAccountStore: ObservableObject {
    @Published public private(set) var user: BackendUser?
    @Published public private(set) var hasSavedCredential = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var error: String?
    @Published public private(set) var revision = 0
    @Published public private(set) var removalPending = false

    private let storage: any BackendCredentialStorage
    private let session: URLSession
    private var generation = UUID()
    private var cancelActiveRequest: (() -> Void)?
    private var accountKey: String?

    public init(storage: any BackendCredentialStorage, session: URLSession = .shared) {
        self.storage = storage
        self.session = session
    }

    public func restore(address: String) async {
        let previousKey = accountKey
        let previouslySaved = hasSavedCredential || user != nil
        let expected = beginOperation()
        user = nil
        hasSavedCredential = false
        removalPending = false
        accountKey = nil
        defer { finishOperation(expected) }
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let anonymous = try RingonomiClient(address: address)
            let key = anonymous.accountKeyString
            accountKey = key
            removalPending = storage.isRemovalPending(for: key)
            guard let token = try storage.load(for: key) else {
                removalPending = storage.isRemovalPending(for: key)
                if previousKey == key, previouslySaved { revision &+= 1 }
                if removalPending { error = "保存したログイン情報の削除が未完了です。削除を再試行してください。" }
                return
            }
            hasSavedCredential = true
            let client = try RingonomiClient(address: address, accessToken: token)
            let session = self.session
            let result = try await perform { try await client.currentUser(using: session) }
            try Task.checkCancellation()
            guard generation == expected else { return }
            user = result
        } catch ConnectionError.http(401) {
            guard generation == expected, !Task.isCancelled else { return }
            hasSavedCredential = false
            revision &+= 1
            do {
                let client = try RingonomiClient(address: address)
                try storage.remove(for: client.accountKeyString)
                error = ConnectionError.http(401).localizedDescription
            } catch {
                removalPending = true
                self.error = ConnectionError.http(401).localizedDescription + " " + error.localizedDescription
            }
        } catch {
            guard generation == expected, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    public func login(address: String, username: String, password: String) async {
        let expected = beginOperation()
        defer { finishOperation(expected) }
        do {
            let anonymous = try RingonomiClient(address: address)
            let session = self.session
            let (token, result) = try await perform {
                let token = try await anonymous.login(username: username, password: password, using: session)
                try Task.checkCancellation()
                let client = try RingonomiClient(address: address, accessToken: token)
                let result = try await client.currentUser(using: session)
                return (token, result)
            }
            try Task.checkCancellation()
            guard generation == expected else { return }
            // Verify the user before replacing a previously stored credential.
            try storage.save(token, for: anonymous.accountKeyString)
            accountKey = anonymous.accountKeyString
            hasSavedCredential = true
            removalPending = false
            user = result
            revision &+= 1
        } catch {
            guard generation == expected, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    public func logout(address: String) {
        cancelCurrentOperation()
        error = nil
        user = nil
        hasSavedCredential = false
        removalPending = false
        revision &+= 1
        do {
            let client = try RingonomiClient(address: address)
            try storage.remove(for: client.accountKeyString)
        } catch { removalPending = true; self.error = error.localizedDescription }
    }

    public func cancelCurrentOperation() {
        cancelActiveRequest?()
        cancelActiveRequest = nil
        generation = UUID()
        isBusy = false
    }

    private func beginOperation() -> UUID {
        cancelCurrentOperation()
        let expected = UUID()
        generation = expected
        isBusy = true
        error = nil
        return expected
    }

    private func finishOperation(_ expected: UUID) {
        if generation == expected { isBusy = false; cancelActiveRequest = nil }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task { try await operation() }
        cancelActiveRequest = { task.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
