import SwiftUI
import RingonomiCore

struct ReservationListView: View {
    let address: String
    @ObservedObject var store: ReservationStore
    @ObservedObject var keywords: KeywordReservationStore
    @ObservedObject private var mutation = RingonomiMutationStore.shared
    @State private var selected: Reservation?
    @State private var acknowledgePending = false
    @State private var recoverCorruptJournal = false
    var body: some View {
        NavigationStack {
            List {
                pendingSection
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
            .appNavigationTitle(Text("録画予約"))
            .toolbar {
                NavigationLink("EPGStation") { EPGStationReservationListView() }
                NavigationLink("キーワード") { KeywordReservationListView(address: address, store: keywords) }
                Button("更新") { Task { await store.refresh(address: address) } }.disabled(store.loading || store.saving)
            }
            .confirmationDialog("前の予約操作の結果を確認しましたか？", isPresented: $acknowledgePending, titleVisibility: .visible) {
                Button("確認済み・操作を再開") {
                    mutation.acknowledgeAfterReview(
                        address: address,
                        readAt: store.lastReadAt,
                        readAddress: store.lastReadAddress ?? "",
                        target: .reservation
                    )
                }
                Button("まだ確認していない", role: .cancel) {}
            } message: {
                Text("予約一覧を更新して、追加・変更・削除の結果を確認してください。結果が不明なまま再送すると重複する場合があります。")
            }
            .confirmationDialog("壊れた操作記録を解除しますか？", isPresented: $recoverCorruptJournal, titleVisibility: .visible) {
                Button("両方の一覧を確認済み・記録を解除") {
                    _ = mutation.recoverCorruptJournalAfterReview(
                        address: address,
                        reservationReadAt: store.lastReadAt,
                        keywordReadAt: keywords.lastReadAt,
                        reservationReadAddress: store.lastReadAddress,
                        keywordReadAddress: keywords.lastReadAddress
                    )
                }
                Button("まだ確認していない", role: .cancel) {}
            } message: {
                Text("操作先を特定できない記録です。現在の接続先で通常予約とキーワード予約の両方を更新し、結果を確認した場合だけ解除してください。")
            }
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

    @ViewBuilder private var pendingSection: some View {
        if let pending = mutation.pending {
            AppSection("前の予約操作の結果を確認してください") {
                Text(pending.title + " · " + pending.action.label)
                if mutation.journalUnreadable || pending.isRecoveryEntry {
                    Text("前の操作記録を読み込めませんでした。操作先を特定できないため、現在の接続先で通常予約とキーワード予約の一覧を更新し、結果を確認してください。")
                        .font(.caption).foregroundStyle(.orange)
                    Button("両方の一覧を確認したので記録を解除") { recoverCorruptJournal = true }
                        .disabled(
                            store.loading || keywords.loading ||
                            !mutation.canRecoverCorruptJournal(
                                address: address,
                                reservationReadAt: store.lastReadAt,
                                keywordReadAt: keywords.lastReadAt,
                                reservationReadAddress: store.lastReadAddress,
                                keywordReadAddress: keywords.lastReadAddress
                            )
                        )
                } else {
                    Text(pending.address).font(.caption).foregroundStyle(.secondary)
                    if pending.target == .keywordReservation {
                        NavigationLink("キーワード予約の操作結果を確認") {
                            KeywordReservationListView(address: address, store: keywords)
                        }
                    }
                    if pending.target != .reservation {
                        Text("キーワード予約一覧を確認するまで、通常予約の操作は再開できません。")
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
                        .disabled(store.loading || !mutation.canAcknowledge(address: address, readAt: store.lastReadAt, readAddress: store.lastReadAddress ?? "", target: .reservation))
                }
            }
        }
    }
}

extension ReservationMutationAction {
    var label: String {
        switch self {
        case .add: return "追加"
        case .update: return "変更"
        case .delete: return "削除"
        case .unknown: return "予約操作"
        }
    }
}
