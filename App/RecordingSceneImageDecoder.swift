import CoreGraphics
import Foundation
import ImageIO
import RingonomiCore

/// Errors returned while decoding a server-generated recording-scene atlas.
///
/// The messages intentionally describe only the local validation failure. No
/// URL, server name, or image content is included in an error.
enum RecordingSceneImageDecoderError: Error, LocalizedError, Equatable, Sendable {
    case emptyData
    case dataTooLarge
    case invalidExpectedDimensions
    case invalidImage
    case unsupportedFormat
    case multipleFrames
    case invalidMetadata
    case unsupportedOrientation
    case metadataMismatch
    case sourceImageTooLarge
    case decodeFailed
    case invalidCropSource
    case cropOutOfBounds
    case emptyCrop
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .emptyData:
            return "録画シーン画像が空です。"
        case .dataTooLarge:
            return "録画シーン画像のサイズが上限を超えています。"
        case .invalidExpectedDimensions:
            return "録画シーン画像の指定サイズが不正です。"
        case .invalidImage:
            return "録画シーン画像を読み取れません。"
        case .unsupportedFormat:
            return "録画シーン画像の形式に対応していません。"
        case .multipleFrames:
            return "アニメーション画像には対応していません。"
        case .invalidMetadata:
            return "録画シーン画像のメタデータが不正です。"
        case .unsupportedOrientation:
            return "録画シーン画像の向き情報に対応していません。"
        case .metadataMismatch:
            return "録画シーン画像のサイズがシーン情報と一致しません。"
        case .sourceImageTooLarge:
            return "録画シーン画像の画素数が上限を超えています。"
        case .decodeFailed:
            return "録画シーン画像をデコードできません。"
        case .invalidCropSource:
            return "録画シーン画像の切り出し元サイズが不正です。"
        case .cropOutOfBounds:
            return "録画シーン画像の切り出し範囲が不正です。"
        case .emptyCrop:
            return "録画シーン画像の切り出し結果が空です。"
        case .cropFailed:
            return "録画シーン画像を切り出せません。"
        }
    }
}

/// Bounded ImageIO decoding for tiled recording-scene images.
///
/// This type has no MainActor isolation. Decode it from a worker task or
/// serial image queue, then transfer the result through the caller's
/// immutable image wrapper when crossing actor boundaries. The decoder never
/// creates the full-size image with `CGImageSourceCreateImageAtIndex`.
enum RecordingSceneImageDecoder {
    static let maximumDataBytes = 16 * 1024 * 1024
    static let maximumSourceSide = 16_384
    static let maximumSourcePixels = 268_435_456
    static let maximumDecodedPixels = 4_000_000

    // Leave room for ImageIO rounding before the post-decode 4M-pixel check.
    private static let decodedPixelMargin = 65_536

    private static let supportedTypeIdentifiers: Set<String> = [
        "public.png",
        "public.jpeg",
        "org.webmproject.webp",
        "public.webp"
    ]

    /// Creates a bounded thumbnail after validating the encoded image.
    ///
    /// `expectedWidth` and `expectedHeight` are the atlas dimensions from the
    /// trusted, separately validated scene metadata. ImageIO metadata must
    /// match them exactly before decoding proceeds.
    static func decode(
        data: Data,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws -> CGImage {
        guard !data.isEmpty else { throw RecordingSceneImageDecoderError.emptyData }
        guard data.count <= maximumDataBytes else {
            throw RecordingSceneImageDecoderError.dataTooLarge
        }
        guard isValidSourceSize(width: expectedWidth, height: expectedHeight) else {
            throw RecordingSceneImageDecoderError.invalidExpectedDimensions
        }

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else {
            throw RecordingSceneImageDecoderError.invalidImage
        }

        guard let sourceType = CGImageSourceGetType(source) else {
            throw RecordingSceneImageDecoderError.invalidImage
        }
        let typeIdentifier = sourceType as String
        guard supportedTypeIdentifiers.contains(typeIdentifier) else {
            throw RecordingSceneImageDecoderError.unsupportedFormat
        }

        guard CGImageSourceGetCount(source) == 1 else {
            throw RecordingSceneImageDecoderError.multipleFrames
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as NSDictionary? else {
            throw RecordingSceneImageDecoderError.invalidMetadata
        }
        guard let imageWidth = integerProperty(properties, key: kCGImagePropertyPixelWidth),
              let imageHeight = integerProperty(properties, key: kCGImagePropertyPixelHeight),
              isValidSourceSize(width: imageWidth, height: imageHeight) else {
            throw RecordingSceneImageDecoderError.invalidMetadata
        }
        guard imageWidth == expectedWidth, imageHeight == expectedHeight else {
            throw RecordingSceneImageDecoderError.metadataMismatch
        }

        guard orientationIsSupported(in: properties) else {
            throw RecordingSceneImageDecoderError.unsupportedOrientation
        }

        let thumbnailMaximumPixelSize = thumbnailPixelSize(
            sourceWidth: imageWidth,
            sourceHeight: imageHeight
        )
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw RecordingSceneImageDecoderError.decodeFailed
        }

        guard image.width > 0, image.height > 0,
              let pixelCount = safePixelCount(width: image.width, height: image.height),
              pixelCount <= maximumDecodedPixels else {
            throw RecordingSceneImageDecoderError.sourceImageTooLarge
        }
        return image
    }

    /// Crops one source-coordinate tile from the scaled ImageIO thumbnail.
    ///
    /// The source rectangle is converted independently on each axis, then
    /// rounded inward to integer coordinates before calling CoreGraphics. This
    /// keeps fractional-scale rounding deterministic and prevents a crop from
    /// leaking pixels from an adjacent tile.
    static func crop(
        image: CGImage,
        sourceRect: RecordingSceneTileRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) throws -> CGImage {
        guard isValidSourceSize(width: sourceWidth, height: sourceHeight),
              let decodedPixels = safePixelCount(width: image.width, height: image.height),
              decodedPixels <= maximumDecodedPixels else {
            throw RecordingSceneImageDecoderError.invalidCropSource
        }
        guard sourceRect.x >= 0, sourceRect.y >= 0,
              sourceRect.width > 0, sourceRect.height > 0,
              sourceRect.x <= sourceWidth - sourceRect.width,
              sourceRect.y <= sourceHeight - sourceRect.height else {
            throw RecordingSceneImageDecoderError.cropOutOfBounds
        }

        let scaleX = CGFloat(image.width) / CGFloat(sourceWidth)
        let scaleY = CGFloat(image.height) / CGFloat(sourceHeight)
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            throw RecordingSceneImageDecoderError.invalidCropSource
        }

        // CGRect.integral rounds outward. At a tile boundary that can admit a
        // pixel from the neighboring tile, so use an inner integer rectangle:
        // ceil the minimum and floor the maximum. Clamp the maxima to absorb
        // harmless floating-point error on the final row or column.
        let rawMinX = CGFloat(sourceRect.x) * scaleX
        let rawMinY = CGFloat(sourceRect.y) * scaleY
        let rawMaxX = CGFloat(sourceRect.x + sourceRect.width) * scaleX
        let rawMaxY = CGFloat(sourceRect.y + sourceRect.height) * scaleY
        let boundedMinX = max(0, min(CGFloat(image.width), rawMinX))
        let boundedMinY = max(0, min(CGFloat(image.height), rawMinY))
        let boundedMaxX = max(0, min(CGFloat(image.width), rawMaxX))
        let boundedMaxY = max(0, min(CGFloat(image.height), rawMaxY))
        let minX = ceil(boundedMinX)
        let minY = ceil(boundedMinY)
        let maxX = floor(boundedMaxX)
        let maxY = floor(boundedMaxY)
        let scaledRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        guard minX >= 0, minY >= 0,
              maxX <= CGFloat(image.width),
              maxY <= CGFloat(image.height) else {
            throw RecordingSceneImageDecoderError.cropOutOfBounds
        }
        guard !scaledRect.isNull, !scaledRect.isEmpty,
              scaledRect.width >= 1, scaledRect.height >= 1 else {
            throw RecordingSceneImageDecoderError.emptyCrop
        }
        guard let cropped = image.cropping(to: scaledRect) else {
            throw RecordingSceneImageDecoderError.cropFailed
        }
        guard cropped.width > 0, cropped.height > 0 else {
            throw RecordingSceneImageDecoderError.emptyCrop
        }
        return cropped
    }

    private static func isValidSourceSize(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maximumSourceSide, height <= maximumSourceSide else {
            return false
        }
        return safePixelCount(width: width, height: height) != nil
    }

    private static func safePixelCount(width: Int, height: Int) -> Int? {
        let (pixels, overflowed) = width.multipliedReportingOverflow(by: height)
        guard !overflowed, pixels > 0, pixels <= maximumSourcePixels else { return nil }
        return pixels
    }

    private static func integerProperty(_ properties: NSDictionary, key: CFString) -> Int? {
        guard let number = properties[key] as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
              value >= 1, value <= Double(maximumSourceSide) else { return nil }
        return Int(value)
    }

    private static func thumbnailPixelSize(sourceWidth: Int, sourceHeight: Int) -> Int {
        let sourcePixels = Double(sourceWidth) * Double(sourceHeight)
        guard sourcePixels.isFinite, sourcePixels > 0 else { return 1 }
        let availablePixels = max(1, maximumDecodedPixels - decodedPixelMargin)
        let scale = min(1, sqrt(Double(availablePixels) / sourcePixels))
        let longSide = Double(max(sourceWidth, sourceHeight))
        let result = Int(floor(longSide * scale))
        return max(1, result)
    }

    private static func orientationIsSupported(in properties: NSDictionary) -> Bool {
        if properties.object(forKey: kCGImagePropertyOrientation) != nil,
           !isOrientationOne(properties.object(forKey: kCGImagePropertyOrientation)) {
            return false
        }

        for dictionaryKey in [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary] {
            guard let value = properties.object(forKey: dictionaryKey) else { continue }
            guard let nested = value as? NSDictionary else { return false }
            if nested.object(forKey: kCGImagePropertyOrientation) != nil,
               !isOrientationOne(nested.object(forKey: kCGImagePropertyOrientation)) {
                return false
            }
        }
        return true
    }

    private static func isOrientationOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let rawValue = number.doubleValue
        return rawValue.isFinite && rawValue.rounded() == rawValue && rawValue == 1
    }
}
