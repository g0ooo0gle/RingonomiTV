import SwiftUI
import RingonomiCore
import CoreGraphics

/// An immutable decoded image can cross the decode task's actor boundary.
private struct DecodedSceneAtlas: @unchecked Sendable {
    let image: CGImage
}

@MainActor
final class RecordingSceneSearchStore: ObservableObject {
    struct Card: Identifiable {
        let scene: RecordingScene
        let image: CGImage
        var id: Int { scene.id }
    }

    static let pageSize = 6
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    @Published private(set) var cards: [Card] = []
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var interval = 30
    @Published private(set) var preferredSceneID: Int?
    private var timeline: RecordingSceneTimeline?
    private var atlas: CGImage?
    private var anchorSeconds = 0.0
    private var generation = 0

    func load(client: RingonomiClient, recordingID: Int, fileID: Int?, position: Double) async {
        generation &+= 1
        let expected = generation
        loading = true
        message = nil
        cards = []
        atlas = nil
        timeline = nil
        pageCount = 0
        preferredSceneID = nil
        anchorSeconds = position.isFinite ? max(0, position) : 0
        defer { if generation == expected { loading = false } }
        do {
            let recording = try await client.recordingSceneRecording(id: recordingID)
            try Task.checkCancellation()
            guard fileID == nil || recording.recordedVideo.id == fileID else {
                message = "録画情報が更新されています。録画一覧から開き直してください。"
                return
            }
            guard recording.recordedVideo.status != "Recording" else {
                message = "シーンサーチは録画完了後に利用できます。"
                return
            }
            guard let info = recording.recordedVideo.thumbnailInfo, info.tile != nil else {
                message = "シーン画像はまだ用意されていません。通常のシーク操作をご利用ください。"
                return
            }
            let next = try RecordingSceneTimeline(durationSeconds: recording.recordedVideo.duration,
                                                   thumbnailInfo: info, sceneIntervalSeconds: Double(interval))
            let data = try await client.recordingSceneImage(recordingID: recordingID)
            try Task.checkCancellation()
            let decode = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let image = try RecordingSceneImageDecoder.decode(data: data,
                    expectedWidth: next.metadata.imageWidth, expectedHeight: next.metadata.imageHeight)
                try Task.checkCancellation()
                return DecodedSceneAtlas(image: image)
            }
            let decoded = try await withTaskCancellationHandler {
                try await decode.value
            } onCancel: {
                decode.cancel()
            }
            try Task.checkCancellation()
            guard generation == expected else { return }
            timeline = next
            atlas = decoded.image
            moveNearAnchor()
#if DEBUG
            print("RingonomiScenesReady: scenes=\(next.sceneCount) pixels=\(decoded.image.width * decoded.image.height)")
#endif
        } catch is CancellationError {
            return
        } catch {
            guard generation == expected, !Task.isCancelled else { return }
            timeline = nil
            atlas = nil
            cards = []
            if let error = error as? RecordingSceneImageDecoderError {
                message = error.localizedDescription
            } else if let error = error as? RecordingSceneError {
                message = error.localizedDescription
            } else {
                message = "シーン画像を取得できませんでした。接続を確認して再試行してください。"
            }
        }
    }

    func selectInterval(_ seconds: Int) {
        guard seconds != interval, let current = timeline else { return }
        do {
            timeline = try RecordingSceneTimeline(durationSeconds: current.durationSeconds,
                metadata: current.metadata, sceneIntervalSeconds: Double(seconds))
            interval = seconds
            moveNearAnchor()
        } catch {
            message = "この間隔では表示できません。別の間隔を選んでください。"
        }
    }

    func focusScene(_ id: Int) {
        if let scene = timeline?.scene(at: id) { anchorSeconds = scene.timeSeconds }
    }

    func movePage(by offset: Int) {
        guard pageCount > 0 else { return }
        showPage(min(pageCount - 1, max(0, pageIndex + offset)))
    }

    func moveToCurrentPosition(_ seconds: Double) {
        anchorSeconds = seconds.isFinite ? max(0, seconds) : 0
        moveNearAnchor()
    }

    private func moveNearAnchor() {
        guard let timeline else { return }
        let scene = timeline.nearestScene(to: anchorSeconds)
        showPage((scene?.id ?? 0) / Self.pageSize, preferred: scene?.id)
    }

    private func showPage(_ index: Int, preferred: Int? = nil) {
        guard let timeline, let atlas,
              let page = timeline.page(at: index, pageSize: Self.pageSize) else { return }
        do {
            let nextCards = try page.scenes.map { scene in
                Card(scene: scene, image: try RecordingSceneImageDecoder.crop(image: atlas,
                    sourceRect: scene.rect, sourceWidth: timeline.metadata.imageWidth,
                    sourceHeight: timeline.metadata.imageHeight))
            }
            cards = nextCards
            pageIndex = index
            pageCount = timeline.pageCount(pageSize: Self.pageSize)
            preferredSceneID = preferred ?? nextCards.first?.id
            message = nil
        } catch {
            cards = []
            message = "シーン画像を切り出せませんでした。再試行してください。"
        }
    }

    func cancel() {
        generation &+= 1
        atlas = nil
        timeline = nil
        cards = []
        loading = false
    }
}
