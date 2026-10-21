import AVFoundation
import Combine
import CoreGraphics
import Foundation
import RingonomiCore

/// Receives AVFoundation timed metadata on the renderer queue and forwards
/// only validated immutable bytes and presentation time to the controller.
private final class RecordingCaptionMetadataDelegate: NSObject,
    AVPlayerItemMetadataOutputPushDelegate,
    @unchecked Sendable {
    private let generation: Int
    private let sink: @Sendable (ARIBRenderPacket) -> Void

    init(
        generation: Int,
        sink: @escaping @Sendable (ARIBRenderPacket) -> Void
    ) {
        self.generation = generation
        self.sink = sink
    }

    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        for group in groups.prefix(32) {
            let seconds = group.timeRange.start.seconds
            guard ARIBCaptionPacket.milliseconds(for: seconds) != nil else {
                continue
            }

            for item in group.items.prefix(64) where Self.isPrivateItem(item) {
                guard Self.isARIB24Owner(item),
                      let payload = item.dataValue,
                      let packet = try? ARIBCaptionPacket(
                        payload: payload,
                        presentationSeconds: seconds
                      ) else {
                    continue
                }

                // The value is recomputed from the validated time so no
                // AVFoundation object crosses the queue/actor boundary.
                sink(
                    ARIBRenderPacket(
                        generation: generation,
                        value: packet
                    )
                )
            }
        }
    }

    private static func isPrivateItem(_ item: AVMetadataItem) -> Bool {
        if item.identifier == AVMetadataIdentifier.id3MetadataPrivate {
            return true
        }
        if let key = item.key as? String,
           key.caseInsensitiveCompare("PRIV") == .orderedSame {
            return true
        }
        return false
    }

    private static func isARIB24Owner(_ item: AVMetadataItem) -> Bool {
        guard let attributes = item.extraAttributes else { return false }
        for (key, value) in attributes {
            let keyText = String(describing: key).lowercased()
            guard keyText.contains("owner") || keyText.contains("info") else {
                continue
            }
            guard let owner = stringValue(value) else { continue }
            let normalized = owner
                .split(whereSeparator: { $0 == "\0" })
                .first.map(String.init) ?? owner
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "aribb24.js" {
                return true
            }
        }
        return false
    }

    private static func stringValue(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSString { return String(value) }
        if let value = value as? Data { return String(data: value, encoding: .utf8) }
        return nil
    }
}

/// Coordinates timed ARIB metadata, native decoding, and subtitle snapshots.
/// Subtitle failures are surfaced through `status` while the video continues.
@MainActor
final class RecordingCaptionController: ObservableObject {
    @Published private(set) var images: [ARIBCaptionImage] = []
    @Published private(set) var status: String?
    @Published private(set) var enabled = true

    private let renderQueue: ARIBCaptionRenderQueue
    private weak var attachedItem: AVPlayerItem?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var metadataDelegate: RecordingCaptionMetadataDelegate?
    private var generation = 0
    private var clockSeconds = 0.0
    private var frameSize = CGSize.zero
    private var isReady = false
    private var renderInFlight = false
    private var needsSnapshot = true
    private var stopped = false

    init() {
        let queue = ARIBCaptionRenderQueue()
        self.renderQueue = queue
        queue.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    /// Starts metadata delivery for a newly loaded player item.
    func attach(to item: AVPlayerItem, targetSeconds: Double) {
        guard !stopped || attachedItem == nil else { return }
        if attachedItem === item {
            clockSeconds = safeClock(targetSeconds)
            renderQueue.updateClock(clockSeconds, generation: generation)
            return
        }

        removeMetadataOutput()
        stopped = false
        generation &+= 1
        clockSeconds = safeClock(targetSeconds)
        frameSize = .zero
        isReady = false
        renderInFlight = false
        needsSnapshot = true
        images = []
        status = nil
        attachedItem = item
        renderQueue.beginGeneration(generation, clockSeconds: clockSeconds)
        installMetadataOutput(on: item, generation: generation)
    }

    /// Replaces the metadata output after a seek on the same item.
    func reset(for seconds: Double) {
        guard !stopped, attachedItem != nil else { return }
        generation &+= 1
        clockSeconds = safeClock(seconds)
        isReady = false
        renderInFlight = false
        needsSnapshot = true
        images = []
        status = nil
        renderQueue.beginGeneration(generation, clockSeconds: clockSeconds)

        if let item = attachedItem {
            removeMetadataOutput()
            installMetadataOutput(on: item, generation: generation)
        }
    }

    /// Updates the player clock and requests at most one render at a time.
    func tick(seconds: Double, frameSize: CGSize, isReady: Bool) {
        guard !stopped else { return }
        clockSeconds = safeClock(seconds)
        self.frameSize = frameSize
        if !self.isReady && isReady { needsSnapshot = true }
        self.isReady = isReady
        renderQueue.updateClock(clockSeconds, generation: generation, isReady: isReady)

        guard isReady else {
            if !images.isEmpty { images = [] }
            return
        }
        scheduleRenderIfNeeded()
    }

    /// Disabling only hides decoded snapshots.  Timed metadata continues to
    /// feed the native decoder, so enabling can immediately render the clock.
    func setEnabled(_ value: Bool) {
        guard !stopped else { return }
        enabled = value
        needsSnapshot = true
        if !value {
            images = []
            status = nil
            return
        }
        status = nil
        renderQueue.beginAvailabilityCheck(generation: generation)
        scheduleRenderIfNeeded()
    }

    /// Tears down output and native work.  Teardown deliberately does not
    /// publish state, because SwiftUI may be destroying the observing view.
    func stop() {
        guard !stopped else { return }
        stopped = true
        generation &+= 1
        renderInFlight = false
        removeMetadataOutput()
        attachedItem = nil
        renderQueue.invalidate(generation: generation)
    }

    private func installMetadataOutput(on item: AVPlayerItem, generation: Int) {
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        let delegate = RecordingCaptionMetadataDelegate(
            generation: generation,
            sink: { [weak renderQueue] packet in
                renderQueue?.accept(packet)
            }
        )
        output.setDelegate(delegate, queue: renderQueue.queue)
        item.add(output)
        metadataOutput = output
        metadataDelegate = delegate
    }

    private func removeMetadataOutput() {
        if let output = metadataOutput {
            output.setDelegate(nil, queue: nil)
            attachedItem?.remove(output)
        }
        metadataOutput = nil
        metadataDelegate = nil
    }

    private func scheduleRenderIfNeeded() {
        guard !stopped, enabled, isReady, !renderInFlight else { return }
        guard let milliseconds = ARIBCaptionPacket.milliseconds(for: clockSeconds) else {
            return
        }

        let size = ARIBCaptionRenderSize(
            width: frameSize.width,
            height: frameSize.height
        )
        renderInFlight = true
        let forceSnapshot = needsSnapshot
        needsSnapshot = false
        renderQueue.render(
            generation: generation,
            milliseconds: milliseconds,
            frameSize: size,
            forceSnapshot: forceSnapshot
        )
    }

    private func handle(_ event: ARIBRenderEvent) {
        guard !stopped else { return }
        switch event {
        case let .rendered(eventGeneration, newImages):
            guard eventGeneration == generation else { return }
            renderInFlight = false
            guard let newImages else { return }
            guard enabled, isReady else {
                images = []
                return
            }
            images = newImages
            if !newImages.isEmpty { status = nil }
        case let .decodeSucceeded(eventGeneration):
            guard eventGeneration == generation, enabled else { return }
            status = nil
        case let .decodeFailed(eventGeneration):
            guard eventGeneration == generation else { return }
            guard enabled else { return }
            status = "字幕を解析できません。映像は継続します。"
        case let .rendererUnavailable(eventGeneration):
            guard eventGeneration == generation else { return }
            renderInFlight = false
            guard enabled else { return }
            status = "字幕を利用できません。映像は継続します。"
        }
    }

    private func safeClock(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return clockSeconds }
        return min(max(0, seconds), ARIBCaptionPacket.maximumSeconds)
    }
}
