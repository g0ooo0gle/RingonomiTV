import Foundation
import Combine
import RingonomiCore

private enum KeywordWriteOperation: Sendable {
    case add(search: ProgramSearchCondition, settings: RecordSettings)
    case update(id: Int, search: ProgramSearchCondition, settings: RecordSettings)
    case delete(id: Int)
}

private enum KeywordWriteResult: Sendable {
    case condition(ReservationCondition, expectedSearch: ProgramSearchCondition, expectedSettings: RecordSettings)
    case deleted
}

@MainActor final class KeywordReservationStore: ObservableObject {
    @Published private(set) var items: [ReservationCondition] = []
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    /// The timestamp of the latest successful keyword-list read.
    @Published private(set) var lastReadAt: Date?
    /// Address associated with `lastReadAt`; stale reads from another
    /// connection must never unlock a pending mutation.
    @Published private(set) var lastReadAddress: String?

    private var address = ""
    private var generation = UUID()
    private let mutation = RingonomiMutationStore.shared

    func invalidateConnection() {
        generation = UUID()
        items = []
        loading = false
        saving = false
        error = nil
        lastReadAt = nil
        lastReadAddress = nil
    }

    func refresh(address next: String) async {
        if address != next {
            address = next
            generation = UUID()
            items = []
            error = nil
            loading = false
            saving = false
            lastReadAt = nil
            lastReadAddress = nil
        }
        guard !next.isEmpty, !loading, !saving else { return }
        let expected = generation
        loading = true
        error = nil
        lastReadAt = nil
        lastReadAddress = nil
        defer { if generation == expected { loading = false } }
        do {
            let client = try RingonomiClient.connected(to: next)
            let readStartedAt = Date()
            let result = try await client.keywordReservations()
            guard !Task.isCancelled, generation == expected else { return }
            items = result.reservationConditions.sorted { $0.id < $1.id }
            lastReadAt = readStartedAt
            lastReadAddress = client.baseURL.absoluteString
#if DEBUG
            print("RingonomiKeywordsReady: count=\(items.count)")
#endif
        } catch {
            guard !Task.isCancelled, generation == expected else { return }
            self.error = "キーワード予約を読み込めませんでした。\(error.localizedDescription)"
        }
    }

    func save(address requested: String, original: ReservationCondition?, search: ProgramSearchCondition, settings: RecordSettings) async throws {
        guard !saving, !loading, requested == address else {
            throw ReservationUIError("一覧の読み込み後にもう一度お試しください。")
        }
        let expected = generation
        let client = try RingonomiClient.connected(to: requested)
        saving = true
        error = nil
        defer { if generation == expected { saving = false } }

        do {
            try await mutation.perform(
                address: requested,
                target: .keywordReservation,
                action: original == nil ? .add : .update,
                title: original?.programSearchCondition.keyword ?? search.keyword,
                subjectID: original?.id,
                prepare: {
                    if let original {
                        let latest = try await client.keywordReservation(id: original.id)
                        try self.requireCurrent(expected)
                        guard latest.id == original.id else {
                            throw ReservationUIError("キーワード予約の識別子が変わりました。画面を閉じて開き直してください。")
                        }
                        let searchValues = try mergingEditedSettings(
                            original: original.programSearchCondition.rawValues,
                            edited: search.rawValues,
                            latest: latest.programSearchCondition.rawValues
                        )
                        let recordingValues = try mergingEditedSettings(
                            original: original.recordSettings.rawValues,
                            edited: settings.rawValues,
                            latest: latest.recordSettings.rawValues
                        )
                        let mergedSearch = ProgramSearchCondition(rawValues: searchValues)
                        let mergedSettings = RecordSettings(rawValues: recordingValues)
                        let all = try await client.keywordReservations()
                        try self.requireCurrent(expected)
                        guard !all.reservationConditions.contains(where: {
                            $0.id != original.id &&
                            $0.programSearchCondition == mergedSearch &&
                            $0.recordSettings == mergedSettings
                        }) else {
                            throw ReservationUIError("同じ検索条件と録画設定がすでに登録されています。一覧を確認してください。")
                        }
                        return KeywordWriteOperation.update(
                            id: original.id,
                            search: mergedSearch,
                            settings: mergedSettings
                        )
                    }

                    let current = try await client.keywordReservations()
                    try self.requireCurrent(expected)
                    guard !current.reservationConditions.contains(where: {
                        $0.programSearchCondition == search && $0.recordSettings == settings
                    }) else {
                        throw ReservationUIError("同じ検索条件がすでに登録されています。一覧を確認してください。")
                    }
                    return KeywordWriteOperation.add(search: search, settings: settings)
                },
                validate: {
                    try self.requireCurrent(expected)
                },
                send: { operation -> KeywordWriteResult in
                    switch operation {
                    case .add(let search, let settings):
                        let added = try await client.addKeywordReservation(search: search, settings: settings)
                        guard added.id > 0 else { throw ReservationError.invalidResponse }
                        return .condition(added, expectedSearch: search, expectedSettings: settings)
                    case .update(let id, let search, let settings):
                        let updated = try await client.updateKeywordReservation(id: id, search: search, settings: settings)
                        guard updated.id == id else { throw ReservationError.invalidResponse }
                        return .condition(updated, expectedSearch: search, expectedSettings: settings)
                    case .delete:
                        throw ReservationError.invalidResponse
                    }
                },
                verify: { result in
                    try await self.readBack(client: client, expected: expected)
                    guard case .condition(let written, let expectedSearch, let expectedSettings) = result,
                          self.items.contains(where: {
                              $0.id == written.id &&
                              preservesRequestedFields(actual: $0.programSearchCondition, expected: expectedSearch) &&
                              preservesRequestedFields(actual: $0.recordSettings, expected: expectedSettings)
                          }) else {
                        throw ReservationError.invalidResponse
                    }
                }
            )
        } catch {
            if generation == expected { self.error = error.localizedDescription }
            throw error
        }
    }

    func delete(address requested: String, original: ReservationCondition) async throws {
        guard !saving, !loading, requested == address else {
            throw ReservationUIError("一覧の読み込み後にもう一度お試しください。")
        }
        let expected = generation
        let client = try RingonomiClient.connected(to: requested)
        saving = true
        error = nil
        defer { if generation == expected { saving = false } }

        do {
            try await mutation.perform(
                address: requested,
                target: .keywordReservation,
                action: .delete,
                title: original.programSearchCondition.keyword,
                subjectID: original.id,
                prepare: {
                    let latest = try await client.keywordReservation(id: original.id)
                    try self.requireCurrent(expected)
                    guard latest.programSearchCondition == original.programSearchCondition,
                          latest.recordSettings == original.recordSettings else {
                        throw ReservationUIError("条件が別の画面で変更されています。一覧から開き直してください。")
                    }
                    return KeywordWriteOperation.delete(id: original.id)
                },
                validate: {
                    try self.requireCurrent(expected)
                },
                send: { operation -> KeywordWriteResult in
                    guard case .delete(let id) = operation else { throw ReservationError.invalidResponse }
                    try await client.deleteKeywordReservation(id: id)
                    return .deleted
                },
                verify: { result in
                    try await self.readBack(client: client, expected: expected)
                    guard case .deleted = result,
                          !self.items.contains(where: { $0.id == original.id }) else {
                        throw ReservationError.invalidResponse
                    }
                }
            )
        } catch {
            if generation == expected { self.error = error.localizedDescription }
            throw error
        }
    }

    private func readBack(client: RingonomiClient, expected: UUID) async throws {
        try requireCurrent(expected)
        let readStartedAt = Date()
        let current = try await client.keywordReservations()
        try requireCurrent(expected)
        items = current.reservationConditions.sorted { $0.id < $1.id }
        lastReadAt = readStartedAt
        lastReadAddress = client.baseURL.absoluteString
    }

    private func requireCurrent(_ expected: UUID) throws {
        guard generation == expected else {
            throw ReservationUIError("接続先が変更されました。画面を開き直してください。")
        }
    }
}

private func preservesRequestedFields(actual: RecordSettings, expected: RecordSettings) -> Bool {
    expected.rawValues.allSatisfy { key, value in actual.rawValues[key] == value }
}

private func preservesRequestedFields(actual: ProgramSearchCondition, expected: ProgramSearchCondition) -> Bool {
    expected.rawValues.allSatisfy { key, value in actual.rawValues[key] == value }
}
