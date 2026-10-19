import SwiftUI
import RingonomiCore

/// Displays the server's live channels without starting any network work.
///
/// Loading and retrying belong to the parent store.  Keeping this view
/// catalog-only makes filter changes immediate and prevents a focus change or
/// a search edit from creating another server request.
struct LiveChannelLibraryView: View {
    let channels: [Channel]
    let loading: Bool
    let error: String?
    let configured: Bool
    @ObservedObject var favorites: LiveChannelFavoritesStore
    let onRefresh: () -> Void
    let onPlay: (Channel) -> Void

    @State private var broadcast: LiveChannelBroadcast = .all
    @State private var sort: LiveChannelSortOrder = .serverOrder
    @State private var favoritesOnly = false
    @State private var committedSearch = ""
    @State private var showingSearch = false
    @State private var confirmingReset = false
    @State private var focusRestoreID: String?
    @State private var restoreAfterRetry = false
    @FocusState private var focus: LiveChannelFocus?

    private enum LiveChannelFocus: Hashable {
        case search
        case broadcast
        case sort
        case favoritesOnly
        case refresh
        case retry
        case watch(String)
        case favorite(String)
    }

    private var query: LiveChannelQuery {
        LiveChannelQuery(
            search: committedSearch,
            broadcast: broadcast,
            favoritesOnly: favoritesOnly,
            sort: sort
        )
    }

    private var visibleChannels: [Channel] {
        LiveChannelCatalog.channels(
            channels,
            query: query,
            favoriteIDs: favorites.favoriteIDs
        )
    }

    private var hasActiveFilter: Bool {
        !committedSearch.isEmpty || broadcast != .all || favoritesOnly
    }

    private var hasStaleChannels: Bool { !channels.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            controls
            favoriteStatus
            serverStatus
            channelContent
        }
        .padding(.horizontal, 48)
        .navigationTitle("ライブチャンネル")
        .sheet(isPresented: $showingSearch, onDismiss: { focus = .search }) {
            LiveChannelSearchSheet(
                initialText: committedSearch,
                onCancel: { showingSearch = false },
                onClear: {
                    committedSearch = ""
                    showingSearch = false
                },
                onSearch: { value in
                    committedSearch = boundedSearch(value)
                    showingSearch = false
                }
            )
        }
        .alert("お気に入りをリセットしますか？", isPresented: $confirmingReset) {
            Button("リセット", role: .destructive) { favorites.reset() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このApple TVで保存した、すべての接続先のお気に入りを初期化します。")
        }
        .onAppear { restoreFocusIfNeeded() }
        .onChange(of: loading) { _, isLoading in
            if !isLoading {
                if restoreAfterRetry {
                    restoreAfterRetry = false
                    if focus == nil || focus == .retry {
                        if error != nil { focus = .retry }
                        else { focus = visibleChannels.first.map { .watch(stableID($0)) } ?? .search }
                    }
                }
                restoreFocusIfNeeded()
            }
        }
        .onChange(of: visibleChannels.map(stableID)) { _, ids in
            restoreFocusAfterRemoval(visibleIDs: ids)
            restoreFocusIfNeeded()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                Picker("放送波", selection: $broadcast) {
                    ForEach(LiveChannelBroadcast.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .focused($focus, equals: .broadcast)

                Picker("並び順", selection: $sort) {
                    ForEach(LiveChannelSortOrder.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .focused($focus, equals: .sort)

                Toggle("お気に入りのみ", isOn: $favoritesOnly)
                    .focused($focus, equals: .favoritesOnly)
                    .disabled(favorites.needsReset)

                Spacer(minLength: 16)

                Button("更新", action: onRefresh)
                    .focused($focus, equals: .refresh)
                    .disabled(loading || !configured)
            }

            HStack(spacing: 16) {
                Button {
                    showingSearch = true
                } label: {
                    Label(
                        committedSearch.isEmpty ? "番組・チャンネルを検索" : "検索: \(committedSearch)",
                        systemImage: "magnifyingglass"
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 640, alignment: .leading)
                }
                .focused($focus, equals: .search)
                .accessibilityLabel("番組・チャンネルを検索")
                .accessibilityValue(committedSearch)

                if !committedSearch.isEmpty {
                    Button("検索を解除") {
                        committedSearch = ""
                    }
                }

                if hasActiveFilter {
                    Text("\(visibleChannels.count)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 18)
        .focusSection()
    }

    @ViewBuilder
    private var favoriteStatus: some View {
        if let message = favoriteErrorMessage {
            HStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Spacer(minLength: 12)
                if favorites.needsReset {
                    Button("お気に入りをリセット") { confirmingReset = true }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private var favoriteErrorMessage: String? {
        if let error = favorites.error { return error }
        return favorites.needsReset ? "お気に入りデータを読み込めませんでした。リセットして再作成してください。" : nil
    }

    @ViewBuilder
    private var serverStatus: some View {
        if loading && hasStaleChannels {
            HStack(spacing: 12) {
                ProgressView()
                Text("チャンネル一覧を更新しています…")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        } else if let error, hasStaleChannels {
            HStack(spacing: 16) {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button("再試行", action: retry)
                    .focused($focus, equals: .retry)
                    .disabled(loading || !configured)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var channelContent: some View {
        if !configured {
            emptyState("設定で視聴サーバーに接続してください。")
        } else if loading && !hasStaleChannels {
            VStack(spacing: 18) {
                ProgressView()
                Text("チャンネル一覧を読み込んでいます…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusSection()
        } else if let error, !hasStaleChannels {
            VStack(spacing: 18) {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("再試行", action: retry)
                    .focused($focus, equals: .retry)
                    .disabled(loading || !configured)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusSection()
            .defaultFocus($focus, .retry, priority: .userInitiated)
        } else if visibleChannels.isEmpty {
            emptyState(emptyMessage)
        } else {
            channelRows
        }
    }

    private var channelRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(visibleChannels, id: \.displayChannelId) { channel in
                    channelRow(channel)
                }
            }
            .padding(.vertical, 8)
        }
        .focusSection()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { focus = .search }
    }

    private func channelRow(_ channel: Channel) -> some View {
        let id = stableID(channel)
        let isFavorite = favorites.favoriteIDs.contains(id)
        return HStack(spacing: 14) {
            Button {
                guard channel.isWatchable else { return }
                focusRestoreID = id
                onPlay(channel)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(channelTitle(channel))
                            .font(.headline)
                            .lineLimit(1)
                        if !channel.displayChannelId.isEmpty {
                            Text(channel.displayChannelId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if let program = channel.programPresent {
                        Text(program.title.isEmpty ? "番組情報なし" : program.title)
                            .lineLimit(1)
                        if !program.description.isEmpty {
                            Text(program.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } else {
                        Text("番組情報なし")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .watch(id))
            .disabled(!channel.isWatchable)
            .accessibilityLabel(channelTitle(channel))
            .accessibilityValue(channel.programPresent?.title ?? "番組情報なし")
            .accessibilityHint(channel.isWatchable ? "選択して視聴" : "視聴できません")

            Button {
                favorites.toggle(channelID: id)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .imageScale(.large)
                    .frame(minWidth: 48, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .favorite(id))
            .disabled(!favorites.canEdit || favorites.needsReset)
            .accessibilityLabel(isFavorite ? "お気に入りから外す" : "お気に入りに追加")
            .accessibilityValue(channelTitle(channel))
        }
    }

    private var emptyMessage: String {
        if favoritesOnly { return "お気に入りのチャンネルがありません。" }
        if !committedSearch.isEmpty { return "検索結果がありません。検索語を変えてください。" }
        if broadcast != .all { return "選択した放送波のチャンネルがありません。" }
        return "チャンネルがありません。更新して再試行してください。"
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusSection()
    }

    private func stableID(_ channel: Channel) -> String {
        channel.displayChannelId
    }

    private func channelTitle(_ channel: Channel) -> String {
        let name = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "チャンネル \(stableID(channel))" : name
    }

    private func boundedSearch(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
    }

    private func retry() {
        restoreAfterRetry = true
        onRefresh()
    }

    private func restoreFocusIfNeeded() {
        guard let id = focusRestoreID,
              !loading,
              visibleChannels.contains(where: { stableID($0) == id }) else { return }
        DispatchQueue.main.async {
            guard let id = focusRestoreID,
                  visibleChannels.contains(where: { stableID($0) == id }) else { return }
            focus = .watch(id)
            focusRestoreID = nil
        }
    }

    private func restoreFocusAfterRemoval(visibleIDs: [String]) {
        let channelID: String
        switch focus {
        case .watch(let id), .favorite(let id): channelID = id
        default: return
        }
        guard !visibleIDs.contains(channelID) else { return }
        focus = visibleIDs.first.map { .watch($0) } ?? .favoritesOnly
    }
}

private struct LiveChannelSearchSheet: View {
    let initialText: String
    let onCancel: () -> Void
    let onClear: () -> Void
    let onSearch: (String) -> Void

    @State private var text: String

    init(
        initialText: String,
        onCancel: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onSearch: @escaping (String) -> Void
    ) {
        self.initialText = initialText
        self.onCancel = onCancel
        self.onClear = onClear
        self.onSearch = onSearch
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("番組・チャンネルを検索")
                .font(.title2)
            TextField("検索語（最大256文字）", text: boundedText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack(spacing: 18) {
                Button("キャンセル", action: onCancel)
                Button("クリア", action: onClear)
                    .disabled(text.isEmpty && initialText.isEmpty)
                Button("検索") { onSearch(text) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(60)
        .frame(minWidth: 720, minHeight: 300)
    }

    private var boundedText: Binding<String> {
        Binding(
            get: { text },
            set: { text = String($0.prefix(256)) }
        )
    }
}
