import SwiftUI
import RingonomiCore

struct ReservationEditor: View {
    let address: String
    @ObservedObject var store: ReservationStore
    let program: GuideProgram
    let channel: GuideChannel
    @State private var original: Reservation?
    @Environment(\.dismiss) private var dismiss
    @State private var settings: RecordSettings
    @State private var startMargin: String
    @State private var endMargin: String
    @State private var tuner: String
    @State private var message: String?
    @State private var confirmation = false
    @State private var deleting = false
    @State private var busy = false

    init(address: String, store: ReservationStore, program: GuideProgram, channel: GuideChannel, original: Reservation?) {
        self.address = address
        self.store = store
        self.program = program
        self.channel = channel
        _original = State(initialValue: original)
        let settings = original?.recordSettings ?? RecordSettings()
        _settings = State(initialValue: settings)
        _startMargin = State(initialValue: settings.startMargin.map(String.init) ?? "")
        _endMargin = State(initialValue: settings.endMargin.map(String.init) ?? "")
        _tuner = State(initialValue: settings.forcedTunerID.map(String.init) ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(program.title).font(.title3)
                    Text(channel.name + " · " + reservationDate(program.startDate) + " – " + reservationTime(program.endDate))
                    if original?.isRecordingInProgress == true { Text("録画中です。設定変更や削除は進行中の録画に影響します。").foregroundStyle(.orange) }
                }
                Section("基本設定") {
                    Toggle("この予約を有効にする", isOn: $settings.isEnabled)
                    Picker("優先度", selection: $settings.priority) {
                        ForEach(1...5, id: \.self) { Text($0 == 3 ? "3（通常）" : String($0)).tag($0) }
                    }
                    TextField("開始マージン（秒・空欄はサーバー既定）", text: $startMargin)
                    TextField("終了マージン（秒・空欄はサーバー既定）", text: $endMargin)
                    Picker("録画方式", selection: $settings.recordingMode) {
                        Text("指定サービス").tag("SpecifiedService")
                        Text("指定サービス・復号なし").tag("SpecifiedServiceWithoutDecoding")
                        Text("全サービス").tag("AllServices")
                        Text("全サービス・復号なし").tag("AllServicesWithoutDecoding")
                        Text("視聴のみ").tag("View")
                        if !["SpecifiedService", "SpecifiedServiceWithoutDecoding", "AllServices", "AllServicesWithoutDecoding", "View"].contains(settings.recordingMode) {
                            Text(settings.recordingMode).tag(settings.recordingMode)
                        }
                    }
                    Toggle("イベントリレーを追従", isOn: $settings.isEventRelayFollowEnabled)
                    Toggle("ぴったり録画", isOn: $settings.isExactRecordingEnabled)
                }
                Section("詳細設定") {
                    recordingModePicker("字幕", selection: $settings.captionRecordingMode)
                    recordingModePicker("データ放送", selection: $settings.dataBroadcastingRecordingMode)
                    Toggle("ワンセグを別ファイルへ保存", isOn: $settings.isOnesegSeparateOutputEnabled)
                    Toggle("連続する番組を一つのファイルへ保存", isOn: $settings.isSequentialRecordingInSingleFileEnabled)
                    TextField("使用チューナーID（空欄は自動）", text: $tuner)
                    Text(settings.recordingFolders.isEmpty ? "保存先：サーバーの既定フォルダー" : "保存先：\(settings.recordingFolders.count)件の既存設定を保持")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("録画後の動作・保存先・スクリプトなど、この画面で変更しない設定は保持します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message { Section { Text(message).foregroundStyle(.red) } }
                Section {
                    if busy { ProgressView("サーバーの処理結果を確認しています…") }
                    Button(original == nil ? "録画予約を追加" : "変更を保存") { confirmation = true }
                        .disabled(busy || store.saving || store.loading)
                    if original != nil {
                        Button("予約を削除", role: .destructive) { deleting = true }.disabled(busy || store.saving || store.loading)
                    }
                    Button("閉じる") { dismiss() }.disabled(busy)
                }
            }.disabled(busy)
            .navigationTitle(original == nil ? "録画予約" : "予約を変更")
            .interactiveDismissDisabled(busy)
            .confirmationDialog(original == nil ? "この番組を録画予約しますか？" : "予約の変更を保存しますか？", isPresented: $confirmation, titleVisibility: .visible) {
                Button(original == nil ? "予約する" : "保存する") { Task { await save() } }
                Button("キャンセル", role: .cancel) {}
            } message: { Text(program.title) }
            .confirmationDialog("この予約を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                Button(original?.isRecordingInProgress == true ? "録画を中止して削除" : "予約を削除", role: .destructive) { Task { await remove() } }
                Button("キャンセル", role: .cancel) {}
            } message: { Text(original?.isRecordingInProgress == true ? "進行中の録画が中止されます。" : program.title) }
        }
    }
    private func recordingModePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("サーバー既定").tag("Default")
            Text("記録する").tag("Enable")
            Text("記録しない").tag("Disable")
            if !["Default", "Enable", "Disable"].contains(selection.wrappedValue) { Text(selection.wrappedValue).tag(selection.wrappedValue) }
        }
    }
    private func integer(_ input: String, label: String, nonnegative: Bool = false) throws -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let value = Int(text), !nonnegative || value >= 0 else { throw ReservationUIError("\(label)は\(nonnegative ? "0以上の" : "")整数で入力してください。") }
        return value
    }
    @MainActor private func save() async {
        guard !busy else { return }
        message = nil
        busy = true
        defer { busy = false }
        do {
            var draft = settings
            draft.startMargin = try integer(startMargin, label: "開始マージン")
            draft.endMargin = try integer(endMargin, label: "終了マージン")
            draft.forcedTunerID = try integer(tuner, label: "チューナーID", nonnegative: true)
            try await store.save(address: address, program: program, original: original, settings: draft)
#if DEBUG
            print("RingonomiReservationSaved: editing=\(original != nil)")
#endif
            dismiss()
        } catch { message = error.localizedDescription + " 操作結果が不明な場合は、再送前に予約一覧を確認してください。" }
    }
    @MainActor private func remove() async {
        guard !busy, let original else { return }
        message = nil
        busy = true
        defer { busy = false }
        do {
            try await store.delete(address: address, reservation: original)
#if DEBUG
            print("RingonomiReservationDeleted")
#endif
            dismiss()
        } catch { message = error.localizedDescription + " 予約一覧を確認してください。" }
    }
}
