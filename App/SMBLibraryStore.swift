import Combine
import Foundation
import RingonomiCore

/// A saved directory inside one SMB connection.
///
/// Credentials are deliberately not part of this value. They are owned by
/// the caller's credential store and are removed by the caller before a
/// connection is deleted from this store.
struct DirectoryPin: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let connectionID: UUID
    let path: SMBRelativePath
    let title: String

    init(
        id: UUID = UUID(),
        connectionID: UUID,
        path: SMBRelativePath,
        title: String
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.utf8.count <= Self.maximumTitleBytes,
              !normalizedTitle.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              }),
              (try? SMBRelativePath(components: path.components)) != nil else {
            throw SMBLibraryStoreError.invalidPin
        }
        self.id = id
        self.connectionID = connectionID
        self.path = path
        self.title = normalizedTitle
    }

    private static let maximumTitleBytes = 4 * 1024

    private enum CodingKeys: String, CodingKey {
        case id, connectionID, path, title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            connectionID: container.decode(UUID.self, forKey: .connectionID),
            path: container.decode(SMBRelativePath.self, forKey: .path),
            title: container.decode(String.self, forKey: .title)
        )
    }
}

enum SMBLibraryStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidArchive
    case saveFailed
    case connectionLimit
    case pinLimit
    case duplicateConnection
    case duplicatePin
    case connectionNotFound
    case pinNotFound
    case invalidConnection
    case invalidPin

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "SMB設定を読み込めませんでした。"
        case .saveFailed:
            return "SMB設定を保存できませんでした。"
        case .connectionLimit:
            return "SMB接続をこれ以上追加できません。"
        case .pinLimit:
            return "SMBピンをこれ以上追加できません。"
        case .duplicateConnection:
            return "同じSMB接続は追加できません。"
        case .duplicatePin:
            return "このSMBフォルダはすでにピン留めされています。"
        case .connectionNotFound:
            return "SMB接続が見つかりません。"
        case .pinNotFound:
            return "SMBピンが見つかりません。"
        case .invalidConnection:
            return "SMB接続情報が不正です。"
        case .invalidPin:
            return "SMBフォルダ情報が不正です。"
        }
    }
}

/// Stores SMB connections and directory pins without storing credentials.
@MainActor
final class SMBLibraryStore: ObservableObject {
    static let maximumConnections = 32
    static let maximumPins = 256
    static let maximumArchiveBytes = 256 * 1024

    @Published private(set) var connections: [SMBConnection] = []
    @Published private(set) var pins: [DirectoryPin] = []
    @Published private(set) var error: String?

    private let defaults: UserDefaults
    private let storageKey = "ringonomi.smbLibrary.v1"
    private var archiveIsInvalid = false

    private struct Archive: Codable, Sendable {
        let connections: [SMBConnection]
        let pins: [DirectoryPin]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadSavedConnections()
    }

    /// Alias used by settings screens that describe these values as saved
    /// connections rather than active browser state.
    var savedConnections: [SMBConnection] { connections }

    func connection(for id: UUID) -> SMBConnection? {
        connections.first { $0.id == id }
    }

    /// Pins are filtered at read time as well as validated while decoding.
    /// This protects the UI if a connection was removed by another state
    /// owner or if a future schema introduces a stale pin reference.
    var displayablePins: [DirectoryPin] {
        pins.filter { isDisplayable($0) }
    }

    func pins(for connectionID: UUID) -> [DirectoryPin] {
        displayablePins.filter { $0.connectionID == connectionID }
    }

    @discardableResult
    func addConnection(_ connection: SMBConnection) throws -> SMBConnection {
        try ensureMutable()
        guard connections.count < Self.maximumConnections else {
            try throwFailure(.connectionLimit)
        }
        guard !connections.contains(where: { $0.id == connection.id }) else {
            try throwFailure(.duplicateConnection)
        }

        var next = connections
        next.append(connection)
        try commit(connections: next, pins: pins)
        return connection
    }

    @discardableResult
    func addConnection(address: String, displayName: String? = nil) throws -> SMBConnection {
        let connection: SMBConnection
        do {
            connection = try SMBConnection(address: address, displayName: displayName)
        } catch {
            try throwFailure(.invalidConnection)
        }
        return try addConnection(connection)
    }

    /// Delete a connection and all pins that point to its UUID. Credential
    /// deletion is intentionally left to the caller before this method.
    func deleteConnection(id: UUID) throws {
        try ensureMutable()
        guard connections.contains(where: { $0.id == id }) else {
            try throwFailure(.connectionNotFound)
        }
        let nextConnections = connections.filter { $0.id != id }
        let nextPins = pins.filter { $0.connectionID != id }
        try commit(connections: nextConnections, pins: nextPins)
    }

    func removeConnection(connectionID: UUID) throws {
        try deleteConnection(id: connectionID)
    }

    @discardableResult
    func renameConnection(id: UUID, displayName: String) throws -> SMBConnection {
        try ensureMutable()
        guard let index = connections.firstIndex(where: { $0.id == id }) else {
            try throwFailure(.connectionNotFound)
        }
        let old = connections[index]
        let renamed: SMBConnection
        do {
            renamed = try SMBConnection(
                id: old.id,
                displayName: displayName,
                server: old.server,
                port: old.port,
                share: old.share,
                baseDirectory: old.baseDirectory
            )
        } catch {
            try throwFailure(.invalidConnection)
        }
        var next = connections
        next[index] = renamed
        try commit(connections: next, pins: pins)
        return renamed
    }

    @discardableResult
    func pin(
        connectionID: UUID,
        path: SMBRelativePath,
        title: String
    ) throws -> DirectoryPin {
        try ensureMutable()
        guard connections.contains(where: { $0.id == connectionID }) else {
            try throwFailure(.connectionNotFound)
        }
        guard (try? SMBRelativePath(components: path.components)) != nil else {
            try throwFailure(.invalidPin)
        }
        guard !pins.contains(where: { $0.connectionID == connectionID && $0.path == path }) else {
            try throwFailure(.duplicatePin)
        }
        guard pins.count < Self.maximumPins else {
            try throwFailure(.pinLimit)
        }

        let pin: DirectoryPin
        do {
            pin = try DirectoryPin(connectionID: connectionID, path: path, title: title)
        } catch {
            try throwFailure(.invalidPin)
        }
        var next = pins
        next.append(pin)
        try commit(connections: connections, pins: next)
        return pin
    }

    func unpin(id: UUID) throws {
        try ensureMutable()
        guard pins.contains(where: { $0.id == id }) else {
            try throwFailure(.pinNotFound)
        }
        try commit(connections: connections, pins: pins.filter { $0.id != id })
    }

    func unpin(connectionID: UUID, path: SMBRelativePath) throws {
        guard let pin = pins.first(where: { $0.connectionID == connectionID && $0.path == path }) else {
            try throwFailure(.pinNotFound)
        }
        try unpin(id: pin.id)
    }

    private func loadSavedConnections() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            guard data.count <= Self.maximumArchiveBytes else {
                throw SMBLibraryStoreError.invalidArchive
            }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            try Self.validate(archive)
            connections = archive.connections
            pins = archive.pins
        } catch {
            // Keep the original bytes untouched. A malformed archive must be
            // visible to the UI and must never be silently replaced by an
            // empty archive during initialization.
            archiveIsInvalid = true
            self.error = SMBLibraryStoreError.invalidArchive.localizedDescription
        }
    }

    private func ensureMutable() throws {
        guard !archiveIsInvalid else { try throwFailure(.invalidArchive) }
    }

    private func commit(connections: [SMBConnection], pins: [DirectoryPin]) throws {
        do {
            guard !archiveIsInvalid else { throw SMBLibraryStoreError.invalidArchive }
            let archive = Archive(connections: connections, pins: pins)
            try Self.validate(archive)
            let data = try JSONEncoder().encode(archive)
            guard data.count <= Self.maximumArchiveBytes else {
                throw SMBLibraryStoreError.saveFailed
            }
            defaults.set(data, forKey: storageKey)
            self.connections = connections
            self.pins = pins
            error = nil
        } catch let storeError as SMBLibraryStoreError {
            error = storeError.localizedDescription
            throw storeError
        } catch {
            error = SMBLibraryStoreError.saveFailed.localizedDescription
            throw SMBLibraryStoreError.saveFailed
        }
    }

    private static func validate(_ archive: Archive) throws {
        guard archive.connections.count <= maximumConnections,
              archive.pins.count <= maximumPins else {
            throw SMBLibraryStoreError.invalidArchive
        }

        let connectionIDs = archive.connections.map(\.id)
        let pinIDs = archive.pins.map(\.id)
        let allIDs = connectionIDs + pinIDs
        guard Set(connectionIDs).count == connectionIDs.count,
              Set(pinIDs).count == pinIDs.count,
              Set(allIDs).count == allIDs.count else {
            throw SMBLibraryStoreError.invalidArchive
        }

        let knownConnectionIDs = Set(connectionIDs)
        for pin in archive.pins {
            guard knownConnectionIDs.contains(pin.connectionID),
                  (try? SMBRelativePath(components: pin.path.components)) != nil else {
                throw SMBLibraryStoreError.invalidArchive
            }
        }
    }

    private func isDisplayable(_ pin: DirectoryPin) -> Bool {
        guard connections.contains(where: { $0.id == pin.connectionID }) else { return false }
        return (try? SMBRelativePath(components: pin.path.components)) != nil
    }

    private func throwFailure(_ failure: SMBLibraryStoreError) throws -> Never {
        error = failure.localizedDescription
        throw failure
    }
}
