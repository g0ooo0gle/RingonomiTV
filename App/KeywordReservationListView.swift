import SwiftUI
import RingonomiCore

struct KeywordReservationListView: View {
    let address: String
    @ObservedObject var store: KeywordReservationStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: KeywordEditorSelection?

    var body: some View {
        List {
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
}
private struct KeywordEditorSelection: Identifiable {
    let id = UUID()
    let original: ReservationCondition?
}
