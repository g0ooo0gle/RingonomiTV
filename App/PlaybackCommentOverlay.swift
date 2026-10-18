import SwiftUI
import UIKit
import RingonomiCore

/// Renders playback comments over the video without taking focus from
/// the transport controls.
///
/// The timeline owns admission, lane assignment, collision avoidance, and
/// thinning.  This view only rebuilds that immutable layout when its inputs or
/// the viewport change, then asks it for the small set of frames visible at
/// the current playback position.
struct PlaybackCommentOverlay: View {
    let comments: [PlaybackComment]
    let clock: () -> Double
    let videoRect: CGRect
    let isPaused: Bool
    let isVisible: Bool

    var topReservedSpace = 280.0
    var bottomReservedSpace = 160.0

    @State private var layout: CommentLayout?
    @State private var metricCache: [MetricCacheKey: PlaybackCommentMetric] = [:]
    @State private var activeGeneration = UUID()

#if DEBUG
    // This is deliberately a plain reference held by State rather than an
    // ObservableObject.  Logging must not publish a change while Canvas is
    // being torn down or redrawn.
    @State private var debugState = CommentOverlayDebugState()
#endif

    var body: some View {
        GeometryReader { geometry in
            let rect = displayRect(in: geometry.size)
            content(for: rect.size)
                .frame(width: rect.width, height: rect.height)
                .clipped()
                .position(x: rect.midX, y: rect.midY)
                .task(id: LayoutInput(viewportSize: rect.size, comments: comments, top: topReservedSpace, bottom: bottomReservedSpace)) {
                    do {
                        try await rebuildTimeline(for: rect.size, comments: comments)
                    } catch is CancellationError {
                        // A newer geometry/comment input owns the next task.
                    } catch {
                        // Layout failure must never interrupt video playback.
                    }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func displayRect(in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        guard videoRect.origin.x.isFinite, videoRect.origin.y.isFinite,
              videoRect.width.isFinite, videoRect.height.isFinite,
              videoRect.width > 0, videoRect.height > 0 else { return bounds }
        let rect = videoRect.intersection(bounds)
        return rect.isNull || rect.isEmpty ? bounds : rect
    }

    @ViewBuilder
    private func content(for size: CGSize) -> some View {
        if isVisible,
           size.width.isFinite,
           size.height.isFinite,
           size.width > 0,
           size.height > 0,
           let layout {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { _ in
                Canvas { context, canvasSize in
                    draw(
                        context: &context,
                        canvasSize: canvasSize,
                        layout: layout
                    )
                }
                .allowsHitTesting(false)
            }
        } else {
            Color.clear
        }
    }

    /// Rebuilds UIKit measurements and the Core timeline only when the
    /// geometry or comment input changes.  It is intentionally not called by
    /// the 30 Hz drawing path.
    @MainActor
    private func rebuildTimeline(
        for size: CGSize,
        comments: [PlaybackComment]
    ) async throws {
        let generation = UUID()
        activeGeneration = generation

        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              comments.count <= 100_000 else {
            guard !Task.isCancelled, activeGeneration == generation else { return }
            layout = nil
            return
        }

        let scale = max(0.1, size.height / 1080.0)
        var nextMetricCache: [MetricCacheKey: PlaybackCommentMetric] = [:]
        var fontCache: [Int: UIFont] = [:]
        var metrics: [PlaybackCommentMetric] = []
        metrics.reserveCapacity(comments.count)

        for (index, comment) in comments.enumerated() {
            try Task.checkCancellation()
            if index > 0, index.isMultiple(of: 256) {
                await Task.yield()
                try Task.checkCancellation()
            }
            metrics.append(
                measure(
                    comment,
                    scale: scale,
                    metricCache: &nextMetricCache,
                    fontCache: &fontCache
                )
            )
        }

        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()

        // The title can occupy two lines above status and playback time.
        let topInset = topReservedSpace * scale
        let bottomInset = bottomReservedSpace * scale

        let nextTimeline = RecordedCommentTimeline(
            comments: comments,
            metrics: metrics,
            viewportWidth: Double(size.width),
            viewportHeight: Double(size.height),
            topInset: Double(max(0, topInset)),
            bottomInset: Double(max(0, bottomInset))
        )

        try Task.checkCancellation()
        guard !Task.isCancelled, activeGeneration == generation else { return }

        // Publish the completed local result once.  In particular, do not
        // mutate @State once per comment while UIKit performs measurement.
        metricCache = nextMetricCache
        layout = CommentLayout(timeline: nextTimeline, comments: comments)

    }

    @MainActor
    private func measure(
        _ comment: PlaybackComment,
        scale: CGFloat,
        metricCache: inout [MetricCacheKey: PlaybackCommentMetric],
        fontCache: inout [Int: UIFont]
    ) -> PlaybackCommentMetric {
        let pointSize = basePointSize(for: comment.size) * scale
        let key = MetricCacheKey(
            text: comment.text,
            pointSize: Int((pointSize * 100).rounded())
        )

        if let cached = metricCache[key] ?? self.metricCache[key] {
            metricCache[key] = cached
            return cached
        }

        guard !comment.text.isEmpty, pointSize.isFinite, pointSize > 0 else {
            let empty = PlaybackCommentMetric(width: 0, height: 0)
            metricCache[key] = empty
            return empty
        }

        let fontKey = Int((pointSize * 100).rounded())
        let font = fontCache[fontKey] ?? {
            let created = UIFont.systemFont(ofSize: pointSize, weight: .regular)
            fontCache[fontKey] = created
            return created
        }()
        let rect = (comment.text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )

        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            let empty = PlaybackCommentMetric(width: 0, height: 0)
            metricCache[key] = empty
            return empty
        }

        let metric = PlaybackCommentMetric(
            width: Double(ceil(rect.width)),
            height: Double(ceil(rect.height))
        )
        metricCache[key] = metric
        return metric
    }

    private func draw(
        context: inout GraphicsContext,
        canvasSize: CGSize,
        layout: CommentLayout
    ) {
        guard canvasSize.width.isFinite,
              canvasSize.height.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0 else { return }

        let currentTime = clock()
        guard currentTime.isFinite, currentTime >= 0 else { return }

        let frames = layout.timeline.visible(at: currentTime)
        debugLogIfNeeded(frameCount: frames.count)

        for frame in frames {
            guard frame.commentIndex >= 0,
                  frame.commentIndex < layout.comments.count,
                  frame.x.isFinite,
                  frame.y.isFinite,
                  frame.width.isFinite,
                  frame.height.isFinite,
                  frame.width > 0,
                  frame.height > 0 else {
                continue
            }

            let comment = layout.comments[frame.commentIndex]
            guard !comment.text.isEmpty else { continue }

            let pointSize = basePointSize(for: comment.size) *
                max(0.1, canvasSize.height / 1080.0)
            guard pointSize.isFinite, pointSize > 0 else { continue }

            let foreground = color(for: comment.colorRGB)
            let resolvedText = context.resolve(
                Text(comment.text)
                    .font(.system(size: pointSize, weight: .regular))
                    .foregroundStyle(foreground)
            )

            let origin = CGPoint(
                x: CGFloat(frame.x),
                y: CGFloat(frame.y)
            )

            // The shadow keeps white and pale broadcast colors readable over
            // bright video while preserving the source color's opacity.
            context.drawLayer { layer in
                layer.addFilter(
                    .shadow(
                        color: .black.opacity(0.86),
                        radius: 2.5,
                        x: 1.0,
                        y: 1.0
                    )
                )
                layer.draw(resolvedText, at: origin, anchor: .topLeading)
            }
        }
    }

    private func basePointSize(for size: PlaybackCommentSize) -> CGFloat {
        switch size {
        case .big:
            return 52
        case .medium:
            return 42
        case .small:
            return 32
        }
    }

    private func color(for rgb: UInt32) -> Color {
        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue).opacity(0.96)
    }

    private func debugLogIfNeeded(frameCount: Int) {
#if DEBUG
        guard frameCount > 0, !debugState.didLogFirstVisible else { return }
        debugState.didLogFirstVisible = true
        print("RingonomiPlaybackCommentsVisible count=\(min(frameCount, 16))")
#else
        _ = frameCount
#endif
    }
}

private struct MetricCacheKey: Hashable {
    let text: String
    let pointSize: Int
}

private struct LayoutInput: Equatable {
    let viewportSize: CGSize
    let comments: [PlaybackComment]
    let top: Double
    let bottom: Double
}

private struct CommentLayout {
    let timeline: RecordedCommentTimeline
    let comments: [PlaybackComment]
}

#if DEBUG
private final class CommentOverlayDebugState {
    var didLogFirstVisible = false
}
#endif
