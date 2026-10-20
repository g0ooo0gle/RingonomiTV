import SwiftUI
import RingonomiCore

@MainActor
final class EPGStationLibraryStore: ObservableObject {
    @Published private(set) var records: [EPGStationRecording] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var cancelled = false
    @Published private(set) var error: String?
    private var request: Task<Void, Never>?
    private var generation = UUID()

    func load(address: String, offset: Int, keyword: String, oldestFirst: Bool) {
        request?.cancel()
        let expected = UUID()
        generation = expected
        records = []
        total = 0
        error = nil
        cancelled = false
        loading = true
        request = Task { @MainActor [weak self] in
            do {
                let client = try EPGStationClient(address: address)
                let page = try await client.recordings(
                    offset: offset, limit: 30, keyword: keyword, isReverse: oldestFirst
                )
                try Task.checkCancellation()
                guard let self, generation == expected else { return }
                records = page.records
                total = page.total
                loading = false
#if DEBUG
                print("RingonomiEPGStationList: count=\(records.count) total=\(total) offset=\(offset)")
#endif
            } catch is CancellationError {
                guard let self, generation == expected else { return }
                loading = false
            } catch {
                guard let self, generation == expected else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    func cancel(clear: Bool = false) {
        let wasLoading = loading
        generation = UUID()
        request?.cancel()
        request = nil
        loading = false
        if clear {
            records = []
            total = 0
            error = nil
            cancelled = false
        } else if wasLoading { cancelled = true }
    }
}

struct EPGStationLibraryView: View {
    @AppStorage("epgstationAddress") private var address = ""
    @State private var draftAddress = ""
    @State private var preparedDraft = false
    @State private var searchDraft = ""
    @State private var keyword = ""
    @State private var oldestFirst = false
    @State private var offset = 0
    @State private var inputError: String?
    @State private var selectedID: Int?
    @State private var detailAddress = ""
    @State private var showingDetail = false
    @StateObject private var store = EPGStationLibraryStore()
    @StateObject private var resumeStore = RecordingResumeStore()
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
        return runtimeAddress ?? address
#else
        return address
#endif
    }

    var body: some View {
        List {
            AppSection("EPGStation接続") {
                TextField("EPGStation URL（例：http://ホスト:8888）", text: $draftAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("接続して録画を読み込む", action: connect)
                    .disabled(store.loading)
                if let inputError { Text(inputError).foregroundStyle(.red) }
            }
            if !effectiveAddress.isEmpty {
                AppSection("録画を探す") {
                    TextField("番組名などで検索", text: $searchDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 24) {
                        Button("検索") {
                            keyword = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            offset = 0
                            reload()
                        }
                        Button("検索を解除") {
                            searchDraft = ""
                            keyword = ""
                            offset = 0
                            reload()
                        }
                        .disabled(keyword.isEmpty && searchDraft.isEmpty)
                    }
                    .disabled(store.loading)
                    Toggle("古い順に表示", isOn: $oldestFirst)
                        .disabled(store.loading)
                        .onChange(of: oldestFirst) { _, _ in offset = 0; reload() }
                }
                AppSection("録画") {
                    if store.loading {
                        ProgressView("録画を読み込んでいます…")
                        Button("読み込みを中止") { store.cancel() }
                    } else if let error = store.error {
                        Text(error).foregroundStyle(.red)
                        Button("再試行", action: reload)
                    } else if store.cancelled {
                        Text("読み込みを中止しました。")
                        Button("再試行", action: reload)
                    } else if store.records.isEmpty {
                        Text(keyword.isEmpty ? "録画がありません。" : "一致する録画がありません。")
                        Button("再読み込み", action: reload)
                    } else {
                        ForEach(store.records) { recording in
                            Button {
                                detailAddress = effectiveAddress
                                selectedID = recording.id
                                showingDetail = true
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(recording.name).font(.headline)
                                    Text(epgStationDate(recording.startAt))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if recording.isRecording { Text("録画中").font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                }
                if !store.loading, store.error == nil, store.total > 0 {
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
            } else {
                Text("接続先を入力すると、EPGStationの録画を表示できます。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("EPGStation録画")
        .navigationDestination(isPresented: $showingDetail) {
            if let selectedID {
                EPGStationRecordingDetailView(
                    address: detailAddress, recordingID: selectedID, resumeStore: resumeStore
                )
            }
        }
        .onAppear {
            if !preparedDraft { draftAddress = effectiveAddress; preparedDraft = true }
            if !effectiveAddress.isEmpty, store.records.isEmpty, !store.loading, store.error == nil { reload() }
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if !handledDebugSelection,
               let index = arguments.firstIndex(of: "--play-epgstation-recording"),
               index + 1 < arguments.count, let id = Int(arguments[index + 1]), id > 0 {
                handledDebugSelection = true
                detailAddress = effectiveAddress
                selectedID = id
                showingDetail = true
            }
#endif
        }
        .onChange(of: effectiveAddress) { _, next in
            showingDetail = false
            selectedID = nil
            detailAddress = ""
            draftAddress = next
            inputError = nil
            offset = 0
            store.cancel(clear: true)
            if !next.isEmpty { reload() }
        }
        .onDisappear { store.cancel() }
    }

    private func connect() {
        let next = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try EPGStationClient(address: next)
            inputError = nil
#if DEBUG
            if runtimeAddress != nil {
                offset = 0
                reload()
                return
            }
#endif
            offset = 0
            if address == next { reload() } else { address = next }
        } catch { inputError = error.localizedDescription }
    }

    private func reload() {
        store.load(address: effectiveAddress, offset: offset, keyword: keyword, oldestFirst: oldestFirst)
    }
}

private struct EPGStationPendingFile {
    let url: URL
    let title: String
    let duration: Double?
    let resumeID: RecordingResumeID
    let status: String
    let savedPosition: Double?
}

private struct EPGStationPlaybackSession: Identifiable {
    let item: FilePlaybackSelection
    let resumeID: RecordingResumeID
    let status: String
    var id: UUID { item.id }
}

private struct EPGStationRecordingDetailView: View {
    let address: String
    let recordingID: Int
    @ObservedObject var resumeStore: RecordingResumeStore
    @Environment(\.dismiss) private var dismiss
    @State private var recording: EPGStationRecording?
    @State private var loading = false
    @State private var error: String?
    @State private var fileError: String?
    @State private var preparingFile = false
    @State private var generation = UUID()
    @State private var detailTask: Task<Void, Never>?
    @State private var fileTask: Task<Void, Never>?
    @State private var pendingFile: EPGStationPendingFile?
    @State private var resumePrompt = false
    @State private var playback: EPGStationPlaybackSession?
    @StateObject private var playbackIdleTimer = PlaybackIdleTimer()
#if DEBUG
    @State private var handledDebugFile = false
#endif

    var body: some View {
        List {
            if loading {
                ProgressView("録画の詳細を読み込んでいます…")
                Button("戻る") { dismiss() }
            } else if let error {
                Text(error).foregroundStyle(.red)
                Button("再試行") { detailTask = Task { await load() } }
                Button("戻る") { dismiss() }
            } else if let recording {
                Section {
                    Text(recording.name).font(.title2)
                    Text(epgStationDate(recording.startAt))
                    if recording.isRecording { Text("録画中").foregroundStyle(.orange) }
                    if recording.isEncoding { Text("エンコード中").foregroundStyle(.secondary) }
                    if let description = recording.description, !description.isEmpty { Text(description) }
                    if let extended = recording.extended, !extended.isEmpty { Text(extended).font(.caption) }
                }
                AppSection("再生するファイル") {
                    if recording.videoFiles.isEmpty {
                        Text("再生できるファイルがありません。")
                        Button("詳細を更新") { detailTask = Task { await load() } }
                    } else {
                        ForEach(recording.videoFiles) { file in
                            Button { prepare(file, recording: recording) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(file.name.isEmpty ? "動画ファイル" : file.name)
                                    Text(file.type == "ts" ? "元のTSファイル" :
                                            (file.type == "encoded" ? "エンコード済みファイル" : "動画ファイル"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(preparingFile)
                        }
                    }
                    if preparingFile {
                        ProgressView("再生を準備しています…")
                        Button("準備を中止") { cancelFilePreparation() }
                    }
                    if let fileError { Text(fileError).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("録画の詳細")
        .task(id: address + ":" + String(recordingID)) { await load() }
        .onDisappear {
            detailTask?.cancel()
            cancelFilePreparation()
        }
        .confirmationDialog("続きから再生しますか？", isPresented: $resumePrompt, titleVisibility: .visible) {
            if let pendingFile {
                Button("続きから再生") { start(pendingFile, position: pendingFile.savedPosition ?? 0) }
                Button("最初から再生") { start(pendingFile, position: 0) }
            }
            Button("キャンセル", role: .cancel) { pendingFile = nil }
        }
        .fullScreenCover(item: $playback) { session in
            FilePlaybackView(item: session.item, onContinuousDisplayChanged: { needed in
                guard playback?.id == session.id else { return }
                playbackIdleTimer.setNeedsContinuousDisplay(needed)
            }, onProgress: { position, duration, ended in
                guard playback?.id == session.id else { return }
                resumeStore.save(session.resumeID, seconds: position, duration: duration,
                                 status: session.status, reachedEnd: ended)
#if DEBUG
                print("RingonomiEPGStationProgress: seconds=\(position) duration=\(duration ?? -1) ended=\(ended)")
#endif
            })
        }
        .onChange(of: playback?.id) { _, id in
            if id == nil { playbackIdleTimer.setNeedsContinuousDisplay(false) }
        }
    }

    private func load() async {
        let expected = UUID()
        generation = expected
        loading = true
        error = nil
        do {
            let client = try EPGStationClient(address: address)
            let result = try await client.recording(id: recordingID)
            try Task.checkCancellation()
            guard generation == expected else { return }
            recording = result
            loading = false
#if DEBUG
            print("RingonomiEPGStationDetail: files=\(result.videoFiles.count)")
            let arguments = ProcessInfo.processInfo.arguments
            if !handledDebugFile,
               let index = arguments.firstIndex(of: "--epgstation-file"), index + 1 < arguments.count,
               let id = Int(arguments[index + 1]), let file = result.videoFiles.first(where: { $0.id == id }) {
                handledDebugFile = true
                prepare(file, recording: result)
            }
#endif
        } catch is CancellationError {
            return
        } catch {
            guard generation == expected, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func prepare(_ file: EPGStationVideoFile, recording: EPGStationRecording) {
        cancelFilePreparation()
        let expected = UUID()
        generation = expected
        preparingFile = true
        fileError = nil
        fileTask = Task { @MainActor in
            defer { if generation == expected { preparingFile = false } }
            do {
                let client = try EPGStationClient(address: address)
                let url = try client.videoURL(fileID: file.id)
                // A growing recording has no stable end yet. Avoid waiting
                // for a duration request that would be discarded below.
                let duration: Double?
                if recording.isRecording {
                    duration = nil
                } else {
                    duration = try? await client.videoDuration(fileID: file.id)
                }
                try Task.checkCancellation()
                guard generation == expected else { return }
                // Namespace the start token so another backend's numeric IDs
                // cannot collide with an EPGStation file bookmark.
                let resumeID = RecordingResumeID(serverURL: client.baseURL, videoID: file.id,
                    recordingStartTime: "epgstation:\(recording.id):\(recording.startAt)")
                let status = recording.isRecording ? "Recording" : "Recorded"
                let hint = recording.isRecording ? nil : duration
                let saved = resumeStore.position(for: resumeID, duration: hint, status: status)
                let pending = EPGStationPendingFile(url: url, title: recording.name, duration: hint,
                    resumeID: resumeID, status: status, savedPosition: saved)
                pendingFile = pending
#if DEBUG
                let fromStart = ProcessInfo.processInfo.arguments.contains("--epgstation-from-start")
#else
                let fromStart = false
#endif
                if saved != nil, !fromStart { resumePrompt = true }
                else { start(pending, position: 0) }
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                fileError = error.localizedDescription
            }
        }
    }

    private func start(_ pending: EPGStationPendingFile, position: Double) {
        let item = FilePlaybackSelection(url: pending.url, title: pending.title,
                                         durationHint: pending.duration, resumePosition: position)
        playback = EPGStationPlaybackSession(item: item, resumeID: pending.resumeID, status: pending.status)
        pendingFile = nil
    }

    private func cancelFilePreparation() {
        generation = UUID()
        fileTask?.cancel()
        fileTask = nil
        preparingFile = false
    }
}

private func epgStationDate(_ milliseconds: Double) -> String {
    guard milliseconds.isFinite, (-62_135_596_800_000...253_402_300_799_000).contains(milliseconds) else {
        return "日時情報なし"
    }
    return Date(timeIntervalSince1970: milliseconds / 1000)
        .formatted(date: .abbreviated, time: .shortened)
}
