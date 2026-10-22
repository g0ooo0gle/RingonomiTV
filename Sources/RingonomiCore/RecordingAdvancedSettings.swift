import Foundation

/// Errors raised when the advanced recording settings editor cannot produce
/// a safe server payload.  The editor keeps the original raw value until a
/// validated change is explicitly applied.
public enum RecordingAdvancedSettingsError: LocalizedError, Equatable, Sendable {
    case foldersNotEditable
    case folderNotFound
    case emptyFolderPath
    case folderPathContainsControlCharacters
    case folderPathTooLong
    case invalidFolderTemplate
    case folderTemplateContainsControlCharacters
    case folderTemplateTooLong
    case invalidPostRecordingMode
    case emptyBatchPath
    case batchPathContainsControlCharacters
    case batchPathTooLong

    public var errorDescription: String? {
        switch self {
        case .foldersNotEditable:
            return "保存先の形式を確認できないため、保存先を変更できません。既存の設定は保持されます。"
        case .folderNotFound:
            return "指定した保存先が見つかりません。"
        case .emptyFolderPath:
            return "保存先フォルダーを入力してください。"
        case .folderPathContainsControlCharacters:
            return "保存先フォルダーに改行などの制御文字は使用できません。"
        case .folderPathTooLong:
            return "保存先フォルダーが長すぎます。"
        case .invalidFolderTemplate:
            return "ファイル名テンプレートの形式を確認してください。"
        case .folderTemplateContainsControlCharacters:
            return "ファイル名テンプレートに改行などの制御文字は使用できません。"
        case .folderTemplateTooLong:
            return "ファイル名テンプレートが長すぎます。"
        case .invalidPostRecordingMode:
            return "録画後の動作を選択肢から選んでください。"
        case .emptyBatchPath:
            return "実行するバッチのパスを入力してください。"
        case .batchPathContainsControlCharacters:
            return "バッチのパスに改行などの制御文字は使用できません。"
        case .batchPathTooLong:
            return "バッチのパスが長すぎます。"
        }
    }
}

/// Stable, UI-facing representation of one recording folder.
///
/// `rawValues` is deliberately the exact server object.  In particular, this
/// type does not use `RecordingFolder(rawValues:)`, whose compatibility getter
/// adds defaults for missing fields.  Unknown keys and explicit null values
/// therefore survive an edit to a different field.
public struct RecordingFolderEdit: Identifiable, Equatable, Sendable {
    public let id: UUID
    public private(set) var rawValues: [String: RawJSONValue]

    public init(id: UUID = UUID(), rawValues: [String: RawJSONValue]) {
        self.id = id
        self.rawValues = rawValues
    }

    /// Creates a new complete folder object. Existing server objects should be
    /// created with `init(id:rawValues:)` so omitted fields remain omitted.
    public init(
        id: UUID = UUID(),
        path: String,
        template: String? = nil,
        oneseg: Bool = false
    ) {
        self.id = id
        self.rawValues = [
            "recording_folder_path": .string(path),
            "recording_file_name_template": template.map(RawJSONValue.string) ?? .null,
            "is_oneseg_separate_recording_folder": .bool(oneseg)
        ]
    }

    /// Returns the server value only when it is a string. Missing, null, and
    /// malformed values are intentionally distinguishable through `rawValues`.
    public var recordingFolderPath: String? {
        guard case .string(let value) = rawValues["recording_folder_path"] else { return nil }
        return value
    }

    public var recordingFileNameTemplate: String? {
        guard case .string(let value) = rawValues["recording_file_name_template"] else { return nil }
        return value
    }

    public var isOnesegSeparateRecordingFolder: Bool? {
        guard case .bool(let value) = rawValues["is_oneseg_separate_recording_folder"] else { return nil }
        return value
    }

    mutating func setPath(_ value: String) {
        rawValues["recording_folder_path"] = .string(value)
    }

    mutating func setTemplate(_ value: String?) {
        rawValues["recording_file_name_template"] = value.map(RawJSONValue.string) ?? .null
    }

    mutating func setOneseg(_ value: Bool) {
        rawValues["is_oneseg_separate_recording_folder"] = .bool(value)
    }
}

/// The seven values accepted by the KonomiTV recording settings API.
public enum RecordingPostRecordingMode: String, CaseIterable, Codable, Sendable {
    case `default` = "Default"
    case nothing = "Nothing"
    case standby = "Standby"
    case standbyAndReboot = "StandbyAndReboot"
    case suspend = "Suspend"
    case suspendAndReboot = "SuspendAndReboot"
    case shutdown = "Shutdown"
}

/// A batch path edit. `unchanged` is the default and preserves the exact raw
/// value from the server; `clear` is only produced by an explicit selection.
public enum RecordingBatchChoice: Hashable, Sendable {
    case unchanged
    case clear
    case path(String)
}

/// A lossless draft for the folder and post-recording fields of RecordSettings.
/// It is safe to construct this draft from a server response containing fields
/// newer than this app understands.
public struct RecordingAdvancedDraft: Equatable, Sendable {
    public private(set) var folders: [RecordingFolderEdit]
    public let foldersEditable: Bool
    public let foldersMessage: String?

    /// The raw string from the server, including an unknown future value. A
    /// malformed/non-string raw value is shown as the compatibility default,
    /// but remains untouched unless the user explicitly selects a valid mode.
    public private(set) var postRecordingMode: String
    public private(set) var batchChoice: RecordingBatchChoice

    private var foldersDirty = false
    private var postModeDirty = false
    private let originalFolderValues: [UUID: [String: RawJSONValue]]
    private let originalBatchValue: RawJSONValue?

    private static let supportedPostRecordingModeSet = Set(
        RecordingPostRecordingMode.allCases.map(\.rawValue)
    )

    private static let maxFolderPathUTF8Count = 4096
    private static let maxTemplateUTF8Count = 4096
    private static let maxBatchPathUTF8Count = 4096

    public init(settings: RecordSettings) {
        let rawFolders = settings.rawValues["recording_folders"]
        let parsedFolders: [RecordingFolderEdit]
        let canEditFolders: Bool
        let folderMessage: String?
        if case .array(let values) = rawFolders,
           values.allSatisfy(Self.isEditableFolderObject) {
            parsedFolders = values.compactMap { value in
                guard case .object(let object) = value else { return nil }
                return RecordingFolderEdit(rawValues: object)
            }
            canEditFolders = true
            folderMessage = nil
        } else {
            parsedFolders = []
            canEditFolders = false
            folderMessage = "保存先データの形式を確認できないため、保存先の編集を無効にしています。既存設定は保持されます。"
        }
        self.folders = parsedFolders
        self.foldersEditable = canEditFolders
        self.foldersMessage = folderMessage
        var originalFolderValues: [UUID: [String: RawJSONValue]] = [:]
        for folder in parsedFolders {
            originalFolderValues[folder.id] = folder.rawValues
        }
        self.originalFolderValues = originalFolderValues

        if case .string(let mode) = settings.rawValues["post_recording_mode"] {
            self.postRecordingMode = mode
        } else {
            self.postRecordingMode = RecordingPostRecordingMode.default.rawValue
        }
        self.batchChoice = .unchanged
        self.originalBatchValue = settings.rawValues["post_recording_bat_file_path"]
    }

    /// The currently displayed batch path. A malformed raw value is returned
    /// as nil for display, while an unchanged draft still preserves it exactly.
    public var currentBatchPath: String? {
        switch batchChoice {
        case .unchanged:
            guard case .string(let path) = originalBatchValue else { return nil }
            return path
        case .clear:
            return nil
        case .path(let path):
            return path
        }
    }

    /// The original valid string, if any. It remains nil for an explicit null,
    /// a missing value, or a malformed raw value; those raw values are still
    /// preserved when the batch choice is unchanged.
    public var originalBatchPath: String? {
        guard case .string(let path) = originalBatchValue else { return nil }
        return path
    }

    /// Whether a server-provided post-recording mode can be shown as a known
    /// picker selection. Unknown strings remain in `postRecordingMode`.
    public var isKnownPostRecordingMode: Bool {
        Self.supportedPostRecordingModeSet.contains(postRecordingMode)
    }

    /// The supported picker values, in the server's spelling and order.
    public static var supportedPostRecordingModes: [String] {
        RecordingPostRecordingMode.allCases.map(\.rawValue)
    }

    /// Add a new complete folder. The returned UUID is the only identity used
    /// by subsequent edits, so deleting an earlier row cannot retarget a row.
    @discardableResult
    public mutating func addFolder(
        path: String = "",
        template: String? = nil,
        oneseg: Bool = false
    ) -> UUID? {
        guard foldersEditable else { return nil }
        let folder = RecordingFolderEdit(path: path, template: template, oneseg: oneseg)
        folders.append(folder)
        foldersDirty = true
        return folder.id
    }

    @discardableResult
    public mutating func removeFolder(id: UUID) -> Bool {
        guard foldersEditable, let index = folders.firstIndex(where: { $0.id == id }) else {
            return false
        }
        folders.remove(at: index)
        foldersDirty = true
        return true
    }

    @discardableResult
    public mutating func updateFolder(id: UUID, path: String) -> Bool {
        updateFolder(id: id) { $0.setPath(path) }
    }

    @discardableResult
    public mutating func updateFolder(id: UUID, template: String?) -> Bool {
        updateFolder(id: id) { $0.setTemplate(template) }
    }

    @discardableResult
    public mutating func updateFolder(id: UUID, oneseg: Bool) -> Bool {
        updateFolder(id: id) { $0.setOneseg(oneseg) }
    }

    // Convenience labels for App code; all mutations still resolve by UUID.
    @discardableResult
    public mutating func setFolderPath(_ value: String, id: UUID) -> Bool {
        updateFolder(id: id, path: value)
    }

    @discardableResult
    public mutating func setFileNameTemplate(_ value: String?, id: UUID) -> Bool {
        updateFolder(id: id, template: value)
    }

    @discardableResult
    public mutating func setOnesegFolder(_ value: Bool, id: UUID) -> Bool {
        updateFolder(id: id, oneseg: value)
    }

    /// Set a known server post-recording mode. An unknown server value can be
    /// displayed and retained, but cannot be introduced by this editor.
    public mutating func setPostRecordingMode(_ value: String) throws {
        guard Self.supportedPostRecordingModeSet.contains(value) else {
            throw RecordingAdvancedSettingsError.invalidPostRecordingMode
        }
        guard value != postRecordingMode || !postModeDirty else { return }
        postRecordingMode = value
        postModeDirty = true
    }

    public mutating func keepBatch() {
        batchChoice = .unchanged
    }

    public mutating func clearBatch() {
        batchChoice = .clear
    }

    /// Select a path supplied by a local registration or a server preset. The
    /// source is intentionally not encoded here; only the explicit path is.
    public mutating func chooseBatch(path: String) {
        batchChoice = .path(path)
    }

    public mutating func setBatch(path: String?) {
        if let path {
            chooseBatch(path: path)
        } else {
            clearBatch()
        }
    }

    /// Apply only explicitly edited keys to the original snapshot. Callers
    /// should pass this result to `mergingEditedSettings` with the original and
    /// latest snapshots; applying a draft to latest first would hide conflicts.
    public func applying(to original: RecordSettings) -> RecordSettings {
        guard foldersDirty || postModeDirty || batchChoice != .unchanged else {
            return original
        }

        var values = original.rawValues
        if foldersDirty {
            values["recording_folders"] = .array(folders.map { .object($0.rawValues) })
        }
        if postModeDirty {
            values["post_recording_mode"] = .string(postRecordingMode)
        }
        switch batchChoice {
        case .unchanged:
            break
        case .clear:
            values["post_recording_bat_file_path"] = .null
        case .path(let path):
            values["post_recording_bat_file_path"] = .string(path)
        }
        return RecordSettings(rawValues: values)
    }

    /// Validates edited values and then applies them to the original snapshot.
    /// An invalid/malformed untouched server value is never rewritten.
    public func validatedApplying(to original: RecordSettings) throws -> RecordSettings {
        if foldersDirty {
            guard foldersEditable else { throw RecordingAdvancedSettingsError.foldersNotEditable }
            try validateChangedFolders()
        }
        if postModeDirty,
           !Self.supportedPostRecordingModeSet.contains(postRecordingMode) {
            throw RecordingAdvancedSettingsError.invalidPostRecordingMode
        }
        if case .path(let path) = batchChoice {
            try Self.validateBatchPath(path)
        }
        return applying(to: original)
    }

    private mutating func updateFolder(
        id: UUID,
        _ update: (inout RecordingFolderEdit) -> Void
    ) -> Bool {
        guard foldersEditable, let index = folders.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let before = folders[index]
        update(&folders[index])
        if folders[index] != before { foldersDirty = true }
        return true
    }

    private static func isEditableFolderObject(_ value: RawJSONValue) -> Bool {
        guard case .object(let object) = value,
              let path = object["recording_folder_path"],
              case .string = path else {
            return false
        }
        if let template = object["recording_file_name_template"] {
            switch template {
            case .string, .null:
                break
            default:
                return false
            }
        }
        if let oneseg = object["is_oneseg_separate_recording_folder"] {
            guard case .bool = oneseg else { return false }
        }
        return true
    }

    private func validateChangedFolders() throws {
        for folder in folders {
            // Existing server values are allowed to remain untouched for
            // forward compatibility. Validate only a folder whose raw object
            // changed, plus newly-added folders without an original UUID.
            if let original = originalFolderValues[folder.id], original == folder.rawValues {
                continue
            }
            try Self.validateFolder(folder)
        }
    }

    private static func validateFolder(_ folder: RecordingFolderEdit) throws {
        guard let path = folder.recordingFolderPath else {
            throw RecordingAdvancedSettingsError.invalidFolderTemplate
        }
        try validateFolderPath(path)

        if let rawTemplate = folder.rawValues["recording_file_name_template"] {
            switch rawTemplate {
            case .null:
                break
            case .string(let template):
                try validateTemplate(template)
            default:
                throw RecordingAdvancedSettingsError.invalidFolderTemplate
            }
        }
        if let rawOneseg = folder.rawValues["is_oneseg_separate_recording_folder"] {
            guard case .bool = rawOneseg else {
                throw RecordingAdvancedSettingsError.foldersNotEditable
            }
        }
    }

    private static func validateFolderPath(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecordingAdvancedSettingsError.emptyFolderPath
        }
        guard value.utf8.count <= maxFolderPathUTF8Count else {
            throw RecordingAdvancedSettingsError.folderPathTooLong
        }
        guard !containsControlCharacter(value) else {
            throw RecordingAdvancedSettingsError.folderPathContainsControlCharacters
        }
    }

    private static func validateTemplate(_ value: String) throws {
        guard value.utf8.count <= maxTemplateUTF8Count else {
            throw RecordingAdvancedSettingsError.folderTemplateTooLong
        }
        guard !containsControlCharacter(value) else {
            throw RecordingAdvancedSettingsError.folderTemplateContainsControlCharacters
        }
    }

    private static func validateBatchPath(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecordingAdvancedSettingsError.emptyBatchPath
        }
        guard value.utf8.count <= maxBatchPathUTF8Count else {
            throw RecordingAdvancedSettingsError.batchPathTooLong
        }
        guard !containsControlCharacter(value) else {
            throw RecordingAdvancedSettingsError.batchPathContainsControlCharacters
        }
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
    }
}
