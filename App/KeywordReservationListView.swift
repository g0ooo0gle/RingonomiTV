import SwiftUI
import RingonomiCore

struct KeywordReservationListView: View {
    let address: String
    @ObservedObject var store: KeywordReservationStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mutation = RingonomiMutationStore.shared
    @State private var editing: KeywordEditorSelection?
    @State private var acknowledgePending = false

    var body: some View {
        List {
            pendingSection
            if let error = store.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("再試行") { Task { await store.refresh(address: address) } }
                }
            }
            ForEach(store.items) { item in
                Button { editing = KeywordEditorSelection(original: item) } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.programSearchCondition.keyword).font(.headline)
                        if !item.programSearchCondition.note.isEmpty { Text(item.programSearchCondition.note).font(.caption) }
                        Text("\(item.programSearchCondition.isEnabled ? "有効" : "無効") · 登録予約 \(item.reservationCount)件")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .appNavigationTitle(Text("キーワード自動予約"))
        .toolbar {
            Button("録画予約を確認") { dismiss() }
            Button("新規条件") { editing = KeywordEditorSelection(original: nil) }
                .disabled(store.loading || store.saving || address.isEmpty)
            Button("更新") { Task { await store.refresh(address: address) } }.disabled(store.loading || store.saving)
        }
        .confirmationDialog("前の予約操作の結果を確認しましたか？", isPresented: $acknowledgePending, titleVisibility: .visible) {
            Button("確認済み・操作を再開") {
                mutation.acknowledgeAfterReview(address: address, readAt: store.lastReadAt, readAddress: store.lastReadAddress ?? "", target: .keywordReservation)
            }
            Button("まだ確認していない", role: .cancel) {}
        } message: {
            Text("キーワード予約一覧を更新して、結果を確認してください。結果が不明なまま再送すると重複する場合があります。")
        }
        .overlay {
            if store.loading { ProgressView("キーワード予約を読み込んでいます…") }
            else if store.items.isEmpty, store.error == nil {
                Text("キーワード予約はありません。「新規条件」から作成できます。")
                    .multilineTextAlignment(.center).padding(60)
            }
        }
        .task(id: address) { await store.refresh(address: address) }
        .sheet(item: $editing) { selection in
            KeywordReservationEditor(address: address, store: store, original: selection.original)
        }
    }

    @ViewBuilder private var pendingSection: some View {
        if let pending = mutation.pending {
            AppSection("前の予約操作の結果を確認してください") {
                Text(pending.title + " · " + pending.action.label)
                if mutation.journalUnreadable || pending.isRecoveryEntry {
                    Text("前の操作記録を読み込めませんでした。操作先を特定できないため、通常予約画面で両方の一覧を更新し、結果を確認してください。")
                        .font(.caption).foregroundStyle(.orange)
                    Button("通常予約画面で復旧を確認") { dismiss() }
                } else {
                    Text(pending.address).font(.caption).foregroundStyle(.secondary)
                    if pending.target == .reservation {
                        Text("通常予約一覧を確認するまで、キーワード予約の操作は再開できません。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let journalError = mutation.journalError {
                    Text(journalError).font(.caption2).foregroundStyle(.red)
                }
                Text("処理された可能性があります。結果を確認するまで同じ操作を送信しません。")
                    .foregroundStyle(.orange).focusable()
                if !mutation.journalUnreadable && !pending.isRecoveryEntry {
                    Button("一覧を確認したので操作を再開") { acknowledgePending = true }
                    .disabled(store.loading || !mutation.canAcknowledge(address: address, readAt: store.lastReadAt, readAddress: store.lastReadAddress ?? "", target: .keywordReservation))
                }
            }
        }
    }
}
private struct KeywordEditorSelection: Identifiable {
    let id = UUID()
    let original: ReservationCondition?
}
