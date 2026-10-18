import AVFoundation
import Combine
import CoreGraphics
import Foundation
import RingonomiCore

/// One immutable image snapshot produced by the native ARIB renderer.
///
/// `CGImage` is retained by this value before it crosses from the renderer's
/// serial queue to the main actor.  The native renderer is never accessed from
/// a view or from the main actor.
struct RecordingCaptionImage: Identifiable, @unchecked Sendable {
    let id = UUID()
    let image: CGImage
    let x: Int
    let y: Int
    let canvasWidth: Int
    let canvasHeight: Int

    init(image: CGImage, x: Int, y: Int, canvasWidth: Int, canvasHeight: Int) {
        self.image = image
        self.x = x
        self.y = y
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }
}

private struct RecordingCaptionPacket: Sendable {
    let generation: Int
    let value: ARIBCaptionPacket
}

private enum RecordingCaptionRenderEvent: Sendable {
    case rendered(generation: Int, images: [RecordingCaptionImage]?)
    case decodeFailed(generation: Int)
    case decodeSucceeded(generation: Int)
    case rendererUnavailable(generation: Int)
}

/// Owns the native decoder and renderer.  Every native call is made on
/// `queue`, including reset, so libaribcaption never sees concurrent access.
private final class RecordingCaptionRenderQueue: @unchecked Sendable {
    let queue = DispatchQueue(
        label: "tv.ringonomi.caption-render",
        qos: .userInitiated
    )

    var onEvent: (@Sendable (RecordingCaptionRenderEvent) -> Void)?

    private let renderer: RNGCaptionRenderer
    private var generation = 0
    private var clockSeconds = 0.0
    private var latestImages: [RecordingCaptionImage] = []
    private var history = ARIBCaptionHistory()
    private var decodedHistory = ARIBCaptionHistory()
    private var observedStart = 0.0
    private var observedEnd = 0.0
    private var hadDecodeError = false
    private var replayedThrough: Int64 = -1

#if DEBUG
    private var metadataCount = 0
    private var decodedCount = 0
    private var renderedCount = 0
    private var didLogMetadata = false
    private var didLogDecoded = false
    private var didLogRendered = false
#endif

    init() {
        renderer = RNGCaptionRenderer()
    }

    func beginGeneration(_ newGeneration: Int, clockSeconds: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation = newGeneration
            self.clockSeconds = Self.clampedClock(clockSeconds)
            let current = ARIBCaptionPacket.milliseconds(for: self.clockSeconds) ?? 0
            // Never carry a caption across an unobserved gap: its clearing
            // packet may be in the part of the recording we skipped.
            if self.clockSeconds < self.observedStart - 0.5 ||
                self.clockSeconds > self.observedEnd + 0.5 ||
                self.history.evictedThroughMilliseconds.map({ current <= $0 }) == true {
                self.history.removeAll()
                self.observedStart = self.clockSeconds
                self.observedEnd = self.clockSeconds
            }
            self.renderer.reset()
            self.latestImages = []
            self.decodedHistory.removeAll()
            self.hadDecodeError = false
#if DEBUG
            self.metadataCount = 0
            self.decodedCount = 0
            self.renderedCount = 0
            self.didLogMetadata = false
            self.didLogDecoded = false
            self.didLogRendered = false
#endif
            guard self.renderer.isAvailable else {
                self.emit(.rendererUnavailable(generation: newGeneration))
                return
            }
            // AVFoundation may not resend timed metadata after a paused
            // seek. Rebuild native state from bounded, already received
            // packets instead of leaving the new position without captions.
            self.replayedThrough = current + 15_000
            for packet in self.history.packets(through: self.replayedThrough) {
                self.decodeIfNeeded(packet, generation: newGeneration)
            }
        }
    }

    func updateClock(_ seconds: Double, generation expectedGeneration: Int, isReady: Bool = false) {
        queue.async { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.clockSeconds = Self.clampedClock(seconds)
            if isReady {
                self.observedStart = min(self.observedStart, self.clockSeconds)
                self.observedEnd = max(self.observedEnd, self.clockSeconds)
                if let current = ARIBCaptionPacket.milliseconds(for: self.clockSeconds) {
                    let upper = current + 15_000
                    for packet in self.history.packets(after: self.replayedThrough, through: upper) {
                        self.decodeIfNeeded(packet, generation: expectedGeneration)
                    }
                    self.replayedThrough = max(self.replayedThrough, upper)
                }
            }
        }
    }

    func accept(_ packet: RecordingCaptionPacket) {
        queue.async { [weak self] in
            guard let self, self.generation == packet.generation else { return }
            guard packet.value.isNear(playbackSeconds: self.clockSeconds) else { return }
            self.history.insert(packet.value)
            self.decodeIfNeeded(packet.value, generation: packet.generation)
        }
    }

    private func decodeIfNeeded(_ packet: ARIBCaptionPacket, generation: Int) {
        guard !decodedHistory.contains(packet) else { return }
#if DEBUG
        metadataCount += 1
        if !didLogMetadata {
            didLogMetadata = true
            print("[Caption] metadata received count=\(metadataCount) pts_ms=\(packet.milliseconds)")
        }
#endif
        let result = renderer.decode(payload: packet.payload, presentationTime: packet.milliseconds)
        guard result >= 0 else {
            if !hadDecodeError { emit(.decodeFailed(generation: generation)) }
            hadDecodeError = true
            return
        }
        decodedHistory.insert(packet)
        if hadDecodeError { emit(.decodeSucceeded(generation: generation)) }
        hadDecodeError = false
#if DEBUG
        decodedCount += 1
        if !didLogDecoded {
            didLogDecoded = true
            print("[Caption] metadata decoded count=\(decodedCount) pts_ms=\(packet.milliseconds)")
        }
#endif
    }

    func render(
        generation expectedGeneration: Int,
        milliseconds: Int64,
        frameSize: ARIBCaptionRenderSize,
        forceSnapshot: Bool
    ) {
        queue.async { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            guard self.renderer.isAvailable else {
                self.emit(.rendererUnavailable(generation: expectedGeneration))
                return
            }

            guard let nativeImages = self.renderer.render(
                at: milliseconds,
                frameWidth: frameSize.width,
                frameHeight: frameSize.height
            ) else {
                // nil means that the native decoder has no newer image.
                self.emit(.rendered(generation: expectedGeneration,
                                    images: forceSnapshot ? self.latestImages : nil))
                return
            }

            let images = self.snapshot(nativeImages)
            self.latestImages = images
#if DEBUG
            self.renderedCount += 1
            if !self.didLogRendered, !images.isEmpty {
                self.didLogRendered = true
                print("[Caption] rendered count=\(self.renderedCount) images=\(images.count) pts_ms=\(milliseconds)")
            }
#endif
            self.emit(.rendered(generation: expectedGeneration, images: images))
        }
    }

    func invalidate(generation newGeneration: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation = newGeneration
            self.renderer.reset()
            self.latestImages = []
            self.history.removeAll()
            self.decodedHistory.removeAll()
            self.observedStart = 0
            self.observedEnd = 0
        }
    }

    private func snapshot(_ nativeImages: [RNGCaptionImage]) -> [RecordingCaptionImage] {
        guard nativeImages.count <= 8 else { return [] }

        var snapshots: [RecordingCaptionImage] = []
        snapshots.reserveCapacity(nativeImages.count)
        var imageBytes = 0

        for nativeImage in nativeImages {
            let canvasWidth = nativeImage.canvasWidth
            let canvasHeight = nativeImage.canvasHeight
            let x = nativeImage.x
            let y = nativeImage.y
            let cgImage = nativeImage.image
            let width = cgImage.width
            let height = cgImage.height

            guard canvasWidth > 0, canvasWidth <= 1_920,
                  canvasHeight > 0, canvasHeight <= 1_080,
                  width > 0, height > 0,
                  x >= 0, y >= 0,
                  x < canvasWidth, y < canvasHeight,
                  width <= canvasWidth, height <= canvasHeight else {
                continue
            }

            let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            let (bytesForImage, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
            guard !pixelOverflow, !byteOverflow,
                  bytesForImage <= 16 * 1024 * 1024,
                  imageBytes <= 16 * 1024 * 1024 - bytesForImage else {
                continue
            }
            imageBytes += bytesForImage
            snapshots.append(
                RecordingCaptionImage(
                    image: cgImage,
                    x: x,
                    y: y,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight
                )
            )
        }
        return snapshots
    }

    private func emit(_ event: RecordingCaptionRenderEvent) {
        onEvent?(event)
    }

    private static func clampedClock(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), ARIBCaptionPacket.maximumSeconds)
    }
}

/// Receives AVFoundation timed metadata on the renderer queue and forwards
/// only validated immutable bytes and presentation time to the controller.
private final class RecordingCaptionMetadataDelegate: NSObject,
    AVPlayerItemMetadataOutputPushDelegate,
    @unchecked Sendable {
    private let generation: Int
    private let sink: @Sendable (RecordingCaptionPacket) -> Void

    init(
        generation: Int,
        sink: @escaping @Sendable (RecordingCaptionPacket) -> Void
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
                    RecordingCaptionPacket(
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
    @Published private(set) var images: [RecordingCaptionImage] = []
    @Published private(set) var status: String?
    @Published private(set) var enabled = true

    private let renderQueue: RecordingCaptionRenderQueue
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
        let queue = RecordingCaptionRenderQueue()
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

    private func handle(_ event: RecordingCaptionRenderEvent) {
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

private extension RecordingCaptionRenderQueue {
    func beginAvailabilityCheck(generation expectedGeneration: Int) {
        queue.async { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            guard !self.renderer.isAvailable else { return }
            self.emit(.rendererUnavailable(generation: expectedGeneration))
        }
    }
}
