import Foundation
import SwiftUI
import RingonomiCore

/// Lossless editor fields for an EPGStation automatic-recording rule.
///
/// Each update is applied to one JSON object in EPGStationRuleOptions.
/// Unknown keys are never rebuilt from a typed model, so fields added by a
/// newer EPGStation server survive an edit made in this app.
struct EPGStationRuleFields: View {
    @Binding var options: EPGStationRuleOptions
    let channels: [EPGStationChannel]
    let directories: [String]

    var body: some View {
        Group {
            searchTextFields
            searchTargetFields
            broadcastFields
            channelFields
            complexSearchFields
            durationFields
            reserveFields
            saveFields
            encodeFields
            unknownFields
        }
    }

    private var searchTextFields: some View {
        AppSection("キーワード") {
            TextField("検索キーワード", text: searchStringBinding("keyword"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("除外キーワード", text: searchStringBinding("ignoreKeyword"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !canEditGroup("searchOption") {
                Text("検索条件を読み取れないため編集できません。サーバーの値を保持しています。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .disabled(!canEditGroup("searchOption"))
    }

    private var searchTargetFields: some View {
        AppSection("検索対象・除外") {
            Toggle("番組名を検索", isOn: searchBoolBinding("name"))
            Toggle("番組概要を検索", isOn: searchBoolBinding("description"))
            Toggle("拡張番組情報を検索", isOn: searchBoolBinding("extended"))
            Toggle("大文字・小文字を区別", isOn: searchBoolBinding("keyCS"))
            Toggle("正規表現を使用", isOn: searchBoolBinding("keyRegExp"))

            Divider()

            Toggle("除外キーワード：大文字・小文字を区別", isOn: searchBoolBinding("ignoreKeyCS"))
            Toggle("除外キーワード：正規表現を使用", isOn: searchBoolBinding("ignoreKeyRegExp"))
            Toggle("除外キーワードを番組名にも適用", isOn: searchBoolBinding("ignoreName"))
            Toggle("除外キーワードを番組概要にも適用", isOn: searchBoolBinding("ignoreDescription"))
            Toggle("除外キーワードを拡張情報にも適用", isOn: searchBoolBinding("ignoreExtended"))
        }
        .disabled(!canEditGroup("searchOption"))
    }

    private var broadcastFields: some View {
        AppSection("放送種別") {
            Toggle("地上波（GR）", isOn: searchBoolBinding("GR"))
            Toggle("BS", isOn: searchBoolBinding("BS"))
            Toggle("CS", isOn: searchBoolBinding("CS"))
            Toggle("スカパー！（SKY）", isOn: searchBoolBinding("SKY"))

            Picker("無料・有料", selection: freeScopeBinding) {
                ForEach(EPGStationRuleFreeScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
        }
        .disabled(!canEditGroup("searchOption"))
    }

    private var channelFields: some View {
        AppSection("対象チャンネル") {
            NavigationLink(channelSelectionTitle) {
                EPGStationRuleChannelSelection(
                    channels: channels,
                    selection: channelIDsBinding,
                    editable: canEditChannelSelection
                )
            }
            .disabled(!canEditChannelSelection)

            if let value = searchValue("channelIds"), !isNull(value), channelIDs == nil {
                Text("対象チャンネルの値を解釈できないため、既存の値を保持したまま変更を停止しています。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .disabled(!canEditGroup("searchOption"))
    }

    private var complexSearchFields: some View {
        AppSection("詳細な検索条件") {
            HStack {
                Text("時間指定モード")
                Spacer()
                Text(timeSpecificationTitle)
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                EPGStationRuleGenreSelection(
                    value: searchRawBinding("genres"),
                    editable: canEditNormalSearch
                )
            } label: {
                EPGStationRuleJSONSummary(
                    title: "ジャンル",
                    value: searchValue("genres"),
                    summary: genreSummary(searchValue("genres"))
                )
            }
            .disabled(!canEditNormalSearch)

            NavigationLink {
                EPGStationRuleTimeSelection(
                    value: searchRawBinding("times"),
                    editable: canEditNormalSearch
                )
            } label: {
                EPGStationRuleJSONSummary(
                    title: "曜日・時間帯",
                    value: searchValue("times"),
                    summary: timeSummary(searchValue("times"))
                )
            }
            .disabled(!canEditNormalSearch)

            EPGStationRuleJSONSummary(
                title: "検索期間",
                value: searchValue("searchPeriods"),
                summary: searchPeriodsSummary(searchValue("searchPeriods"))
            )

            Text(options.isTimeSpecification == true
                 ? "時刻指定ルールの曜日・時間帯とジャンルは、サーバー値を保持したまま表示します。"
                 : "曜日・時間帯とジャンルを編集できます。検索期間など未対応の項目は保持します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!canEditGroup("searchOption"))
    }

    private var durationFields: some View {
        AppSection("番組長") {
            TextField("最短（分・空欄は指定なし）", text: searchIntegerBinding("durationMin"))
                .textInputAutocapitalization(.never)
            TextField("最長（分・空欄は指定なし）", text: searchIntegerBinding("durationMax"))
                .textInputAutocapitalization(.never)
            Text("分単位で指定します。数字以外の入力は保存時に検証エラーとして扱い、黙って削除しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!canEditGroup("searchOption"))
    }

    private var reserveFields: some View {
        AppSection("予約") {
            Toggle("予約を有効にする", isOn: reserveBoolBinding("enable", default: true))
            Toggle("終了時刻不足を許可", isOn: reserveBoolBinding("allowEndLack"))
            Toggle("重複を避ける", isOn: reserveBoolBinding("avoidDuplicate"))
            TextField(
                "重複回避期間（日・空欄は指定なし）",
                text: reserveIntegerBinding("periodToAvoidDuplicate")
            )
            if let tags = reserveValue("tags") {
                EPGStationRuleJSONSummary(
                    title: "タグ",
                    value: tags,
                    summary: rawSummary(tags)
                )
            }
            if !canEditGroup("reserveOption") {
                Text("予約設定を読み取れないため編集できません。サーバーの値を保持しています。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .disabled(!canEditGroup("reserveOption"))
    }

    private var saveFields: some View {
        AppSection("保存先") {
            NavigationLink(saveDirectoryTitle) {
                EPGStationChoiceList(
                    title: "保存先",
                    values: saveDirectoryChoices,
                    selection: saveDirectory
                ) { value in
                    setSaveDirectory(value)
                }
            }

            if let saveOption {
                if let parent = stringValue(saveOption["parentDirectoryName"]) {
                    Text("親ディレクトリ：\(parent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let directory = stringValue(saveOption["directory"]) {
                    Text("相対保存先：\(directory)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !unknownKeys(in: saveOption, known: Self.saveKnownKeys).isEmpty {
                    Text("追加の保存設定を保持しています。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let raw = options.rawValues["saveOption"], !isNull(raw) {
                Text("保存先設定を読み取れないため編集できません。サーバーの値を保持しています。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("「サーバーの既定」を選ぶと、サーバー側の保存先設定を使います。相対保存先など他の設定は保持します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!canEditOptionalGroup("saveOption"))
    }

    private var encodeFields: some View {
        AppSection("エンコード") {
            if let encodeOption {
                ForEach(1...3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("エンコード\(index)")
                        if let mode = stringValue(encodeOption["mode\(index)"]), !mode.isEmpty {
                            Text("モード：\(mode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let parent = stringValue(encodeOption["encodeParentDirectoryName\(index)"]), !parent.isEmpty {
                            Text("親ディレクトリ：\(parent)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let directory = stringValue(encodeOption["directory\(index)"]), !directory.isEmpty {
                            Text("保存先：\(directory)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let delete = boolValue(encodeOption["isDeleteOriginalAfterEncode"]) {
                    Text(delete ? "エンコード後に元ファイルを削除します。" : "エンコード後も元ファイルを保持します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !unknownKeys(in: encodeOption, known: Self.encodeKnownKeys).isEmpty {
                    Text("追加のエンコード設定を保持しています。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("エンコード設定なし")
                    .foregroundStyle(.secondary)
            }

            Text("エンコード設定は表示のみです。未対応の項目もそのまま保持します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!canEditOptionalGroup("encodeOption"))
    }

    @ViewBuilder
    private var unknownFields: some View {
        let paths = unknownOptionPaths
        if !paths.isEmpty {
            AppSection("サーバー由来の未対応項目") {
                Text("サーバーが追加した設定を保持しています。編集時にも削除しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(paths.count)項目を保持中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timeSpecificationTitle: String {
        guard let isTimeSpecified = options.isTimeSpecification else { return "設定なし" }
        return isTimeSpecified ? "曜日・時刻を指定して予約" : "番組情報から予約"
    }

    private var canEditNormalSearch: Bool {
        canEditGroup("searchOption") && options.isTimeSpecification != true
    }

    private var channelSelectionTitle: String {
        guard let channelIDs else {
            if searchValue("channelIds") == nil || isNull(searchValue("channelIds")) {
                return "全チャンネル"
            }
            return "チャンネル設定を読み取れません"
        }
        if channelIDs.isEmpty { return "選択なし（確認が必要）" }
        return "選択したチャンネル：\(channelIDs.count)件"
    }

    private var canEditChannelSelection: Bool {
        guard canEditGroup("searchOption") else { return false }
        guard let value = searchValue("channelIds") else { return true }
        if isNull(value) { return true }
        guard case .array(let values) = value else { return false }
        return values.allSatisfy {
            if case .integer(let id) = $0 { return id > 0 }
            return false
        }
    }

    private var channelIDs: [Int]? {
        guard let value = searchValue("channelIds") else { return nil }
        if isNull(value) { return nil }
        guard case .array(let values) = value else { return nil }
        var result: [Int] = []
        for value in values {
            guard case .integer(let id) = value else { return nil }
            result.append(id)
        }
        return result
    }

    private var channelIDsBinding: Binding<[Int]?> {
        Binding(
            get: { channelIDs },
            set: { newValue in
                updateSearch(
                    "channelIds",
                    newValue.map { .array($0.map(RawJSONValue.integer)) } ?? .null
                )
            }
        )
    }

    private var freeScopeBinding: Binding<EPGStationRuleFreeScope> {
        Binding(
            get: {
                guard let value = searchValue("isFree"),
                      case .bool(let isFree) = value else {
                    return .all
                }
                return isFree ? .free : .all
            },
            set: { scope in
                let value: RawJSONValue
                switch scope {
                case .all: value = .bool(false)
                case .free: value = .bool(true)
                }
                updateSearch("isFree", value)
            }
        )
    }

    private var saveOption: [String: RawJSONValue]? {
        optionObject("saveOption")
    }

    private var encodeOption: [String: RawJSONValue]? {
        optionObject("encodeOption")
    }

    private var saveDirectoryKey: String { "parentDirectoryName" }

    private var saveDirectory: String? {
        guard let value = saveOption?[saveDirectoryKey] else { return "" }
        return stringValue(value) ?? ""
    }

    private var saveDirectoryTitle: String {
        let value = saveDirectory ?? ""
        return value.isEmpty ? "サーバーの既定" : value
    }

    private var saveDirectoryChoices: [(String, String)] {
        var values = [("", "サーバーの既定")]
        values.append(contentsOf: directories.filter { !$0.isEmpty }.map { ($0, $0) })
        if let current = saveDirectory, !current.isEmpty, !values.contains(where: { $0.0 == current }) {
            values.append((current, current + "（現在値）"))
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0.0).inserted }
    }

    private var unknownOptionPaths: [String] {
        var paths: [String] = []
        let topUnknown = unknownKeys(in: options.rawValues, known: Self.topKnownKeys)
        paths.append(contentsOf: topUnknown)
        if let search = optionObject("searchOption") {
            paths.append(contentsOf: unknownKeys(in: search, known: Self.searchKnownKeys).map { "searchOption.\($0)" })
        }
        if let reserve = optionObject("reserveOption") {
            paths.append(contentsOf: unknownKeys(in: reserve, known: Self.reserveKnownKeys).map { "reserveOption.\($0)" })
        }
        if let save = saveOption {
            paths.append(contentsOf: unknownKeys(in: save, known: Self.saveKnownKeys).map { "saveOption.\($0)" })
        }
        if let encode = encodeOption {
            paths.append(contentsOf: unknownKeys(in: encode, known: Self.encodeKnownKeys).map { "encodeOption.\($0)" })
        }
        return paths.sorted()
    }

    private func searchValue(_ key: String) -> RawJSONValue? {
        optionObject("searchOption")?[key]
    }

    private func reserveValue(_ key: String) -> RawJSONValue? {
        optionObject("reserveOption")?[key]
    }

    private func optionObject(_ key: String) -> [String: RawJSONValue]? {
        guard let value = options.rawValues[key] else { return nil }
        guard case .object(let object) = value else { return nil }
        return object
    }

    private func canEditGroup(_ key: String) -> Bool {
        guard let value = options.rawValues[key] else { return true }
        switch value {
        case .object, .null: return true
        default: return false
        }
    }

    private func canEditOptionalGroup(_ key: String) -> Bool {
        canEditGroup(key)
    }

    private func updateSearch(_ key: String, _ value: RawJSONValue) {
        updateNestedObject("searchOption", key: key, value: value)
    }

    private func updateReserve(_ key: String, _ value: RawJSONValue) {
        updateNestedObject("reserveOption", key: key, value: value)
    }

    private func updateNestedObject(_ group: String, key: String, value: RawJSONValue) {
        guard canEditGroup(group) else { return }
        var values = optionObject(group) ?? [:]
        values[key] = value
        options.rawValues[group] = .object(values)
    }

    private func setSaveDirectory(_ value: String) {
        guard canEditOptionalGroup("saveOption") else { return }
        if value.isEmpty, saveOption == nil {
            options.rawValues.removeValue(forKey: "saveOption")
            return
        }
        var values = optionObject("saveOption") ?? [:]
        values[saveDirectoryKey] = value.isEmpty ? .null : .string(value)
        options.rawValues["saveOption"] = .object(values)
    }

    private func searchStringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { stringValue(searchValue(key)) ?? "" },
            set: { updateSearch(key, .string($0)) }
        )
    }

    private func searchRawBinding(_ key: String) -> Binding<RawJSONValue?> {
        Binding(
            get: { searchValue(key) },
            set: { updateSearch(key, $0 ?? .null) }
        )
    }

    private func searchIntegerBinding(_ key: String) -> Binding<String> {
        integerBinding(
            get: { searchValue(key) },
            set: { updateSearch(key, $0) }
        )
    }

    private func reserveIntegerBinding(_ key: String) -> Binding<String> {
        integerBinding(
            get: { reserveValue(key) },
            set: { updateReserve(key, $0) }
        )
    }

    private func integerBinding(
        get: @escaping () -> RawJSONValue?,
        set: @escaping (RawJSONValue) -> Void
    ) -> Binding<String> {
        Binding(
            get: { integerText(get()) },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    set(.null)
                } else if let value = Int(trimmed) {
                    set(.integer(value))
                } else {
                    set(.string(text))
                }
            }
        )
    }

    private func searchBoolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { boolValue(searchValue(key)) ?? false },
            set: { updateSearch(key, .bool($0)) }
        )
    }

    private func reserveBoolBinding(_ key: String, default defaultValue: Bool = false) -> Binding<Bool> {
        Binding(
            get: { boolValue(reserveValue(key)) ?? defaultValue },
            set: { updateReserve(key, .bool($0)) }
        )
    }

    private func stringValue(_ value: RawJSONValue?) -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else { return nil }
        return string
    }

    private func boolValue(_ value: RawJSONValue?) -> Bool? {
        guard let value else { return nil }
        guard case .bool(let bool) = value else { return nil }
        return bool
    }

    private func integerText(_ value: RawJSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .integer(let integer): return String(integer)
        case .number(let number): return String(number)
        case .string(let string): return string
        case .null: return ""
        default: return rawSummary(value)
        }
    }

    private func isNull(_ value: RawJSONValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return true }
        return false
    }

    private func rawSummary(_ value: RawJSONValue?) -> String {
        guard value != nil else { return "未指定" }
        return "サーバー値を保持中（この画面では編集できません）"
    }

    private func genreSummary(_ value: RawJSONValue?) -> String {
        guard let value else { return "未指定（全ジャンル）" }
        if isNull(value) { return "未指定（全ジャンル）" }
        guard case .array(let genres) = value else { return rawSummary(value) }
        if genres.isEmpty { return "0件（保存時に確認が必要）" }
        let items = genres.prefix(5).map { genre in
            guard case .object(let object) = genre else { return rawSummary(genre) }
            let major = integerText(object["genre"])
            let sub = integerText(object["subGenre"])
            let majorName = Int(major).map(epgStationGenreName) ?? major
            return sub.isEmpty ? majorName : "\(majorName)・中分類 \(sub)"
        }
        let suffix = genres.count > items.count ? "、ほか\(genres.count - items.count)件" : ""
        return items.joined(separator: "、") + suffix
    }

    private func timeSummary(_ value: RawJSONValue?) -> String {
        guard let value else { return "未指定（全曜日・時間帯）" }
        if isNull(value) { return "未指定（全曜日・時間帯）" }
        guard case .array(let times) = value else { return rawSummary(value) }
        if times.isEmpty { return "0件（保存時に確認が必要）" }
        if options.isTimeSpecification == true {
            return "\(times.count)件（時刻指定ルールのサーバー値を保持）"
        }
        let items = times.prefix(4).map { time in
            guard case .object(let object) = time else { return rawSummary(time) }
            let week = integerText(object["week"])
            let start = integerText(object["start"])
            let range = integerText(object["range"])
            if start.isEmpty {
                return "\(weekdaySummary(week))・終日（曜日のみ）"
            }
            let rangeText = range.isEmpty ? "継続時間未指定" : "\(range)時間"
            return "\(weekdaySummary(week))・\(start)時から\(rangeText)"
        }
        let suffix = times.count > items.count ? "、ほか\(times.count - items.count)件" : ""
        return items.joined(separator: "、") + suffix
    }

    private func weekdaySummary(_ value: String) -> String {
        guard let week = Int(value) else { return "曜日指定" }
        let names = ["日", "月", "火", "水", "木", "金", "土"]
        let selected = names.indices.compactMap { index in
            week & (1 << index) != 0 ? names[index] : nil
        }
        return selected.isEmpty ? "曜日未指定" : selected.joined(separator: "・")
    }

    private func searchPeriodsSummary(_ value: RawJSONValue?) -> String {
        guard let value else { return "未指定" }
        if isNull(value) { return "未指定" }
        guard case .array(let periods) = value else { return rawSummary(value) }
        if periods.isEmpty { return "0件" }
        return "\(periods.count)件（サーバー値を保持）"
    }

    private func unknownKeys(
        in values: [String: RawJSONValue],
        known: Set<String>
    ) -> [String] {
        values.keys.filter { !known.contains($0) }.sorted()
    }

    private static let topKnownKeys: Set<String> = [
        "isTimeSpecification", "searchOption", "reserveOption", "saveOption", "encodeOption"
    ]

    private static let searchKnownKeys: Set<String> = [
        "keyword", "ignoreKeyword",
        "keyCS", "keyRegExp", "name", "description", "extended",
        "ignoreKeyCS", "ignoreKeyRegExp", "ignoreName", "ignoreDescription", "ignoreExtended",
        "GR", "BS", "CS", "SKY", "isFree",
        "channelIds", "genres", "times", "durationMin", "durationMax", "searchPeriods"
    ]

    private static let reserveKnownKeys: Set<String> = [
        "enable", "allowEndLack", "avoidDuplicate", "periodToAvoidDuplicate", "tags"
    ]

    private static let saveKnownKeys: Set<String> = [
        "parentDirectoryName", "directory", "recordedFormat"
    ]

    private static let encodeKnownKeys: Set<String> = [
        "mode1", "encodeParentDirectoryName1", "directory1",
        "mode2", "encodeParentDirectoryName2", "directory2",
        "mode3", "encodeParentDirectoryName3", "directory3",
        "isDeleteOriginalAfterEncode"
    ]
}

private enum EPGStationRuleFreeScope: Hashable, CaseIterable {
    case all
    case free

    var title: String {
        switch self {
        case .all: return "すべて"
        case .free: return "無料放送のみ"
        }
    }
}
