import SwiftUI
import RingonomiCore

/// 詳細のCM区間を使う。情報の取得失敗で本体の再生は中断しない。
struct RecordingChapterControls: View {
    let client: RingonomiClient
    let recordingID: Int
    let fileID: Int?
    @ObservedObject var controller: RecordingPlaybackController
    @State private var timeline: RecordingChapterTimeline?
    @State private var fetching = false
    @State private var error: String?
    @State private var reload = 0

    private var hasSections: Bool { timeline?.hasCommercialSections == true }
    private var hasBoundaries: Bool { timeline?.hasChapterBoundaries == true }

    var body: some View {
        Menu("チャプター") {
            Button(hasBoundaries ? "前のチャプター" : "1分戻る") {
                if let timeline { controller.seek(to: timeline.previous(from: controller.currentSeconds)) }
                else { controller.seek(seconds: -60) }
            }
            Button(hasBoundaries ? "次のチャプター" : "3分進む") {
                if let timeline { controller.seek(to: timeline.next(from: controller.currentSeconds)) }
                else { controller.seek(seconds: 180) }
            }
            Divider()
            if fetching {
                Text("チャプター情報を取得中…")
            } else if let error {
                Text(error)
                Button("情報を再取得") { reload &+= 1 }
            } else if let timeline, hasSections {
                ForEach(timeline.chapters) { chapter in
                    Button("\(chapter.id + 1) · \(Playback.timestamp(chapter.startTime)) · \(chapter.isCommercial ? "CM" : "本編")") {
                        controller.seek(to: chapter.startTime)
                    }
                }
            } else {
                Text("CM区間情報はありません")
            }
        }
        .disabled(controller.isLoading || controller.failure != nil)
        .task(id: reload) { await load() }
    }

    @MainActor private func load() async {
        guard !fetching else { return }
        fetching = true
        error = nil
        defer { fetching = false }
        do {
            let detail = try await client.fetch(["api", "videos", String(recordingID)], as: Recording.self)
            guard !Task.isCancelled else { return }
            guard detail.id == recordingID, fileID == nil || detail.recordedVideo.id == fileID else {
                timeline = nil
                error = "録画情報が更新されています。録画一覧から開き直してください。"
                return
            }
            timeline = RecordingChapterTimeline(duration: detail.recordedVideo.duration,
                                                 sections: detail.recordedVideo.cmSections ?? [])
            if timeline == nil { error = "録画時間の情報を取得できませんでした。" }
#if DEBUG
            print("RingonomiChaptersReady: count=\(timeline?.chapters.count ?? 0) commercials=\(timeline?.commercialSections.count ?? 0)")
#endif
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            timeline = nil
            self.error = "チャプター情報を取得できませんでした。"
        }
    }
}
