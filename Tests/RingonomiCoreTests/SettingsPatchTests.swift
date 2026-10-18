import XCTest
@testable import RingonomiCore

final class SettingsPatchTests: XCTestCase {
    func testPreservesUnknownFieldsAndRemoteEditsToOtherFields() throws {
        let before: [String: RawJSONValue] = ["priority": .integer(3), "folder": .string("original")]
        let edited: [String: RawJSONValue] = ["priority": .integer(4), "folder": .string("original")]
        let latest: [String: RawJSONValue] = ["priority": .integer(3), "folder": .string("remote"), "extension": .object(["enabled": .bool(true)])]
        let result = try mergingEditedSettings(original: before, edited: edited, latest: latest)
        XCTAssertEqual(result["priority"], .integer(4))
        XCTAssertEqual(result["folder"], .string("remote"))
        XCTAssertEqual(result["extension"], latest["extension"])
    }

    func testOverlappingDifferentChangesRejectWithoutModifyingLatest() {
        let latest: [String: RawJSONValue] = ["priority": .integer(5)]
        XCTAssertThrowsError(try mergingEditedSettings(original: ["priority": .integer(3)], edited: ["priority": .integer(4)], latest: latest)) {
            XCTAssertEqual($0 as? SettingsPatchError, .conflictingChange)
        }
        XCTAssertEqual(latest["priority"], .integer(5))
    }

    func testSameChangeInBothClientsIsNotAConflict() throws {
        XCTAssertEqual(try mergingEditedSettings(original: ["enabled": .bool(false)], edited: ["enabled": .bool(true)], latest: ["enabled": .bool(true)]), ["enabled": .bool(true)])
    }

    func testUntouchedFieldsDeletedRemotelyStayDeleted() throws {
        let original: [String: RawJSONValue] = ["legacy": .string("value")]
        XCTAssertEqual(try mergingEditedSettings(original: original, edited: original, latest: [:]), [:])
    }

    func testExplicitNullDiffersFromRemovingAKey() throws {
        let original: [String: RawJSONValue] = ["margin": .integer(10), "legacy": .bool(true)]
        XCTAssertEqual(try mergingEditedSettings(original: original, edited: ["margin": .null], latest: original), ["margin": .null])
    }

    func testPreservesNestedDateAndServiceFieldsWhenEditingKeyword() throws {
        let range: RawJSONValue = .array([.object(["network_id": .integer(1), "future_field": .null])])
        let original: [String: RawJSONValue] = ["keyword": .string("before"), "service_ranges": range]
        let edited: [String: RawJSONValue] = ["keyword": .string("after"), "service_ranges": range]
        XCTAssertEqual(try mergingEditedSettings(original: original, edited: edited, latest: original)["service_ranges"], range)
    }
}
