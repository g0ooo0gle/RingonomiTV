import SwiftUI
import RingonomiCore

struct KeywordTimeRangeSelection: View {
    @Binding var selection: [ProgramSearchDate]?
    @State private var editing: TimeRangeEdit?

    var body: some View {
        List {
            Section {
                Toggle("すべての日時", isOn: Binding(
                    get: { selection == nil },
                    set: { isAll in
                        guard isAll != (selection == nil) else { return }
                        selection = isAll ? nil : []
                    }
                ))
                Text("番組の開始日時で判定します。複数の範囲は、いずれかに一致する番組を対象にします。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let ranges = selection {
                AppSection("指定した日時範囲") {
                    ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
                        HStack(spacing: 24) {
                            Button {
                                editing = TimeRangeEdit(index: index, range: range)
                            } label: {
                                Text(KeywordSearchFilters.timeRangeSummary(range))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            Button("削除", role: .destructive) {
                                guard var values = selection, values.indices.contains(index), values[index] == range else { return }
                                values.remove(at: index)
                                selection = values
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if ranges.isEmpty {
                        Text("日時範囲を追加するか「すべての日時」を選択してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("日時範囲を追加") {
                        editing = TimeRangeEdit(index: nil, range: ProgramSearchDate(
                            startDayOfWeek: 0, startHour: 0, startMinute: 0,
                            endDayOfWeek: 0, endHour: 1, endMinute: 0
                        ))
                    }
                }
            }
        }
        .appNavigationTitle(Text("曜日・時間帯"))
        .sheet(item: $editing) { item in
            KeywordTimeRangeEditor(range: item.range, allowUnchangedRange: item.index != nil) { updated in
                guard var values = selection else { return false }
                if let index = item.index {
                    guard values.indices.contains(index), values[index] == item.range else { return false }
                    values[index] = updated
                } else {
                    values.append(updated)
                }
                selection = values
                return true
            }
        }
    }
}

private struct TimeRangeEdit: Identifiable {
    let id = UUID()
    let index: Int?
    let range: ProgramSearchDate
}

private struct KeywordTimeRangeEditor: View {
    let allowUnchangedRange: Bool
    let onApply: (ProgramSearchDate) -> Bool
    @State private var draft: KeywordWeeklyTimeDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private let weekdayNames = ["日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日"]

    init(range: ProgramSearchDate, allowUnchangedRange: Bool, onApply: @escaping (ProgramSearchDate) -> Bool) {
        self.allowUnchangedRange = allowUnchangedRange
        self.onApply = onApply
        _draft = State(initialValue: KeywordWeeklyTimeDraft(range: range))
    }

    var body: some View {
        NavigationStack {
            Form {
                AppSection("開始（日本時間）") {
                    weekdayPicker("開始曜日", selection: $draft.startDayOfWeek)
                    TextField("開始時刻（HH:mm）", text: $draft.startTime)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                AppSection("終了（日本時間）") {
                    weekdayPicker("終了曜日", selection: $draft.endDayOfWeek)
                    TextField("終了時刻（HH:mm）", text: $draft.endTime)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("日をまたぐ場合は終了曜日も変えてください。終了日時が開始日時より前なら翌週までの範囲になります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("適用") { apply() }
                    Button("キャンセル") { dismiss() }
                }
            }
            .appNavigationTitle(Text("日時範囲を編集"))
            .alert("日時を確認してください", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("閉じる") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func weekdayPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(weekdayNames.indices, id: \.self) { value in
                Text(weekdayNames[value]).tag(value)
            }
            if !weekdayNames.indices.contains(selection.wrappedValue) {
                Text("曜日を選択してください").tag(selection.wrappedValue)
            }
        }.pickerStyle(.menu)
    }

    private func apply() {
        do {
            let value = try draft.validated(allowUnchangedRange: allowUnchangedRange)
            guard onApply(value) else {
                error = "日時範囲が変更されています。閉じて一覧から開き直してください。"
                return
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
