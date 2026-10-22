import XCTest
@testable import RingonomiCore

final class RecordingAdvancedSettingsTests: XCTestCase {
    private func settings(
        folders: RawJSONValue = .array([]),
        postMode: RawJSONValue = .string("FutureMode"),
        batch: RawJSONValue = .string("/server/keep.sh")
    ) -> RecordSettings {
        RecordSettings(rawValues: [
            "recording_folders": folders,
            "post_recording_mode": postMode,
            "post_recording_bat_file_path": batch,
            "future_setting": .object(["enabled": .bool(true), "value": .integer(42)])
        ])
    }

    private func folder(
        path: RawJSONValue = .string("/recordings"),
        template: RawJSONValue? = .null,
        oneseg: RawJSONValue? = .bool(false),
        unknown: RawJSONValue = .object(["future": .string("keep")])
    ) -> RawJSONValue {
        var object: [String: RawJSONValue] = [
            "recording_folder_path": path,
            "future_folder": unknown
        ]
        if let template { object["recording_file_name_template"] = template }
        if let oneseg { object["is_oneseg_separate_recording_folder"] = oneseg }
        return .object(object)
    }

    func testNoOpPreservesCompleteRawSettings() throws {
        let original = settings(
            folders: .array([folder(), folder(path: .string("/archive"), template: nil, oneseg: nil)]),
            postMode: .string("FutureMode"),
            batch: .null
        )
        let draft = RecordingAdvancedDraft(settings: original)

        XCTAssertTrue(draft.foldersEditable)
        XCTAssertEqual(try draft.validatedApplying(to: original), original)
        XCTAssertEqual(draft.applying(to: original).rawValues, original.rawValues)
    }

    func testChangingOneFolderPreservesOtherFolderAndUnknownFields() throws {
        let first = folder(path: .string("/first"), unknown: .object(["first_future": .integer(1)]))
        let second = folder(path: .string("/second"), unknown: .object(["second_future": .bool(true)]))
        let original = settings(folders: .array([first, second]))
        var draft = RecordingAdvancedDraft(settings: original)
        let firstID = try XCTUnwrap(draft.folders.first?.id)
        let secondRaw = try XCTUnwrap(draft.folders.last?.rawValues)

        XCTAssertTrue(draft.updateFolder(id: firstID, path: "/changed"))
        let edited = try draft.validatedApplying(to: original)
        guard case .array(let editedFolders) = edited.rawValues["recording_folders"] else {
            return XCTFail("recording_folders was not an array")
        }
        guard case .object(let editedFirst) = editedFolders[0],
              case .object(let editedSecond) = editedFolders[1] else {
            return XCTFail("recording folder objects were lost")
        }
        XCTAssertEqual(editedFirst["recording_folder_path"], .string("/changed"))
        XCTAssertEqual(editedFirst["future_folder"], .object(["first_future": .integer(1)]))
        XCTAssertEqual(editedSecond, secondRaw)
    }

    func testFolderRemovalAndUpdateUseStableUUIDs() throws {
        let original = settings(folders: .array([
            folder(path: .string("/remove")),
            folder(path: .string("/keep"))
        ]))
        var draft = RecordingAdvancedDraft(settings: original)
        let removeID = try XCTUnwrap(draft.folders.first?.id)
        let keepID = try XCTUnwrap(draft.folders.last?.id)

        XCTAssertTrue(draft.removeFolder(id: removeID))
        XCTAssertFalse(draft.removeFolder(id: removeID))
        XCTAssertTrue(draft.updateFolder(id: keepID, path: "/still-keep"))
        XCTAssertEqual(draft.folders.map(\.id), [keepID])
        XCTAssertEqual(draft.folders.first?.recordingFolderPath, "/still-keep")
    }

    func testMalformedFolderArrayDisablesEditingAndPreservesRawValue() throws {
        let malformed = settings(folders: .array([
            folder(),
            .string("not-an-object")
        ]))
        var draft = RecordingAdvancedDraft(settings: malformed)

        XCTAssertFalse(draft.foldersEditable)
        XCTAssertNotNil(draft.foldersMessage)
        XCTAssertTrue(draft.folders.isEmpty)
        XCTAssertNil(draft.addFolder(path: "/new"))
        XCTAssertEqual(try draft.validatedApplying(to: malformed), malformed)
    }

    func testMalformedKnownFolderFieldDisablesEditingWithoutDroppingData() throws {
        let malformed = settings(folders: .array([
            folder(template: .integer(3)),
            folder(path: .string("/second"))
        ]))
        let draft = RecordingAdvancedDraft(settings: malformed)

        XCTAssertFalse(draft.foldersEditable)
        XCTAssertEqual(try draft.validatedApplying(to: malformed).rawValues, malformed.rawValues)
    }

    func testMissingAndNullOptionalFolderFieldsRemainMissingAndNull() throws {
        let original = settings(folders: .array([
            folder(template: nil, oneseg: nil, unknown: .null)
        ]))
        var draft = RecordingAdvancedDraft(settings: original)
        let id = try XCTUnwrap(draft.folders.first?.id)
        XCTAssertNil(draft.folders[0].recordingFileNameTemplate)
        XCTAssertNil(draft.folders[0].isOnesegSeparateRecordingFolder)
        XCTAssertTrue(draft.updateFolder(id: id, path: "/updated"))

        let edited = try draft.validatedApplying(to: original)
        guard case .array(let values) = edited.rawValues["recording_folders"],
              case .object(let object) = values[0] else {
            return XCTFail("folder was not preserved")
        }
        XCTAssertNil(object["recording_file_name_template"])
        XCTAssertNil(object["is_oneseg_separate_recording_folder"])
        XCTAssertEqual(object["future_folder"], .null)
    }

    func testClearBatchChangesOnlyTheBatchKey() throws {
        let original = settings(
            folders: .array([folder()]),
            postMode: .string("FutureMode"),
            batch: .string("/server/keep.sh")
        )
        var draft = RecordingAdvancedDraft(settings: original)
        draft.clearBatch()
        let edited = try draft.validatedApplying(to: original)

        XCTAssertEqual(edited.rawValues["post_recording_bat_file_path"], .null)
        XCTAssertEqual(edited.rawValues["post_recording_mode"], .string("FutureMode"))
        XCTAssertEqual(edited.rawValues["recording_folders"], original.rawValues["recording_folders"])
        XCTAssertEqual(edited.rawValues["future_setting"], original.rawValues["future_setting"])
    }

    func testUnknownPostModeIsDisplayedAndOnlyKnownExplicitSelectionIsAllowed() throws {
        let original = settings(postMode: .string("FutureMode"))
        var draft = RecordingAdvancedDraft(settings: original)
        XCTAssertEqual(draft.postRecordingMode, "FutureMode")
        XCTAssertFalse(draft.isKnownPostRecordingMode)
        XCTAssertThrowsError(try draft.setPostRecordingMode("InventedMode")) {
            XCTAssertEqual($0 as? RecordingAdvancedSettingsError, .invalidPostRecordingMode)
        }
        XCTAssertEqual(try draft.validatedApplying(to: original), original)

        try draft.setPostRecordingMode("Standby")
        let edited = try draft.validatedApplying(to: original)
        XCTAssertEqual(edited.rawValues["post_recording_mode"], .string("Standby"))
        XCTAssertEqual(edited.rawValues["post_recording_bat_file_path"], original.rawValues["post_recording_bat_file_path"])
    }

    func testBatchPathSelectionValidatesAndKeepsExplicitClear() throws {
        let original = settings(batch: .string("/old.sh"))
        var draft = RecordingAdvancedDraft(settings: original)
        draft.chooseBatch(path: "/new.sh")
        XCTAssertEqual(
            try draft.validatedApplying(to: original).rawValues["post_recording_bat_file_path"],
            .string("/new.sh")
        )

        draft.setBatch(path: nil)
        XCTAssertEqual(
            try draft.validatedApplying(to: original).rawValues["post_recording_bat_file_path"],
            .null
        )
    }

    func testInvalidFolderAndBatchInputsThrowOnValidation() throws {
        let original = settings(folders: .array([folder(path: .string("/valid"))]))
        var empty = RecordingAdvancedDraft(settings: original)
        let id = try XCTUnwrap(empty.folders.first?.id)
        XCTAssertTrue(empty.updateFolder(id: id, path: "  \n"))
        XCTAssertThrowsError(try empty.validatedApplying(to: original)) {
            XCTAssertEqual($0 as? RecordingAdvancedSettingsError, .emptyFolderPath)
        }

        var control = RecordingAdvancedDraft(settings: original)
        let controlID = try XCTUnwrap(control.folders.first?.id)
        XCTAssertTrue(control.updateFolder(id: controlID, path: "/bad\u{0000}path"))
        XCTAssertThrowsError(try control.validatedApplying(to: original)) {
            XCTAssertEqual($0 as? RecordingAdvancedSettingsError, .folderPathContainsControlCharacters)
        }

        var huge = RecordingAdvancedDraft(settings: original)
        let hugeID = try XCTUnwrap(huge.folders.first?.id)
        XCTAssertTrue(huge.updateFolder(id: hugeID, path: String(repeating: "x", count: 4097)))
        XCTAssertThrowsError(try huge.validatedApplying(to: original)) {
            XCTAssertEqual($0 as? RecordingAdvancedSettingsError, .folderPathTooLong)
        }

        var batch = RecordingAdvancedDraft(settings: original)
        batch.chooseBatch(path: "\t")
        XCTAssertThrowsError(try batch.validatedApplying(to: original)) {
            XCTAssertEqual($0 as? RecordingAdvancedSettingsError, .emptyBatchPath)
        }
    }

    func testUnchangedInvalidExistingFolderDoesNotBlockAnotherFolderEdit() throws {
        let original = settings(folders: .array([
            folder(path: .string(""), template: .string(String(repeating: "x", count: 4097))),
            folder(path: .string("/valid"))
        ]))
        var draft = RecordingAdvancedDraft(settings: original)
        let secondID = try XCTUnwrap(draft.folders.last?.id)

        XCTAssertTrue(draft.updateFolder(id: secondID, path: "/changed"))
        let edited = try draft.validatedApplying(to: original)
        guard case .array(let values) = edited.rawValues["recording_folders"],
              values.count == 2,
              case .object(let first) = values[0],
              case .object(let second) = values[1] else {
            return XCTFail("folder raw values were not preserved")
        }
        guard case .array(let originalValues) = original.rawValues["recording_folders"],
              case .object(let originalFirst) = originalValues[0] else {
            return XCTFail("original folder raw value was not an object")
        }
        XCTAssertEqual(first, originalFirst)
        XCTAssertEqual(second["recording_folder_path"], .string("/changed"))
    }

    func testThreeWayMergeRejectsSameKeyConflict() throws {
        let original = settings(folders: .array([folder(path: .string("/original"))]))
        var draft = RecordingAdvancedDraft(settings: original)
        let id = try XCTUnwrap(draft.folders.first?.id)
        XCTAssertTrue(draft.updateFolder(id: id, path: "/edited"))
        let edited = try draft.validatedApplying(to: original)
        let latest = settings(folders: .array([folder(path: .string("/remote"))]))

        XCTAssertThrowsError(try mergingEditedSettings(
            original: original.rawValues,
            edited: edited.rawValues,
            latest: latest.rawValues
        )) {
            XCTAssertEqual($0 as? SettingsPatchError, .conflictingChange)
        }
    }

    func testThreeWayMergePreservesUnrelatedServerChanges() throws {
        let original = settings(folders: .array([folder(path: .string("/original"))]))
        var draft = RecordingAdvancedDraft(settings: original)
        let id = try XCTUnwrap(draft.folders.first?.id)
        XCTAssertTrue(draft.updateFolder(id: id, path: "/edited"))
        let edited = try draft.validatedApplying(to: original)

        var latestRaw = original.rawValues
        latestRaw["server_added_field"] = .string("keep")
        let merged = try mergingEditedSettings(
            original: original.rawValues,
            edited: edited.rawValues,
            latest: latestRaw
        )
        XCTAssertEqual(merged["server_added_field"], .string("keep"))
        guard case .array(let values) = merged["recording_folders"],
              let firstValue = values.first,
              case .object(let first) = firstValue else {
            return XCTFail("merged folder missing")
        }
        XCTAssertEqual(first["recording_folder_path"], .string("/edited"))
    }
}
