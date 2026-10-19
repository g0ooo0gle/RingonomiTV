import SwiftUI
import RingonomiCore

struct EPGStationRuleListView: View {
    @AppStorage("epgstationAddress") private var address = ""
    @State private var draftAddress = ""
    @State private var keyword = ""
    @State private var appliedKeyword = ""
    @State private var offset = 0
    @State private var prepared = false
    @State private var inputError: String?
    @State private var selectedID: Int?
    @State private var detailAddress: String?
    @State private var showingDetail = false
    @State private var creation: EPGStationRuleEditorConnection?
    @State private var acknowledge = false
    @State private var restoreRowFocus = false
    @FocusState private var focusedID: Int?
    @StateObject private var store = EPGStationRuleStore()
    @ObservedObject private var mutation = EPGStationMutationStore.shared

    private var effectiveAddress: String {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--epgstation-url"), i + 1 < args.count { return args[i + 1] }
#endif
        return address
    }

    var body: some View {
        VStack(spacing: 0) {
            EPGStationListHeader("EPGStationキーワード予約") {
                Button("ルールを追加") { creation = .init(address: effectiveAddress, original: nil) }
                    .disabled(effectiveAddress.isEmpty || mutation.busy || mutation.pending != nil)
                Button("更新", action: reload).disabled(effectiveAddress.isEmpty || store.loading)
            }
            ruleList
        }
        .navigationTitle("")
        .sheet(item: $creation, onDismiss: { restoreRowFocus = true; reload() }) { context in
            EPGStationRuleEditor(address: context.address, original: context.original) { offset = 0; selectedID = nil }
        }
        .navigationDestination(isPresented: $showingDetail) {
            if let selectedID { EPGStationRuleDetailView(address: detailAddress ?? effectiveAddress, id: selectedID) }
        }
        .confirmationDialog("前の操作結果を確認しましたか？", isPresented: $acknowledge, titleVisibility: .visible) {
            Button("確認済み・操作を再開") {
                mutation.acknowledgeAfterReview(address: effectiveAddress, readAt: store.lastReadAt, target: "rule")
            }
            Button("まだ確認していない", role: .cancel) {}
        } message: {
            Text("対象のルールと録画予約を確認してください。結果が不明なまま追加し直すと重複することがあります。")
        }
        .onAppear {
            if !prepared {
                prepared = true
                draftAddress = effectiveAddress
                if !effectiveAddress.isEmpty { reload() }
            } else if store.cancelled, !showingDetail { reload() }
#if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if selectedID == nil, let i = args.firstIndex(of: "--epgstation-rule"), i + 1 < args.count, let id = Int(args[i + 1]), id > 0 {
                selectedID = id
                detailAddress = effectiveAddress
                showingDetail = true
            }
#endif
        }
        .onChange(of: address) { _, _ in
            store.cancel(clear: true)
            showingDetail = false
            selectedID = nil
            detailAddress = nil
            creation = nil
            draftAddress = effectiveAddress
            offset = 0
            appliedKeyword = ""
            keyword = ""
            if !effectiveAddress.isEmpty { reload() }
        }
        .onChange(of: mutation.busy) { _, busy in
            if !busy, mutation.pending != nil { appliedKeyword = ""; keyword = ""; offset = 0; reload() }
        }
        .onChange(of: showingDetail) { _, visible in
            if !visible { restoreRowFocus = true; reload() }
        }
        .task(id: store.loading) {
            guard !store.loading, restoreRowFocus, !store.items.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, !showingDetail else { return }
            focusedID = store.items.contains(where: { $0.id == selectedID }) ? selectedID : store.items.first?.id
            restoreRowFocus = false
        }
        .onDisappear { store.cancel() }
    }

    private var ruleList: some View {
        List {
            pendingSection
            Section("EPGStation接続") {
                TextField("EPGStation URL（例：http://ホスト:8888）", text: $draftAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("接続してルールを読み込む", action: connect).disabled(store.loading || mutation.busy)
                if let inputError { Text(inputError).foregroundStyle(.red) }
            }
            if effectiveAddress.isEmpty {
                Text("EPGStationの接続先を入力してください。")
            } else {
                Section("ルールの検索") {
                    TextField("登録済みルールのキーワード", text: $keyword)
                    Button("検索") { offset = 0; appliedKeyword = keyword; reload() }.disabled(store.loading)
                    if !appliedKeyword.isEmpty {
                        Button("検索を解除") { keyword = ""; appliedKeyword = ""; offset = 0; reload() }
                    }
                }
                ruleSection
                if !store.loading, store.error == nil, !store.cancelled, store.total > 0 {
                    Section {
                        Text("\(offset / 30 + 1) / \(max(1, (store.total - 1) / 30 + 1)) ページ · \(store.total)件")
                        HStack(spacing: 24) {
                            Button("前のページ") { offset = max(0, offset - 30); reload() }.disabled(offset == 0)
                            Button("次のページ") { offset += 30; reload() }.disabled(offset + 30 >= store.total)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var pendingSection: some View {
        if let pending = mutation.pending {
            Section("前の操作結果を確認してください") {
                Text(pending.title + " · " + pending.action)
                Text(mutation.journalUnreadable ? "以前使用した接続先の一覧を確認してください。" : pending.address)
                    .font(.caption).foregroundStyle(.secondary)
                Text("処理された可能性があります。ルールと録画予約を確認するまで、再送信しないでください。")
                    .foregroundStyle(.orange).focusable()
                if pending.target == "rule" || mutation.journalUnreadable {
                    Button("一覧を確認したので操作を再開") { acknowledge = true }
                        .disabled(!appliedKeyword.isEmpty || store.loading || !mutation.canAcknowledge(address: effectiveAddress, readAt: store.lastReadAt, target: "rule"))
                    if let id = pending.ruleID,
                       (try? EPGStationClient(address: effectiveAddress).baseURL.absoluteString) == pending.address {
                        Button("対象のルールを確認") { selectedID = id; detailAddress = effectiveAddress; showingDetail = true }
                    }
                }
                NavigationLink("録画予約を確認") { EPGStationReservationListView() }
            }
        }
    }

    private var ruleSection: some View {
        Section("自動予約ルール") {
            if store.loading {
                ProgressView("ルールを読み込んでいます…")
                Button("読み込みを中止") { store.cancel() }
            } else if let error = store.error {
                Text(error).foregroundStyle(.red)
                Button("再試行", action: reload)
            } else if store.cancelled {
                Text("読み込みを中止しました。")
                Button("再試行", action: reload)
            } else if store.items.isEmpty {
                Text(appliedKeyword.isEmpty ? "このページにルールはありません。" : "一致するルールはありません。")
                if offset > 0 { Button("先頭のページを表示") { offset = 0; reload() } }
            } else {
                ForEach(store.items) { item in
                    Button { selectedID = item.id; detailAddress = effectiveAddress; showingDetail = true } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(epgStationRuleTitle(item.options)).font(.headline).lineLimit(2)
                            Text("\(item.options.enabled == true ? "有効" : "無効") · ルール \(item.id)" + (item.reservesCount.map { " · 予約 \($0)件" } ?? ""))
                                .font(.caption)
                            if !epgStationRuleString(item.options.searchValues["ignoreKeyword"]).isEmpty {
                                Text("除外：" + epgStationRuleString(item.options.searchValues["ignoreKeyword"]))
                                    .font(.caption).lineLimit(1)
                            }
                        }
                    }
                    .focused($focusedID, equals: item.id)
                }
            }
        }
    }

    private func reload() { if !effectiveAddress.isEmpty { store.load(address: effectiveAddress, offset: offset, keyword: appliedKeyword) } }
    private func connect() {
        do {
            let normalized = try EPGStationClient(address: draftAddress).baseURL.absoluteString
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--epgstation-url") {
                guard normalized == (try EPGStationClient(address: effectiveAddress).baseURL.absoluteString) else {
                    throw ReservationUIError("検証中の接続先は起動引数から指定されています。通常起動して変更してください。")
                }
            } else { address = normalized }
#else
            address = normalized
#endif
            inputError = nil
            offset = 0
            appliedKeyword = ""
            reload()
        } catch { inputError = error.localizedDescription }
    }
}

struct EPGStationRuleEditorConnection: Identifiable {
    let id = UUID()
    let address: String
    let original: EPGStationRule?
}
