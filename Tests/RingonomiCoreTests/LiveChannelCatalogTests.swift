import Foundation
import XCTest
@testable import RingonomiCore

final class LiveChannelCatalogTests: XCTestCase {
    private func channel(
        _ id: String,
        displayID: String,
        name: String,
        type: String? = nil,
        channelNumber: String? = nil,
        title: String? = nil,
        watchable: Bool = true,
        display: Bool = true
    ) -> Channel {
        var object: [String: Any] = [
            "id": id,
            "display_channel_id": displayID,
            "name": name,
            "is_watchable": watchable,
            "is_display": display
        ]
        if let type { object["type"] = type }
        if let channelNumber { object["channel_number"] = channelNumber }
        if let title {
            object["program_present"] = [
                "id": id + "-program",
                "title": title,
                "description": ""
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Channel.self, from: data)
    }

    func testSearchUsesANDWidthInsensitiveJapaneseAndProgramTitle() {
        let news = channel(
            "1", displayID: "gr011", name: "ＮＨＫ 総合", channelNumber: "1", title: "朝ニュース"
        )
        let other = channel("2", displayID: "gr021", name: "民放", channelNumber: "2", title: "朝ニュース")

        let result = LiveChannelCatalog.channels(
            [news, other],
            query: LiveChannelQuery(search: " nhk   朝 ")
        )

        XCTAssertEqual(result.map(\.id), ["1"])
    }

    func testSearchIncludesChannelNumberAndDisplayID() {
        let first = channel("1", displayID: "gr011", name: "局A", channelNumber: "011")
        let second = channel("2", displayID: "bs101", name: "局B", channelNumber: "101")

        XCTAssertEqual(
            LiveChannelCatalog.channels([first, second], query: LiveChannelQuery(search: "011")).map(\.id),
            ["1"]
        )
        XCTAssertEqual(
            LiveChannelCatalog.channels([first, second], query: LiveChannelQuery(search: "BS101")).map(\.id),
            ["2"]
        )
    }

    func testBroadcastUsesTypeThenPrefixAndChecksBS4KBeforeBS() {
        let typed = channel("1", displayID: "unknown", name: "地上波", type: "GR")
        let bs4K = channel("2", displayID: "bs4k101", name: "BS4K", type: nil)
        let bs = channel("3", displayID: "bs101", name: "BS", type: nil)
        let unknown = channel("4", displayID: "other", name: "その他")

        XCTAssertEqual(LiveChannelCatalog.broadcast(for: typed), .gr)
        XCTAssertEqual(LiveChannelCatalog.broadcast(for: bs4K), .bs4k)
        XCTAssertEqual(LiveChannelCatalog.broadcast(for: bs), .bs)
        XCTAssertEqual(LiveChannelCatalog.broadcast(for: unknown), .other)
        XCTAssertEqual(
            LiveChannelCatalog.channels([typed, bs4K, bs, unknown], query: LiveChannelQuery(broadcast: .bs4k)).map(\.id),
            ["2"]
        )
    }

    func testFiltersUnsafeChannelsAndDeduplicatesDisplayIDInServerOrder() {
        let first = channel("1", displayID: "gr011", name: "最初")
        let duplicate = channel("2", displayID: "gr011", name: "重複")
        let hidden = channel("3", displayID: "gr012", name: "非表示", display: false)
        let unwatched = channel("4", displayID: "gr013", name: "視聴不可", watchable: false)
        let last = channel("5", displayID: "gr014", name: "最後")

        let result = LiveChannelCatalog.channels([first, duplicate, hidden, unwatched, last])
        XCTAssertEqual(result.map(\.id), ["1", "5"])
    }

    func testNameSortIsStableForEqualNamesAndFavoritesFirstPreservesPartitions() {
        let first = channel("1", displayID: "gr001", name: "同名")
        let second = channel("2", displayID: "gr002", name: "AAA")
        let third = channel("3", displayID: "gr003", name: "同名")

        XCTAssertEqual(
            LiveChannelCatalog.channels(
                [first, second, third],
                query: LiveChannelQuery(sort: .name)
            ).map(\.id),
            ["2", "1", "3"]
        )
        XCTAssertEqual(
            LiveChannelCatalog.channels(
                [first, second, third],
                query: LiveChannelQuery(sort: .favoritesFirst),
                favoriteIDs: ["gr003", "gr002"]
            ).map(\.id),
            ["2", "3", "1"]
        )
    }

    func testFavoritesOnlyAndMissingOptionalMetadataRemainCompatible() {
        let old = channel("1", displayID: "gr001", name: "旧形式")
        let newer = channel("2", displayID: "bs101", name: "新形式", type: "BS", channelNumber: "101")

        XCTAssertNil(old.type)
        XCTAssertNil(old.channelNumber)
        XCTAssertEqual(
            LiveChannelCatalog.channels(
                [old, newer],
                query: LiveChannelQuery(favoritesOnly: true),
                favoriteIDs: ["bs101"]
            ).map(\.id),
            ["2"]
        )
    }

    func testFilteringKeepsTheFirstVisibleRecordForDuplicateDisplayIDs() {
        let first = channel("first", displayID: "gr011", name: "現在の放送局", type: "GR")
        let duplicate = channel("duplicate", displayID: "gr011", name: "古い別名", type: "BS")
        XCTAssertTrue(LiveChannelCatalog.channels(
            [first, duplicate], query: LiveChannelQuery(search: "古い")
        ).isEmpty)
        XCTAssertTrue(LiveChannelCatalog.channels(
            [first, duplicate], query: LiveChannelQuery(broadcast: .bs)
        ).isEmpty)
    }
}
