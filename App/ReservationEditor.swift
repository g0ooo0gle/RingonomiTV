import SwiftUI
import RingonomiCore

struct ReservationEditor: View {
    let address: String
    @ObservedObject var store: ReservationStore
    let program: GuideProgram
    let channel: GuideChannel
    @State private var original: Reservation?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RecordingSettingsDraft
    @State private var message: String?
    @State private var confirmation = false
    @State private var deleting = false
    @State private var busy = false
    @FocusState private var closeFocused: Bool
    @ObservedObject private var mutation = RingonomiMutationStore.shared

    init(address: String, store: ReservationStore, program: GuideProgram, channel: GuideChannel, original: Reservation?) {
        self.address = address
        self.store = store
        self.program = program
        self.channel = channel
        _original = State(initialValue: original)
        _draft = State(initialValue: RecordingSettingsDraft(settings: original?.recordSettings ?? RecordSettings()))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(program.title).font(.title3)
                    Text(channel.name + " · " + reservationDate(program.startDate) + " – " + reservationTime(program.endDate))
                    if original?.isRecordingInProgress == true { Text("録画中です。設定変更や削除は進行中の録画に影響します。").foregroundStyle(.orange) }
                }
                RecordingSettingsFields(draft: $draft, address: address)
                if let pending = mutation.pending {
                    Section("前の予約操作") {
                        Text(pending.isRecoveryEntry || mutation.journalUnreadable
                             ? "前の操作結果を確認できません。予約一覧を更新して確認してください。"
                             : "前の操作結果を予約一覧で確認するまで、追加の予約操作は停止しています。")
                            .foregroundStyle(.orange)
                        if let journalError = mutation.journalError {
                            Text(journalError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                if let message { Section { Text(message).foregroundStyle(.red) } }
                Section {
                    if busy { ProgressView("サーバーの処理結果を確認しています…") }
                    Button(original == nil ? "録画予約を追加" : "変更を保存") { confirmation = true }
                        .disabled(busy || store.saving || store.loading || mutation.busy || mutation.pending != nil)
                    if original != nil {
                        Button("予約を削除", role: .destructive) { deleting = true }
                            .disabled(busy || store.saving || store.loading || mutation.busy || mutation.pending != nil)
                    }
                    Button("閉じる") { dismiss() }
                        .disabled(busy)
                        .focused($closeFocused)
                }
            }.disabled(busy)
            .navigationFormViewport()
            .appNavigationTitle(Text(original == nil ? "録画予約" : "予約を変更"))
            .interactiveDismissDisabled(busy)
            .onChange(of: busy) { _, isBusy in
                guard !isBusy, mutation.pending != nil else { return }
                closeFocused = true
            }
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
    @MainActor private func save() async {
        guard !busy else { return }
        message = nil
        busy = true
        defer { busy = false }
        do {
            let settings = try draft.validatedSettings()
            try await store.save(address: address, program: program, original: original, settings: settings)
#if DEBUG
            print("RingonomiReservationSaved: editing=\(original != nil)")
#endif
            dismiss()
        } catch {
            message = reservationErrorMessage(error) + (mutation.pending == nil ? "" : " 操作結果が不明な場合は、再送前に予約一覧を確認してください。")
        }
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
        } catch { message = reservationErrorMessage(error) + " 予約一覧を確認してください。" }
    }
}
