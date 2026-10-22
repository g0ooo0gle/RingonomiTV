import Combine
import CoreGraphics
import Foundation
import RingonomiCore
import SwiftUI

/// Caption state belongs to the live input, while all native calls stay on
/// the same bounded serial renderer used for recordings.
@MainActor
final class LiveCaptionController: ObservableObject {
    @Published private(set) var images: [ARIBCaptionImage] = []
    @Published private(set) var status: String?
    @Published private(set) var enabled = true

    private let renderQueue: ARIBCaptionRenderQueue
    private var generation = 0
    private var streamID: UUID?
    private var discontinuitySequence: UInt64?
    private var timeline = LiveCaptionClock()
    private var clockSeconds = 0.0
    private var frameSize = CGSize.zero
    private var isReady = false
    private var renderInFlight = false
    private var needsSnapshot = true
    private var stopped = true
    private var clockUnavailable = false

    init() {
        let queue = ARIBCaptionRenderQueue()
        renderQueue = queue
        queue.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
    }

    func prepare() {
        generation &+= 1
        stopped = false
        clockUnavailable = false
        streamID = nil
        discontinuitySequence = nil
        timeline = LiveCaptionClock()
        clockSeconds = 0
        frameSize = .zero
        isReady = false
        renderInFlight = false
        needsSnapshot = true
        images = []
        status = nil
        renderQueue.invalidate(generation: generation)
        renderQueue.beginGeneration(generation, clockSeconds: 0)
    }

    func accept(_ batch: LiveCaptionBatch) {
        guard !stopped, !clockUnavailable else { return }
        guard batch.isSynchronized else {
            invalidateClock()
            return
        }
        if let streamID, streamID != batch.streamID {
            // A decoder reconnect starts another transport clock. Keep video
            // alive and wait for an explicit reload to establish its origin.
            invalidateClock()
            return
        }
#if DEBUG
        if streamID == nil {
            print("[LiveCaption] input clock=\(batch.firstClockTicks ?? -1) video=\(batch.firstVideoTicks ?? -1)")
        }
#endif
        streamID = batch.streamID
        if let sequence = discontinuitySequence, sequence != batch.discontinuitySequence {
            generation &+= 1
            images = []
            renderInFlight = false
            needsSnapshot = true
            renderQueue.invalidate(generation: generation)
            renderQueue.beginGeneration(generation, clockSeconds: clockSeconds)
        }
        discontinuitySequence = batch.discontinuitySequence
        timeline.observe(firstTicks: batch.firstClockTicks ?? batch.firstVideoTicks,
                         currentTicks: batch.currentClockTicks,
                         sequence: batch.discontinuitySequence)
        guard timeline.isSynchronized else {
            invalidateClock()
            return
        }
        for caption in batch.captions {
            guard let value = timeline.packet(caption) else { continue }
            renderQueue.accept(ARIBRenderPacket(generation: generation, value: value))
        }
    }

    func tick(seconds: Double, frameSize: CGSize, isReady: Bool) {
        guard !stopped, seconds.isFinite else { return }
        clockSeconds = min(max(0, seconds), ARIBCaptionPacket.maximumSeconds)
        self.frameSize = frameSize
        if !self.isReady && isReady { needsSnapshot = true }
        self.isReady = isReady
        renderQueue.updateClock(clockSeconds, generation: generation, isReady: isReady)
        guard isReady, timeline.isSynchronized, !clockUnavailable else {
            if !images.isEmpty { images = [] }
            return
        }
        scheduleRender()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        needsSnapshot = true
        status = nil
        if !value { images = []; return }
        guard !stopped else { return }
        guard !clockUnavailable else {
            status = "字幕を同期できません。映像は継続します。"
            return
        }
        renderQueue.beginAvailabilityCheck(generation: generation)
        scheduleRender()
    }

    /// Do not publish while the observing SwiftUI hierarchy is being removed.
    func stop() {
        guard !stopped else { return }
        stopped = true
        generation &+= 1
        renderInFlight = false
        renderQueue.invalidate(generation: generation)
    }

    private func invalidateClock() {
        clockUnavailable = true
        generation &+= 1
        renderInFlight = false
        images = []
        if enabled { status = "字幕を同期できません。映像は継続します。" }
        renderQueue.invalidate(generation: generation)
    }

    private func scheduleRender() {
        guard !stopped, !clockUnavailable, enabled, isReady, timeline.isSynchronized, !renderInFlight,
              let milliseconds = ARIBCaptionPacket.milliseconds(for: clockSeconds) else { return }
        renderInFlight = true
        let snapshot = needsSnapshot
        needsSnapshot = false
        renderQueue.render(generation: generation, milliseconds: milliseconds,
                           frameSize: ARIBCaptionRenderSize(width: frameSize.width, height: frameSize.height),
                           forceSnapshot: snapshot)
    }

    private func handle(_ event: ARIBRenderEvent) {
        guard !stopped else { return }
        switch event {
        case let .rendered(expected, snapshots):
            guard expected == generation else { return }
            renderInFlight = false
            guard enabled, isReady, timeline.isSynchronized else {
                if !images.isEmpty { images = [] }
                return
            }
            guard let snapshots else { return }
            images = snapshots
            if !snapshots.isEmpty { status = nil }
        case let .decodeSucceeded(expected):
            guard expected == generation, enabled else { return }
            status = nil
        case let .decodeFailed(expected):
            guard expected == generation, enabled else { return }
            status = "字幕を解析できません。映像は継続します。"
        case let .rendererUnavailable(expected):
            guard expected == generation else { return }
            renderInFlight = false
            if enabled { status = "字幕を利用できません。映像は継続します。" }
        }
    }
}

struct LiveCaptionOverlay: View {
    @ObservedObject var controller: LiveCaptionController
    let videoRect: CGRect
    let isVisible: Bool

    var body: some View {
        ARIBCaptionImagesOverlay(images: controller.images, videoRect: videoRect,
                                 isVisible: isVisible && controller.enabled)
    }
}

struct LiveCaptionStatus: View {
    @ObservedObject var controller: LiveCaptionController

    var body: some View {
        if controller.enabled, let status = controller.status { Text(status).font(.caption) }
    }
}
