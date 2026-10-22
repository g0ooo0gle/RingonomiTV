import CoreGraphics
import SwiftUI

/// Displays native ARIB caption images inside the video's aspect-fitted rect.
/// The overlay never takes focus or touches the playback controller.
struct RecordingCaptionOverlay: View {
    @ObservedObject private var controller: RecordingCaptionController
    let videoRect: CGRect
    let isVisible: Bool

    init(
        controller: RecordingCaptionController,
        videoRect: CGRect,
        isVisible: Bool
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        self.videoRect = videoRect
        self.isVisible = isVisible
    }

    var body: some View {
        ARIBCaptionImagesOverlay(images: controller.images, videoRect: videoRect, isVisible: isVisible)
    }
}

struct ARIBCaptionImagesOverlay: View {
    let images: [ARIBCaptionImage]
    let videoRect: CGRect
    let isVisible: Bool

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let rect = validVideoRect(in: bounds)
            if isVisible, let rect {
                ZStack(alignment: .topLeading) {
                    ForEach(images) { caption in
                        captionView(caption, in: CGRect(origin: .zero, size: rect.size))
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .clipped()
                .position(x: rect.midX, y: rect.midY)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func validVideoRect(in bounds: CGRect) -> CGRect? {
        guard videoRect.origin.x.isFinite,
              videoRect.origin.y.isFinite,
              videoRect.width.isFinite,
              videoRect.height.isFinite,
              videoRect.width > 0,
              videoRect.height > 0 else {
            return nil
        }
        let intersection = videoRect.intersection(bounds)
        guard !intersection.isNull, !intersection.isEmpty else {
            return nil
        }
        // Keep the original canvas mapping when a layer is briefly outside
        // its parent during a transition; the outer stack still clips it.
        return videoRect
    }

    @ViewBuilder
    private func captionView(
        _ caption: ARIBCaptionImage,
        in rect: CGRect
    ) -> some View {
        let canvasWidth = CGFloat(caption.canvasWidth)
        let canvasHeight = CGFloat(caption.canvasHeight)
        let imageWidth = CGFloat(caption.image.width)
        let imageHeight = CGFloat(caption.image.height)
        let scaleX = rect.width / canvasWidth
        let scaleY = rect.height / canvasHeight
        let width = imageWidth * scaleX
        let height = imageHeight * scaleY
        let x = rect.minX + CGFloat(caption.x) * scaleX + width / 2
        let y = rect.minY + CGFloat(caption.y) * scaleY + height / 2

        if canvasWidth.isFinite, canvasHeight.isFinite,
           canvasWidth > 0, canvasHeight > 0,
           imageWidth.isFinite, imageHeight.isFinite,
           imageWidth > 0, imageHeight > 0,
           scaleX.isFinite, scaleY.isFinite,
           width.isFinite, height.isFinite,
           width > 0, height > 0,
           x.isFinite, y.isFinite {
            Image(decorative: caption.image, scale: 1.0)
                .resizable()
                .frame(width: width, height: height)
                .position(x: x, y: y)
        } else {
            EmptyView()
        }
    }
}
