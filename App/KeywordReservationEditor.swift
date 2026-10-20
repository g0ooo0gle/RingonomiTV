import SwiftUI
import RingonomiCore

struct KeywordReservationEditor: View {
    let address: String
    @ObservedObject var store: KeywordReservationStore
    @State private var original: ReservationCondition?
    @State private var search: ProgramSearchCondition
    @State private var recording: RecordingSettingsDraft
    @State private var minimumDuration: String
    @State private var maximumDuration: String
    @State private var duplicateDays: String
    @State private var message: String?
    @State private var confirmation = false
    @State private var deleting = false
    @State private var busy = false
    @State private var previewing = false
    @State private var preview: ProgramSearchResponse?
    @State private var previewGeneration = UUID()
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(address: String, store: KeywordReservationStore, original: ReservationCondition?) {
        self.address = address
        self.store = store
        _original = State(initialValue: original)
        let condition = original?.programSearchCondition ?? ProgramSearchCondition()
        _search = State(initialValue: condition)
        _recording = State(initialValue: RecordingSettingsDraft(settings: original?.recordSettings ?? RecordSettings()))
        _minimumDuration = State(initialValue: condition.durationRangeMin.map(String.init) ?? "")
        _maximumDuration = State(initialValue: condition.durationRangeMax.map(String.init) ?? "")
        _duplicateDays = State(initialValue: String(condition.duplicateTitleCheckPeriodDays))
    }

    var body: some View {
        NavigationStack {
            Form {
                searchFields
                AppSection("対象チャンネル") {
                    NavigationLink(search.serviceRanges == nil ? "全チャンネル" : "選択したチャンネル：\(search.serviceRanges?.count ?? 0)件") {
                        KeywordChannelSelection(address: address, selection: $search.serviceRanges)
                    }
                }
                filterFields
                AppSection("番組長・重複チェック") {
                    TextField("最短の番組長（分・空欄は指定なし）", text: $minimumDuration)
                    TextField("最長の番組長（分・空欄は指定なし）", text: $maximumDuration)
                    Picker("同名録画の重複チェック", selection: $search.duplicateTitleCheckScope) {
                        Text("チェックしない").tag("None")
                        Text("同じチャンネル").tag("SameChannelOnly")
                        Text("すべてのチャンネル").tag("AllChannels")
                        if !["None", "SameChannelOnly", "AllChannels"].contains(search.duplicateTitleCheckScope) {
                            Text(search.duplicateTitleCheckScope).tag(search.duplicateTitleCheckScope)
                        }
                    }
                    TextField("重複チェックの対象日数", text: $duplicateDays)
                }
                previewSection
                RecordingSettingsFields(draft: $recording, address: address)
                Section {
                    if busy { ProgressView("サーバーの処理結果を確認しています…") }
                    Button(original == nil ? "条件を追加" : "変更を保存") { confirmation = true }
                        .disabled(store.loading || store.saving || previewing)
                    if original != nil { Button("条件を削除", role: .destructive) { deleting = true }.disabled(store.saving || previewing) }
                    Button("閉じる") { dismiss() }
                }
            }
            .disabled(busy)
            .appNavigationTitle(Text(original == nil ? "新しいキーワード予約" : "キーワード予約を変更"))
            .interactiveDismissDisabled(busy)
            .onChange(of: search.rawValues) { _, _ in invalidatePreview() }
            .onChange(of: minimumDuration) { _, _ in invalidatePreview() }
            .onChange(of: maximumDuration) { _, _ in invalidatePreview() }
            .onChange(of: duplicateDays) { _, _ in invalidatePreview() }
            .onDisappear { invalidatePreview() }
            .alert("操作できませんでした", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) {
                Button("閉じる") { message = nil }
            } message: { Text(message ?? "") }
            .confirmationDialog("この検索条件を保存しますか？", isPresented: $confirmation, titleVisibility: .visible) {
                Button("保存する") { Task { await save() } }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(search.isEnabled ? "一致する番組がサーバーで自動予約されます。作成済みの予約は別途「予約」画面で確認・変更できます。" : "条件を無効の状態で保存します。")
            }
            .confirmationDialog("この条件を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                Button("条件を削除", role: .destructive) { Task { await remove() } }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("すでに作成された録画予約は残ります。不要な予約は「予約」画面で確認してください。") }
        }
    }

    private var filterFields: some View {
        Group {
            AppSection("ジャンル") {
                NavigationLink(search.genreRanges == nil ? "すべてのジャンル" : "指定したジャンル：\(search.genreRanges?.count ?? 0)件") {
                    KeywordGenreSelection(selection: Binding(
                        get: { search.genreRanges },
                        set: { value in
                            search.genreRanges = value
                            if value == nil { search.isExcludeGenreRanges = false }
                        }
                    ))
                }
                Toggle("指定したジャンルを除外", isOn: $search.isExcludeGenreRanges)
                    .disabled(search.genreRanges == nil)
            }
            AppSection("曜日・時間帯") {
                NavigationLink(search.dateRanges == nil ? "すべての日時" : "指定した日時範囲：\(search.dateRanges?.count ?? 0)件") {
                    KeywordTimeRangeSelection(selection: Binding(
                        get: { search.dateRanges },
                        set: { value in
                            search.dateRanges = value
                            if value == nil { search.isExcludeDateRanges = false }
                        }
                    ))
                }
                Toggle("指定した日時範囲を除外", isOn: $search.isExcludeDateRanges)
                    .disabled(search.dateRanges == nil)
                Text("番組の開始日時を日本時間で指定します。ジャンルと日時は両方の条件で絞り込みます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var searchFields: some View {
        AppSection("検索条件") {
            TextField("検索キーワード", text: $search.keyword)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("除外キーワード", text: $search.excludeKeyword)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("メモ", text: $search.note)
            Toggle("自動予約を有効にする", isOn: $search.isEnabled)
            Toggle("番組名だけを検索", isOn: $search.isTitleOnly)
            Toggle("大文字・小文字を区別", isOn: $search.isCaseSensitive)
            Toggle("あいまい検索", isOn: $search.isFuzzySearchEnabled)
            Toggle("正規表現を使用", isOn: $search.isRegexSearchEnabled)
            Picker("放送種別", selection: $search.broadcastType) {
                Text("無料放送のみ").tag("FreeOnly")
                Text("すべて").tag("All")
                Text("有料放送のみ").tag("PaidOnly")
                if !["FreeOnly", "All", "PaidOnly"].contains(search.broadcastType) {
                    Text(search.broadcastType).tag(search.broadcastType)
                }
            }
        }
    }

    private var previewSection: some View {
        AppSection("検索結果の確認") {
            Button("この条件で番組を検索") {
                previewTask?.cancel()
                previewTask = Task { await loadPreview() }
            }.disabled(previewing)
            if previewing { ProgressView("サーバーで番組を検索しています…") }
            if let preview {
                Text("該当する番組：\(preview.total)件（先頭50件まで表示）")
                ForEach(Array(preview.programs.prefix(50).enumerated()), id: \.offset) { _, program in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(program.title)
                        Text(reservationDate(program.startDate) + " – " + reservationTime(program.endDate)).font(.caption)
                    }
                }
            }
        }
    }

    private func validatedSearch() throws -> ProgramSearchCondition {
        var result = search
        if original == nil, result.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ReservationUIError("検索キーワードを入力してください。")
        }
        result.durationRangeMin = try optionalInteger(minimumDuration, label: "最短の番組長", nonnegative: true)
        result.durationRangeMax = try optionalInteger(maximumDuration, label: "最長の番組長", nonnegative: true)
        if let minimum = result.durationRangeMin, let maximum = result.durationRangeMax, minimum > maximum {
            throw ReservationUIError("最短の番組長は最長以下にしてください。")
        }
        guard let days = Int(duplicateDays.trimmingCharacters(in: .whitespacesAndNewlines)), days >= 0 else {
            throw ReservationUIError("対象日数は0以上の整数で入力してください。")
        }
        result.duplicateTitleCheckPeriodDays = days
        if let ranges = result.serviceRanges, ranges.isEmpty {
            throw ReservationUIError("対象チャンネルを選ぶか「全チャンネル」を選択してください。")
        }
        try KeywordSearchFilters.validate(result)
        return result
    }

    @MainActor private func loadPreview() async {
        guard !previewing else { return }
        message = nil
        let expected = UUID()
        previewGeneration = expected
        do {
            var condition = try validatedSearch()
            // Preview the matching programs even when the saved rule is disabled.
            condition.isEnabled = true
            previewing = true
            defer { if previewGeneration == expected { previewing = false } }
            let result = try await RingonomiClient.connected(to: address).searchPrograms(condition: condition)
            guard !Task.isCancelled, previewGeneration == expected else { return }
            preview = result
#if DEBUG
            print("RingonomiKeywordPreview: total=\(result.total)")
#endif
        } catch {
            guard !Task.isCancelled, previewGeneration == expected else { return }
            message = "検索できませんでした。\(error.localizedDescription)"
        }
    }

    private func invalidatePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewGeneration = UUID()
        previewing = false
        preview = nil
    }

    @MainActor private func save() async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let condition = try validatedSearch()
            let settings = try recording.validatedSettings()
            try await store.save(address: address, original: original, search: condition, settings: settings)
#if DEBUG
            print("RingonomiKeywordSaved: editing=\(original != nil)")
#endif
            dismiss()
        } catch { message = error.localizedDescription + " 操作結果が不明な場合は、再送前に一覧を確認してください。" }
    }

    @MainActor private func remove() async {
        guard !busy, let original else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await store.delete(address: address, original: original)
#if DEBUG
            print("RingonomiKeywordDeleted")
#endif
            dismiss()
        } catch { message = error.localizedDescription + " 一覧を確認してください。" }
    }
}
