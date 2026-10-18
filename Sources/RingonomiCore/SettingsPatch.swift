import Foundation

public enum SettingsPatchError: LocalizedError, Equatable {
    case conflictingChange

    public var errorDescription: String? {
        "同じ設定が別の画面で変更されています。画面を閉じて開き直してください。"
    }
}

/// Apply only the fields edited by this client to the latest server settings.
/// An overlapping change from another client must be resolved explicitly.
public func mergingEditedSettings(
    original: [String: RawJSONValue],
    edited: [String: RawJSONValue],
    latest: [String: RawJSONValue]
) throws -> [String: RawJSONValue] {
    var result = latest
    for key in Set(original.keys).union(edited.keys) {
        let before = original[key]
        let after = edited[key]
        guard before != after else { continue }
        guard latest[key] == before || latest[key] == after else {
            throw SettingsPatchError.conflictingChange
        }
        result[key] = after
    }
    return result
}
