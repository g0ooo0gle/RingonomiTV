import XCTest
@testable import RingonomiCore

final class KeywordGenreCatalogTests: XCTestCase {
    func testCatalogUsesOfficialConcreteNamesAndUniqueIdentifiers() {
        let majors = KeywordGenreCatalog.all
        XCTAssertEqual(majors.count, 13)
        XCTAssertEqual(Set(majors.map(\.id)).count, majors.count)
        XCTAssertEqual(Set(majors.map(\.name)).count, majors.count)

        let middles = majors.flatMap(\.middles)
        XCTAssertEqual(Set(middles.map(\.id)).count, middles.count)
        XCTAssertTrue(middles.allSatisfy { !$0.name.isEmpty })
        XCTAssertTrue(middles.allSatisfy { $0.name == "すべて" || !$0.name.contains("／") })
        XCTAssertTrue(majors.allSatisfy { $0.middles.first?.name == "すべて" })
    }

    func testOfficialMajorAndMiddleLookup() {
        XCTAssertEqual(
            KeywordGenreCatalog.major(named: "アニメ・特撮")?.middles.map(\.name),
            ["すべて", "国内アニメ", "海外アニメ", "特撮", "その他"]
        )
        XCTAssertEqual(
            KeywordGenreCatalog.middle(named: "すべて", inMajor: "映画")?.name,
            "すべて"
        )
        XCTAssertNil(KeywordGenreCatalog.major(named: "拡張"))
        XCTAssertNil(KeywordGenreCatalog.middle(named: "", inMajor: "映画"))
    }
}
