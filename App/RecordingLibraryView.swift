import SwiftUI
import RingonomiCore

private struct RecordingDetailSelection: Identifiable {
    let id = UUID()
    let recording: Recording
    let client: RingonomiClient
}

struct RecordingLibraryView: View {
    let address: String
    @ObservedObject var resumeStore: RecordingResumeStore
    let onPlay: (Recording, RingonomiClient) -> Void
    @StateObject private var store = RecordingLibraryStore()
    @State private var draft = ""
    @State private var keyword = ""
    @State private var page = 1
    @State private var order = RecordingSortOrder.newest
    @State private var revision = 0
    @State private var selected: RecordingDetailSelection?
    @State private var pendingPlayback: RecordingDetailSelection?
    @State private var detailReturnID: Int?
    @FocusState private var focus: LibraryFocus?

    private enum LibraryFocus: Hashable {
        case search, retry, play(Int), detail(Int)
    }
    private var request: RecordingLibraryRequest {
        RecordingLibraryRequest(address: address, query: RecordingQuery(keyword: keyword, page: page, order: order), revision: revision)
    }
    private var isCurrent: Bool { store.loadedRequest == request }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack(spacing: 20) {
                    TextField("番組名・シリーズ名・サブタイトルを検索", text: $draft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .search).onSubmit { search() }
                    Button("検索") { search() }
                    Button("クリア") { draft = ""; search() }.disabled(draft.isEmpty && keyword.isEmpty)
                }
                HStack(spacing: 24) {
                    Picker("並び順", selection: Binding(get: { order }, set: { order = $0; page = 1 })) {
                        Text("新しい順").tag(RecordingSortOrder.newest)
                        Text("古い順").tag(RecordingSortOrder.oldest)
                    }.pickerStyle(.menu)
                    Button("前のページ") { page -= 1 }.disabled(store.loading || page <= 1)
                    Text(store.loading ? "読み込み中…" : "\(page) / \(store.pageCount) ページ").monospacedDigit()
                    Button("次のページ") { page += 1 }.disabled(store.loading || !isCurrent || page >= store.pageCount)
                    if isCurrent { Text("全\(store.total)件").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("更新") { revision &+= 1 }.disabled(store.loading)
                }
                List {
                    ForEach(store.items) { recording in
                        HStack(spacing: 24) {
                            Button { play(recording) } label: {
                                RecordingSummary(recording: recording, position: position(recording))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.bordered).focused($focus, equals: .play(recording.id))
                            Button("詳細") { showDetail(recording) }
                                .buttonStyle(.bordered).focused($focus, equals: .detail(recording.id))
                        }.disabled(!isCurrent || store.loading)
                    }
                }
                .onExitCommand { focus = .search }
                .overlay {
                    if store.loading { ProgressView("録画一覧を読み込んでいます…") }
                    else if let error = store.error {
                        VStack(spacing: 24) {
                            Text(error).multilineTextAlignment(.center)
                            Button("再試行") { revision &+= 1 }.focused($focus, equals: .retry)
                        }.padding(40)
                    } else if store.items.isEmpty {
                        Text(address.isEmpty ? "設定で視聴サーバーに接続してください。" : keyword.isEmpty ? "録画はありません。" : "該当する録画はありません。検索語を変えてください。")
                            .foregroundStyle(.secondary).padding(40)
                    }
                }
            }.padding(.horizontal, 40).navigationTitle("録画ライブラリ")
            .task(id: request) { await store.load(request) }
            .onChange(of: store.loading) { _, loading in
                guard !loading else { return }
                if store.error != nil { focus = .retry }
                else if isCurrent {
                    if page > store.pageCount { page = store.pageCount }
                    else if let first = store.items.first { focus = .play(first.id) }
                }
            }
            .onChange(of: address) { _, _ in page = 1 }
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

    private func search() {
        keyword = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        page = 1
        revision &+= 1
    }
    private func client() -> RingonomiClient? {
        guard isCurrent, !store.loading else { return nil }
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
        }.padding(.vertical, 8)
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
