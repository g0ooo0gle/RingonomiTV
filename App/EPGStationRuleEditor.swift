import SwiftUI
import RingonomiCore

struct EPGStationRuleEditor: View {
    let address: String
    let original: EPGStationRule?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = EPGStationRuleEditorStore()
    @ObservedObject private var mutation = EPGStationMutationStore.shared
    @State private var options = epgStationNewRuleOptions()
    @State private var prepared = false
    @State private var confirm = false
    @State private var showingPreview = false
    @State private var submitting = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @FocusState private var footerFocus: Footer?
    private enum Footer: Hashable { case save, close }

    private var needsPreview: Bool {
        options.isTimeSpecification != true && options.enabled == true
            && (original?.options.enabled != true || original?.options.searchValues != options.searchValues)
    }
    private var previewCurrent: Bool { store.previewedSearch == options.searchValues }
    private var canSave: Bool {
        !submitting && !mutation.busy && mutation.pending == nil && !store.loading
            && store.error == nil && !store.previewing && (!needsPreview || previewCurrent)
            && original?.options != options
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                EPGStationListHeader(original == nil ? "EPGStationルールを追加" : "EPGStationルールを編集") {
                    Button("プレビュー") {
                        store.search(address: address, values: options.searchValues)
                        showingPreview = true
                    }.disabled(submitting || store.loading || store.previewing || store.error != nil || options.isTimeSpecification == true)
                    Button("保存内容を確認") { confirm = true }.disabled(!canSave)
                }
                editorForm
            }
            .disabled(submitting)
            .navigationTitle("")
            .sheet(isPresented: $showingPreview) {
                NavigationStack {
                    List {
                        if store.previewing { ProgressView("番組を検索しています…") }
                        if let error = store.previewError { Text(error).foregroundStyle(.red).focusable() }
                        if previewCurrent {
                            Text("検索結果：\(store.preview.count)件（最大30件）")
                            ForEach(store.preview) { program in
                                EPGStationRulePreviewRow(program: program, channel: previewChannel(program))
                            }
                        }
                        Button("条件に戻る") { showingPreview = false }
                    }
                    .navigationTitle("番組検索プレビュー")
                    .onExitCommand { showingPreview = false }
                }
            }
            .interactiveDismissDisabled(submitting)
            .onExitCommand(perform: close)
            .confirmationDialog("この内容でルールを保存しますか？", isPresented: $confirm, titleVisibility: .visible) {
                Button("保存する", action: beginSave)
                Button("戻って修正", role: .cancel) {}
            } message: {
                Text(epgStationRuleTitle(options) + "\n" + (options.enabled == true ? "有効" : "無効")
                     + "\n保存すると、関連する録画予約が再計算されます。追加・変更・取り消しが行われる場合があります。")
            }
            .onAppear {
                guard !prepared else { return }
                prepared = true
                if let original { options = original.options }
                store.load(address: address)
            }
            .onChange(of: options.searchValues) { _, _ in store.invalidatePreview() }
            .onChange(of: submitting) { _, busy in
                if !busy, message != nil { footerFocus = .close }
            }
            .onChange(of: showingPreview) { _, visible in
                if !visible, store.previewing { store.invalidatePreview() }
            }
            .onDisappear {
                // tvOS presents these child screens full-screen. Their
                // appearance must not discard the draft's search result.
                guard !showingPreview, !confirm, !submitting else { return }
                store.cancel()
                operation?.cancel()
            }
        }
    }

    private var editorForm: some View {
        Form {
            if store.loading {
                ProgressView("放送局と保存先を読み込んでいます…")
            } else if let error = store.error {
                Text(error).foregroundStyle(.red)
                Button("再試行") { store.load(address: address) }
            } else {
                if original == nil {
                    Section {
                        Text("新しいルールは無効の状態から設定できます。有効にすると、一致する番組が自動で録画予約されます。")
                            .font(.caption).foregroundStyle(.secondary).focusable()
                    }
                }
                EPGStationRuleFields(options: $options, channels: store.channels, directories: store.directories)
                previewSection
            }
            if let message { Section { Text(message).foregroundStyle(.red).focusable() } }
            if mutation.pending != nil, !submitting {
                Section {
                    Text("前の操作結果が未確認です。ルール一覧へ戻り、結果を確認してください。")
                        .foregroundStyle(.orange).focusable()
                }
            }
            Section {
                if submitting { ProgressView("ルールの処理結果を確認しています…") }
                Button("保存内容を確認") { confirm = true }.disabled(!canSave).focused($footerFocus, equals: .save)
                Button("閉じる", action: close).disabled(submitting).focused($footerFocus, equals: .close)
            }
        }
    }

    private var previewSection: some View {
        Section("検索プレビュー") {
            if options.isTimeSpecification == true {
                Text("時刻指定ルールの時間条件を保持しています。番組検索のプレビューには対応していません。")
                    .font(.caption).foregroundStyle(.secondary).focusable()
            } else {
                Text("現在の番組表から先頭30件を表示します。重複・競合・録画済みなどの条件により、実際の録画予約とは異なる場合があります。")
                    .font(.caption).foregroundStyle(.secondary).focusable()
                Button("この条件で番組を検索") { store.search(address: address, values: options.searchValues) }
                    .disabled(store.previewing)
                if store.previewing {
                    ProgressView("番組を検索しています…")
                    Button("検索を中止") { store.invalidatePreview() }
                }
                if let error = store.previewError { Text(error).foregroundStyle(.red).focusable() }
                if previewCurrent {
                    Text(store.preview.isEmpty ? "現在の番組表に一致する番組はありません。" : "検索結果：\(store.preview.count)件（最大30件）")
                    ForEach(store.preview) { program in
                        EPGStationRulePreviewRow(program: program, channel: previewChannel(program))
                    }
                } else if needsPreview {
                    Text("有効な検索条件を保存する前に、プレビューを確認してください。")
                        .foregroundStyle(.orange).focusable()
                }
            }
        }
    }

    private func close() { if !submitting { dismiss() } }
    private func previewChannel(_ program: EPGStationScheduleProgram) -> String? {
        store.channels.first(where: { $0.id == program.channelID }).map { $0.halfWidthName ?? $0.name }
    }
    private func beginSave() {
        guard canSave else { return }
        submitting = true
        message = nil
        operation = Task { await save() }
    }
    private func save() async {
        defer { submitting = false }
        do {
            try await EPGStationRuleActions.save(address: address, original: original, edited: options, mutation: mutation)
            guard !Task.isCancelled else { return }
            onSaved()
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            message = error.localizedDescription
        }
    }
}

private struct EPGStationRulePreviewRow: View {
    let program: EPGStationScheduleProgram
    let channel: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(program.name)
            Text(epgStationSchedule(start: program.startAt, end: program.endAt)).font(.caption)
            if let channel { Text(channel).font(.caption) }
            if !program.isFree { Text("有料放送").font(.caption).foregroundStyle(.orange) }
        }.focusable()
    }
}

private func epgStationNewRuleOptions() -> EPGStationRuleOptions {
    EPGStationRuleOptions(rawValues: [
        "isTimeSpecification": .bool(false),
        "searchOption": .object([
            "keyword": .string(""), "ignoreKeyword": .string(""),
            "name": .bool(true), "description": .bool(false), "extended": .bool(false),
            "keyCS": .bool(false), "keyRegExp": .bool(false),
            "ignoreName": .bool(true), "ignoreDescription": .bool(false), "ignoreExtended": .bool(false),
            "ignoreKeyCS": .bool(false), "ignoreKeyRegExp": .bool(false),
            "GR": .bool(true), "BS": .bool(false), "CS": .bool(false), "SKY": .bool(false), "isFree": .bool(true)
        ]),
        "reserveOption": .object(["enable": .bool(false), "allowEndLack": .bool(false), "avoidDuplicate": .bool(true)])
    ])
}
