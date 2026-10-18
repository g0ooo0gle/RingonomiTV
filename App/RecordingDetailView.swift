import SwiftUI
import RingonomiCore

struct RecordingDetailView: View {
    let client: RingonomiClient
    let onPlay: (Recording) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recording: Recording
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0

    init(recording: Recording, client: RingonomiClient, onPlay: @escaping (Recording) -> Void) {
        self.client = client
        self.onPlay = onPlay
        _recording = State(initialValue: recording)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(recording.title).font(.title2)
                HStack(spacing: 24) {
                    Button("再生") { onPlay(recording) }.disabled(loading)
                    Button("閉じる") { dismiss() }
                }
                if loading { ProgressView("録画の詳細を読み込んでいます…") }
                if let error {
                    Text(error).foregroundStyle(.orange)
                    Button("詳細を再取得") { revision &+= 1 }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(recording.channel?.name ?? "チャンネル情報なし")
                    Text(recordingDate(recording.startTime) + " ～ " + recordingDate(recording.endTime))
                    Text("録画時間：" + Playback.timestamp(recording.recordedVideo.duration))
                    if recording.recordedVideo.status == "Recording" { Text("録画中") }
                    if recording.isPartiallyRecorded == true {
                        Text("一部のみ録画されています").foregroundStyle(.orange)
                    }
                    if let series = recording.seriesTitle, !series.isEmpty { Text("シリーズ：" + series) }
                    if let episode = recording.episodeNumber, !episode.isEmpty { Text("話数：" + episode) }
                    if let subtitle = recording.subtitle, !subtitle.isEmpty { Text(subtitle) }
                    if !recording.genres.isEmpty {
                        Text(recording.genres.map { $0.major + " / " + $0.middle }.joined(separator: "、"))
                    }
                }.foregroundStyle(.secondary)
                if !recording.description.isEmpty { Text(recording.description) }
                ForEach((recording.detail ?? [:]).keys.sorted(), id: \.self) { heading in
                    VStack(alignment: .leading, spacing: 10) {
                        if !heading.isEmpty { Text(heading).font(.headline) }
                        Text(recording.detail?[heading] ?? "")
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(60)
        }
        .onExitCommand { dismiss() }
        .task(id: revision) {
            let expectedRevision = revision
            loading = true
            error = nil
            defer {
                if revision == expectedRevision { loading = false }
            }
            do {
                let latest = try await client.recording(id: recording.id)
                guard !Task.isCancelled, revision == expectedRevision else { return }
                recording = latest
            } catch {
                guard !Task.isCancelled, revision == expectedRevision else { return }
                self.error = "詳細を取得できませんでした。再試行するか、一覧の情報で再生できます。"
            }
        }
    }
}
