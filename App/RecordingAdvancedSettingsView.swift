import SwiftUI
import RingonomiCore

struct RecordingAdvancedSettingsView: View {
    @Binding var draft: RecordingAdvancedDraft
    let address: String
    @StateObject private var batches = RecordingBatchStore()
    @State private var error: String?

    var body: some View {
        Form {
            AppSection("保存先") {
                NavigationLink(draft.foldersEditable ? (draft.folders.isEmpty ? "サーバーの既定フォルダー" : "保存先フォルダー：\(draft.folders.count)件") : "現在の保存先を保持") {
                    RecordingFoldersView(draft: $draft)
                }
                if let message = draft.foldersMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            AppSection("録画後の処理") {
                Picker("録画後の動作", selection: Binding(
                    get: { draft.postRecordingMode },
                    set: { value in
                        guard value != draft.postRecordingMode else { return }
                        do { try draft.setPostRecordingMode(value) }
                        catch { self.error = error.localizedDescription }
                    }
                )) {
                    ForEach(RecordingPostRecordingMode.allCases, id: \.rawValue) { mode in
                        Text(modeTitle(mode)).tag(mode.rawValue)
                    }
                    if !draft.isKnownPostRecordingMode {
                        Text("現在の設定：\(draft.postRecordingMode)").tag(draft.postRecordingMode)
                    }
                }
                NavigationLink {
                    RecordingBatchSelection(draft: $draft, store: batches)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("録画後バッチ")
                        Text(draft.currentBatchPath ?? "指定なし")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .task(id: address) { batches.configure(address: address) }
                Text("録画後の動作とバッチは録画サーバーで実行されます。サーバーが対応する設定を選んでください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("保存先と録画後処理")
        .alert("設定を確認してください", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("閉じる") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func modeTitle(_ mode: RecordingPostRecordingMode) -> String {
        switch mode {
        case .default: return "サーバー既定"
        case .nothing: return "何もしない"
        case .standby: return "スタンバイ"
        case .standbyAndReboot: return "スタンバイ・復帰後に再起動"
        case .suspend: return "休止"
        case .suspendAndReboot: return "休止・復帰後に再起動"
        case .shutdown: return "シャットダウン"
        }
    }
}

private struct RecordingFolderEditorTarget: Identifiable {
    let id = UUID()
    let folder: RecordingFolderEdit?
}

private struct RecordingFoldersView: View {
    @Binding var draft: RecordingAdvancedDraft
    @State private var editing: RecordingFolderEditorTarget?

    var body: some View {
        List {
            Section {
                Text("録画サーバー上のフォルダーを指定します。保存先が空の場合は、サーバーの既定フォルダーを使います。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if draft.foldersEditable {
                AppSection("保存先フォルダー") {
                    ForEach(draft.folders) { folder in
                        Button { editing = RecordingFolderEditorTarget(folder: folder) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(folder.recordingFolderPath.flatMap { $0.isEmpty ? nil : $0 } ?? "フォルダー未入力")
                                    .lineLimit(2)
                                if folder.isOnesegSeparateRecordingFolder == true {
                                    Text("ワンセグ用").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button("保存先を追加") { editing = RecordingFolderEditorTarget(folder: nil) }
                }
            } else {
                Section { Text(draft.foldersMessage ?? "保存先の形式を確認できません。既存設定は保持されます。") }
            }
        }
        .navigationTitle("保存先フォルダー")
        .sheet(item: $editing) { item in
            RecordingFolderEditor(folder: item.folder) { path, template, oneseg in
                var candidate = draft
                if let original = item.folder {
                    guard candidate.folders.contains(where: { $0.id == original.id && $0.rawValues == original.rawValues }) else {
                        throw ReservationUIError("保存先が変更されています。一覧から開き直してください。")
                    }
                    if path != original.recordingFolderPath { candidate.updateFolder(id: original.id, path: path) }
                    if template != original.recordingFileNameTemplate { candidate.updateFolder(id: original.id, template: template) }
                    if oneseg != (original.isOnesegSeparateRecordingFolder ?? false) { candidate.updateFolder(id: original.id, oneseg: oneseg) }
                } else {
                    guard candidate.addFolder(path: path, template: template, oneseg: oneseg) != nil else {
                        throw RecordingAdvancedSettingsError.foldersNotEditable
                    }
                }
                _ = try candidate.validatedApplying(to: RecordSettings())
                draft = candidate
            } onDelete: {
                guard let original = item.folder,
                      draft.folders.contains(where: { $0.id == original.id && $0.rawValues == original.rawValues }),
                      draft.removeFolder(id: original.id) else {
                    throw ReservationUIError("保存先が変更されています。一覧から開き直してください。")
                }
            }
        }
    }
}

private struct RecordingFolderEditor: View {
    let folder: RecordingFolderEdit?
    let onApply: (String, String?, Bool) throws -> Void
    let onDelete: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var template: String
    @State private var oneseg: Bool
    @State private var error: String?
    @State private var deleting = false

    init(folder: RecordingFolderEdit?, onApply: @escaping (String, String?, Bool) throws -> Void, onDelete: @escaping () throws -> Void) {
        self.folder = folder
        self.onApply = onApply
        self.onDelete = onDelete
        _path = State(initialValue: folder?.recordingFolderPath ?? "")
        _template = State(initialValue: folder?.recordingFileNameTemplate ?? "")
        _oneseg = State(initialValue: folder?.isOnesegSeparateRecordingFolder ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                AppSection("保存先") {
                    TextField("サーバー上のフォルダーパス", text: $path)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("ワンセグ用の保存先", isOn: $oneseg)
                }
                AppSection("ファイル名") {
                    TextField("ファイル名テンプレート（空欄は既定）", text: $template)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("録画サーバーが対応するテンプレートを指定してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("適用") {
                        do {
                            // Keep an existing empty template distinct from null until it is edited.
                            let value = template == (folder?.recordingFileNameTemplate ?? "")
                                ? folder?.recordingFileNameTemplate : (template.isEmpty ? nil : template)
                            try onApply(path, value, oneseg)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    if folder != nil { Button("保存先を削除", role: .destructive) { deleting = true } }
                    Button("キャンセル") { dismiss() }
                }
            }
            .navigationTitle(folder == nil ? "保存先を追加" : "保存先を編集")
            .alert("保存先を確認してください", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("閉じる") { error = nil }
            } message: { Text(error ?? "") }
            .confirmationDialog("この保存先を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    do { try onDelete(); dismiss() } catch { self.error = error.localizedDescription }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("この予約の保存先から削除します。録画ファイルは削除されません。") }
        }
    }
}

private struct RecordingBatchSelection: View {
    @Binding var draft: RecordingAdvancedDraft
    @ObservedObject var store: RecordingBatchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            AppSection("この予約に適用") {
                choice("元の設定を保持", detail: draft.originalBatchPath, value: .unchanged)
                choice("バッチを実行しない", detail: nil, value: .clear)
                if case .path(let path) = draft.batchChoice, !store.entries.contains(where: { $0.path == path }) {
                    choice("選択済みのパス", detail: path, value: .path(path))
                }
            }
            AppSection("登録済みバッチ") {
                ForEach(store.entries) { entry in
                    choice(entry.name, detail: entry.path, value: .path(entry.path))
                }
                if store.entries.isEmpty { Text("登録済みバッチはありません。").foregroundStyle(.secondary) }
                NavigationLink("バッチの登録・削除") { RecordingBatchLibraryView(store: store) }
            }
            if let error = store.error { Section { Text(error).foregroundStyle(.orange) } }
            Section {
                Text("サーバー上にあるバッチのパスを選びます。選択後、予約画面で保存すると適用されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("録画後バッチ")
    }

    private func choice(_ title: String, detail: String?, value: RecordingBatchChoice) -> some View {
        Button {
            switch value {
            case .unchanged: draft.keepBatch()
            case .clear: draft.setBatch(path: nil)
            case .path(let path): draft.chooseBatch(path: path)
            }
            dismiss()
        } label: {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                if draft.batchChoice == value { Image(systemName: "checkmark").accessibilityLabel("選択中") }
            }
        }
    }
}

private struct RecordingBatchLibraryView: View {
    @ObservedObject var store: RecordingBatchStore
    @State private var adding = false
    @State private var deleting: RegisteredRecordingBatch?
    @State private var confirmingDeletion = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("登録一覧は接続先ごとにこのApple TVへ保存されます。登録・削除だけでは、サーバーの予約やファイルは変更されません。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("バッチを登録") { adding = true }.disabled(!store.canEdit)
            }
            AppSection("登録済み") {
                ForEach(store.entries) { entry in
                    Button { deleting = entry; confirmingDeletion = true } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.name)
                            Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.disabled(!store.canEdit)
                }
                if store.entries.isEmpty { Text("登録済みバッチはありません。").foregroundStyle(.secondary) }
            }
            if let error = store.error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle("バッチの登録・削除")
        .sheet(isPresented: $adding) { RecordingBatchRegistration(store: store) }
        .confirmationDialog("この登録を削除しますか？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("登録を削除", role: .destructive) {
                guard let entry = deleting else { return }
                do { try store.remove(id: entry.id) } catch { self.error = error.localizedDescription }
                deleting = nil
            }
            Button("キャンセル", role: .cancel) { deleting = nil }
        } message: { Text("\(deleting?.name ?? "")\n予約で選択済みのパスや、サーバー上のバッチは削除されません。") }
        .alert("登録を更新できませんでした", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("閉じる") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct RecordingBatchRegistration: View {
    @ObservedObject var store: RecordingBatchStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                AppSection("録画後バッチ") {
                    TextField("表示名", text: $name)
                    TextField("サーバー上のバッチファイルのパス", text: $path)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button("登録") {
                        do { try store.add(name: name, path: path); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!store.canEdit)
                    Button("キャンセル") { dismiss() }
                }
            }
            .navigationTitle("バッチを登録")
            .alert("入力内容を確認してください", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("閉じる") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
