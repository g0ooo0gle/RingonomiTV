import Foundation
import XCTest
@testable import RingonomiCore

final class LiveChannelFavoritesTests: XCTestCase {
    func testRoundTripIsolatesServersAndDoesNotSerializeRawAddress() throws {
        let firstKey = try LiveChannelFavoritesArchive.serverKey(address: "https://EXAMPLE.invalid/proxy/tv/")
        let sameKey = try LiveChannelFavoritesArchive.serverKey(address: "https://example.invalid/proxy/")
        let otherKey = try LiveChannelFavoritesArchive.serverKey(address: "https://other.invalid/proxy/")
        XCTAssertEqual(firstKey, sameKey)
        XCTAssertNotEqual(firstKey, otherKey)

        var archive = LiveChannelFavoritesArchive()
        try archive.setFavorite("gr011", isFavorite: true, serverKey: firstKey)
        try archive.setFavorite("bs101", isFavorite: true, serverKey: otherKey)
        let data = try archive.data()
        let restored = try LiveChannelFavoritesArchive(data: data)

        XCTAssertEqual(restored.favoriteIDs(serverKey: firstKey), ["gr011"])
        XCTAssertEqual(restored.favoriteIDs(serverKey: otherKey), ["bs101"])
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("example.invalid") == true)
    }

    func testServerKeyRejectsCredentialsQueryAndFragment() {
        for address in [
            "https://user:password@example.invalid/",
            "https://example.invalid/?private=1",
            "https://example.invalid/#private"
        ] {
            XCTAssertThrowsError(try LiveChannelFavoritesArchive.serverKey(address: address)) { error in
                XCTAssertEqual(error as? LiveChannelFavoritesError, .invalidServerAddress)
            }
        }
    }

    func testCorruptVersionKeysAndDuplicateIDsAreRejected() {
        let key = String(repeating: "a", count: 64)
        let invalidVersion = Data(#"{"version":2,"servers":{}}"#.utf8)
        XCTAssertThrowsError(try LiveChannelFavoritesArchive(data: invalidVersion)) { error in
            XCTAssertEqual(error as? LiveChannelFavoritesError, .unsupportedVersion)
        }

        let invalidID = Data(#"{"version":1,"servers":{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":["gr/011"]}}"#.utf8)
        XCTAssertThrowsError(try LiveChannelFavoritesArchive(data: invalidID)) { error in
            XCTAssertEqual(error as? LiveChannelFavoritesError, .invalidChannelID)
        }

        let duplicateID = Data(#"{"version":1,"servers":{"\#(key)":["gr011","gr011"]}}"#.utf8)
        XCTAssertThrowsError(try LiveChannelFavoritesArchive(data: duplicateID)) { error in
            XCTAssertEqual(error as? LiveChannelFavoritesError, .invalidChannelID)
        }
    }

    func testFavoriteLimitDoesNotEvictExistingValues() throws {
        let key = String(repeating: "b", count: 64)
        var archive = LiveChannelFavoritesArchive()
        for index in 0..<LiveChannelFavoritesArchive.maximumFavoritesPerServer {
            try archive.setFavorite("channel_\(index)", isFavorite: true, serverKey: key)
        }
        XCTAssertThrowsError(try archive.setFavorite("overflow", isFavorite: true, serverKey: key)) { error in
            XCTAssertEqual(error as? LiveChannelFavoritesError, .favoriteLimitExceeded)
        }
        XCTAssertEqual(archive.favoriteIDs(serverKey: key).count, 256)
        XCTAssertTrue(archive.favoriteIDs(serverKey: key).contains("channel_0"))
    }

    func testServerLimitAndArchiveSizeAreBounded() throws {
        var archive = LiveChannelFavoritesArchive()
        for value in 0..<LiveChannelFavoritesArchive.maximumServers {
            let key = String(repeating: "0", count: 63) + String(format: "%x", value)
            try archive.setFavorite("channel", isFavorite: true, serverKey: key)
        }
        XCTAssertThrowsError(try archive.setFavorite(
            "channel", isFavorite: true,
            serverKey: String(repeating: "e", count: 64)
        )) { error in
            XCTAssertEqual(error as? LiveChannelFavoritesError, .serverLimitExceeded)
        }

        let oversized = Data(repeating: 0x7B, count: LiveChannelFavoritesArchive.maximumArchiveBytes + 1)
        XCTAssertThrowsError(try LiveChannelFavoritesArchive(data: oversized)) { error in
            XCTAssertEqual(error as? LiveChannelFavoritesError, .archiveTooLarge)
        }
    }

    func testInvalidMutationsAreRejectedWithoutStateChange() throws {
        let key = String(repeating: "c", count: 64)
        var archive = LiveChannelFavoritesArchive()
        XCTAssertThrowsError(try archive.setFavorite("日本語", isFavorite: true, serverKey: key))
        XCTAssertThrowsError(try archive.setFavorite("gr011", isFavorite: true, serverKey: "short"))
        XCTAssertTrue(archive.favoriteIDs(serverKey: key).isEmpty)
    }
}
