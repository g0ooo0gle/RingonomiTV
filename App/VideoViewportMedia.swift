import CoreGraphics
import RingonomiCore
import SwiftUI

/// Applies an in-memory viewport crop without changing the identity of the
/// wrapped native video view. The player can therefore keep decoding while
/// the user edits the crop.
struct VideoViewportMedia<Content: View>: View {
    let crop: VideoViewportCrop
    let videoRect: CGRect
    private let content: () -> Content

    init(
        crop: VideoViewportCrop,
        videoRect: CGRect,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.crop = crop
        self.videoRect = videoRect
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let transform = makeTransform(in: geometry.size)
            let scale = CGFloat(transform?.scale ?? 1)
            let offsetX = CGFloat(transform?.offsetX ?? 0)
            let offsetY = CGFloat(transform?.offsetY ?? 0)
            let displayRect = transform.map { cgRect($0.displayRect) } ?? bounds

            // Keep the native view in one stable subtree. Only the transform
            // and mask change as videoRect becomes available or is corrected.
            ZStack(alignment: .topLeading) {
                Color.black
                content()
                    .frame(width: bounds.width, height: bounds.height)
                    .scaleEffect(scale, anchor: .center)
                    .offset(x: offsetX, y: offsetY)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            // The display rect is calculated in the untransformed viewport.
            // Keeping the mask on the outer stack prevents a cropped L-bar
            // from reappearing in a letterboxed side margin.
            .clipShape(VideoViewportDisplayRectShape(rect: displayRect))
        }
        .background(Color.black)
        .clipped()
    }

    private func makeTransform(in size: CGSize) -> VideoViewportTransform? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        let rect = validVideoRect(in: bounds) ?? bounds
        guard
              let viewport = try? VideoViewportSize(
                width: Double(size.width),
                height: Double(size.height)
              ),
              let coreVideoRect = try? VideoViewportRect(
                x: Double(rect.minX),
                y: Double(rect.minY),
                width: Double(rect.width),
                height: Double(rect.height)
              ) else {
            return nil
        }
        return try? VideoViewportTransform(
            crop: crop,
            videoRect: coreVideoRect,
            viewportSize: viewport
        )
    }

    private func validVideoRect(in bounds: CGRect) -> CGRect? {
        guard videoRect.origin.x.isFinite,
              videoRect.origin.y.isFinite,
              videoRect.width.isFinite,
              videoRect.height.isFinite,
              videoRect.width > 0,
              videoRect.height > 0,
              videoRect.minX >= bounds.minX,
              videoRect.minY >= bounds.minY,
              videoRect.maxX.isFinite,
              videoRect.maxY.isFinite,
              videoRect.maxX <= bounds.maxX,
              videoRect.maxY <= bounds.maxY else {
            return nil
        }
        return videoRect
    }

    private func cgRect(_ rect: VideoViewportRect) -> CGRect {
        CGRect(
            x: CGFloat(rect.x),
            y: CGFloat(rect.y),
            width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        )
    }
}

private struct VideoViewportDisplayRectShape: Shape {
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return Path() }
        return Path(clipped)
    }
}
