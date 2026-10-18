import SwiftUI
import RingonomiCore

/// 詳細のCM区間を使う。情報の取得失敗で本体の再生は中断しない。
struct RecordingChapterControls: View {
    let client: RingonomiClient
    let recordingID: Int
    let fileID: Int?
    @ObservedObject var controller: RecordingPlaybackController
    @AppStorage("recordingAutoSkipCM") private var automaticSkip = false
    @State private var isComplete = false
    @State private var timeline: RecordingChapterTimeline?
    @State private var fetching = false
    @State private var error: String?
    @State private var reload = 0

    private var hasSections: Bool { timeline?.commercialSections.isEmpty == false }
    private var hasBoundaries: Bool { timeline?.hasChapterBoundaries == true }

    var body: some View {
        Menu("チャプター") {
            Button("直前のCMスキップを戻す") { controller.undoCommercialSkip() }
                .disabled(!controller.canUndoCommercialSkip)
            Button(automaticSkip ? "CM自動スキップ：オン" : "CM自動スキップ：オフ") {
                automaticSkip.toggle()
            }
            if timeline != nil, !isComplete {
                Text("自動スキップは録画完了後に利用できます")
            }
            Divider()
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
            } else if let timeline, hasSections {
                ForEach(timeline.chapters) { chapter in
                    Button("\(chapter.id + 1) · \(Playback.timestamp(chapter.startTime)) · \(chapter.isCommercial ? "CM" : "本編")") {
                        controller.seek(to: chapter.startTime)
                    }
                }
            } else {
                Text("CM区間情報はありません")
            }
            Button("情報を再取得") { reload &+= 1 }.disabled(fetching)
        }
        .disabled(controller.isLoading || controller.failure != nil)
        .task(id: reload) { await load() }
        .task(id: automaticSkip) { controller.setAutomaticCommercialSkip(automaticSkip) }
    }

    @MainActor private func load() async {
        guard !fetching else { return }
        fetching = true
        error = nil
        isComplete = false
        timeline = nil
        controller.configureCommercialTimeline(nil, isComplete: false)
        defer { fetching = false }
        do {
            let detail = try await client.fetch(["api", "videos", String(recordingID)], as: Recording.self)
            guard !Task.isCancelled else { return }
            guard detail.id == recordingID, fileID == nil || detail.recordedVideo.id == fileID else {
                timeline = nil
                error = "録画情報が更新されています。録画一覧から開き直してください。"
                return
            }
            isComplete = detail.recordedVideo.status == "Recorded"
            timeline = RecordingChapterTimeline(duration: detail.recordedVideo.duration,
                                                 sections: detail.recordedVideo.cmSections ?? [])
            controller.configureCommercialTimeline(timeline, isComplete: isComplete)
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
