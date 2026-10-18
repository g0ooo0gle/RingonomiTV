import XCTest
@testable import RingonomiCore

final class RecordingMetadataTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func testDecodesPartialRecordingAndRecordedVideoStatus() throws {
        let data = Data(#"""
        {
          "id": 485,
          "title": "ニュース",
          "description": "番組内容",
          "is_free": true,
          "is_partially_recorded": true,
          "recorded_video": {
            "id": 599,
            "duration": 599.93,
            "status": "Recorded"
          }
        }
        """#.utf8)

        let recording = try decoder.decode(Recording.self, from: data)

        XCTAssertEqual(recording.isPartiallyRecorded, true)
        XCTAssertEqual(recording.recordedVideo.status, "Recorded")
    }

    func testMissingRecordingMetadataRemainsCompatible() throws {
        let data = Data(#"""
        {
          "id": 7,
          "title": "録画",
          "description": "番組",
          "is_free": false,
          "recorded_video": {
            "id": 42,
            "duration": 75.5
          }
        }
        """#.utf8)

        let recording = try decoder.decode(Recording.self, from: data)

        XCTAssertNil(recording.isPartiallyRecorded)
        XCTAssertNil(recording.recordedVideo.status)
    }
}
