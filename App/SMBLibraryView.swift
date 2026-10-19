import SwiftUI
import RingonomiCore

/// SMB share browser. Credentials are loaded only for the duration of a
/// directory request and are never included in navigation values or labels.
struct SMBLibraryView: View {
    let onOpen: (SMBConnection, SMBLibraryEntry) -> Void

    @StateObject private var library: SMBLibraryStore
    @State private var showingAdd = false
    @State private var editingConnection: SMBConnection?
    @State private var editingCredentials: SMBCredentials?
    @State private var pendingDelete: SMBConnection?
    @State private var message: String?
#if DEBUG
    @State private var runtimeConnection: SMBConnection?
    @State private var runtimeConnectionPrepared = false
#endif

    private let keychain = SMBCredentialsKeychain()

    private var pins: [DirectoryPin] { library.displayablePins }

    private var hasConnectionToShow: Bool {
        if !library.connections.isEmpty { return true }
#if DEBUG
        return runtimeConnection != nil
#else
        return false
#endif
    }

    init(onOpen: @escaping (SMBConnection, SMBLibraryEntry) -> Void = { _, _ in }) {
        self.onOpen = onOpen
        _library = StateObject(wrappedValue: SMBLibraryStore())
    }

    var body: some View {
        List {
#if DEBUG
            if let runtimeConnection {
                Section("デバッグ共有（未保存）") {
                    NavigationLink {
                        SMBFolderView(
                            connection: runtimeConnection,
                            path: .root,
                            library: library,
                            allowsPinning: false,
                            onOpen: onOpen
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("起動時SMB共有")
                                .font(.headline)
                            Text(connectionLocation(runtimeConnection))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
#endif
                if !library.connections.isEmpty {
                    Section("共有") {
                        ForEach(library.connections) { connection in
                            connectionRow(connection)
                        }
                    }
                }

                if !pins.isEmpty {
                    Section("ピン留め") {
                        ForEach(pins) { pin in
                            if let connection = library.connection(for: pin.connectionID) {
                                NavigationLink {
                                    SMBFolderView(
                                        connection: connection,
                                        path: pin.path,
                                        library: library,
                                        onOpen: onOpen
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(pin.title)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(connection.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    }
                }

                if !hasConnectionToShow {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "externaldrive.connected.to.line.below")
                                .font(.largeTitle)
                            Text("SMB共有が登録されていません")
                            Text("共有を追加すると、録画ファイルを参照できます。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                }
            }
            .navigationTitle("SMBライブラリ")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("共有を追加", systemImage: "plus")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let error = library.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                }
            }
            .sheet(isPresented: $showingAdd) {
                NavigationStack {
                    SMBConnectionForm { draft in
                        addConnection(draft)
                    }
                }
            }
            .sheet(item: $editingConnection, onDismiss: {
                editingCredentials = nil
            }) { connection in
                NavigationStack {
                    SMBEditCredentialsForm(
                        connection: connection,
                        initialCredentials: editingCredentials
                    ) { credentials in
                        updateCredentials(credentials, for: connection)
                    }
                }
            }
            .confirmationDialog(
                "共有を削除しますか？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    if let connection = pendingDelete {
                        deleteConnection(connection)
                    }
                    pendingDelete = nil
                }
                Button("キャンセル", role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                Text(pendingDelete?.displayName ?? "登録済みの共有")
            }
            .alert(
                "SMB操作",
                isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { message = nil } }
                )
            ) {
                Button("閉じる", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "SMB操作に失敗しました。")
            }
#if DEBUG
            .onAppear { prepareRuntimeConnection() }
#endif
    }

#if DEBUG
    private func prepareRuntimeConnection() {
        guard !runtimeConnectionPrepared else { return }
        runtimeConnectionPrepared = true
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--smb-url"),
              index + 1 < arguments.count else { return }
        let rawAddress = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawAddress.isEmpty, !rawAddress.hasPrefix("--") else {
            message = "--smb-url の共有URLを確認してください。"
            return
        }
        do {
            runtimeConnection = try SMBConnection(
                address: rawAddress,
                displayName: "起動時SMB共有"
            )
        } catch {
            message = "--smb-url の共有URLを確認してください。"
        }
    }
#endif

    @ViewBuilder
    private func connectionRow(_ connection: SMBConnection) -> some View {
        HStack(spacing: 16) {
            NavigationLink {
                SMBFolderView(
                    connection: connection,
                    path: .root,
                    library: library,
                    onOpen: onOpen
                )
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(connectionLocation(connection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Menu {
                Button("認証情報を変更") {
                    beginCredentialEdit(connection)
                }
                Button("共有を削除", role: .destructive) {
                    pendingDelete = connection
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .accessibilityLabel("共有の操作")
            }
        }
    }

    private func connectionLocation(_ connection: SMBConnection) -> String {
        let port = connection.port == 445 ? "" : ":\(connection.port)"
        let base = connection.baseDirectory.description
        let host = connection.server.contains(":")
            ? "[\(connection.server)]"
            : connection.server
        return "smb://\(host)\(port)/\(connection.share)"
            + (base.isEmpty ? "" : "/\(base)")
    }

    private func addConnection(_ draft: SMBConnectionDraft) -> String? {
        do {
            let address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { throw SMBError.invalidConnection }
            let connection = try SMBConnection(
                address: address,
                displayName: draft.displayName.nilIfBlank
            )
            let credentials = draft.credentials
            try keychain.save(credentials, for: connection)
            do {
                _ = try library.addConnection(connection)
            } catch {
                // The connection was never committed. Remove the just-created
                // credential item so a failed save cannot leave an orphan.
                _ = try? keychain.remove(for: connection)
                throw error
            }
            showingAdd = false
            return nil
        } catch let error as SMBLibraryStoreError {
            let text = error.errorDescription ?? "SMB設定を保存できませんでした。"
            return text
        } catch let error as SMBError {
            let text = error.errorDescription ?? "SMB接続情報が不正です。"
            return text
        } catch {
            let text = "SMB設定を保存できませんでした。"
            return text
        }
    }

    private func beginCredentialEdit(_ connection: SMBConnection) {
        do {
            editingCredentials = try keychain.load(for: connection)
            editingConnection = connection
        } catch {
            message = "SMBの認証情報を読み込めませんでした。"
        }
    }

    private func updateCredentials(_ credentials: SMBCredentials?, for connection: SMBConnection) -> String? {
        do {
            try keychain.save(credentials, for: connection)
            editingConnection = nil
            editingCredentials = nil
            return nil
        } catch {
            let text = credentials == nil
                ? "SMBの認証情報を削除できませんでした。"
                : "SMBの認証情報を保存できませんでした。"
            return text
        }
    }

    private func deleteConnection(_ connection: SMBConnection) {
        do {
            // Remove credentials first. If this fails, leave the saved share
            // intact so the user can retry without losing its location.
            try keychain.remove(for: connection)
            try library.deleteConnection(id: connection.id)
        } catch let error as SMBLibraryStoreError {
            message = error.errorDescription ?? "SMB共有を削除できませんでした。"
        } catch {
            message = "SMB共有または認証情報を削除できませんでした。"
        }
    }
}

private struct SMBConnectionDraft {
    var address: String
    var displayName: String
    var guest: Bool
    var username: String
    var password: String

    var credentials: SMBCredentials? {
        guard !guest else { return nil }
        return SMBCredentials(username: username, password: password)
    }
}

private struct SMBConnectionForm: View {
    let onSave: (SMBConnectionDraft) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var displayName = ""
    @State private var guest = true
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?

    private var canSave: Bool {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if guest { return true }
        return !username.isEmpty
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("保存") { save() }
                    .disabled(!canSave)
            }
            .padding(.horizontal, 36)

            Form {
                Section("共有") {
                    TextField("smb://ホスト/共有", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("表示名（任意）", text: $displayName)
                        .lineLimit(1)
                }
                Section("認証") {
                    Toggle("ゲストとして接続", isOn: $guest)
                    if !guest {
                        TextField("ユーザー名", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("パスワード", text: $password)
                    }
                }
                Text("認証情報は端末のKeychainに保存し、共有URLには含めません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle("共有を追加")
        .onExitCommand { dismiss() }
        .onDisappear { password = "" }
    }

    private func save() {
        guard canSave else {
            message = "共有URLと認証情報を確認してください。"
            return
        }
        let result = onSave(SMBConnectionDraft(
            address: address,
            displayName: displayName,
            guest: guest,
            username: username,
            password: password
        ))
        if let result {
            message = result
        } else {
            password = ""
            dismiss()
        }
    }
}

private struct SMBEditCredentialsForm: View {
    let connection: SMBConnection
    let initialCredentials: SMBCredentials?
    let onSave: (SMBCredentials?) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var guest: Bool
    @State private var username: String
    @State private var password = ""
    @State private var message: String?

    init(
        connection: SMBConnection,
        initialCredentials: SMBCredentials?,
        onSave: @escaping (SMBCredentials?) -> String?
    ) {
        self.connection = connection
        self.initialCredentials = initialCredentials
        self.onSave = onSave
        _guest = State(initialValue: initialCredentials == nil)
        _username = State(initialValue: initialCredentials?.username ?? "")
    }

    private var canSave: Bool {
        guest || !username.isEmpty
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("保存") { save() }
                    .disabled(!canSave)
            }
            .padding(.horizontal, 36)

            Form {
                Section("共有") {
                    Text(connection.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Section("認証") {
                    Toggle("ゲストとして接続", isOn: $guest)
                    if !guest {
                        TextField("ユーザー名", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("新しいパスワード", text: $password)
                        Text("保存済みパスワードは表示しません。空欄で保存すると空のパスワードに変更します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle("認証情報を変更")
        .onExitCommand { dismiss() }
        .onDisappear { password = "" }
    }

    private func save() {
        guard canSave else {
            message = "ユーザー名を入力してください。"
            return
        }
        let credentials = guest ? nil : SMBCredentials(username: username, password: password)
        if let result = onSave(credentials) {
            message = result
        } else {
            password = ""
            dismiss()
        }
    }
}

/// A folder browser for one saved connection. Folder changes stay in this
/// screen so the tvOS back action returns to the library without growing a
/// navigation stack for every directory.
struct SMBFolderView: View {
    let connection: SMBConnection
    @ObservedObject var library: SMBLibraryStore
    let allowsPinning: Bool
    let onOpen: (SMBConnection, SMBLibraryEntry) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var directory: SMBDirectoryStore
    @State private var currentPath: SMBRelativePath
    @State private var query = ""
    @State private var showingSearch = false
    @State private var message: String?
    @State private var needsReload = true

    private let keychain = SMBCredentialsKeychain()

    init(
        connection: SMBConnection,
        path: SMBRelativePath,
        library: SMBLibraryStore,
        allowsPinning: Bool = true,
        onOpen: @escaping (SMBConnection, SMBLibraryEntry) -> Void = { _, _ in }
    ) {
        self.connection = connection
        self.library = library
        self.allowsPinning = allowsPinning
        self.onOpen = onOpen
        _directory = StateObject(wrappedValue: SMBDirectoryStore())
        _currentPath = State(initialValue: path)
    }

    private var title: String {
        currentPath.components.last ?? connection.share
    }

    private var visibleEntries: [SMBLibraryEntry] {
        SMBLibraryEntry.search(query, in: directory.entries)
    }

    private var pin: DirectoryPin? {
        library.pins(for: connection.id).first { $0.path == currentPath }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !query.isEmpty {
                Text("このフォルダー内を検索")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if directory.loading {
                loadingView
            } else if directory.cancelled {
                cancelledView
            } else if let error = directory.error {
                errorView(error)
            } else if directory.entries.isEmpty {
                emptyView
            } else if visibleEntries.isEmpty {
                Text("検索結果がありません。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                entriesList
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSearch = true
                } label: {
                    Label("検索", systemImage: "magnifyingglass")
                }
                .disabled(directory.loading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    togglePin()
                } label: {
                    Label(
                        pin == nil ? "ピン留め" : "ピン留めを外す",
                        systemImage: pin == nil ? "pin" : "pin.slash"
                    )
                }
                .disabled(directory.loading || !allowsPinning)
            }
            ToolbarItem(placement: .automatic) {
                Button("更新") { reload() }
                    .disabled(directory.loading)
            }
        }
        .sheet(isPresented: $showingSearch) {
            SMBFolderSearchForm(initialQuery: query) { value in
                query = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .overlay(alignment: .bottom) {
            if let warning = directory.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .alert(
            "SMB操作",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("閉じる", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "SMB操作に失敗しました。")
        }
        .onAppear {
            if needsReload { reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if needsReload { reload() }
            case .inactive, .background:
                needsReload = true
                directory.cancel()
            @unknown default:
                needsReload = true
                directory.cancel()
            }
        }
        .onDisappear {
            needsReload = true
            directory.cancel()
        }
    }

    private var entriesList: some View {
        List {
            if let parent = currentPath.parent() {
                Section {
                    Button {
                        navigate(to: parent)
                    } label: {
                        Label("親フォルダーへ戻る", systemImage: "arrow.up.left")
                    }
                }
            }

            Section {
                ForEach(visibleEntries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: SMBLibraryEntry) -> some View {
        HStack(spacing: 14) {
            if entry.isDirectory {
                Button {
                    navigate(to: entry.path)
                } label: {
                    entryLabel(entry)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    onOpen(connection, entry)
                } label: {
                    entryLabel(entry)
                }
                .buttonStyle(.plain)
            }

            if entry.isDirectory && allowsPinning {
                Spacer(minLength: 12)
                Button {
                    togglePin(entry: entry)
                } label: {
                    Image(systemName: isPinned(entry) ? "pin.fill" : "pin")
                        .accessibilityLabel(isPinned(entry) ? "ピン留めを外す" : "ピン留め")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func entryLabel(_ entry: SMBLibraryEntry) -> some View {
        Label {
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: entry.isDirectory ? "folder" : "film")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView("フォルダーを読み込んでいます…")
            Button("キャンセル") { directory.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 18) {
            Text(safeDirectoryError(error))
                .multilineTextAlignment(.center)
                .foregroundStyle(.red)
                .lineLimit(3)
            Button("再試行") { reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }

    private func safeDirectoryError(_ error: String) -> String {
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 512,
              !trimmed.unicodeScalars.contains(where: {
                  $0.value < 0x20 && $0.value != 0x09
              }) else {
            return "フォルダーを読み込めませんでした。接続先と認証情報を確認してください。"
        }
        return trimmed
    }

    private var cancelledView: some View {
        VStack(spacing: 18) {
            Text("読み込みをキャンセルしました。")
                .foregroundStyle(.secondary)
            Button("再読み込み") { reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.largeTitle)
            Text("このフォルダーは空です。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isPinned(_ entry: SMBLibraryEntry) -> Bool {
        library.pins(for: connection.id).contains { $0.path == entry.path }
    }

    private func togglePin(entry: SMBLibraryEntry? = nil) {
        guard allowsPinning else { return }
        let targetPath = entry?.path ?? currentPath
        if library.pins(for: connection.id).contains(where: { $0.path == targetPath }) {
            do {
                try library.unpin(connectionID: connection.id, path: targetPath)
            } catch {
                message = "ピン留めを変更できませんでした。"
            }
            return
        }

        let title = entry?.name ?? self.title
        do {
            _ = try library.pin(connectionID: connection.id, path: targetPath, title: title)
        } catch {
            message = "ピン留めを保存できませんでした。"
        }
    }

    private func reload() {
        guard scenePhase != .inactive, scenePhase != .background else { return }
        needsReload = false
        directory.cancel(clear: true)
        do {
            let loaded = try keychain.load(for: connection)
            directory.load(connection: connection, path: currentPath, credentials: loaded)
        } catch {
            directory.reportCredentialFailure()
        }
    }

    private func navigate(to newPath: SMBRelativePath) {
        guard newPath != currentPath else { return }
        currentPath = newPath
        query = ""
        reload()
    }
}

private struct SMBFolderSearchForm: View {
    let initialQuery: String
    let onSearch: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(initialQuery: String, onSearch: @escaping (String) -> Void) {
        self.initialQuery = initialQuery
        self.onSearch = onSearch
        _draft = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("このフォルダー内を検索")
                .font(.title2)
                .bold()

            TextField("ファイル名・フォルダー名", text: $draft)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 20) {
                Button("検索") {
                    onSearch(draft)
                    dismiss()
                }
                Button("解除") {
                    onSearch("")
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {
                    dismiss()
                }
            }
        }
        .padding(40)
        .frame(maxWidth: 720)
        .onExitCommand {
            dismiss()
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
