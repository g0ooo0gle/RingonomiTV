import SwiftUI
import RingonomiCore

struct EPGStationReservationListView: View {
    @AppStorage("epgstationAddress") private var address = ""
    @State private var draftAddress = ""
    @State private var preparedDraft = false
    @State private var filter = EPGStationReservationFilter.all
    @State private var offset = 0
    @State private var inputError: String?
    @State private var selectedID: Int?
    @State private var detailAddress: String?
    @State private var showingDetail = false
    @State private var creation: EPGStationReservationEditorConnection?
    @State private var acknowledgePending = false
    @ObservedObject private var mutation = EPGStationMutationStore.shared
    @StateObject private var store = EPGStationReservationStore()
#if DEBUG
    @State private var handledDebugSelection = false
    private var runtimeAddress: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--epgstation-url"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
#endif
    private var effectiveAddress: String {
#if DEBUG
        runtimeAddress ?? address
#else
        address
#endif
    }

    var body: some View {
        List {
            if let pending = mutation.pending {
                Section("前の操作結果を確認してください") {
                    Text(pending.title + " · " + pending.action)
                    if let schedule = pending.schedule { Text(schedule).font(.caption) }
                    Text(mutation.journalUnreadable ? "以前使用した接続先の予約一覧を確認してください。" : pending.address)
                        .font(.caption).foregroundStyle(.secondary)
                    Text("処理された可能性があります。接続先の予約一覧を更新して確認するまで、同じ操作を送信しないでください。")
                        .foregroundStyle(.orange).focusable()
                    if pending.target == "rule" {
                        NavigationLink("キーワード予約の操作結果を確認") { EPGStationRuleListView() }
                    }
                    Button("一覧を確認したので操作を再開") { acknowledgePending = true }
                        .disabled(filter != .all || store.loading || !mutation.canAcknowledge(address: effectiveAddress, readAt: store.lastReadAt))
                    if let id = pending.reservationID,
                       (try? EPGStationClient(address: effectiveAddress).baseURL.absoluteString) == pending.address {
                        Button("対象の予約を確認") {
                            selectedID = id
                            detailAddress = effectiveAddress
                            showingDetail = true
                        }
                    }
                }
            }
            Section("EPGStation接続") {
                TextField("EPGStation URL（例：http://ホスト:8888）", text: $draftAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("接続して予約を読み込む", action: connect)
                    .disabled(store.loading)
                if let inputError { Text(inputError).foregroundStyle(.red) }
            }
            if effectiveAddress.isEmpty {
                Text("接続先を入力すると、EPGStationの録画予約を表示できます。")
                    .foregroundStyle(.secondary)
            } else {
                Section("絞り込み") {
                    Picker("予約の状態", selection: $filter) {
                        ForEach(EPGStationReservationFilter.allCases, id: \.self) { value in
                            Text(reservationFilterName(value)).tag(value)
                        }
                    }
                    .disabled(store.loading)
                    .onChange(of: filter) { _, _ in offset = 0; reload() }
                }
                Section("録画予約") {
                    if store.loading {
                        ProgressView("録画予約を読み込んでいます…")
                        Button("読み込みを中止") { store.cancel() }
                    } else if let error = store.error {
                        Text(error).foregroundStyle(.red)
                        Button("再試行", action: reload)
                    } else if store.cancelled {
                        Text("読み込みを中止しました。")
                        Button("再試行", action: reload)
                    } else if store.items.isEmpty {
                        if offset > 0 {
                            Text("このページに録画予約はありません。")
                            Button("先頭のページを表示") { offset = 0; reload() }
                        } else {
                            Text(filter == .all ? "録画予約はありません。" : "この状態の録画予約はありません。")
                            Button("再読み込み", action: reload)
                        }
                    } else {
                        ForEach(store.items) { item in
                            Button {
                                selectedID = item.id
                                detailAddress = effectiveAddress
                                showingDetail = true
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(reservationTitle(item)).font(.headline).lineLimit(2)
                                    Text(reservationSchedule(item)).font(.caption)
                                    Text(store.channelNames[item.channelID] ?? "放送局情報なし")
                                        .font(.caption).foregroundStyle(.secondary)
                                    EPGStationReservationStatus(item: item)
                                }
                            }
                        }
                    }
                }
                if !store.loading, !store.cancelled, store.error == nil, store.total > 0 {
                    Section {
                        Text("\(offset / 30 + 1) / \(max(1, (store.total - 1) / 30 + 1)) ページ · \(store.total)件")
                        HStack(spacing: 24) {
                            Button("前のページ") { offset = max(0, offset - 30); reload() }
                                .disabled(offset == 0)
                            Button("次のページ") { offset += 30; reload() }
                                .disabled(offset + 30 >= store.total)
                        }
                    }
                }
            }
        }
        .navigationTitle("EPGStation予約")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink("キーワード予約") { EPGStationRuleListView() }
                Button("予約を追加") {
                    creation = EPGStationReservationEditorConnection(address: effectiveAddress, original: nil)
                }.disabled(effectiveAddress.isEmpty || mutation.busy || mutation.pending != nil)
                Button("更新", action: reload)
                    .disabled(effectiveAddress.isEmpty || store.loading)
            }
        }
        .sheet(item: $creation) { context in
            EPGStationReservationEditor(address: context.address, original: context.original) {
                offset = 0
                reload()
            }
        }
        .confirmationDialog("前の操作結果を確認しましたか？", isPresented: $acknowledgePending, titleVisibility: .visible) {
            Button("確認済み・操作を再開") { mutation.acknowledgeAfterReview(address: effectiveAddress, readAt: store.lastReadAt) }
            Button("まだ確認していない", role: .cancel) {}
        } message: {
            Text("結果が分からないまま追加し直すと、同じ録画予約が重複する場合があります。")
        }
        .navigationDestination(isPresented: $showingDetail) {
            if let selectedID, let detailAddress {
                EPGStationReservationDetailView(address: detailAddress, reservationID: selectedID)
            }
        }
        .onAppear {
            if !preparedDraft {
                preparedDraft = true
                draftAddress = effectiveAddress
                if !effectiveAddress.isEmpty { reload() }
            } else if !effectiveAddress.isEmpty, store.cancelled || mutation.pending != nil {
                reload()
            }
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if !handledDebugSelection,
               let index = arguments.firstIndex(of: "--epgstation-reservation"),
               index + 1 < arguments.count, let id = Int(arguments[index + 1]), id > 0 {
                handledDebugSelection = true
                selectedID = id
                detailAddress = effectiveAddress
                showingDetail = true
            }
#endif
        }
        .onChange(of: effectiveAddress) { _, next in
            creation = nil
            showingDetail = false
            selectedID = nil
            detailAddress = nil
            draftAddress = next
            offset = 0
            store.cancel(clear: true)
            if !next.isEmpty { reload() }
        }
        .onChange(of: showingDetail) { wasShowing, isShowing in
            guard wasShowing, !isShowing else { return }
            let dismissedAddress = detailAddress
            selectedID = nil
            detailAddress = nil
            guard dismissedAddress == effectiveAddress, !effectiveAddress.isEmpty else { return }
            reload()
        }
        .onChange(of: mutation.busy) { wasBusy, isBusy in
            if wasBusy, !isBusy, mutation.pending != nil {
                offset = 0
                if filter != .all { filter = .all } else { reload() }
            }
        }
        .onDisappear { store.cancel() }
    }

    private func connect() {
        do {
            let next = try EPGStationClient(address: draftAddress).baseURL.absoluteString
            inputError = nil
            offset = 0
#if DEBUG
            if runtimeAddress != nil { reload(); return }
#endif
            if address == next { reload() }
            else { address = next }
        } catch { inputError = error.localizedDescription }
    }

    private func reload() {
        guard !effectiveAddress.isEmpty else { return }
        store.load(address: effectiveAddress, offset: offset, filter: filter)
    }
}

private struct EPGStationReservationDetailView: View {
    let address: String
    let reservationID: Int
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = EPGStationReservationDetailStore()
    @ObservedObject private var mutation = EPGStationMutationStore.shared
    @State private var editing: EPGStationReservationEditorConnection?
    @State private var confirmCancel = false
    @State private var confirmedAfterStart = false
    @State private var mutationMessage: String?
    @State private var showingFailure = false
    @State private var submitting = false
    @State private var cancelTask: Task<Void, Never>?

    var body: some View {
        List {
            if store.loading {
                ProgressView("予約の詳細を読み込んでいます…")
                Button("読み込みを中止") { store.cancel() }
                    .onExitCommand(perform: goBack)
            } else if let error = store.error {
                Text(error).foregroundStyle(.red)
                Button("再試行", action: reload)
                    .onExitCommand(perform: goBack)
                Button("一覧に戻る", action: goBack)
                    .onExitCommand(perform: goBack)
            } else if store.cancelled {
                Text("読み込みを中止しました。")
                Button("再試行", action: reload)
                    .onExitCommand(perform: goBack)
                Button("一覧に戻る", action: goBack)
                    .onExitCommand(perform: goBack)
            } else if let item = store.item {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(reservationTitle(item)).font(.title2).lineLimit(3)
                        Text(reservationSchedule(item))
                        EPGStationReservationStatus(item: item)
                        Text(store.channelNames[item.channelID] ?? "放送局情報なし")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .focusable()
                    .accessibilityElement(children: .combine)
                    .onExitCommand(perform: goBack)
                }
                if let description = item.description, !description.isEmpty {
                    Section("番組の内容") {
                        Text(description).focusable().onExitCommand(perform: goBack)
                    }
                }
                if let extended = item.extended, !extended.isEmpty {
                    Section("詳しい情報") {
                        Text(extended).focusable().onExitCommand(perform: goBack)
                    }
                }
                Section("録画の設定") {
                    Text(item.allowEndLack ? "番組末尾の切れを許可" : "番組末尾の切れを許可しない")
                    Text(item.isDeleteOriginalAfterEncode ? "変換後に元の動画を削除" : "変換後も元の動画を保持")
                }
                Section {
                    Button("詳細を更新", action: reload)
                        .disabled(submitting || mutation.busy)
                        .onExitCommand(perform: goBack)
                    Button("一覧に戻る", action: goBack)
                        .disabled(submitting || mutation.busy)
                        .onExitCommand(perform: goBack)
                }
                Section("予約の操作") {
                    if item.ruleID == nil {
                        Button("録画設定を変更") {
                            editing = EPGStationReservationEditorConnection(address: address, original: item)
                        }
                            .onExitCommand(perform: goBack)
                    } else {
                        Text("ルール予約の設定は、予約元のルールで変更してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(item.ruleID == nil ? "予約を取り消す" : "この回の予約を除外", role: .destructive) {
                        confirmedAfterStart = Date().timeIntervalSince1970 * 1000 >= item.startAt
                        confirmCancel = true
                    }.onExitCommand(perform: goBack)
                }.disabled(submitting || mutation.busy || mutation.pending != nil)
            }
            if submitting || mutation.busy { ProgressView("予約の処理結果を確認しています…") }
            if let mutationMessage { Text(mutationMessage).foregroundStyle(.orange).focusable() }
        }
        .navigationTitle("EPGStation予約の詳細")
        .interactiveDismissDisabled(submitting)
        .onAppear {
            if store.cancelled || (store.item == nil && !store.loading && store.error == nil) {
                reload()
            }
        }
        .onChange(of: address) { _, _ in reload() }
        .onChange(of: reservationID) { _, _ in reload() }
        .onExitCommand(perform: goBack)
        .sheet(item: $editing) { context in
            EPGStationReservationEditor(address: context.address, original: context.original) { reload() }
        }
        .confirmationDialog("この予約を取り消しますか？", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button(confirmedAfterStart ? "録画への影響を確認して取り消す" : "予約を取り消す", role: .destructive) {
                if let item = store.item {
                    beginCancel(item: item, confirmedAfterStart: confirmedAfterStart)
                }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            if let item = store.item {
                Text(item.name + (item.ruleID == nil ? "\n手動予約を取り消します。" : "\nこの回を除外します。ルールは残ります。") + (confirmedAfterStart ? "\n録画開始時刻を過ぎています。進行中の録画が停止する場合があります。" : ""))
            }
        }
        .alert("予約操作の結果を確認してください", isPresented: $showingFailure) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(mutationMessage ?? "予約操作の結果を確認できませんでした。予約一覧を確認してください。")
        }
        .onDisappear {
            // A detail view can disappear while its editor or confirmation
            // dialog is presented.  Keep those child operations alive; only
            // cancel a read/task when the detail itself is really leaving.
            guard !submitting, !showingFailure, editing == nil, !confirmCancel else { return }
            store.cancel()
            cancelTask?.cancel()
        }
    }

    private func reload() { store.load(address: address, id: reservationID) }

    private func goBack() {
        guard !submitting, !mutation.busy else { return }
#if DEBUG
        print("RingonomiEPGStationReservationDetail: back")
#endif
        dismiss()
    }

    private func beginCancel(item: EPGStationReservation, confirmedAfterStart: Bool) {
        guard !submitting, !mutation.busy, mutation.pending == nil else { return }
        confirmCancel = false
        submitting = true
        showingFailure = false
        mutationMessage = nil
        cancelTask = Task { await cancelReservation(item: item, confirmedAfterStart: confirmedAfterStart) }
    }

    @MainActor private func cancelReservation(
        item original: EPGStationReservation,
        confirmedAfterStart: Bool
    ) async {
        defer {
            submitting = false
            cancelTask = nil
        }
        mutationMessage = nil
        do {
            let client = try EPGStationClient(address: address)
            var removed = false
            try await mutation.perform(address: address, title: original.name, action: "取消", reservationID: original.id, schedule: epgStationSchedule(start: original.startAt, end: original.endAt), prepare: {
                let latest = try await client.reservation(id: original.id)
                try epgStationRequireSameReservation(original, latest)
                guard latest.isSkip == original.isSkip, latest.isOverlap == original.isOverlap else {
                    throw ReservationUIError("予約の状態が変わりました。詳細を更新してから確認してください。")
                }
                guard confirmedAfterStart || Date().timeIntervalSince1970 * 1000 < latest.startAt else {
                    throw ReservationUIError("録画開始時刻になりました。詳細を更新して取消の影響を確認してください。")
                }
                return latest
            }, send: { latest in
                try await client.deleteReservation(id: latest.id)
                do {
                    let updated = try await client.reservation(id: latest.id)
                    guard latest.ruleID != nil, !updated.isConflict,
                          (latest.isOverlap ? updated.isOverlap : updated.isSkip) else {
                        throw EPGStationWriteError.outcomeUnknown
                    }
                } catch EPGStationError.httpStatus(404) {
                    // A manual reservation (or event-relay reservation) was removed.
                    removed = true
                } catch { throw EPGStationWriteError.outcomeUnknown }
            })
            guard !Task.isCancelled else { return }
            mutationMessage = "予約サーバーが取消を受け付けました。進行中の録画停止には時間がかかる場合があります。"
#if DEBUG
            print("RingonomiEPGStationMutation: cancelled")
#endif
            if removed { dismiss() } else { reload() }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            mutationMessage = mutation.pending == nil ? error.localizedDescription : "取消の結果を確認できませんでした。再送せず一覧を更新して確認してください。"
            showingFailure = true
        }
    }
}

private struct EPGStationReservationStatus: View {
    let item: EPGStationReservation

    var body: some View {
        HStack(spacing: 16) {
            Text(item.ruleID == nil ? "手動予約" : "ルール予約")
            if item.isTimeSpecified { Text("時間指定") }
            if item.isConflict { Text("競合").foregroundStyle(.red) }
            if item.isSkip { Text("スキップ").foregroundStyle(.orange) }
            if item.isOverlap { Text("重複除外").foregroundStyle(.orange) }
            if !item.isConflict, !item.isSkip, !item.isOverlap { Text("予約済み") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private func reservationFilterName(_ filter: EPGStationReservationFilter) -> String {
    switch filter {
    case .all: "すべて"
    case .normal: "予約済み"
    case .conflict: "競合"
    case .skip: "スキップ"
    case .overlap: "重複除外"
    }
}

private func reservationSchedule(_ item: EPGStationReservation) -> String {
    func formatted(_ value: Double) -> String {
        guard value.isFinite, (-62_135_596_800_000...253_402_300_799_000).contains(value) else {
            return "日時情報なし"
        }
        return reservationDate(Date(timeIntervalSince1970: value / 1000))
    }
    return formatted(item.startAt) + " – " + formatted(item.endAt)
}

private func reservationTitle(_ item: EPGStationReservation) -> String {
    item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "番組名なし" : item.name
}

private struct EPGStationReservationEditorConnection: Identifiable {
    let id = UUID()
    let address: String
    let original: EPGStationReservation?
}
