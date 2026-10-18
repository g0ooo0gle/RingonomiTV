import SwiftUI
import RingonomiCore

private struct RecordingDetailSelection: Identifiable {
    let id = UUID()
    let recording: Recording
    let client: RingonomiClient
}

private enum RecordingLibraryMode: String, CaseIterable {
    case all, channel, genre, weekday, series

    var title: String {
        switch self {
        case .all: return "全件"
        case .channel: return "チャンネル別"
        case .genre: return "ジャンル別"
        case .weekday: return "曜日別"
        case .series: return "シリーズ別"
        }
    }

    var grouping: RecordingGrouping? {
        switch self {
        case .all: return nil
        case .channel: return .channel
        case .genre: return .genre
        case .weekday: return .weekday
        case .series: return .series
        }
    }
}

struct RecordingLibraryView: View {
    let address: String
    @ObservedObject var resumeStore: RecordingResumeStore
    let onPlay: (Recording, RingonomiClient) -> Void
    @StateObject private var store = RecordingLibraryStore()
    @StateObject private var catalog = RecordingCatalogStore()
    @State private var mode = RecordingLibraryMode.all
    @State private var groupID: String?
    @State private var draft = ""
    @State private var keyword = ""
    @State private var page = 1
    @State private var order = RecordingSortOrder.newest
    @State private var revision = 0
    @State private var selected: RecordingDetailSelection?
    @State private var pendingPlayback: RecordingDetailSelection?
    @State private var detailReturnID: Int?
    @FocusState private var focus: LibraryFocus?
    private let allGroupsID = "all-groups"

    private enum LibraryFocus: Hashable {
        case search, mode, retry, cancel, group(String), play(Int), detail(Int)
    }
    private var request: RecordingLibraryRequest {
        RecordingLibraryRequest(address: address, query: RecordingQuery(keyword: keyword, page: page, order: order), revision: revision)
    }
    private var pagedRequest: RecordingLibraryRequest? { mode == .all ? request : nil }
    private var catalogRequest: RecordingCatalogRequest? {
        guard mode.grouping != nil else { return nil }
        return RecordingCatalogRequest(address: address, keyword: keyword, revision: revision)
    }
    private var isCurrent: Bool {
        if mode.grouping != nil {
            return catalog.index != nil && catalog.loadedRequest == catalogRequest
        }
        return store.loadedRequest == request
    }
    private var loading: Bool { mode == .all ? store.loading : catalog.loading }
    private var failureMessage: String? { mode == .all ? store.error : catalog.error }
    private var busy: Bool { loading || (!isCurrent && failureMessage == nil && !address.isEmpty) }
    private var groups: [RecordingGroup] {
        guard isCurrent, let grouping = mode.grouping else { return [] }
        return catalog.index?.groups(for: grouping) ?? []
    }
    private var groupedRecordings: [Recording] {
        guard isCurrent, let grouping = mode.grouping, let index = catalog.index else { return [] }
        let matches = index.recordings(for: grouping, groupID: groupID)
        return order == .newest ? matches : Array(matches.reversed())
    }
    private var total: Int { mode == .all ? store.total : groupedRecordings.count }
    private var pageCount: Int { total > 0 ? (total - 1) / RecordingQuery.pageSize + 1 : 1 }
    private var displayedRecordings: [Recording] {
        guard mode != .all else { return store.items }
        guard page > 0, page <= pageCount else { return [] }
        let matches = groupedRecordings
        let start = (page - 1) * RecordingQuery.pageSize
        guard start < matches.count else { return [] }
        return Array(matches[start..<min(matches.count, start + RecordingQuery.pageSize)])
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                searchControls
                pagingControls
                libraryResults
            }.padding(.horizontal, 40).navigationTitle("録画ライブラリ")
            .task(id: pagedRequest) {
                if let request = pagedRequest { await store.load(request) }
            }
            .task(id: catalogRequest) {
                if let request = catalogRequest { await catalog.load(request) }
            }
            .onChange(of: loading) { _, loading in
                if loading, mode != .all { focus = .cancel }
                else if !loading { finishLoading() }
            }
            .onChange(of: mode) { _, _ in
                groupID = nil
                page = 1
                if mode != .all, isCurrent { focus = .group(allGroupsID) }
            }
            .onChange(of: order) { _, _ in page = 1 }
            .onChange(of: address) { _, _ in
                mode = .all
                groupID = nil
                page = 1
            }
            .sheet(item: $selected, onDismiss: {
                if let item = pendingPlayback {
                    pendingPlayback = nil
                    onPlay(item.recording, item.client)
                } else if let id = detailReturnID { focus = .detail(id) }
            }) { item in
                RecordingDetailView(recording: item.recording, client: item.client) { recording in
                    pendingPlayback = RecordingDetailSelection(recording: recording, client: item.client)
                    selected = nil
                }
            }
        }
    }

    private var searchControls: some View {
        HStack(spacing: 20) {
            Picker("表示", selection: $mode) {
                ForEach(RecordingLibraryMode.allCases, id: \.self) { value in
                    Text(value.title).lineLimit(1).tag(value)
                }
            }.pickerStyle(.menu).frame(width: 320).focused($focus, equals: .mode)
            TextField("番組名・シリーズ名・サブタイトルを検索", text: $draft)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .search).onSubmit { search() }
            Button("検索") { search() }
            Button("クリア") { draft = ""; search() }.disabled(draft.isEmpty && keyword.isEmpty)
        }
    }

    private var pagingControls: some View {
        HStack(spacing: 24) {
            Picker("並び順", selection: $order) {
                Text("新しい順").tag(RecordingSortOrder.newest)
                Text("古い順").tag(RecordingSortOrder.oldest)
            }.pickerStyle(.menu)
            Button("前のページ") { page -= 1 }.disabled(busy || page <= 1)
            Text(busy ? "読み込み中…" : "\(page) / \(pageCount) ページ").monospacedDigit()
            Button("次のページ") { page += 1 }.disabled(busy || !isCurrent || page >= pageCount)
            if isCurrent { Text("全\(total)件").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("更新") { revision &+= 1 }.disabled(busy)
        }
    }

    private var libraryResults: some View {
        HStack(spacing: 20) {
            if mode != .all, isCurrent { groupRows.id(mode).frame(width: 360) }
            recordingRows
        }
        .overlay {
            if busy, mode != .all {
                VStack(spacing: 24) {
                    ProgressView("分類用の録画一覧を取得しています…")
                    Text("\(catalog.loadedCount) / \(catalog.total) 件").monospacedDigit()
                    Button("分類を中止") { mode = .all }.focused($focus, equals: .cancel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
                .defaultFocus($focus, .cancel, priority: .userInitiated)
            } else if busy {
                ProgressView("録画一覧を読み込んでいます…")
            } else if let error = failureMessage {
                VStack(spacing: 24) {
                    Text(error).multilineTextAlignment(.center)
                    Button("再試行") { revision &+= 1 }.focused($focus, equals: .retry)
                    if mode != .all { Button("全件へ戻る") { mode = .all } }
                }.padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()
                    .defaultFocus($focus, .retry, priority: .userInitiated)
            } else if displayedRecordings.isEmpty {
                Text(address.isEmpty ? "設定で視聴サーバーに接続してください。" : "該当する録画はありません。検索語や分類を変えてください。")
                    .foregroundStyle(.secondary).padding(40)
            }
        }
    }

    private var recordingRows: some View {
        List {
            ForEach(displayedRecordings) { recording in
                HStack(spacing: 24) {
                    Button { play(recording) } label: {
                        RecordingSummary(recording: recording, position: position(recording))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered).focused($focus, equals: .play(recording.id))
                    Button("詳細") { showDetail(recording) }
                        .buttonStyle(.bordered).focused($focus, equals: .detail(recording.id))
                }.disabled(!isCurrent || busy)
            }
        }
        .onExitCommand { focus = mode == .all ? .search : .group(groupID ?? allGroupsID) }
    }

    private var groupRows: some View {
        List {
            Button {
                selectGroup(nil)
            } label: {
                groupLabel(title: "すべて", count: catalog.total, selected: groupID == nil)
            }.focused($focus, equals: .group(allGroupsID))
            ForEach(groups) { group in
                Button { selectGroup(group.id) } label: {
                    groupLabel(title: group.title, count: group.count, selected: groupID == group.id)
                }.focused($focus, equals: .group(group.id))
            }
        }.onExitCommand { focus = .mode }
    }

    private func groupLabel(title: String, count: Int, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if selected { Image(systemName: "checkmark") }
            Text(title).lineLimit(2).multilineTextAlignment(.leading)
            Spacer()
            Text("\(count)").font(.caption).monospacedDigit()
        }
    }

    private func finishLoading() {
        guard !loading else { return }
        if failureMessage != nil { focus = .retry; return }
        guard isCurrent else { return }
        if mode != .all, let groupID, !groups.contains(where: { $0.id == groupID }) {
            self.groupID = nil
            page = 1
        }
        if page > pageCount { page = pageCount }
        if mode != .all { focus = .group(groupID ?? allGroupsID) }
        else if let first = displayedRecordings.first { focus = .play(first.id) }
    }

    private func selectGroup(_ id: String?) {
        groupID = id
        page = 1
        if let first = displayedRecordings.first { focus = .play(first.id) }
    }

    private func search() {
        keyword = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        groupID = nil
        page = 1
        revision &+= 1
    }
    private func client() -> RingonomiClient? {
        guard isCurrent, !busy else { return nil }
        return try? RingonomiClient(address: request.address)
    }
    private func play(_ recording: Recording) {
        guard let client = client() else { return }
        onPlay(recording, client)
    }
    private func showDetail(_ recording: Recording) {
        guard let client = client() else { return }
        detailReturnID = recording.id
        pendingPlayback = nil
        selected = RecordingDetailSelection(recording: recording, client: client)
    }
    private func position(_ recording: Recording) -> Double? {
        guard let client = try? RingonomiClient(address: address) else { return nil }
        return resumeStore.position(for: recording, client: client)
    }
}

private struct RecordingSummary: View {
    let recording: Recording
    let position: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(recording.title).font(.headline).lineLimit(2)
            Text(recordingDate(recording.startTime) + " · " + (recording.channel?.name ?? "チャンネル情報なし") + " · " + Playback.timestamp(recording.recordedVideo.duration))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                if recording.recordedVideo.status == "Recording" { Text("録画中") }
                if recording.isPartiallyRecorded == true { Text("一部のみ録画されています").foregroundStyle(.orange) }
                if let position { Text("続き：\(Playback.timestamp(position))") }
            }.font(.caption)
            if !recording.description.isEmpty { Text(recording.description).font(.caption).lineLimit(2) }
        }.padding(.vertical, 8).multilineTextAlignment(.leading)
    }
}

@MainActor
func recordingDate(_ value: String?) -> String {
    guard let value else { return "日時情報なし" }
    let date = RecordingTimeFormat.fractional.date(from: value) ?? RecordingTimeFormat.standard.date(from: value)
    guard let date else { return "日時情報なし" }
    return RecordingTimeFormat.display.string(from: date)
}

@MainActor
private enum RecordingTimeFormat {
    static let standard = ISO8601DateFormatter()
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy/M/d(E) HH:mm"
        return formatter
    }()
}
