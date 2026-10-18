import XCTest
@testable import RingonomiCore

final class RecordingResumeTests: XCTestCase {
    func testIdentityNormalizesServerAndKeepsEndpointOutOfBookmarkPayload() throws {
        let firstURL = try XCTUnwrap(URL(string: "HTTPS://TV.Example:443/proxy///?temporary=1#fragment"))
        let secondURL = try XCTUnwrap(URL(string: "https://tv.example/proxy"))
        let first = RecordingResumeID(
            serverURL: firstURL,
            videoID: 42,
            recordingStartTime: " 2026-10-18T12:00:00+09:00 "
        )
        let second = RecordingResumeID(
            serverURL: secondURL,
            videoID: 42,
            recordingStartTime: "2026-10-18T12:00:00+09:00"
        )

        XCTAssertEqual(first.serverKey, second.serverKey)
        XCTAssertEqual(first.storageKey, second.storageKey)
        XCTAssertEqual(first.startTime, "2026-10-18T12:00:00+09:00")
        XCTAssertEqual(first.recordedVideoID, 42)

        let payload = try XCTUnwrap(String(data: JSONEncoder().encode(first), encoding: .utf8))
        XCTAssertFalse(payload.contains("tv.example"))
        XCTAssertFalse(payload.contains("/proxy"))
    }

    func testDifferentServerPathVideoOrStartTimeCannotShareStorageKey() throws {
        let base = try XCTUnwrap(URL(string: "https://tv.example/proxy"))
        let otherPath = try XCTUnwrap(URL(string: "https://tv.example/other"))
        let first = RecordingResumeID(serverURL: base, videoID: 42, recordingStartTime: "start-a")
        let otherPathID = RecordingResumeID(serverURL: otherPath, videoID: 42, recordingStartTime: "start-a")
        let otherVideo = RecordingResumeID(serverURL: base, videoID: 43, recordingStartTime: "start-a")
        let otherStart = RecordingResumeID(serverURL: base, videoID: 42, recordingStartTime: "start-b")
        let noStart = RecordingResumeID(serverURL: base, videoID: 42, recordingStartTime: nil)
        let otherServer = RecordingResumeID(serverURL: try XCTUnwrap(URL(string: "https://other.example/proxy")),
                                            videoID: 42, recordingStartTime: "start-a")
        let otherPort = RecordingResumeID(serverURL: try XCTUnwrap(URL(string: "https://tv.example:7000/proxy")),
                                          videoID: 42, recordingStartTime: "start-a")
        let otherScheme = RecordingResumeID(serverURL: try XCTUnwrap(URL(string: "http://tv.example/proxy")),
                                            videoID: 42, recordingStartTime: "start-a")

        XCTAssertNotEqual(first.storageKey, otherPathID.storageKey)
        XCTAssertNotEqual(first.storageKey, otherVideo.storageKey)
        XCTAssertNotEqual(first.storageKey, otherStart.storageKey)
        XCTAssertNotEqual(first.storageKey, noStart.storageKey)
        XCTAssertNotEqual(first.storageKey, otherServer.storageKey)
        XCTAssertNotEqual(first.storageKey, otherPort.storageKey)
        XCTAssertNotEqual(first.storageKey, otherScheme.storageKey)
    }

    func testClampRejectsInvalidValuesAndAvoidsSeekingExactlyAtEnd() {
        XCTAssertEqual(RecordingResumePolicy.clamp(seconds: 12, duration: 100), 12)
        XCTAssertEqual(RecordingResumePolicy.clamp(seconds: 1_000, duration: 100)!, 99.75, accuracy: 0.0001)
        XCTAssertEqual(RecordingResumePolicy.clamp(seconds: 10, duration: nil), 10)
        XCTAssertEqual(RecordingResumePolicy.clamp(seconds: 10, duration: 0), 10)
        XCTAssertEqual(RecordingResumePolicy.clamp(seconds: 10, duration: .infinity), 10)
        XCTAssertEqual(RecordingResumePolicy.clamp(seconds: 10, duration: 0.1), 0)
        XCTAssertNil(RecordingResumePolicy.clamp(seconds: -1, duration: 100))
        XCTAssertNil(RecordingResumePolicy.clamp(seconds: .nan, duration: 100))
        XCTAssertNil(RecordingResumePolicy.clamp(seconds: .infinity, duration: 100))
    }

    func testCandidateRequiresFiveSecondsAndHonorsRecordedNearEnd() {
        let short = RecordingResumeEntry(seconds: 4.99, updatedAt: Date(timeIntervalSince1970: 1))
        XCTAssertNil(RecordingResumePolicy.candidate(entry: short, duration: 100))

        let meaningful = RecordingResumeEntry(seconds: 5, updatedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(RecordingResumePolicy.candidate(entry: meaningful, duration: 100), 5)

        let nearEnd = RecordingResumeEntry(seconds: 96, updatedAt: Date(timeIntervalSince1970: 1))
        XCTAssertNil(RecordingResumePolicy.candidate(entry: nearEnd, duration: 100, status: "Recorded"))
        XCTAssertEqual(RecordingResumePolicy.candidate(entry: nearEnd, duration: 100, status: "Recording"), 96)
        XCTAssertEqual(RecordingResumePolicy.candidate(entry: nearEnd, duration: 100), 96)
    }

    func testShouldClearRequiresFinalRecordingForNearEndButAllowsAuthoritativeEnd() {
        XCTAssertFalse(RecordingResumePolicy.shouldClear(seconds: 99, duration: 100, status: "Recording", reachedEnd: true))
        XCTAssertTrue(RecordingResumePolicy.shouldClear(seconds: 99, duration: 100, status: "Recorded", reachedEnd: false))
        XCTAssertTrue(RecordingResumePolicy.shouldClear(seconds: 96, duration: 100, status: "Recorded", reachedEnd: false))
        XCTAssertFalse(RecordingResumePolicy.shouldClear(seconds: 94, duration: 100, status: "Recorded", reachedEnd: false))
        XCTAssertFalse(RecordingResumePolicy.shouldClear(seconds: 96, duration: 100, status: nil, reachedEnd: false))
        XCTAssertTrue(RecordingResumePolicy.shouldClear(seconds: 0, duration: nil, status: nil, reachedEnd: true))
        XCTAssertTrue(RecordingResumePolicy.shouldClear(seconds: 0, duration: nil, status: "Recorded", reachedEnd: true))
    }

    func testArchiveRoundTripsAndKeepsNewestTwoHundredEntries() throws {
        let base = Date(timeIntervalSince1970: 0)
        var input: [String: RecordingResumeEntry] = [:]
        for index in 0..<201 {
            input["key-\(index)"] = RecordingResumeEntry(
                seconds: Double(index + 5),
                updatedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }

        let archive = RecordingResumeArchive(entries: input)
        XCTAssertEqual(archive.entries.count, 200)
        XCTAssertNil(archive.entry(for: "key-0"))
        XCTAssertEqual(archive.entry(for: "key-200")?.seconds, 205)

        let data = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(RecordingResumeArchive.self, from: data)
        XCTAssertEqual(decoded, archive)
    }

    func testArchiveSkipsCorruptEntriesWithoutDiscardingValidOnes() throws {
        let data = Data(#"""
        {
          "valid": {"seconds": 42, "updatedAt": 0},
          "negative": {"seconds": -1, "updatedAt": 0},
          "wrongType": {"seconds": "bad", "updatedAt": 0}
        }
        """#.utf8)

        let archive = try JSONDecoder().decode(RecordingResumeArchive.self, from: data)

        XCTAssertEqual(archive.entry(for: "valid")?.seconds, 42)
        XCTAssertNil(archive.entry(for: "negative"))
        XCTAssertNil(archive.entry(for: "wrongType"))
    }

    func testRecordingStartTimeIsOptionalAndDecodesForResumeIdentity() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = Data(#"""
        {
          "id": 7,
          "title": "録画",
          "description": "番組",
          "is_free": true,
          "start_time": "2026-10-18T12:00:00+09:00",
          "recorded_video": {"id": 42, "duration": 75.5}
        }
        """#.utf8)

        let recording = try decoder.decode(Recording.self, from: data)

        XCTAssertEqual(recording.startTime, "2026-10-18T12:00:00+09:00")
    }
}
