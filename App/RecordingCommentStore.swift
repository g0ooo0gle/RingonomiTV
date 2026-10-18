import SwiftUI
import RingonomiCore

@MainActor
final class RecordingCommentStore: ObservableObject {
    @Published private(set) var comments: [PlaybackComment] = []
    @Published private(set) var status: String?
    @Published private(set) var loading = false
    private var generation = UUID()

    func load(client: RingonomiClient, recordingID: Int) async {
        let expected = UUID()
        generation = expected
        loading = true
        comments = []
        status = "実況：過去ログを読み込んでいます…"
        defer { if generation == expected { loading = false } }
        do {
            let response = try await client.recordedComments(recordingID: recordingID)
            guard !Task.isCancelled, generation == expected else { return }
            guard response.isSuccess else {
                status = "実況：過去ログを取得できませんでした。あとで再取得してください。"
                return
            }
            comments = response.comments
            status = comments.isEmpty ? "実況：コメントはありません。" : nil
#if DEBUG
            print("RingonomiRecordedComments: loaded=\(comments.count)")
#endif
        } catch {
            guard !Task.isCancelled, generation == expected else { return }
            status = "実況を取得できませんでした。実況メニューから再取得できます。"
#if DEBUG
            print("RingonomiRecordedComments: request failed")
#endif
        }
    }

    func disable() {
        cancel()
        comments = []
        status = nil
        loading = false
    }

    /// Called on disappearance without publishing into SwiftUI teardown.
    func cancel() { generation = UUID() }
}
