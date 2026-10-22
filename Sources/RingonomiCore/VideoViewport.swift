import Foundation

/// Validation failures for the in-memory video viewport transform.
public enum VideoViewportError: Error, LocalizedError, Equatable, Sendable {
    case invalidCrop
    case invalidSize
    case invalidVideoRect

    public var errorDescription: String? {
        switch self {
        case .invalidCrop:
            return "映像クロップ範囲が不正です。"
        case .invalidSize:
            return "映像サイズが不正です。"
        case .invalidVideoRect:
            return "映像表示領域が不正です。"
        }
    }
}

/// A positive finite size used by the viewport calculation.
public struct VideoViewportSize: Equatable, Sendable {
    public static let maximumDimension = 1_000_000.0

    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) throws {
        guard Self.isValidDimension(width), Self.isValidDimension(height) else {
            throw VideoViewportError.invalidSize
        }
        self.width = width
        self.height = height
    }

    private static func isValidDimension(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= maximumDimension
    }
}

/// A non-negative rectangle in viewport coordinates.
public struct VideoViewportRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0,
              width.isFinite, height.isFinite,
              width > 0, height > 0,
              width <= VideoViewportSize.maximumDimension,
              height <= VideoViewportSize.maximumDimension else {
            throw VideoViewportError.invalidVideoRect
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    fileprivate init(uncheckedX x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// A normalized crop from the original video frame.
///
/// Each edge is limited to 40% and the remaining width and height must each
/// be at least 50%. This keeps a bad preference from producing a degenerate
/// scale or an overflowing translation.
public struct VideoViewportCrop: Equatable, Sendable {
    public static let maximumEdge = 0.4
    public static let minimumRemainingExtent = 0.5

    public let left: Double
    public let top: Double
    public let right: Double
    public let bottom: Double

    public init(left: Double, top: Double, right: Double, bottom: Double) throws {
        guard Self.isValidEdge(left),
              Self.isValidEdge(top),
              Self.isValidEdge(right),
              Self.isValidEdge(bottom),
              1 - left - right >= Self.minimumRemainingExtent,
              1 - top - bottom >= Self.minimumRemainingExtent else {
            throw VideoViewportError.invalidCrop
        }
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public static let identity = VideoViewportCrop(uncheckedLeft: 0, top: 0, right: 0, bottom: 0)
    public static let leftL = VideoViewportCrop(uncheckedLeft: 0.15, top: 0, right: 0, bottom: 0.15)
    public static let rightL = VideoViewportCrop(uncheckedLeft: 0, top: 0, right: 0.15, bottom: 0.15)
    public static let bottomBar = VideoViewportCrop(uncheckedLeft: 0, top: 0, right: 0, bottom: 0.20)

    private init(uncheckedLeft left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var remainingWidth: Double { 1 - left - right }
    public var remainingHeight: Double { 1 - top - bottom }

    private static func isValidEdge(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= maximumEdge
    }
}

/// Named presets suitable for a tvOS settings or playback menu.
public enum VideoViewportPreset: String, CaseIterable, Sendable {
    case identity
    case leftL
    case rightL
    case bottomBar

    public var crop: VideoViewportCrop {
        switch self {
        case .identity:
            return .identity
        case .leftL:
            return .leftL
        case .rightL:
            return .rightL
        case .bottomBar:
            return .bottomBar
        }
    }
}

/// A mapped point in viewport coordinates.
public struct VideoViewportPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    fileprivate init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The scale and translation shared by the video and caption canvases.
///
/// `scale` is dimensionless and `offsetX`/`offsetY` are the values to pass to
/// a SwiftUI `.scaleEffect(scale, anchor: .center)` followed by
/// `.offset(x:y:)`. The calculation starts with the actual letterboxed
/// `videoRect`, then crops and fits that absolute rectangle into the whole
/// viewport without changing its aspect ratio.
public struct VideoViewportTransform: Equatable, Sendable {
    public let crop: VideoViewportCrop
    public let videoRect: VideoViewportRect
    public let viewportSize: VideoViewportSize
    public let displayRect: VideoViewportRect
    public let scale: Double
    public let offsetX: Double
    public let offsetY: Double

    public init(
        crop: VideoViewportCrop,
        videoRect: VideoViewportRect,
        viewportSize: VideoViewportSize
    ) throws {
        guard videoRect.maxX <= viewportSize.width,
              videoRect.maxY <= viewportSize.height else {
            throw VideoViewportError.invalidVideoRect
        }

        // Identity means preserve the native letterboxed frame exactly.  It
        // must not enlarge a small videoRect merely because the surrounding
        // viewport is larger.
        if crop == .identity {
            self.crop = crop
            self.videoRect = videoRect
            self.viewportSize = viewportSize
            self.displayRect = videoRect
            self.scale = 1
            self.offsetX = 0
            self.offsetY = 0
            return
        }

        let cropX = videoRect.x + crop.left * videoRect.width
        let cropY = videoRect.y + crop.top * videoRect.height
        let cropWidth = crop.remainingWidth * videoRect.width
        let cropHeight = crop.remainingHeight * videoRect.height
        guard cropX.isFinite, cropY.isFinite,
              cropWidth.isFinite, cropHeight.isFinite,
              cropWidth > 0, cropHeight > 0 else {
            throw VideoViewportError.invalidVideoRect
        }
        let scale = min(viewportSize.width / cropWidth, viewportSize.height / cropHeight)
        let fittedWidth = cropWidth * scale
        let fittedHeight = cropHeight * scale
        let displayX = (viewportSize.width - fittedWidth) / 2
        let displayY = (viewportSize.height - fittedHeight) / 2
        let affineTranslationX = displayX - cropX * scale
        let affineTranslationY = displayY - cropY * scale
        let viewportCenterX = viewportSize.width / 2
        let viewportCenterY = viewportSize.height / 2
        let offsetX = affineTranslationX + (scale - 1) * viewportCenterX
        let offsetY = affineTranslationY + (scale - 1) * viewportCenterY

        guard scale.isFinite, scale > 0,
              fittedWidth.isFinite, fittedHeight.isFinite,
              fittedWidth > 0, fittedHeight > 0,
              displayX.isFinite, displayY.isFinite,
              offsetX.isFinite, offsetY.isFinite else {
            throw VideoViewportError.invalidVideoRect
        }

        self.crop = crop
        self.videoRect = videoRect
        self.viewportSize = viewportSize
        self.displayRect = VideoViewportRect(
            uncheckedX: displayX,
            y: displayY,
            width: fittedWidth,
            height: fittedHeight
        )
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    /// Maps a normalized point from the original video into the viewport.
    /// Points outside the selected crop return nil because they are clipped.
    public func mapSourcePoint(x: Double, y: Double) -> VideoViewportPoint? {
        guard x.isFinite, y.isFinite,
              x >= crop.left, x <= 1 - crop.right,
              y >= crop.top, y <= 1 - crop.bottom else {
            return nil
        }
        let sourceX = videoRect.x + x * videoRect.width
        let sourceY = videoRect.y + y * videoRect.height
        let mappedX = viewportSize.width / 2 +
            (sourceX - viewportSize.width / 2) * scale + offsetX
        let mappedY = viewportSize.height / 2 +
            (sourceY - viewportSize.height / 2) * scale + offsetY
        guard mappedX.isFinite, mappedY.isFinite else { return nil }
        return VideoViewportPoint(x: mappedX, y: mappedY)
    }
}
