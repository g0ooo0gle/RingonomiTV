import Foundation
import XCTest
@testable import RingonomiCore

final class SMBResumeTests: XCTestCase {
    private let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func connection(
        displayName: String = "表示名",
        server: String = "NAS.Example",
        port: Int = 445,
        share: String = "recordings",
        base: SMBRelativePath = .root,
        id: UUID? = nil
    ) throws -> SMBConnection {
        try SMBConnection(
            id: id ?? connectionID,
            displayName: displayName,
            server: server,
            port: port,
            share: share,
            baseDirectory: base
        )
    }

    private func entry(
        path: SMBRelativePath? = nil,
        size: Int64? = 100,
        modifiedDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> SMBLibraryEntry {
        let resolvedPath: SMBRelativePath
        if let path {
            resolvedPath = path
        } else {
            resolvedPath = try SMBRelativePath(components: ["movie.ts"])
        }
        return try SMBLibraryEntry(
            name: resolvedPath.components.last!,
            path: resolvedPath,
            isDirectory: false,
            size: size,
            modifiedDate: modifiedDate
        )
    }

    private func key(_ value: Int) -> String {
        let suffix = String(format: "%064x", value)
        return "ringonomi.smb.resume.v1.\(suffix)"
    }

    func testIdentitySeparatesConnectionAndEntryMetadataButIgnoresDisplayName() throws {
        let base = try SMBRelativePath(components: ["TV"])
        let path = try SMBRelativePath(components: ["movie.ts"])
        let firstConnection = try connection(base: base)
        let renamedConnection = try connection(displayName: "別の表示名", base: base)
        let firstEntry = try entry(path: path)
        let first = SMBResumeID(connection: firstConnection, entry: firstEntry)
        XCTAssertEqual(first.storageKey, SMBResumeID(connection: renamedConnection, entry: firstEntry).storageKey)
        XCTAssertTrue(first.storageKey.hasPrefix("ringonomi.smb.resume.v1."))
        XCTAssertEqual(first.storageKey.count, "ringonomi.smb.resume.v1.".count + 64)
        XCTAssertFalse(first.storageKey.contains("NAS"))
        XCTAssertFalse(first.storageKey.contains("movie.ts"))

        XCTAssertNotEqual(
            first.storageKey,
            SMBResumeID(connection: try connection(base: base, id: UUID()), entry: firstEntry).storageKey
        )
        XCTAssertNotEqual(
            first.storageKey,
            SMBResumeID(connection: try connection(server: "other.example", base: base), entry: firstEntry).storageKey
        )
        XCTAssertNotEqual(
            first.storageKey,
            SMBResumeID(connection: try connection(port: 1445, base: base), entry: firstEntry).storageKey
        )
        XCTAssertNotEqual(
            first.storageKey,
            SMBResumeID(connection: try connection(share: "other", base: base), entry: firstEntry).storageKey
        )
        XCTAssertNotEqual(
            first.storageKey,
            SMBResumeID(connection: try connection(base: .root), entry: firstEntry).storageKey
        )
        XCTAssertNotEqual(
            first.storageKey,
            SMBResumeID(connection: firstConnection, entry: try entry(path: try SMBRelativePath(components: ["other.ts"]))).storageKey
        )
        XCTAssertNotEqual(
            first.storageKey,
            SMBResumeID(connection: firstConnection, entry: try entry(path: path, size: 101)).storageKey
        )
        XCTAssertNotEqual(
            first.storageKey,
            SMBResumeID(connection: firstConnection, entry: try entry(path: path, modifiedDate: Date(timeIntervalSince1970: 1_700_000_001))).storageKey
        )
    }

    func testPolicyValidatesFinitePositionAndKeepsUsefulNearEndBookmark() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNotNil(SMBResumePolicy.validatedBookmark(seconds: 5, duration: 10, updatedAt: date))
        XCTAssertNil(SMBResumePolicy.validatedBookmark(seconds: -1, duration: 10, updatedAt: date))
        XCTAssertNil(SMBResumePolicy.validatedBookmark(seconds: .nan, duration: 10, updatedAt: date))
        XCTAssertNil(SMBResumePolicy.validatedBookmark(seconds: 1, duration: .infinity, updatedAt: date))
        XCTAssertNil(SMBResumePolicy.validatedBookmark(seconds: 9.75, duration: 10, updatedAt: date))
        XCTAssertNil(SMBResumePolicy.validatedBookmark(seconds: 1, duration: 10, updatedAt: Date(timeIntervalSinceReferenceDate: .nan)))

        let short = SMBResumeBookmark(seconds: 4.9, duration: 10, updatedAt: date)
        XCTAssertNil(SMBResumePolicy.candidate(bookmark: short))
        let useful = SMBResumeBookmark(seconds: 8, duration: 10, updatedAt: date)
        XCTAssertEqual(SMBResumePolicy.candidate(bookmark: useful), 8)
    }

    func testRestoredPositionRejectsLengthChangeInsteadOfClamping() {
        let bookmark = SMBResumeBookmark(
            seconds: 40,
            duration: 100,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(SMBResumePolicy.restoredPosition(bookmark: bookmark, currentDuration: 100), 40)
        XCTAssertEqual(SMBResumePolicy.restoredPosition(bookmark: bookmark, currentDuration: 100.7), 40)
        XCTAssertNil(SMBResumePolicy.restoredPosition(bookmark: bookmark, currentDuration: 101))
        XCTAssertNil(SMBResumePolicy.restoredPosition(bookmark: bookmark, currentDuration: 99), "duration mismatch must not clamp")
        XCTAssertNil(SMBResumePolicy.restoredPosition(bookmark: bookmark, currentDuration: .nan))

        let nearCurrentEnd = SMBResumeBookmark(
            seconds: 99.8,
            duration: 100,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertNil(SMBResumePolicy.restoredPosition(bookmark: nearCurrentEnd, currentDuration: 100))
    }

    func testArchiveRoundTripsAndRemovesByOpaqueID() throws {
        let id = SMBResumeID(connection: try connection(), entry: try entry())
        let bookmark = try XCTUnwrap(SMBResumePolicy.validatedBookmark(
            seconds: 60,
            duration: 600,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        var archive = SMBResumeArchive()
        try archive.set(bookmark, for: id)
        let decoded = try SMBResumeArchive(data: archive.data())
        XCTAssertEqual(decoded.entry(for: id), bookmark)
        XCTAssertNil(try decoded.data().range(of: Data("movie.ts".utf8)))

        archive.remove(for: id)
        XCTAssertNil(archive.entry(for: id))
    }

    func testCorruptEntryAndInvalidNamespaceDoNotDiscardValidEntries() throws {
        let good = key(1)
        let bad = key(2)
        let json = """
        {
          "version": 1,
          "entries": {
            "\(good)": {"seconds": 30, "duration": 600, "updatedAt": 1000},
            "\(bad)": {"seconds": "not-a-number", "duration": 600, "updatedAt": 1000},
            "wrong.namespace": {"seconds": 30, "duration": 600, "updatedAt": 1000}
          }
        }
        """
        let archive = try SMBResumeArchive(data: Data(json.utf8))
        XCTAssertEqual(archive.entry(for: good)?.seconds, 30)
        XCTAssertNil(archive.entry(for: bad))
        XCTAssertEqual(archive.entries.count, 1)
    }

    func testArchiveKeepsNewestTwoHundredEntries() throws {
        var archive = SMBResumeArchive()
        for index in 0..<201 {
            let bookmark = SMBResumeBookmark(
                seconds: 10,
                duration: 600,
                updatedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
            try archive.set(bookmark, for: key(index))
        }
        XCTAssertEqual(archive.entries.count, SMBResumeArchive.maximumEntries)
        XCTAssertNil(archive.entry(for: key(0)))
        XCTAssertNotNil(archive.entry(for: key(1)))
        XCTAssertNotNil(archive.entry(for: key(200)))
    }

    func testArchiveRejectsInvalidSetAndKey() throws {
        var archive = SMBResumeArchive()
        XCTAssertThrowsError(try archive.set(
            SMBResumeBookmark(seconds: -1, duration: 600),
            for: key(1)
        )) { error in
            XCTAssertEqual(error as? SMBResumeArchiveError, .invalidBookmark)
        }
        XCTAssertThrowsError(try archive.set(
            SMBResumeBookmark(seconds: 10, duration: 600),
            for: "ringonomi.smb.resume.v1.bad"
        )) { error in
            XCTAssertEqual(error as? SMBResumeArchiveError, .invalidKey)
        }
        XCTAssertThrowsError(try archive.remove(for: "wrong.namespace")) { error in
            XCTAssertEqual(error as? SMBResumeArchiveError, .invalidKey)
        }
    }
    func testAbsentMetadataStillSeparatesPathsAndNormalizesHost() throws {
        let file = try entry(size: nil, modifiedDate: nil)
        let id = SMBResumeID(connection: try connection(), entry: file)
        XCTAssertEqual(id, SMBResumeID(connection: try connection(server: "nas.example"), entry: file))
        XCTAssertNotEqual(id, SMBResumeID(connection: try connection(),
            entry: try entry(path: SMBRelativePath(components: ["other.ts"]), size: nil, modifiedDate: nil)))
        let payload = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        for token in ["nas.example", "recordings", "movie.ts"] { XCTAssertFalse(payload.contains(token)) }
    }

    func testArchiveRejectsOversizeAndFutureSchema() {
        XCTAssertThrowsError(try SMBResumeArchive(data: Data(repeating: 0, count: SMBResumeArchive.maximumDataBytes + 1)))
        XCTAssertThrowsError(try SMBResumeArchive(data: Data(#"{"version":2,"entries":{}}"#.utf8)))
    }

    func testPolicyRejectsUnknownDurationAndInvalidSavedClock() {
        let now = Date()
        for duration in [0.0, -1, Double.nan, Double.infinity] {
            XCTAssertNil(SMBResumePolicy.validatedBookmark(seconds: 20, duration: duration, updatedAt: now))
        }
        for seconds in [Double.infinity, Double.nan, -1] {
            let bookmark = SMBResumeBookmark(seconds: seconds, duration: 100)
            XCTAssertNil(SMBResumePolicy.candidate(bookmark: bookmark))
            XCTAssertNil(SMBResumePolicy.restoredPosition(bookmark: bookmark, currentDuration: 100))
        }
        XCTAssertNil(SMBResumePolicy.candidate(bookmark: SMBResumeBookmark(seconds: 4.9, duration: 100)))
    }

}
