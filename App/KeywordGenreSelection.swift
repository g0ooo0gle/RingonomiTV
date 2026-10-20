import SwiftUI
import RingonomiCore

/// Selects the OR-ed genre ranges used by a keyword reservation condition.
///
/// `nil` is the server representation for all genres.  An empty, non-nil
/// array is intentionally kept distinct: it is an invalid-but-editable draft
/// that the parent editor rejects on save, rather than being silently changed
/// to all genres.
struct KeywordGenreSelection: View {
    @Binding var selection: [ProgramSearchGenre]?

    var body: some View {
        List {
            Toggle("すべてのジャンル", isOn: allGenresBinding)

            if selection == nil {
                Section {
                    Text("ジャンル条件なし（全ジャンル）")
                        .foregroundStyle(.secondary)
                }
            } else {
                selectedSummary

                AppSection("大分類") {
                    ForEach(KeywordGenreCatalog.all) { major in
                        NavigationLink {
                            KeywordGenreMiddleSelection(
                                majorName: major.name,
                                knownMiddles: major.middles,
                                selection: $selection
                            )
                        } label: {
                            majorLabel(major.name, count: selectedCount(for: major.name))
                        }
                    }
                }

                if !unknownMajorNames.isEmpty {
                    AppSection("サーバーから取得した未登録の大分類") {
                        ForEach(unknownMajorNames, id: \.self) { major in
                            NavigationLink {
                                KeywordGenreMiddleSelection(
                                    majorName: major,
                                    knownMiddles: [],
                                    selection: $selection
                                )
                            } label: {
                                majorLabel(majorDisplayName(major), count: selectedCount(for: major))
                            }
                        }
                    }
                }

                Section {
                    Text("複数選択時は、いずれかのジャンルに一致する番組が対象です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("対象ジャンル")
    }

    private var allGenresBinding: Binding<Bool> {
        Binding(
            get: { selection == nil },
            set: { isAll in
                guard isAll != (selection == nil) else { return }
                selection = isAll ? nil : []
            }
        )
    }

    private var selectedSummary: some View {
        AppSection("選択中（OR）") {
            if let selection, selection.isEmpty {
                Text("ジャンルが選択されていません。保存時に確認が必要です。")
                    .foregroundStyle(.orange)
            } else if let selection {
                ForEach(Array(selection.enumerated()), id: \.offset) { index, genre in
                    HStack(alignment: .top, spacing: 16) {
                        genreSummary(genre)
                        Spacer(minLength: 12)
                        Button("削除", role: .destructive) { removeSelection(at: index) }
                    }
                }
            }
        }
    }

    private func majorLabel(_ name: String, count: Int) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(count == 0 ? "未選択" : "\(count)件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func genreSummary(_ genre: ProgramSearchGenre) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(majorDisplayName(genre.major))
            Text(middleDisplayName(genre.middle, major: genre.major))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var unknownMajorNames: [String] {
        let known = Set(KeywordGenreCatalog.all.map(\.name))
        return orderedUnique((selection ?? []).map(\.major).filter { !known.contains($0) })
    }

    private func selectedCount(for major: String) -> Int {
        (selection ?? []).filter { $0.major == major }.count
    }

    private func removeSelection(at index: Int) {
        guard var values = selection, values.indices.contains(index) else { return }
        values.remove(at: index)
        selection = values
    }

    private func majorDisplayName(_ major: String) -> String {
        major.isEmpty ? "大分類未指定（サーバー値）" : major
    }

    private func middleDisplayName(_ middle: String, major: String) -> String {
        if middle == "すべて" { return "すべて（大分類全体）" }
        if middle.isEmpty { return "中分類未指定（\(majorDisplayName(major))）" }
        let known = KeywordGenreCatalog.middle(named: middle, inMajor: major) != nil
        return known ? middle : "未登録: \(middle)"
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct KeywordGenreMiddleSelection: View {
    let majorName: String
    let knownMiddles: [KeywordGenreMiddle]
    @Binding var selection: [ProgramSearchGenre]?

    var body: some View {
        List {
            Section {
                Text("中分類を複数選択できます。『すべて』はこの大分類全体を対象にします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !knownMiddles.isEmpty {
                AppSection("中分類") {
                    ForEach(knownMiddles) { middle in
                        Toggle(isOn: binding(for: middle.name)) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(middle.name == "すべて" ? "すべて（大分類全体）" : middle.name)
                                if middle.name == "すべて" {
                                    Text("この大分類の全中分類")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if !unknownMiddleNames.isEmpty {
                AppSection("サーバーから取得した未登録の中分類") {
                    ForEach(unknownMiddleNames, id: \.self) { middle in
                        Toggle(isOn: binding(for: middle)) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("未登録: \(middle.isEmpty ? "中分類未指定" : middle)")
                                Text("既存のサーバー値を保持中。オフにすると削除します。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(majorName.isEmpty ? "未登録の大分類" : majorName)
    }

    private var unknownMiddleNames: [String] {
        let known = Set(knownMiddles.map(\.name))
        return orderedUnique(
            (selection ?? [])
                .filter { $0.major == majorName && !known.contains($0.middle) }
                .map(\.middle)
        )
    }

    private func binding(for middle: String) -> Binding<Bool> {
        Binding(
            get: { isSelected(middle: middle) },
            set: { setSelected($0, middle: middle) }
        )
    }

    private func isSelected(middle: String) -> Bool {
        (selection ?? []).contains { $0.major == majorName && $0.middle == middle }
    }

    private func setSelected(_ selected: Bool, middle: String) {
        guard var values = selection else { return }
        if selected {
            // A known server object may carry future fields.  Leave it intact
            // instead of replacing it with a newly generated object.
            guard !values.contains(where: { $0.major == majorName && $0.middle == middle }) else { return }
            values.append(ProgramSearchGenre(major: majorName, middle: middle))
        } else {
            // Removing is explicit user action; this also removes duplicate
            // copies of the same visible condition while preserving all other
            // unknown objects.
            values.removeAll { $0.major == majorName && $0.middle == middle }
        }
        selection = values
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
