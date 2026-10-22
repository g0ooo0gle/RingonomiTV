import XCTest
@testable import RingonomiCore

final class VideoViewportTests: XCTestCase {
    private func size(_ width: Double, _ height: Double) throws -> VideoViewportSize {
        try VideoViewportSize(width: width, height: height)
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) throws -> VideoViewportRect {
        try VideoViewportRect(x: x, y: y, width: width, height: height)
    }

    func testIdentity16By9MapsVideoAndCaptionCoordinatesWithoutDistortion() throws {
        let transform = try VideoViewportTransform(
            crop: .identity,
            videoRect: try rect(0, 0, 1920, 1080),
            viewportSize: try size(1920, 1080)
        )

        XCTAssertEqual(transform.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.offsetX, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.offsetY, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.displayRect, try rect(0, 0, 1920, 1080))
        let center = try XCTUnwrap(transform.mapSourcePoint(x: 0.5, y: 0.5))
        XCTAssertEqual(center.x, 960, accuracy: 0.0001)
        XCTAssertEqual(center.y, 540, accuracy: 0.0001)
    }

    func testLetterboxedFourByThreeVideoUsesActualVideoRect() throws {
        let transform = try VideoViewportTransform(
            crop: .identity,
            videoRect: try rect(240, 0, 1440, 1080),
            viewportSize: try size(1920, 1080)
        )

        XCTAssertEqual(transform.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.offsetX, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.offsetY, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.displayRect, try rect(240, 0, 1440, 1080))
        let center = try XCTUnwrap(transform.mapSourcePoint(x: 0.5, y: 0.5))
        XCTAssertEqual(center.x, 960, accuracy: 0.0001)
        XCTAssertEqual(center.y, 540, accuracy: 0.0001)
    }

    func testIdentityPreservesAnOffCenterSmallerVideoRect() throws {
        let videoRect = try rect(10, 20, 1000, 500)
        let transform = try VideoViewportTransform(
            crop: .identity,
            videoRect: videoRect,
            viewportSize: try size(1920, 1080)
        )

        XCTAssertEqual(transform.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.offsetX, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.offsetY, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.displayRect, videoRect)
        let center = try XCTUnwrap(transform.mapSourcePoint(x: 0.5, y: 0.5))
        XCTAssertEqual(center.x, 510, accuracy: 0.0001)
        XCTAssertEqual(center.y, 270, accuracy: 0.0001)
    }

    func testLeftAndRightLShapesFitWithAspectPreservedAndKeepCaptionTransform() throws {
        let left = try VideoViewportTransform(
            crop: .leftL,
            videoRect: try rect(0, 0, 1920, 1080),
            viewportSize: try size(1920, 1080)
        )
        XCTAssertEqual(left.displayRect.width / left.displayRect.height,
                       1920.0 / 1080.0,
                       accuracy: 0.0001)
        XCTAssertEqual(left.scale, 1.0 / 0.85, accuracy: 0.0001)
        XCTAssertEqual(left.displayRect, try rect(0, 0, 1920, 1080))
        XCTAssertEqual(left.offsetX, -169.4117647, accuracy: 0.0001)
        XCTAssertEqual(left.offsetY, 95.2941176, accuracy: 0.0001)
        XCTAssertNil(left.mapSourcePoint(x: 0.05, y: 0.5))
        let leftCaption = try XCTUnwrap(left.mapSourcePoint(x: 0.5, y: 0.5))
        XCTAssertTrue(leftCaption.x > 0 && leftCaption.x < 1920)

        let right = try VideoViewportTransform(
            crop: .rightL,
            videoRect: try rect(0, 0, 1920, 1080),
            viewportSize: try size(1920, 1080)
        )
        XCTAssertEqual(right.displayRect, try rect(0, 0, 1920, 1080))
        XCTAssertEqual(right.offsetX, 169.4117647, accuracy: 0.0001)
        XCTAssertEqual(right.offsetY, 95.2941176, accuracy: 0.0001)
        XCTAssertNil(right.mapSourcePoint(x: 0.95, y: 0.5))
        XCTAssertNotNil(right.mapSourcePoint(x: 0.5, y: 0.5))
    }

    func testFourByThreeLetterboxWithLeftLUsesViewportFitAndSwiftUIOffsets() throws {
        let transform = try VideoViewportTransform(
            crop: .leftL,
            videoRect: try rect(240, 0, 1440, 1080),
            viewportSize: try size(1920, 1080)
        )

        XCTAssertEqual(transform.scale, 1.0 / 0.85, accuracy: 0.0001)
        XCTAssertEqual(transform.displayRect, try rect(240, 0, 1440, 1080))
        XCTAssertEqual(transform.offsetX, -127.0588235, accuracy: 0.0001)
        XCTAssertEqual(transform.offsetY, 95.2941176, accuracy: 0.0001)
        let center = try XCTUnwrap(transform.mapSourcePoint(x: 0.575, y: 0.425))
        XCTAssertEqual(center.x, 960, accuracy: 0.0001)
        XCTAssertEqual(center.y, 540, accuracy: 0.0001)
    }

    func testPresetListAndBottomBarAreStable() throws {
        XCTAssertEqual(VideoViewportPreset.allCases.count, 4)
        XCTAssertEqual(VideoViewportPreset.identity.crop, .identity)
        let transform = try VideoViewportTransform(
            crop: .bottomBar,
            videoRect: try rect(0, 0, 1280, 720),
            viewportSize: try size(1280, 720)
        )
        XCTAssertLessThan(transform.displayRect.height, 720)
        XCTAssertNil(transform.mapSourcePoint(x: 0.5, y: 0.95))
    }

    func testInvalidCropSizesAndOutOfBoundsVideoRectAreRejected() throws {
        XCTAssertThrowsError(try VideoViewportCrop(left: -0.01, top: 0, right: 0, bottom: 0))
        XCTAssertThrowsError(try VideoViewportCrop(left: 0.41, top: 0, right: 0, bottom: 0))
        XCTAssertThrowsError(try VideoViewportCrop(left: 0.3, top: 0, right: 0.3, bottom: 0))
        XCTAssertThrowsError(try VideoViewportCrop(left: 0, top: 0.3, right: 0, bottom: 0.3))
        XCTAssertThrowsError(try VideoViewportCrop(left: .nan, top: 0, right: 0, bottom: 0))

        XCTAssertThrowsError(try VideoViewportSize(width: 0, height: 1080))
        XCTAssertThrowsError(try VideoViewportSize(width: .infinity, height: 1080))
        XCTAssertThrowsError(try VideoViewportSize(width: Double.greatestFiniteMagnitude, height: 1080))
        XCTAssertThrowsError(try VideoViewportRect(x: -1, y: 0, width: 1920, height: 1080))
        XCTAssertThrowsError(try VideoViewportRect(x: 0, y: 0, width: 0, height: 1080))
        XCTAssertThrowsError(try VideoViewportRect(x: 0, y: 0, width: .infinity, height: 1080))
        XCTAssertThrowsError(try VideoViewportTransform(
            crop: .identity,
            videoRect: try rect(100, 0, 1920, 1080),
            viewportSize: try size(1920, 1080)
        ))

        let tinyRect = try rect(.leastNonzeroMagnitude, 0, .leastNonzeroMagnitude, 1)
        XCTAssertThrowsError(try VideoViewportTransform(
            crop: try VideoViewportCrop(left: 0.4, top: 0, right: 0.1, bottom: 0),
            videoRect: tinyRect,
            viewportSize: try size(1920, 1080)
        ))
    }
}
