import Foundation
import XCTest
@testable import RingonomiCore

final class SMBLibraryTests: XCTestCase {
    private let connectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testConnectionNormalizesServerPortShareAndUnicodeBaseDirectory() throws {
        let connection = try SMBConnection(
            address: "smb://NAS.Example:1445/共有/TV%20番組",
            id: connectionID
        )

        XCTAssertEqual(connection.id, connectionID)
        XCTAssertEqual(connection.server, "nas.example")
        XCTAssertEqual(connection.port, 1445)
        XCTAssertEqual(connection.share, "共有")
        XCTAssertEqual(connection.baseDirectory.components, ["TV 番組"])
        XCTAssertEqual(connection.displayName, "nas.example/共有")
        let rootURL = try connection.url(for: .root)
        XCTAssertTrue(rootURL.absoluteString.hasPrefix("smb://nas.example:1445/"))
        XCTAssertTrue(rootURL.absoluteString.contains("%E5%85%B1%E6%9C%89"))
        XCTAssertTrue(rootURL.absoluteString.contains("TV%20"))
    }

    func testIPv6DefaultPortAndLiteralPercentAreEncodedOnce() throws {
        let connection = try SMBConnection(
            address: "smb://[2001:DB8::1]/Share",
            id: connectionID
        )
        XCTAssertEqual(connection.server, "2001:db8::1")
        XCTAssertEqual(connection.port, 445)
        XCTAssertEqual(
            try connection.url(for: .root).absoluteString,
            "smb://[2001:db8::1]/Share"
        )

        let path = try SMBRelativePath(components: ["folder", "100%2Ets"])
        let childURL = try connection.url(for: path)
        XCTAssertTrue(childURL.absoluteString.contains("100%252Ets"))
        XCTAssertFalse(childURL.absoluteString.contains("100%2Ets"))
    }

    func testConnectionRejectsCredentialsQueriesFragmentsTraversalAndUnsafeEncoding() {
        let invalid = [
            "ftp://nas.example/share",
            "smb://user:password@nas.example/share",
            "smb://nas.example/share?token=secret",
            "smb://nas.example/share#private",
            "smb://nas.example",
            "smb://nas.example/share/../secret",
            "smb://nas.example/share/%2e%2e",
            "smb://nas.example/share/%2fescape",
            "smb://nas.example/share/%5Cescape",
            "smb://nas.example/share/%ZZ",
            "smb://nas.example/share//double",
            "smb://[::::]/share",
            "smb://[2001:db8:::1]/share",
            "smb://[fe80::1%25en0]/share"
        ]

        for address in invalid {
            XCTAssertThrowsError(try SMBConnection(address: address), address)
        }
    }

    func testMalformedCodableValuesBecomeSanitizedSMBErrors() throws {
        let malformedConnection = Data(#"{"id":"not-a-uuid","displayName":"x","server":"nas.example","share":"share"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SMBConnection.self, from: malformedConnection)) { error in
            XCTAssertEqual(error as? SMBError, .invalidConnection)
        }

        let malformedPath = Data(#"{"not":"an-array"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SMBRelativePath.self, from: malformedPath)) { error in
            XCTAssertEqual(error as? SMBError, .invalidPath)
        }

        let malformedEntry = Data(#"{"name":"movie.ts","path":{"components":["outside"]},"isDirectory":false}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SMBLibraryEntry.self, from: malformedEntry)) { error in
            XCTAssertEqual(error as? SMBError, .invalidEntry)
        }
    }

    func testRelativePathValidatesComponentsAndParentChild() throws {
        let root = SMBRelativePath.root
        XCTAssertTrue(root.isRoot)
        XCTAssertNil(root.parent())

        let path = try root.child("録画").child("movie 100%2Ets")
        XCTAssertEqual(path.components, ["録画", "movie 100%2Ets"])
        XCTAssertEqual(path.description, "録画/movie 100%2Ets")
        XCTAssertEqual(path.parent()?.components, ["録画"])
        XCTAssertEqual(path.stableKey, "6:録画/14:movie 100%2Ets")

        let invalidNames = [".", "..", "", "a/b", "a\\b", "bad\u{0001}"]
        for name in invalidNames {
            XCTAssertThrowsError(try root.child(name), name)
        }
        XCTAssertThrowsError(try SMBRelativePath(string: "/absolute"))
        XCTAssertThrowsError(try SMBRelativePath(string: "a//b"))
        XCTAssertThrowsError(try SMBRelativePath(components: Array(repeating: "x", count: 65)))
    }

    func testURLRejectsCombinedBaseAndRelativePathBeyondBounds() throws {
        let depthBase = try SMBRelativePath(
            components: Array(repeating: "x", count: SMBRelativePath.maximumDepth)
        )
        let depthConnection = try SMBConnection(
            server: "nas.example",
            share: "share",
            baseDirectory: depthBase,
            id: connectionID
        )
        let child = try SMBRelativePath(components: ["child"])
        XCTAssertThrowsError(try depthConnection.url(for: child))

        let wideComponent = String(repeating: "x", count: SMBRelativePath.maximumComponentBytes)
        let byteBase = try SMBRelativePath(
            components: Array(repeating: wideComponent, count: SMBRelativePath.maximumDepth / 4)
        )
        let byteConnection = try SMBConnection(
            server: "nas.example",
            share: "share",
            baseDirectory: byteBase,
            id: connectionID
        )
        let extra = try SMBRelativePath(components: [String(repeating: "y", count: 20)])
        XCTAssertThrowsError(try byteConnection.url(for: extra))
    }

    func testCodableRoundTripDoesNotAddCredentialsOrLoseBaseDirectory() throws {
        let connection = try SMBConnection(
            address: "smb://nas.example/share/base",
            id: connectionID,
            displayName: "居間NAS"
        )
        let data = try JSONEncoder().encode(connection)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("password"))
        XCTAssertFalse(encoded.contains("user"))
        XCTAssertFalse(encoded.contains("smb://"))
        let restored = try JSONDecoder().decode(SMBConnection.self, from: data)
        XCTAssertEqual(restored, connection)
    }

    func testExternalURLMustStayInsideSameHostPortShareAndBasePrefix() throws {
        let connection = try SMBConnection(
            address: "smb://nas.example:1445/share/base",
            id: connectionID
        )
        let inside = try XCTUnwrap(URL(string: "smb://NAS.EXAMPLE:1445/share/base/folder/movie.m2ts"))
        XCTAssertEqual(
            try connection.relativePath(for: inside).components,
            ["folder", "movie.m2ts"]
        )

        let rejected = [
            "smb://other.example:1445/share/base/folder/movie.m2ts",
            "smb://nas.example:1446/share/base/folder/movie.m2ts",
            "smb://nas.example:1445/other/base/folder/movie.m2ts",
            "smb://nas.example:1445/share/base2/movie.m2ts",
            "smb://nas.example:1445/Share/base/folder/movie.m2ts",
            "smb://user@nas.example:1445/share/base/movie.m2ts",
            "smb://nas.example:1445/share/base/movie.m2ts?x=1",
            "smb://nas.example:1445/share/base/movie.m2ts#x",
            "smb://nas.example:1445/share/base/%2e%2e/secret.m2ts"
        ]
        for value in rejected {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try connection.relativePath(for: url), value)
        }
    }

    func testStableKeysIncludeConnectionUUIDAndRelativePath() throws {
        let first = try SMBConnection(
            address: "smb://nas.example/share",
            id: connectionID
        )
        let second = try SMBConnection(
            address: "smb://nas.example/share",
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        )
        let path = try SMBRelativePath(components: ["folder", "movie.ts"])
        XCTAssertEqual(first.stableKey(for: path), first.stableKey(for: path))
        XCTAssertNotEqual(first.stableKey(for: path), second.stableKey(for: path))
        XCTAssertNotEqual(first.stableKey(for: path), first.stableKey(for: try path.child("other")))
        XCTAssertTrue(first.stableKey(for: path).hasPrefix("smb:\(connectionID.uuidString.lowercased()):"))
    }

    func testEntriesValidatePathAndRecognizeVideoExtensions() throws {
        let directory = try SMBLibraryEntry(
            name: "録画",
            parent: .root,
            isDirectory: true
        )
        let movie = try SMBLibraryEntry(
            name: "Movie.M2TS",
            parent: try SMBRelativePath(components: ["録画"]),
            isDirectory: false,
            size: 123,
            modifiedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let text = try SMBLibraryEntry(
            name: "notes.txt",
            parent: .root,
            isDirectory: false
        )
        XCTAssertTrue(directory.isDirectory)
        XCTAssertFalse(directory.isVideo)
        XCTAssertEqual(movie.fileExtension, "m2ts")
        XCTAssertTrue(movie.isVideo)
        XCTAssertFalse(text.isVideo)
        let connection = try SMBConnection(address: "smb://nas.example/share")
        XCTAssertNotEqual(movie.stableKey(for: connection), movie.id)

        XCTAssertThrowsError(
            try SMBLibraryEntry(
                name: "wrong.ts",
                path: try SMBRelativePath(components: ["other.ts"]),
                isDirectory: false
            )
        )
        XCTAssertThrowsError(
            try SMBLibraryEntry(
                name: "negative.ts",
                parent: .root,
                isDirectory: false,
                size: -1
            )
        )
    }

    func testDirectoryFirstNaturalSortAndLocalSearch() throws {
        let entries = [
            try SMBLibraryEntry(name: "file10.ts", parent: .root, isDirectory: false),
            try SMBLibraryEntry(name: "Folder", parent: .root, isDirectory: true),
            try SMBLibraryEntry(name: "file2.ts", parent: .root, isDirectory: false),
            try SMBLibraryEntry(name: "file1.ts", parent: .root, isDirectory: false),
            try SMBLibraryEntry(name: "映画.mkv", parent: .root, isDirectory: false)
        ]
        let sorted = SMBLibraryEntry.sorted(entries)
        XCTAssertTrue(sorted.first?.isDirectory == true)
        let sortedNames = sorted.map(\.name)
        let firstIndex = try XCTUnwrap(sortedNames.firstIndex(of: "file1.ts"))
        let secondIndex = try XCTUnwrap(sortedNames.firstIndex(of: "file2.ts"))
        let tenthIndex = try XCTUnwrap(sortedNames.firstIndex(of: "file10.ts"))
        XCTAssertLessThan(firstIndex, secondIndex)
        XCTAssertLessThan(secondIndex, tenthIndex)

        let search = SMBLibraryEntry.search("FILE 2", in: entries)
        XCTAssertEqual(search.map(\.name), ["file2.ts"])
        XCTAssertEqual(SMBLibraryEntry.search("", in: entries), sorted)
    }

    func testErrorsNeverEchoPotentialURLOrCredential() {
        let secret = "smb://user:password@private.example/private-share"
        let descriptions = [
            SMBError.invalidConnection.localizedDescription,
            SMBError.invalidPath.localizedDescription,
            SMBError.invalidEntry.localizedDescription,
            SMBError.unsafeExternalURL.localizedDescription
        ]
        for description in descriptions {
            XCTAssertFalse(description.contains(secret))
            XCTAssertFalse(description.contains("password"))
            XCTAssertFalse(description.contains("private.example"))
        }
    }
}
