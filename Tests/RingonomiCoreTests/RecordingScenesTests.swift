import Foundation
import XCTest
@testable import RingonomiCore

final class RecordingScenesTests: XCTestCase {
    private func metadata(
        imageWidth: Int = 960,
        imageHeight: Int = 540,
        tileWidth: Int = 320,
        tileHeight: Int = 180,
        columns: Int = 3,
        rows: Int = 3,
        interval: Double = 10,
        totalTiles: Int = 9
    ) throws -> RecordingThumbnailTile {
        try RecordingThumbnailTile(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            columnCount: columns,
            rowCount: rows,
            intervalSeconds: interval,
            totalTiles: totalTiles
        )
    }

    func testMetadataMapsSceneTimeToAtlasRectangleAndPagesLazily() throws {
        let timeline = try RecordingSceneTimeline(durationSeconds: 65, metadata: metadata())

        XCTAssertEqual(timeline.sceneCount, 7)
        XCTAssertEqual(timeline.pageCount, 1)
        XCTAssertEqual(timeline.scene(at: 0)?.timeSeconds, 0)
        XCTAssertEqual(timeline.scene(at: 4)?.timeSeconds, 40)
        XCTAssertEqual(timeline.scene(at: 4)?.tileIndex, 4)
        XCTAssertEqual(timeline.scene(at: 4)?.rect, RecordingSceneTileRect(x: 320, y: 180, width: 320, height: 180))
        XCTAssertNil(timeline.scene(at: 7))

        let page = try XCTUnwrap(timeline.page(at: 0, pageSize: 3))
        XCTAssertEqual(page.index, 0)
        XCTAssertEqual(page.pageSize, 3)
        XCTAssertEqual(page.scenes.map(\.id), [0, 1, 2])
        XCTAssertEqual(timeline.pageCount(pageSize: 3), 3)
        XCTAssertEqual(timeline.pageIndex(forSceneIndex: 4, pageSize: 3), 1)
        XCTAssertEqual(timeline.timePoints(interval: 30), [0, 30, 60])
        XCTAssertEqual(timeline.tile(at: 44)?.tileIndex, 4)
    }

    func testCustomSearchIntervalCanReuseOneTileForMultipleSceneTimes() throws {
        let timeline = try RecordingSceneTimeline(
            durationSeconds: 31,
            metadata: try metadata(imageWidth: 400, imageHeight: 200, tileWidth: 100, tileHeight: 100,
                                   columns: 4, rows: 1, interval: 10, totalTiles: 4),
            sceneIntervalSeconds: 5
        )

        XCTAssertEqual(timeline.sceneCount, 7)
        XCTAssertEqual(timeline.scene(at: 1)?.timeSeconds, 5)
        XCTAssertEqual(timeline.scene(at: 1)?.tileIndex, 0)
        XCTAssertEqual(timeline.scene(at: 2)?.timeSeconds, 10)
        XCTAssertEqual(timeline.scene(at: 2)?.tileIndex, 1)
        XCTAssertEqual(timeline.scene(at: 3)?.rect.x, 100)
    }

    func testEOFIsExcludedAndPositionsAreSafelyClamped() throws {
        let timeline = try RecordingSceneTimeline(
            durationSeconds: 10,
            metadata: try metadata(imageWidth: 100, imageHeight: 10, tileWidth: 100, tileHeight: 10,
                                   columns: 1, rows: 1, interval: 10, totalTiles: 1)
        )

        XCTAssertEqual(timeline.sceneCount, 1)
        let last = try XCTUnwrap(timeline.scene(at: 0))
        XCTAssertLessThan(last.timeSeconds, 10)
        XCTAssertNil(timeline.scene(atOrBefore: Double.nan))
        XCTAssertEqual(timeline.scene(atOrBefore: -10)?.id, 0)
        XCTAssertEqual(timeline.nearestScene(to: 10)?.id, 0)
    }

    func testSnakeAndCamelMetadataDecodeAndRoundTrip() throws {
        let snake = Data(
            #"{"image_width":400,"image_height":200,"tile_width":100,"tile_height":100,"column_count":4,"row_count":1,"interval_sec":10,"total_tiles":4}"#.utf8
        )
        let decoded = try JSONDecoder().decode(RecordingThumbnailTile.self, from: snake)
        XCTAssertEqual(decoded, try metadata(imageWidth: 400, imageHeight: 200, tileWidth: 100, tileHeight: 100,
                                             columns: 4, rows: 1, interval: 10, totalTiles: 4))

        let convertedDecoder = JSONDecoder()
        convertedDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let converted = try convertedDecoder.decode(RecordingThumbnailTile.self, from: snake)
        XCTAssertEqual(converted, decoded)

        let encoded = try JSONEncoder().encode(decoded)
        let restored = try JSONDecoder().decode(RecordingThumbnailTile.self, from: encoded)
        XCTAssertEqual(restored, decoded)

        let infoData = Data(
            #"{"version":1,"tile":{"imageWidth":400,"imageHeight":200,"tileWidth":100,"tileHeight":100,"columnCount":4,"rowCount":1,"intervalSeconds":10,"totalTiles":4}}"#.utf8
        )
        let info = try JSONDecoder().decode(RecordingThumbnailInfo.self, from: infoData)
        XCTAssertEqual(info.version, 1)
        XCTAssertEqual(info.tile, decoded)
        XCTAssertThrowsError(try RecordingThumbnailInfo(version: 2, tile: decoded))
        XCTAssertNoThrow(try RecordingThumbnailInfo(version: 1, tile: nil))
    }

    func testRecordingDecodesSnakeCaseScenesAndIgnoresInvalidOptionalAtlas() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let valid = #"{"id":17,"title":"番組","description":"説明","is_free":true,"recorded_video":{"id":42,"duration":75.5,"thumbnail_info":{"version":1,"tile":{"image_width":400,"image_height":200,"tile_width":100,"tile_height":100,"column_count":4,"row_count":1,"interval_sec":10,"total_tiles":4}}}}"#
        let recording = try decoder.decode(Recording.self, from: Data(valid.utf8))
        XCTAssertEqual(recording.id, 17)
        XCTAssertEqual(recording.recordedVideo.id, 42)
        XCTAssertEqual(recording.recordedVideo.thumbnailInfo?.tile?.intervalSeconds, 10)
        XCTAssertEqual(recording.recordedVideo.thumbnailInfo?.tile?.totalTiles, 4)
        let invalid = valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":999")
        let playable = try decoder.decode(Recording.self, from: Data(invalid.utf8))
        XCTAssertEqual(playable.id, 17)
        XCTAssertNil(playable.recordedVideo.thumbnailInfo)
    }

    func testInvalidMetadataAndOverflowAreRejected() {
        let invalidValues: [(Int, Int, Int, Int, Int, Int, Double, Int)] = [
            (0, 180, 320, 180, 1, 1, 10, 1),
            (320, 180, 321, 180, 1, 1, 10, 1),
            (320, 180, 320, 180, 2, 1, 10, 3),
            (320, 180, 320, 180, 1, 1, 0, 1),
            (320, 180, 320, 180, 1, 1, 10, 0),
            (16_384, 16_384, 1, 1, 512, 512, 10, 100_000)
        ]
        for values in invalidValues {
            XCTAssertThrowsError(try RecordingThumbnailTile(
                imageWidth: values.0, imageHeight: values.1,
                tileWidth: values.2, tileHeight: values.3,
                columnCount: values.4, rowCount: values.5,
                intervalSeconds: values.6, totalTiles: values.7
            ))
        }
        XCTAssertThrowsError(try RecordingThumbnailTile(
            imageWidth: Int.max, imageHeight: 1, tileWidth: 1, tileHeight: 1,
            columnCount: 1, rowCount: 1, intervalSeconds: 1, totalTiles: 1
        ))
    }

    func testInvalidDurationIntervalAndPageInputsAreSafe() throws {
        let valid = try metadata()
        XCTAssertThrowsError(try RecordingSceneTimeline(durationSeconds: 0, metadata: valid)) { error in
            XCTAssertEqual(error as? RecordingSceneError, .invalidDuration)
        }
        XCTAssertThrowsError(try RecordingSceneTimeline(durationSeconds: .infinity, metadata: valid)) { error in
            XCTAssertEqual(error as? RecordingSceneError, .invalidDuration)
        }
        XCTAssertThrowsError(try RecordingSceneTimeline(durationSeconds: 10, metadata: valid, sceneIntervalSeconds: .nan)) { error in
            XCTAssertEqual(error as? RecordingSceneError, .invalidInterval)
        }

        let timeline = try RecordingSceneTimeline(durationSeconds: 65, metadata: valid)
        XCTAssertNil(timeline.page(at: -1))
        XCTAssertNil(timeline.page(at: 0, pageSize: 0))
        XCTAssertNil(timeline.page(at: 0, pageSize: RecordingSceneTimeline.maximumPageSize + 1))
        XCTAssertEqual(timeline.pageCount(pageSize: 0), 0)
        XCTAssertNil(timeline.pageIndex(forSceneIndex: timeline.sceneCount, pageSize: 3))
        XCTAssertEqual(timeline.timePoints(interval: 0), [])
        XCTAssertEqual(timeline.timePoints(interval: .infinity), [])
        XCTAssertThrowsError(try RecordingSceneTimeline(
            durationSeconds: 65,
            thumbnailInfo: try RecordingThumbnailInfo(version: 1, tile: nil)
        )) { error in
            XCTAssertEqual(error as? RecordingSceneError, .invalidMetadata)
        }
    }

    func testTileUsesNativeMetadataIntervalAndSubnormalIntervalDoesNotTrap() throws {
        let timeline = try RecordingSceneTimeline(durationSeconds: 65, metadata: metadata())
        XCTAssertEqual(timeline.tile(at: 44)?.tileIndex, 4)
        XCTAssertEqual(timeline.tile(at: 44)?.timeSeconds, 40)
        XCTAssertEqual(timeline.tile(at: 10)?.tileIndex, 1)
        XCTAssertEqual(timeline.tile(at: -2)?.tileIndex, 0)
        XCTAssertEqual(timeline.tile(at: 100)?.tileIndex, 6)

        let singleTile = try metadata(imageWidth: 100, imageHeight: 10, tileWidth: 100, tileHeight: 10,
                                      columns: 1, rows: 1, interval: 1, totalTiles: 1)
        let tinyInterval = try RecordingSceneTimeline(
            durationSeconds: 10,
            metadata: singleTile,
            sceneIntervalSeconds: Double.leastNonzeroMagnitude
        )
        XCTAssertEqual(tinyInterval.scene(atOrBefore: 10)?.id, 0)
        XCTAssertEqual(tinyInterval.nearestScene(to: 10)?.id, 0)
    }

    func testExcessiveSceneCountIsRejectedBeforeLargeAllocation() throws {
        let metadata = try RecordingThumbnailTile(
            imageWidth: 181, imageHeight: 181, tileWidth: 1, tileHeight: 1,
            columnCount: 181, rowCount: 181, intervalSeconds: 1, totalTiles: 32_761
        )
        XCTAssertThrowsError(try RecordingSceneTimeline(
            durationSeconds: RecordingSceneTimeline.maximumDurationSeconds,
            metadata: metadata,
            sceneIntervalSeconds: 0.01
        )) { error in
            XCTAssertEqual(error as? RecordingSceneError, .tooManyScenes)
        }
    }
}
