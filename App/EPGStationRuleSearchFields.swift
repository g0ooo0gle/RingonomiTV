import Foundation
import SwiftUI
import RingonomiCore

/// Human-readable ARIB major genre names used by EPGStation rule options.
func epgStationGenreName(_ major: Int) -> String {
    switch major {
    case 0: return "ニュース・報道"
    case 1: return "スポーツ"
    case 2: return "情報・ワイドショー"
    case 3: return "ドラマ"
    case 4: return "音楽"
    case 5: return "バラエティ"
    case 6: return "映画"
    case 7: return "アニメ・特撮"
    case 8: return "ドキュメンタリー・教養"
    case 9: return "劇場・公演"
    case 10: return "趣味・教育"
    case 11: return "福祉"
    case 12, 13: return "予約"
    case 14: return "拡張"
    case 15: return "その他"
    default: return "サーバー定義 \(major)"
    }
}

struct EPGStationRuleChannelSelection: View {
    let channels: [EPGStationChannel]
    @Binding var selection: [Int]?
    let editable: Bool

    var body: some View {
        List {
            Section {
                Toggle("すべてのチャンネル", isOn: allChannelsBinding)
                    .disabled(!editable || channels.isEmpty)
                if selection == nil {
                    Text("チャンネルを指定せず、サーバーが扱う全チャンネルを対象にします。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let selection {
                AppSection("チャンネル") {
                    if channels.isEmpty {
                        Text("チャンネル一覧を取得できないため、既存の選択値を保持しています。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(channels) { channel in
                            Toggle(
                                channel.halfWidthName ?? channel.name,
                                isOn: channelBinding(channel.id)
                            )
                            .disabled(!editable)
                        }
                    }
                    if selection.isEmpty {
                        Text("選択なし。保存時にサーバーの検証で拒否される可能性があります。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                let unknownIDs = selection.filter { id in !channels.contains { $0.id == id } }
                if !unknownIDs.isEmpty {
                    AppSection("サーバーから取得できないチャンネル") {
                        Text("既存のチャンネル設定を保持中（\(unknownIDs.map { String($0) }.joined(separator: "、"))）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !editable {
                Section {
                    Text("対象チャンネルの値を解釈できないため、この画面では変更できません。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .appNavigationTitle(Text("対象チャンネル"))
    }

    private var allChannelsBinding: Binding<Bool> {
        Binding(
            get: { selection == nil },
            set: { isAll in
                guard isAll != (selection == nil) else { return }
                selection = isAll ? nil : []
            }
        )
    }

    private func channelBinding(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { selection?.contains(id) ?? false },
            set: { selected in
                guard var values = selection else { return }
                if selected {
                    if !values.contains(id) { values.append(id) }
                } else {
                    values.removeAll { $0 == id }
                }
                selection = values
            }
        )
    }
}

struct EPGStationRuleGenreSelection: View {
    @Binding var value: RawJSONValue?
    let editable: Bool

    var body: some View {
        List {
            Section {
                Toggle("すべてのジャンル", isOn: allGenresBinding)
                    .disabled(!editable)
                if allGenres {
                    Text("ジャンルを指定せず、すべてのジャンルを対象にします。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if arrayValue != nil {
                AppSection("大分類") {
                    ForEach(0..<16, id: \.self) { major in
                        Toggle(epgStationGenreName(major), isOn: majorBinding(major))
                            .disabled(!editable)
                    }
                }

                if arrayValue?.isEmpty == true {
                    Text("ジャンルを1つ以上選択するか、「すべてのジャンル」を選択してください。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if unknownGenreCount > 0 {
                    AppSection("追加のジャンル設定") {
                        Text("\(unknownGenreCount)件の既存値を保持しています。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if hasUnreadableValue {
                Section {
                    Text("ジャンル設定を解釈できないため、既存のサーバー値を保持しています。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !editable {
                Section {
                    Text("時刻指定ルールのジャンルは、この画面では変更せず保持します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .appNavigationTitle(Text("対象ジャンル"))
    }

    private var allGenres: Bool {
        value == nil || isNull(value)
    }

    private var allGenresBinding: Binding<Bool> {
        Binding(
            get: { allGenres },
            set: { selected in
                guard selected != allGenres else { return }
                value = selected ? .null : .array([])
            }
        )
    }

    private var arrayValue: [RawJSONValue]? {
        guard let value else { return nil }
        if case .array(let values) = value { return values }
        return nil
    }

    private var hasUnreadableValue: Bool {
        guard let value else { return false }
        switch value {
        case .null, .array: return false
        default: return true
        }
    }

    private var unknownGenreCount: Int {
        guard let arrayValue else { return 0 }
        return arrayValue.reduce(into: 0) { count, raw in
            guard case .object(let object) = raw,
                  case .integer(let major) = object["genre"],
                  (0...15).contains(major) else {
                count += 1
                return
            }
        }
    }

    private func majorBinding(_ major: Int) -> Binding<Bool> {
        Binding(
            get: { containsMajor(major) },
            set: { selected in setMajor(major, selected: selected) }
        )
    }

    private func containsMajor(_ major: Int) -> Bool {
        guard let arrayValue else { return false }
        return arrayValue.contains { raw in
            guard case .object(let object) = raw,
                  case .integer(let value) = object["genre"] else {
                return false
            }
            return value == major
        }
    }

    private func setMajor(_ major: Int, selected: Bool) {
        guard editable, var values = arrayValue else { return }
        if selected {
            guard !containsMajor(major) else { return }
            values.append(.object(["genre": .integer(major)]))
        } else {
            values.removeAll { raw in
                guard case .object(let object) = raw,
                      case .integer(let value) = object["genre"] else {
                    return false
                }
                return value == major
            }
        }
        value = .array(values)
    }

    private func isNull(_ value: RawJSONValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return true }
        return false
    }
}

struct EPGStationRuleTimeSelection: View {
    @Binding var value: RawJSONValue?
    let editable: Bool
    @State private var editing: EPGStationRuleTimeEdit?

    var body: some View {
        List {
            Section {
                Toggle("すべての曜日・時間帯", isOn: allTimesBinding)
                    .disabled(!editable)
                if allTimes {
                    Text("曜日・時間帯を指定せず、番組情報の条件だけで検索します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if timeValues != nil {
                AppSection("指定した曜日・時間帯") {
                    ForEach(validEntries) { entry in
                        HStack(spacing: 16) {
                            Button {
                                editing = EPGStationRuleTimeEdit(
                                    index: entry.index,
                                    original: entry.object,
                                    draft: entry.draft
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(weekSummary(entry.draft.week))
                                    Text(timeSummary(entry.draft))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .disabled(!editable)

                            Button("削除", role: .destructive) {
                                remove(at: entry.index)
                            }
                            .disabled(!editable)
                        }
                    }

                    if validEntries.isEmpty {
                        Text("指定された時間帯はありません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if unreadableEntryCount > 0 {
                        Text("\(unreadableEntryCount)件の既存値を保持しています。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button("曜日・時間帯を追加") {
                        editing = EPGStationRuleTimeEdit(
                            index: nil,
                            original: nil,
                            draft: EPGStationRuleTimeDraft(week: 127, start: nil, range: nil)
                        )
                    }
                    .disabled(!editable)
                }
            } else if hasUnreadableValue {
                Section {
                    Text("曜日・時間帯を解釈できないため、既存のサーバー値を保持しています。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !editable {
                Section {
                    Text("時刻指定ルールの時間条件は、単位を変換せず保持します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .appNavigationTitle(Text("曜日・時間帯"))
        .sheet(item: $editing) { item in
            EPGStationRuleTimeEditor(draft: item.draft) { draft in
                apply(draft, to: item)
            }
        }
    }

    private var allTimes: Bool {
        value == nil || isNull(value)
    }

    private var allTimesBinding: Binding<Bool> {
        Binding(
            get: { allTimes },
            set: { selected in
                guard selected != allTimes else { return }
                value = selected ? .null : .array([])
            }
        )
    }

    private var timeValues: [RawJSONValue]? {
        guard let value else { return nil }
        if case .array(let values) = value { return values }
        return nil
    }

    private var hasUnreadableValue: Bool {
        guard let value else { return false }
        switch value {
        case .null, .array: return false
        default: return true
        }
    }

    private var validEntries: [EPGStationRuleTimeEntry] {
        guard let timeValues else { return [] }
        return timeValues.enumerated().compactMap { index, raw in
            guard case .object(let object) = raw,
                  case .integer(let week) = object["week"],
                  (1...127).contains(week) else {
                return nil
            }
            let start: Int?
            if let rawStart = object["start"], !isNull(rawStart) {
                guard case .integer(let startValue) = rawStart,
                      (0...23).contains(startValue) else {
                    return nil
                }
                start = startValue
            } else {
                start = nil
            }
            let range: Int?
            if let rawRange = object["range"], !isNull(rawRange) {
                guard case .integer(let rangeValue) = rawRange,
                      (1...23).contains(rangeValue) else {
                    return nil
                }
                range = rangeValue
            } else {
                range = nil
            }
            return EPGStationRuleTimeEntry(
                index: index,
                object: object,
                draft: EPGStationRuleTimeDraft(week: week, start: start, range: range)
            )
        }
    }

    private var unreadableEntryCount: Int {
        max(0, (timeValues?.count ?? 0) - validEntries.count)
    }

    private func remove(at index: Int) {
        guard editable, var values = timeValues, values.indices.contains(index) else { return }
        values.remove(at: index)
        value = .array(values)
    }

    private func apply(
        _ draft: EPGStationRuleTimeDraft,
        to edit: EPGStationRuleTimeEdit
    ) -> Bool {
        guard editable, (1...127).contains(draft.week),
              draft.range.map({ (1...23).contains($0) }) ?? true,
              draft.start.map({ (0...23).contains($0) }) ?? true,
              draft.start == nil || draft.range != nil else {
            return false
        }
        var values = timeValues ?? []
        if let index = edit.index {
            guard let original = edit.original,
                  values.indices.contains(index),
                  case .object(var object) = values[index],
                  object == original else {
                return false
            }
            object["week"] = .integer(draft.week)
            if let start = draft.start {
                object["start"] = .integer(start)
                object["range"] = draft.range.map(RawJSONValue.integer) ?? .null
            } else {
                object.removeValue(forKey: "start")
                object.removeValue(forKey: "range")
            }
            values[index] = .object(object)
        } else {
            var object: [String: RawJSONValue] = ["week": .integer(draft.week)]
            if let start = draft.start {
                object["start"] = .integer(start)
                object["range"] = draft.range.map(RawJSONValue.integer) ?? .null
            } else {
                object.removeValue(forKey: "start")
                object.removeValue(forKey: "range")
            }
            values.append(.object(object))
        }
        value = .array(values)
        return true
    }

    private func weekSummary(_ week: Int) -> String {
        let names = ["日", "月", "火", "水", "木", "金", "土"]
        let selected = names.indices.compactMap { index in
            week & (1 << index) != 0 ? names[index] : nil
        }
        return selected.isEmpty ? "曜日未指定" : selected.joined(separator: "・")
    }

    private func timeSummary(_ draft: EPGStationRuleTimeDraft) -> String {
        guard let start = draft.start else { return "終日（曜日のみ）" }
        let startText = String(format: "%02d時", start)
        let rangeText = draft.range.map { "\($0)時間" } ?? "継続時間未指定"
        return "\(startText)から\(rangeText)"
    }

    private func isNull(_ value: RawJSONValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return true }
        return false
    }
}

private struct EPGStationRuleTimeEntry: Identifiable {
    let index: Int
    let object: [String: RawJSONValue]
    let draft: EPGStationRuleTimeDraft

    var id: Int { index }
}

private struct EPGStationRuleTimeEdit: Identifiable {
    let id = UUID()
    let index: Int?
    let original: [String: RawJSONValue]?
    let draft: EPGStationRuleTimeDraft
}

private struct EPGStationRuleTimeDraft: Equatable {
    var week: Int
    var start: Int?
    var range: Int?
}

private struct EPGStationRuleTimeEditor: View {
    @State private var draft: EPGStationRuleTimeDraft
    let onApply: (EPGStationRuleTimeDraft) -> Bool
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let weekNames = ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"]

    init(
        draft: EPGStationRuleTimeDraft,
        onApply: @escaping (EPGStationRuleTimeDraft) -> Bool
    ) {
        var normalized = draft
        if normalized.start != nil, normalized.range == nil {
            normalized.range = 1
        }
        _draft = State(initialValue: normalized)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                AppSection("曜日") {
                    ForEach(weekNames.indices, id: \.self) { index in
                        Toggle(weekNames[index], isOn: weekdayBinding(index))
                    }
                    Text("複数の曜日を選ぶと、いずれかの曜日に一致します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                AppSection("時間") {
                    Picker("開始時刻", selection: startBinding) {
                        Text("終日").tag(nil as Int?)
                        ForEach(0...23, id: \.self) { hour in
                            Text(String(format: "%02d時", hour)).tag(Optional(hour))
                        }
                    }
                    Picker("継続時間", selection: $draft.range) {
                        Text("指定なし").tag(nil as Int?)
                        ForEach(1...23, id: \.self) { range in
                            Text("\(range)時間").tag(Optional(range))
                        }
                    }.disabled(draft.start == nil)
                    if draft.start == nil {
                        Text("終日を選ぶと、開始時刻と継続時間を指定しない曜日条件として保存します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("適用") {
                        guard (1...127).contains(draft.week) else {
                            error = "曜日を1つ以上選択してください。"
                            return
                        }
                        guard draft.start == nil || draft.range != nil else {
                            error = "開始時刻を指定した場合は、継続時間も選択してください。"
                            return
                        }
                        guard onApply(draft) else {
                            error = "値が更新されています。画面を閉じてから開き直してください。"
                            return
                        }
                        dismiss()
                    }
                    Button("キャンセル", role: .cancel) { dismiss() }
                }
            }
            .appNavigationTitle(Text("曜日・時間帯を編集"))
            .alert("入力を確認してください", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("閉じる") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func weekdayBinding(_ index: Int) -> Binding<Bool> {
        let bit = 1 << index
        return Binding(
            get: { draft.week & bit != 0 },
            set: { enabled in
                if enabled {
                    draft.week |= bit
                } else {
                    draft.week &= ~bit
                }
            }
        )
    }

    private var startBinding: Binding<Int?> {
        Binding(
            get: { draft.start },
            set: { start in
                draft.start = start
                if start == nil {
                    draft.range = nil
                } else if draft.range == nil {
                    draft.range = 1
                }
            }
        )
    }
}

struct EPGStationRuleJSONSummary: View {
    let title: String
    let value: RawJSONValue?
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                if value == nil {
                    Text("未指定")
                        .foregroundStyle(.secondary)
                }
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }
}
