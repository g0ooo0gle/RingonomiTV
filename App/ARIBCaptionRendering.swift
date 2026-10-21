import CoreGraphics
import Foundation
import RingonomiCore

/// One immutable image snapshot produced by the native ARIB renderer.
///
/// `CGImage` is retained by this value before it crosses from the renderer's
/// serial queue to the main actor.  The native renderer is never accessed from
/// a view or from the main actor.
struct ARIBCaptionImage: Identifiable, @unchecked Sendable {
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

struct ARIBRenderPacket: Sendable {
    let generation: Int
    let value: ARIBCaptionPacket
}

enum ARIBRenderEvent: Sendable {
    case rendered(generation: Int, images: [ARIBCaptionImage]?)
    case decodeFailed(generation: Int)
    case decodeSucceeded(generation: Int)
    case rendererUnavailable(generation: Int)
}

/// Owns the native decoder and renderer.  Every native call is made on
/// `queue`, including reset, so libaribcaption never sees concurrent access.
final class ARIBCaptionRenderQueue: @unchecked Sendable {
    let queue = DispatchQueue(
        label: "tv.ringonomi.caption-render",
        qos: .userInitiated
    )

    var onEvent: (@Sendable (ARIBRenderEvent) -> Void)?

    private let renderer: RNGCaptionRenderer
    private var generation = 0
    private var clockSeconds = 0.0
    private var latestImages: [ARIBCaptionImage] = []
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

    func accept(_ packet: ARIBRenderPacket) {
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

    private func snapshot(_ nativeImages: [RNGCaptionImage]) -> [ARIBCaptionImage] {
        guard nativeImages.count <= 8 else { return [] }

        var snapshots: [ARIBCaptionImage] = []
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
                ARIBCaptionImage(
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

    private func emit(_ event: ARIBRenderEvent) {
        onEvent?(event)
    }

    private static func clampedClock(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), ARIBCaptionPacket.maximumSeconds)
    }
}

extension ARIBCaptionRenderQueue {
    func beginAvailabilityCheck(generation expectedGeneration: Int) {
        queue.async { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            guard !self.renderer.isAvailable else { return }
            self.emit(.rendererUnavailable(generation: expectedGeneration))
        }
    }
}
