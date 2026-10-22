import Foundation
import XCTest
@testable import RingonomiCore

final class RecordingBatchLibraryTests: XCTestCase {
    private let firstAddress = "https://EXAMPLE.invalid/proxy/tv/"
    private let otherAddress = "https://other.invalid/proxy/"

    func testRoundTripPreservesOrderAndIsolatesNormalizedServers() throws {
        let firstKey = try RecordingBatchArchive.serverKey(address: firstAddress)
        let sameKey = try RecordingBatchArchive.serverKey(address: "https://example.invalid/proxy/")
        let otherKey = try RecordingBatchArchive.serverKey(address: otherAddress)
        XCTAssertEqual(firstKey, sameKey)
        XCTAssertNotEqual(firstKey, otherKey)

        let first = try RegisteredRecordingBatch(name: "本編 100%", path: #"\\録画\2026"#)
        let second = try RegisteredRecordingBatch(name: "ニュース", path: #"/recordings/朝"#)
        let other = try RegisteredRecordingBatch(name: "別サーバー", path: "/archive")
        var archive = RecordingBatchArchive()
        try archive.upsert(first, serverKey: firstKey)
        try archive.upsert(second, serverKey: sameKey)
        try archive.upsert(other, serverKey: otherKey)

        let restored = try RecordingBatchArchive(data: archive.data())
        XCTAssertEqual(restored.entries(serverKey: firstKey), [first, second])
        XCTAssertEqual(restored.entries(serverKey: otherKey), [other])
        let encoded = try restored.data()
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("example.invalid") == true)
        XCTAssertTrue(String(data: encoded, encoding: .utf8)?.contains("100%") == true)
    }

    func testUpsertReplacesInPlaceAndRemoveIsScopedToServer() throws {
        let firstKey = try RecordingBatchArchive.serverKey(address: firstAddress)
        let otherKey = try RecordingBatchArchive.serverKey(address: otherAddress)
        let id = UUID()
        let first = try RegisteredRecordingBatch(id: id, name: "最初", path: "/one")
        let second = try RegisteredRecordingBatch(name: "二番目", path: "/two")
        let replacement = try RegisteredRecordingBatch(id: id, name: "更新", path: "/updated")
        var archive = RecordingBatchArchive()
        try archive.upsert(first, serverKey: firstKey)
        try archive.upsert(second, serverKey: firstKey)
        try archive.upsert(try RegisteredRecordingBatch(id: id, name: "別側", path: "/other"), serverKey: otherKey)
        try archive.upsert(replacement, serverKey: firstKey)
        XCTAssertEqual(archive.entries(serverKey: firstKey), [replacement, second])
        XCTAssertFalse(try archive.remove(id: id, serverKey: firstKey) == false)
        XCTAssertEqual(archive.entries(serverKey: firstKey), [second])
        XCTAssertEqual(archive.entries(serverKey: otherKey).first?.name, "別側")
    }

    func testTextValidationAllowsPathsAndNamesUsedByRecordings() throws {
        _ = try RegisteredRecordingBatch(name: "日本語 / 100%", path: #"C:\録画\2026 10月"#)
        XCTAssertThrowsError(try RegisteredRecordingBatch(name: " \n ", path: "/valid")) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidName)
        }
        XCTAssertThrowsError(try RegisteredRecordingBatch(name: "valid", path: "/bad\u{0000}path")) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidPath)
        }
        XCTAssertThrowsError(try RegisteredRecordingBatch(name: String(repeating: "a", count: RecordingBatchArchive.maximumNameBytes + 1), path: "/valid")) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidName)
        }
        XCTAssertThrowsError(try RegisteredRecordingBatch(name: "valid", path: String(repeating: "あ", count: RecordingBatchArchive.maximumPathBytes))) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidPath)
        }
    }

    func testMalformedNamespaceVersionAndDuplicateIDsFailClosed() throws {
        let key = String(repeating: "a", count: 64)
        let duplicateID = UUID().uuidString
        let duplicate = Data(#"{"version":1,"servers":[{"key":"\#(key)","entries":[{"id":"\#(duplicateID)","name":"one","path":"/one"},{"id":"\#(duplicateID)","name":"two","path":"/two"}]}]}"#.utf8)
        XCTAssertThrowsError(try RecordingBatchArchive(data: duplicate)) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .duplicateID)
        }

        let duplicateNamespace = Data(#"{"version":1,"servers":[{"key":"\#(key)","entries":[]},{"key":"\#(key.uppercased())","entries":[]}] }"#.utf8)
        XCTAssertThrowsError(try RecordingBatchArchive(data: duplicateNamespace)) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidNamespace)
        }
        XCTAssertThrowsError(try RecordingBatchArchive(data: Data(#"{"version":2,"servers":[]}"#.utf8))) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try RecordingBatchArchive(data: Data(#"{"version":1,"servers":[{"key":"short","entries":[]}] }"#.utf8))) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidServerKey)
        }
        XCTAssertThrowsError(try RecordingBatchArchive(data: Data(#"not-json"#.utf8))) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidArchive)
        }
    }

    func testCapacityLimitsDoNotDiscardExistingEntries() throws {
        let firstKey = try RecordingBatchArchive.serverKey(address: firstAddress)
        var archive = RecordingBatchArchive()
        for index in 0..<RecordingBatchArchive.maximumEntriesPerServer {
            try archive.upsert(
                RegisteredRecordingBatch(name: "録画\(index)", path: "/\(index)"),
                serverKey: firstKey
            )
        }
        XCTAssertThrowsError(try archive.upsert(
            RegisteredRecordingBatch(name: "上限超過", path: "/overflow"),
            serverKey: firstKey
        )) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .batchLimitExceeded)
        }
        XCTAssertEqual(archive.entries(serverKey: firstKey).count, RecordingBatchArchive.maximumEntriesPerServer)

        for index in 1..<RecordingBatchArchive.maximumServers {
            let address = "https://server\(index).invalid/"
            let key = try RecordingBatchArchive.serverKey(address: address)
            try archive.upsert(RegisteredRecordingBatch(name: "録画", path: "/recordings"), serverKey: key)
        }
        XCTAssertEqual(archive.entries(serverKey: firstKey).count, RecordingBatchArchive.maximumEntriesPerServer)
        XCTAssertThrowsError(try archive.upsert(
            RegisteredRecordingBatch(name: "追加", path: "/extra"),
            serverKey: try RecordingBatchArchive.serverKey(address: "https://overflow.invalid/")
        )) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .serverLimitExceeded)
        }
    }

    func testInvalidServerKeysAndAddressesDoNotMutateArchive() throws {
        var archive = RecordingBatchArchive()
        let entry = try RegisteredRecordingBatch(name: "録画", path: "/recordings")
        XCTAssertThrowsError(try archive.upsert(entry, serverKey: "short")) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidServerKey)
        }
        XCTAssertThrowsError(try archive.upsert(entry, serverKey: "not a hex key")) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidServerKey)
        }
        for address in [
            "https://user:password@example.invalid/",
            "https://example.invalid/?secret=1",
            "https://example.invalid/#secret"
        ] {
            XCTAssertThrowsError(try RecordingBatchArchive.serverKey(address: address)) { error in
                XCTAssertEqual(error as? RecordingBatchArchiveError, .invalidServerAddress)
            }
        }
        XCTAssertTrue(archive.entries(serverKey: String(repeating: "a", count: 64)).isEmpty)
    }

    func testArchiveSizeIsBounded() throws {
        let oversized = Data(repeating: 0x20, count: RecordingBatchArchive.maximumArchiveBytes + 1)
        XCTAssertThrowsError(try RecordingBatchArchive(data: oversized)) { error in
            XCTAssertEqual(error as? RecordingBatchArchiveError, .archiveTooLarge)
        }
    }
}
