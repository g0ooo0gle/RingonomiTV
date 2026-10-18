import Foundation
import RingonomiCore

/// All writes share the reservation journal. A failed verification is an
/// unknown outcome, not permission to send the mutation again.
@MainActor
enum EPGStationRuleActions {
    static func save(address: String, original: EPGStationRule?, edited: EPGStationRuleOptions,
                     mutation: EPGStationMutationStore) async throws {
        let client = try EPGStationClient(address: address)
        try await mutation.perform(address: address, title: epgStationRuleTitle(edited),
                                   action: original == nil ? "ルールを追加" : "ルールを変更",
                                   target: "rule", ruleID: original?.id) {
            let oldDirectory = original?.options.rawValues["saveOption"].flatMap(epgStationRuleObject)?["parentDirectoryName"]
            let editedDirectory = edited.rawValues["saveOption"].flatMap(epgStationRuleObject)?["parentDirectoryName"]
            if editedDirectory != oldDirectory, case .string(let directory) = editedDirectory, !directory.isEmpty {
                let config = try await client.config()
                guard config.recordedDirectories.contains(directory) else {
                    throw ReservationUIError("選択した保存先がありません。画面を開き直してください。")
                }
            }
            let all = try await allRules(client: client)
            let options: EPGStationRuleOptions
            if let original {
                // Fetch last, after the potentially paginated duplicate scan.
                // EPGStation has no conditional PUT; this narrows, but cannot
                // eliminate, the interval in which another client may write.
                let latest = try await client.rule(id: original.id)
                options = try mergingEditedRuleOptions(original: original.options, edited: edited, latest: latest.options)
            } else { options = edited }
            try requireConstrainedSearch(options)
            guard !all.contains(where: { $0.id != original?.id && epgStationRuleOptionsMatch(requested: options, actual: $0.options) }) else {
                throw ReservationUIError("同じ条件と録画設定のルールがすでにあります。一覧を確認してください。")
            }
            return options
        } send: { options in
            let id: Int
            if let original {
                id = original.id
                try await client.updateRule(id: id, options: options)
            } else { id = try await client.createRule(options: options) }
            let readBack = try await client.rule(id: id)
            guard epgStationRuleOptionsMatch(requested: options, actual: readBack.options) else {
                throw EPGStationWriteError.outcomeUnknown
            }
        }
    }

    static func setEnabled(address: String, original: EPGStationRule, mutation: EPGStationMutationStore) async throws {
        let client = try EPGStationClient(address: address)
        let enabled = original.options.enabled != true
        try await mutation.perform(address: address, title: epgStationRuleTitle(original.options),
                                   action: enabled ? "ルールを有効化" : "ルールを無効化", target: "rule", ruleID: original.id) {
            let latest = try await client.rule(id: original.id)
            guard latest.options == original.options else { throw SettingsPatchError.conflictingChange }
            if enabled { try requireConstrainedSearch(latest.options) }
            return latest.options
        } send: { options in
            try await client.setRuleEnabled(id: original.id, enabled: enabled)
            var expected = options
            expected.enabled = enabled
            let readBack = try await client.rule(id: original.id)
            guard epgStationRuleOptionsMatch(requested: expected, actual: readBack.options) else {
                throw EPGStationWriteError.outcomeUnknown
            }
        }
    }

    static func delete(address: String, original: EPGStationRule, mutation: EPGStationMutationStore) async throws {
        let client = try EPGStationClient(address: address)
        try await mutation.perform(address: address, title: epgStationRuleTitle(original.options),
                                   action: "ルールを削除", target: "rule", ruleID: original.id) {
            let latest = try await client.rule(id: original.id)
            guard latest.options == original.options else { throw SettingsPatchError.conflictingChange }
            return original.id
        } send: { id in
            try await client.deleteRule(id: id)
            do {
                _ = try await client.rule(id: id)
                throw EPGStationWriteError.outcomeUnknown
            } catch EPGStationError.httpStatus(404) { /* Confirmed absent. */ }
        }
    }

    private static func allRules(client: EPGStationClient) async throws -> [EPGStationRule] {
        var result: [EPGStationRule] = []
        var seen = Set<Int>()
        while result.count <= 20_000 {
            try Task.checkCancellation()
            let page = try await client.rules(offset: result.count, limit: 100)
            guard page.rules.allSatisfy({ seen.insert($0.id).inserted }) else { throw EPGStationError.invalidResponse }
            result += page.rules
            if result.count >= page.total { return result }
            guard !page.rules.isEmpty else { throw EPGStationError.invalidResponse }
        }
        throw ReservationUIError("ルールが多すぎるため重複を確認できません。EPGStation側で確認してください。")
    }

    private static func requireConstrainedSearch(_ options: EPGStationRuleOptions) throws {
        let search = options.searchValues
        for (value, label) in [(search["durationMin"], "番組長の最短"), (search["durationMax"], "番組長の最長"), (options.reserveValues["periodToAvoidDuplicate"], "重複回避期間")] {
            guard let value, value != .null else { continue }
            guard case .integer(let number) = value, number >= 0 else {
                throw ReservationUIError(label + "は0以上の整数で入力してください。")
            }
        }
        if case .integer(let minimum) = search["durationMin"], case .integer(let maximum) = search["durationMax"], minimum > maximum {
            throw ReservationUIError("番組長の最長は、最短以上の値にしてください。")
        }
        let keyword = epgStationRuleString(search["keyword"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let arrays = ["channelIds", "genres", "times", "searchPeriods"]
        for key in arrays {
            if case .array(let values) = search[key], values.isEmpty {
                throw ReservationUIError("対象チャンネル・ジャンル・曜日時刻に空の選択があります。条件を選ぶか、対象を「すべて」に戻してください。")
            }
        }
        let hasSelection = arrays.contains { key in
            if case .array(let values) = search[key] { return !values.isEmpty }
            return false
        }
        guard !keyword.isEmpty || hasSelection else {
            throw ReservationUIError("キーワード、放送局、ジャンル、曜日時刻のいずれかを指定してください。")
        }
    }
}

func epgStationRuleObject(_ value: RawJSONValue) -> [String: RawJSONValue]? {
    if case .object(let values) = value { return values }
    return nil
}

func epgStationRuleString(_ value: RawJSONValue?) -> String {
    if case .string(let string) = value { return string }
    return ""
}

func epgStationRuleTitle(_ options: EPGStationRuleOptions) -> String {
    let keyword = epgStationRuleString(options.searchValues["keyword"])
    return keyword.isEmpty ? (options.isTimeSpecification == true ? "曜日・時刻指定ルール" : "条件指定ルール") : keyword
}

func epgStationRuleOptionsMatch(requested: EPGStationRuleOptions, actual: EPGStationRuleOptions) -> Bool {
    requested.matchesServerReadback(actual)
}
