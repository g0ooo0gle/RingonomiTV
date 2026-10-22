import Foundation

/// Safe validation failures for recording scene-search metadata.
public enum RecordingSceneError: Error, LocalizedError, Equatable, Sendable {
    case invalidMetadata
    case invalidDuration
    case invalidInterval
    case tooManyScenes

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            return "録画シーン情報が不正です。"
        case .invalidDuration:
            return "録画時間が不正です。"
        case .invalidInterval:
            return "シーン間隔が不正です。"
        case .tooManyScenes:
            return "録画シーンが多すぎるため表示できません。"
        }
    }
}

/// The versioned metadata envelope returned with a recorded video's tiled
/// thumbnails.  A missing tile is valid: the server can expose the envelope
/// before thumbnails have been generated.
public struct RecordingThumbnailInfo: Codable, Equatable, Sendable {
    public let version: Int
    public let tile: RecordingThumbnailTile?

    private enum CodingKeys: String, CodingKey {
        case version
        case tile
    }

    public init(version: Int, tile: RecordingThumbnailTile?) throws {
        guard version == 1 else {
            throw RecordingSceneError.invalidMetadata
        }
        self.version = version
        self.tile = tile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            tile: container.decodeIfPresent(RecordingThumbnailTile.self, forKey: .tile)
        )
    }
}

/// Metadata for one server-generated tiled thumbnail sheet.
///
/// This value contains dimensions only. It never decodes or retains the
/// atlas image, which lets the tvOS UI request only the visible page while
/// keeping Apple TV HD memory use bounded.
public struct RecordingThumbnailTile: Codable, Equatable, Sendable {
    public static let maximumImageDimension = 16_384
    public static let maximumImagePixels = 256 * 1024 * 1024
    public static let maximumColumns = 512
    public static let maximumRows = 512
    public static let maximumTiles = 32_768
    public static let maximumIntervalSeconds = 24 * 60 * 60.0

    public let imageWidth: Int
    public let imageHeight: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let columnCount: Int
    public let rowCount: Int
    public let intervalSeconds: Double
    public let totalTiles: Int

    private enum CodingKeys: String, CodingKey {
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case tileWidth = "tile_width"
        case tileHeight = "tile_height"
        case columnCount = "column_count"
        case rowCount = "row_count"
        case intervalSeconds = "interval_sec"
        case totalTiles = "total_tiles"
        case imageWidthCamel = "imageWidth"
        case imageHeightCamel = "imageHeight"
        case tileWidthCamel = "tileWidth"
        case tileHeightCamel = "tileHeight"
        case columnCountCamel = "columnCount"
        case rowCountCamel = "rowCount"
        // JSONDecoder.convertFromSnakeCase maps interval_sec to intervalSec,
        // while a plain decoder sees the original interval_sec key.
        case intervalSecondsNormalized = "intervalSec"
        case intervalSecondsCamel = "intervalSeconds"
        case totalTilesCamel = "totalTiles"
    }

    public init(
        imageWidth: Int,
        imageHeight: Int,
        tileWidth: Int,
        tileHeight: Int,
        columnCount: Int,
        rowCount: Int,
        intervalSeconds: Double,
        totalTiles: Int
    ) throws {
        guard Self.isPositiveDimension(imageWidth),
              Self.isPositiveDimension(imageHeight),
              imageWidth <= Self.maximumImageDimension,
              imageHeight <= Self.maximumImageDimension,
              imageWidth.multipliedReportingOverflow(by: imageHeight).overflow == false,
              imageWidth * imageHeight <= Self.maximumImagePixels,
              Self.isPositiveDimension(tileWidth),
              Self.isPositiveDimension(tileHeight),
              tileWidth <= imageWidth,
              tileHeight <= imageHeight,
              columnCount > 0,
              columnCount <= Self.maximumColumns,
              rowCount > 0,
              rowCount <= Self.maximumRows,
              intervalSeconds.isFinite,
              intervalSeconds > 0,
              intervalSeconds <= Self.maximumIntervalSeconds,
              totalTiles > 0,
              totalTiles <= Self.maximumTiles else {
            throw RecordingSceneError.invalidMetadata
        }

        let (capacity, capacityOverflowed) = columnCount.multipliedReportingOverflow(by: rowCount)
        let (requiredWidth, widthOverflowed) = tileWidth.multipliedReportingOverflow(by: columnCount)
        let (requiredHeight, heightOverflowed) = tileHeight.multipliedReportingOverflow(by: rowCount)
        guard !capacityOverflowed,
              !widthOverflowed,
              !heightOverflowed,
              capacity <= Self.maximumTiles,
              totalTiles <= capacity,
              requiredWidth <= imageWidth,
              requiredHeight <= imageHeight else {
            throw RecordingSceneError.invalidMetadata
        }

        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.columnCount = columnCount
        self.rowCount = rowCount
        self.intervalSeconds = intervalSeconds
        self.totalTiles = totalTiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ snake: CodingKeys, _ camel: CodingKeys) throws -> T {
            if container.contains(snake) {
                return try container.decode(T.self, forKey: snake)
            }
            return try container.decode(T.self, forKey: camel)
        }
        let intervalSeconds: Double
        if container.contains(.intervalSecondsNormalized) {
            intervalSeconds = try container.decode(Double.self, forKey: .intervalSecondsNormalized)
        } else {
            intervalSeconds = try decode(.intervalSeconds, .intervalSecondsCamel)
        }

        try self.init(
            imageWidth: decode(.imageWidth, .imageWidthCamel),
            imageHeight: decode(.imageHeight, .imageHeightCamel),
            tileWidth: decode(.tileWidth, .tileWidthCamel),
            tileHeight: decode(.tileHeight, .tileHeightCamel),
            columnCount: decode(.columnCount, .columnCountCamel),
            rowCount: decode(.rowCount, .rowCountCamel),
            intervalSeconds: intervalSeconds,
            totalTiles: decode(.totalTiles, .totalTilesCamel)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(imageWidth, forKey: .imageWidth)
        try container.encode(imageHeight, forKey: .imageHeight)
        try container.encode(tileWidth, forKey: .tileWidth)
        try container.encode(tileHeight, forKey: .tileHeight)
        try container.encode(columnCount, forKey: .columnCount)
        try container.encode(rowCount, forKey: .rowCount)
        try container.encode(intervalSeconds, forKey: .intervalSeconds)
        try container.encode(totalTiles, forKey: .totalTiles)
    }

    private static func isPositiveDimension(_ value: Int) -> Bool {
        value > 0
    }
}

/// The rectangle occupied by one tile in the server's atlas image.
public struct RecordingSceneTileRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One lazily generated scene-search item. `timeSeconds` is the seek time,
/// while `tileIndex` and `rect` identify the image to crop from the atlas.
public struct RecordingScene: Identifiable, Equatable, Sendable {
    public let id: Int
    public let timeSeconds: Double
    public let tileIndex: Int
    public let rect: RecordingSceneTileRect

    public init(id: Int, timeSeconds: Double, tileIndex: Int, rect: RecordingSceneTileRect) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.tileIndex = tileIndex
        self.rect = rect
    }
}

/// A bounded page of scene-search items. Pages are produced on demand and do
/// not retain the full thumbnail atlas or the complete scene list.
public struct RecordingScenePage: Equatable, Sendable {
    public let index: Int
    public let pageSize: Int
    public let scenes: [RecordingScene]

    public init(index: Int, pageSize: Int, scenes: [RecordingScene]) {
        self.index = index
        self.pageSize = pageSize
        self.scenes = scenes
    }
}

/// Converts recording duration and tile metadata into safe scene times and
/// atlas rectangles without allocating a complete image or scene atlas.
public struct RecordingSceneTimeline: Equatable, Sendable {
    public static let defaultPageSize = 24
    public static let maximumPageSize = 256
    public static let maximumDurationSeconds = 7 * 24 * 60 * 60.0
    public static let maximumSceneIntervalSeconds = 24 * 60 * 60.0
    public static let minimumSeekMarginSeconds = 0.25
    public static let maximumSceneCount = 8_192

    public let durationSeconds: Double
    public let metadata: RecordingThumbnailTile
    public let sceneIntervalSeconds: Double
    public let sceneCount: Int

    private let safeEndSeconds: Double
    private let lastTileTimeSeconds: Double

    public init(
        durationSeconds: Double,
        metadata: RecordingThumbnailTile,
        sceneIntervalSeconds: Double? = nil
    ) throws {
        guard durationSeconds.isFinite,
              durationSeconds > 0,
              durationSeconds <= Self.maximumDurationSeconds else {
            throw RecordingSceneError.invalidDuration
        }
        let interval = sceneIntervalSeconds ?? metadata.intervalSeconds
        guard interval.isFinite,
              interval > 0,
              interval <= Self.maximumSceneIntervalSeconds else {
            throw RecordingSceneError.invalidInterval
        }

        let safeEnd = max(0, durationSeconds - Self.minimumSeekMarginSeconds)
        let lastTileTime = Double(metadata.totalTiles - 1) * metadata.intervalSeconds
        guard lastTileTime.isFinite else { throw RecordingSceneError.invalidMetadata }
        let availableEnd = min(safeEnd, lastTileTime)
        let quotient = availableEnd / interval
        guard quotient.isFinite, quotient >= 0 else {
            throw RecordingSceneError.invalidInterval
        }
        guard quotient < Double(Self.maximumSceneCount) else {
            throw RecordingSceneError.tooManyScenes
        }
        let calculatedCount = Int(floor(quotient)) + 1
        guard calculatedCount > 0, calculatedCount <= Self.maximumSceneCount else {
            throw RecordingSceneError.tooManyScenes
        }

        self.durationSeconds = durationSeconds
        self.metadata = metadata
        self.sceneIntervalSeconds = interval
        self.sceneCount = calculatedCount
        self.safeEndSeconds = safeEnd
        self.lastTileTimeSeconds = lastTileTime
    }

    /// Creates a timeline from the versioned server response.  The envelope
    /// may legitimately omit its tile while thumbnail generation is pending;
    /// callers can then fall back to the ordinary recording controls.
    public init(
        durationSeconds: Double,
        thumbnailInfo: RecordingThumbnailInfo,
        sceneIntervalSeconds: Double? = nil
    ) throws {
        guard let tile = thumbnailInfo.tile else {
            throw RecordingSceneError.invalidMetadata
        }
        try self.init(
            durationSeconds: durationSeconds,
            metadata: tile,
            sceneIntervalSeconds: sceneIntervalSeconds
        )
    }

    public var pageCount: Int {
        pageCount(pageSize: Self.defaultPageSize)
    }

    public func pageCount(pageSize: Int) -> Int {
        guard Self.isValidPageSize(pageSize), sceneCount > 0 else { return 0 }
        return (sceneCount + pageSize - 1) / pageSize
    }

    public func page(at pageIndex: Int, pageSize: Int = Self.defaultPageSize) -> RecordingScenePage? {
        guard Self.isValidPageSize(pageSize), pageIndex >= 0 else { return nil }
        let totalPages = pageCount(pageSize: pageSize)
        guard pageIndex < totalPages else { return nil }
        let start = pageIndex * pageSize
        let end = min(sceneCount, start + pageSize)
        var scenes: [RecordingScene] = []
        scenes.reserveCapacity(end - start)
        for index in start..<end {
            if let scene = scene(at: index) { scenes.append(scene) }
        }
        return RecordingScenePage(index: pageIndex, pageSize: pageSize, scenes: scenes)
    }

    public func pageIndex(forSceneIndex index: Int, pageSize: Int = Self.defaultPageSize) -> Int? {
        guard Self.isValidPageSize(pageSize), (0..<sceneCount).contains(index) else { return nil }
        return index / pageSize
    }

    /// Returns bounded seek positions for a UI sampling interval without
    /// allocating any thumbnail image data.  Invalid or excessively dense
    /// intervals return an empty array so a picker cannot trigger an unsafe
    /// allocation.
    public func timePoints(interval: Double) -> [Double] {
        guard interval.isFinite,
              interval > 0,
              interval <= Self.maximumSceneIntervalSeconds else {
            return []
        }
        let end = min(safeEndSeconds, lastTileTimeSeconds)
        let quotient = end / interval
        guard quotient.isFinite,
              quotient >= 0,
              quotient < Double(Self.maximumSceneCount) else {
            return []
        }
        let count = Int(floor(quotient)) + 1
        guard count > 0, count <= Self.maximumSceneCount else { return [] }
        return (0..<count).compactMap { index in
            let point = Double(index) * interval
            return point.isFinite && point <= end ? point : nil
        }
    }

    public func scene(at index: Int) -> RecordingScene? {
        guard (0..<sceneCount).contains(index) else { return nil }
        let time = Double(index) * sceneIntervalSeconds
        guard time.isFinite, time >= 0, time <= safeEndSeconds else { return nil }
        let rawTileIndex = floor(time / metadata.intervalSeconds)
        guard rawTileIndex.isFinite, rawTileIndex >= 0, rawTileIndex < Double(metadata.totalTiles) else {
            return nil
        }
        let tileIndex = min(metadata.totalTiles - 1, Int(rawTileIndex))
        return makeScene(id: index, timeSeconds: time, tileIndex: tileIndex)
    }

    /// Returns the scene at or before a playback position. Invalid or
    /// negative positions are clamped to the first scene; positions after the
    /// safe end are clamped to the last scene.
    public func scene(atOrBefore seconds: Double) -> RecordingScene? {
        guard seconds.isFinite else { return nil }
        let clamped = min(max(0, seconds), safeEndSeconds)
        let rawIndex = floor(clamped / sceneIntervalSeconds)
        guard rawIndex.isFinite, rawIndex >= 0 else { return scene(at: 0) }
        let boundedIndex = min(Double(sceneCount - 1), rawIndex)
        let index = Int(boundedIndex)
        return scene(at: index)
    }

    /// Returns the closest scene to a playback position without seeking past
    /// the safe end of the recording.
    public func nearestScene(to seconds: Double) -> RecordingScene? {
        guard seconds.isFinite else { return nil }
        let clamped = min(max(0, seconds), safeEndSeconds)
        let rawIndex = (clamped / sceneIntervalSeconds).rounded()
        guard rawIndex.isFinite, rawIndex >= 0 else { return scene(at: 0) }
        let boundedIndex = min(Double(sceneCount - 1), rawIndex)
        let index = Int(boundedIndex)
        return scene(at: index)
    }

    /// Returns the atlas tile associated with a playback position.  This uses
    /// the server's native tile interval, independently of the UI sampling
    /// interval used by `scene(atOrBefore:)` and `timePoints(interval:)`.
    /// Image download and cropping remain an application concern and can
    /// therefore be limited to visible cards.
    public func tile(at seconds: Double) -> RecordingScene? {
        guard seconds.isFinite else { return nil }
        let clamped = min(max(0, seconds), min(safeEndSeconds, lastTileTimeSeconds))
        let rawTileIndex = floor(clamped / metadata.intervalSeconds)
        guard rawTileIndex.isFinite,
              rawTileIndex >= 0,
              rawTileIndex < Double(metadata.totalTiles) else {
            return nil
        }
        let boundedTileIndex = min(Double(metadata.totalTiles - 1), rawTileIndex)
        let tileIndex = Int(boundedTileIndex)
        let tileTime = Double(tileIndex) * metadata.intervalSeconds
        return makeScene(id: tileIndex, timeSeconds: tileTime, tileIndex: tileIndex)
    }

    private func makeScene(id: Int, timeSeconds: Double, tileIndex: Int) -> RecordingScene? {
        guard id >= 0,
              timeSeconds.isFinite,
              timeSeconds >= 0,
              (0..<metadata.totalTiles).contains(tileIndex) else {
            return nil
        }
        let column = tileIndex % metadata.columnCount
        let row = tileIndex / metadata.columnCount
        let x = column * metadata.tileWidth
        let y = row * metadata.tileHeight
        guard x >= 0,
              y >= 0,
              x + metadata.tileWidth <= metadata.imageWidth,
              y + metadata.tileHeight <= metadata.imageHeight else {
            return nil
        }
        return RecordingScene(
            id: id,
            timeSeconds: timeSeconds,
            tileIndex: tileIndex,
            rect: RecordingSceneTileRect(
                x: x,
                y: y,
                width: metadata.tileWidth,
                height: metadata.tileHeight
            )
        )
    }

    private static func isValidPageSize(_ value: Int) -> Bool {
        (1...maximumPageSize).contains(value)
    }
}
