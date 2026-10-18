import Foundation
import Combine
import RingonomiCore

@MainActor final class KeywordReservationStore: ObservableObject {
    @Published private(set) var items: [ReservationCondition] = []
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    private var address = ""
    private var generation = UUID()

    func invalidateConnection() {
        generation = UUID()
        items = []
        loading = false
        saving = false
        error = nil
    }

    func refresh(address next: String) async {
        if address != next {
            address = next
            generation = UUID()
            items = []
            error = nil
            loading = false
            saving = false
        }
        guard !next.isEmpty, !loading, !saving else { return }
        let expected = generation
        loading = true
        error = nil
        defer { if generation == expected { loading = false } }
        do {
            let result = try await RingonomiClient.connected(to: next).keywordReservations()
            guard !Task.isCancelled, generation == expected else { return }
            items = result.reservationConditions.sorted { $0.id < $1.id }
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
            if let original {
                let latest = try await client.keywordReservation(id: original.id)
                try requireCurrent(expected)
                let searchValues = try mergingEditedSettings(original: original.programSearchCondition.rawValues,
                    edited: search.rawValues, latest: latest.programSearchCondition.rawValues)
                let recordingValues = try mergingEditedSettings(original: original.recordSettings.rawValues,
                    edited: settings.rawValues, latest: latest.recordSettings.rawValues)
                let mergedSearch = ProgramSearchCondition(rawValues: searchValues)
                let mergedSettings = RecordSettings(rawValues: recordingValues)
                let all = try await client.keywordReservations()
                try requireCurrent(expected)
                guard !all.reservationConditions.contains(where: {
                    $0.id != original.id && $0.programSearchCondition == mergedSearch && $0.recordSettings == mergedSettings
                }) else {
                    throw ReservationUIError("同じ検索条件と録画設定がすでに登録されています。一覧を確認してください。")
                }
                let updated = try await client.updateKeywordReservation(id: original.id,
                    search: mergedSearch, settings: mergedSettings)
                guard updated.id == original.id else { throw ReservationError.invalidResponse }
            } else {
                let current = try await client.keywordReservations()
                try requireCurrent(expected)
                guard !current.reservationConditions.contains(where: { $0.programSearchCondition == search && $0.recordSettings == settings }) else {
                    throw ReservationUIError("同じ検索条件がすでに登録されています。一覧を確認してください。")
                }
                _ = try await client.addKeywordReservation(search: search, settings: settings)
            }
            try await readBack(client: client, expected: expected)
        } catch {
            if generation == expected {
                try? await readBack(client: client, expected: expected)
                self.error = error.localizedDescription
            }
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
            let latest = try await client.keywordReservation(id: original.id)
            try requireCurrent(expected)
            guard latest.programSearchCondition == original.programSearchCondition,
                  latest.recordSettings == original.recordSettings else {
                throw ReservationUIError("条件が別の画面で変更されています。一覧から開き直してください。")
            }
            try await client.deleteKeywordReservation(id: original.id)
            try await readBack(client: client, expected: expected)
            guard !items.contains(where: { $0.id == original.id }) else {
                throw ReservationUIError("削除結果を確認できませんでした。一覧を確認してください。")
            }
        } catch {
            if generation == expected {
                try? await readBack(client: client, expected: expected)
                self.error = error.localizedDescription
            }
            throw error
        }
    }

    private func readBack(client: RingonomiClient, expected: UUID) async throws {
        try requireCurrent(expected)
        let current = try await client.keywordReservations()
        try requireCurrent(expected)
        items = current.reservationConditions.sorted { $0.id < $1.id }
    }

    private func requireCurrent(_ expected: UUID) throws {
        guard generation == expected else { throw ReservationUIError("接続先が変更されました。画面を開き直してください。") }
    }
}
