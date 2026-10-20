import Combine
import Foundation
import RingonomiCore

/// Stores only registrations; execution remains a recording-server action.
@MainActor
final class RecordingBatchStore: ObservableObject {
    private static let storageKey = "recordingBatchRegistrations.v1"
    @Published private(set) var entries: [RegisteredRecordingBatch] = []
    @Published private(set) var error: String?
    @Published private(set) var canEdit = false
    private var serverKey: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func configure(address: String) {
        entries = []
        serverKey = nil
        canEdit = false
        error = nil
        do {
            let key = try RecordingBatchArchive.serverKey(address: address)
            let archive = try readArchive()
            serverKey = key
            entries = archive.entries(serverKey: key)
            canEdit = true
        } catch {
            self.error = "登録済みバッチを読み込めません。接続先または保存データを確認してください。既存データは保持しています。"
        }
    }

    func add(name: String, path: String) throws {
        let entry = try RegisteredRecordingBatch(name: name, path: path)
        try change { archive, key in try archive.upsert(entry, serverKey: key) }
    }

    func remove(id: UUID) throws {
        try change { archive, key in try archive.remove(id: id, serverKey: key) }
    }

    private func readArchive() throws -> RecordingBatchArchive {
        guard let object = defaults.object(forKey: Self.storageKey) else {
            return RecordingBatchArchive()
        }
        guard let data = object as? Data else { throw ReservationUIError("登録一覧の形式が不正です。") }
        return try RecordingBatchArchive(data: data)
    }

    private func change(_ edit: (inout RecordingBatchArchive, String) throws -> Void) throws {
        guard canEdit, let key = serverKey else {
            throw ReservationUIError("登録一覧を読み込んでから操作してください。")
        }
        do {
            var archive = try readArchive()
            try edit(&archive, key)
            let data = try archive.data()
            defaults.set(data, forKey: Self.storageKey)
            entries = archive.entries(serverKey: key)
            error = nil
        } catch {
            self.error = "登録一覧を更新できませんでした。既存データは保持しています。"
            throw error
        }
    }
}
