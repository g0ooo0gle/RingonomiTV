import SwiftUI
import RingonomiCore

struct ReservationListView: View {
    let address: String
    @ObservedObject var store: ReservationStore
    @State private var selected: Reservation?
    var body: some View {
        NavigationStack {
            List {
                if let error = store.error {
                    Section { Text(error).foregroundStyle(.red); Button("再試行") { Task { await store.refresh(address: address) } } }
                }
                ForEach(store.items) { item in
                    Button { selected = item } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(item.program.title).font(.headline)
                            Text(reservationDate(item.program.startDate) + " – " + reservationTime(item.program.endDate) + " · " + item.channel.name).font(.caption)
                            HStack {
                                Text(item.isRecordingInProgress ? "録画中" : item.recordSettings.isEnabled ? "予約済み" : "無効")
                                Text(availability(item.recordingAvailability))
                                Text("優先度 \(item.recordSettings.priority)")
                            }.font(.caption).foregroundStyle(item.recordingAvailability == "Unavailable" ? .red : .secondary)
                            if !item.comment.isEmpty { Text(item.comment).font(.caption).lineLimit(2) }
                        }
                    }
                }
            }.overlay {
                if store.loading { ProgressView("録画予約を読み込んでいます…") }
                else if store.items.isEmpty, store.error == nil {
                    Text(address.isEmpty ? "設定で視聴サーバーに接続してください。" : "録画予約はありません。番組表で番組を選んで予約できます。")
                        .multilineTextAlignment(.center).padding(60)
                }
            }
            .navigationTitle("録画予約")
            .toolbar { Button("更新") { Task { await store.refresh(address: address) } }.disabled(store.loading || store.saving) }
            .task(id: address) { await store.refresh(address: address) }
            .sheet(item: $selected) { item in
                ReservationEditor(address: address, store: store, program: item.program, channel: item.channel, original: item)
            }
        }
    }
    private func availability(_ value: String) -> String {
        switch value {
        case "Full": return "全編録画可能"
        case "Partial": return "一部のみ録画可能"
        case "Unavailable": return "録画不可・チューナー不足"
        default: return value
        }
    }
}
