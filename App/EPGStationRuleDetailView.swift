import SwiftUI
import RingonomiCore

struct EPGStationRuleDetailView: View {
    let address: String
    let id: Int
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = EPGStationRuleDetailStore()
    @ObservedObject private var mutation = EPGStationMutationStore.shared
    @State private var editor: EPGStationRuleEditorConnection?
    @State private var confirmation: Action?
    @State private var message: String?
    @State private var showingFailure = false
    @State private var submitting = false
    @State private var operation: Task<Void, Never>?
    @FocusState private var focusedTarget: FocusTarget?
    @State private var pendingFocus: FocusTarget?
    @State private var focusGeneration = 0
    private enum Action: String, Identifiable { case toggle, delete; var id: String { rawValue } }
    private enum FocusTarget: Hashable { case toggle, loadError }

    private var focusTaskID: String {
        "\(store.loading)-\(submitting)-\(focusGeneration)"
    }

    var body: some View {
        List {
            if store.loading {
                ProgressView("ルールと関連する予約を読み込んでいます…")
                Button("読み込みを中止") { store.cancel() }
            } else if let error = store.error {
                Text(error).foregroundStyle(.red)
                Button("再試行", action: reload).focused($focusedTarget, equals: .loadError)
            } else if store.cancelled {
                Text("読み込みを中止しました。")
                Button("再試行", action: reload).focused($focusedTarget, equals: .loadError)
            }
            if let item = store.item {
                Section("ルール \(item.id)") {
                    Text(epgStationRuleTitle(item.options)).font(.title3)
                    Text(item.options.enabled == true ? "有効" : "無効")
                    Text(item.options.isTimeSpecification == true ? "曜日・時刻を指定して予約" : "番組情報から予約")
                    let excluded = epgStationRuleString(item.options.searchValues["ignoreKeyword"])
                    if !excluded.isEmpty { Text("除外：" + excluded) }
                }
                Section("操作") {
                    Button("検索条件・録画設定を編集") { editor = .init(address: address, original: item) }
                    Button(item.options.enabled == true ? "ルールを無効にする" : "ルールを有効にする") { confirmation = .toggle }
                        .focused($focusedTarget, equals: .toggle)
                    Button("ルールを削除", role: .destructive) { confirmation = .delete }
                }.disabled(submitting || mutation.busy || mutation.pending != nil || store.loading)
                Section("関連する録画予約") {
                    Text("ルールの保存・有効無効切替・削除により、関連する録画予約が再計算されます。更新して最新の状態を確認してください。")
                        .font(.caption).foregroundStyle(.secondary).focusable()
                    if let error = store.reservationError {
                        Text("予約の状態は確認できませんでした。" + error).foregroundStyle(.orange)
                    } else {
                        Text("\(store.reservationTotal)件（先頭30件まで表示）")
                        ForEach(store.reservations) { reservation in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(reservation.name)
                                Text(epgStationSchedule(start: reservation.startAt, end: reservation.endAt)).font(.caption)
                                Text(reservation.isSkip ? "除外" : reservation.isConflict ? "競合" : reservation.isOverlap ? "重複" : "予約済み")
                                    .font(.caption)
                            }.focusable()
                        }
                    }
                }
            }
            if let message {
                Section { Text(message).foregroundStyle(.orange).focusable() }
            }
            if mutation.pending != nil, !submitting {
                Text("前の操作結果が未確認です。一覧へ戻り、結果を確認してください。")
                    .foregroundStyle(.orange).focusable()
            }
            if submitting { ProgressView("ルールの処理結果を確認しています…") }
            Button("一覧へ戻る") { if !submitting { dismiss() } }.disabled(submitting)
        }
        .navigationTitle("EPGStationルール詳細")
        .toolbar { Button("更新", action: reload).disabled(store.loading || submitting) }
        .sheet(item: $editor, onDismiss: reload) { context in
            EPGStationRuleEditor(address: context.address, original: context.original) {
                message = "ルールの保存を確認しました。録画予約の再計算は続いている場合があります。"
            }
        }
        .confirmationDialog(confirmation == .delete ? "このルールを削除しますか？" : "ルールの有効状態を変更しますか？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let action = confirmation, let item = store.item {
                Button(action == .delete ? "ルールを削除する" : item.options.enabled == true ? "無効にする" : "有効にする", role: action == .delete ? .destructive : nil) {
                    beginApply(action, item: item)
                }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text(confirmation == .delete
                 ? "関連する録画予約が取り消されます。録画済みの動画ファイルは削除されません。"
                 : "関連する録画予約が追加・変更・取り消される場合があります。処理には時間がかかることがあります。")
        }
        .alert("操作結果を確認してください", isPresented: $showingFailure) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(message ?? "操作結果を確認できませんでした。詳細画面を確認してください。")
        }
        .onAppear { if store.item == nil || store.cancelled { reload() } }
        .task(id: focusTaskID) {
            guard let pendingFocus, !store.loading, !submitting else { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled, self.pendingFocus == pendingFocus, !store.loading, !submitting else { return }
            self.pendingFocus = nil
            if store.error != nil, pendingFocus == .toggle {
                focusedTarget = .loadError
            } else {
                focusedTarget = pendingFocus
            }
        }
        .onDisappear {
            guard !submitting, !showingFailure, confirmation == nil, editor == nil else { return }
            pendingFocus = nil
            store.cancel()
            operation?.cancel()
        }
        .onExitCommand { if !submitting { dismiss() } }
    }

    private func reload() { store.load(address: address, id: id) }
    private func beginApply(_ action: Action, item: EPGStationRule) {
        guard !submitting else { return }
        submitting = true
        message = nil
        showingFailure = false
        operation = Task { await apply(action, item: item) }
    }
    private func apply(_ action: Action, item: EPGStationRule) async {
        defer { submitting = false }
        do {
            switch action {
            case .toggle: try await EPGStationRuleActions.setEnabled(address: address, original: item, mutation: mutation)
            case .delete: try await EPGStationRuleActions.delete(address: address, original: item, mutation: mutation)
            }
            guard !Task.isCancelled else { return }
            if action == .delete { dismiss() }
            else {
                message = "ルールの変更を確認しました。録画予約の再計算は続いている場合があります。更新して確認してください。"
                pendingFocus = .toggle
                focusGeneration &+= 1
                reload()
            }
        } catch {
            guard !Task.isCancelled else { return }
            message = error.localizedDescription
            showingFailure = true
        }
    }
}
