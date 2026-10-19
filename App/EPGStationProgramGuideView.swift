import SwiftUI
import RingonomiCore

/// EPGStationの番組表。番組表の表示モデルと、予約に渡す元の数値モデルを
/// 同じ選択状態で保持するため、詳細画面からそのまま予約画面へ進める。
struct EPGStationProgramGuideView: View {
    @AppStorage("epgstationAddress") private var address = ""
    @AppStorage("epgstationGuidePresentation") private var presentation = "grid"
    @State private var draftAddress = ""
    @State private var prepared = false
    @State private var dayOffset = 0
    @State private var broadcast: EPGStationGuideBroadcast = .terrestrial
    @State private var query = ""
    @State private var revision = 0
    @State private var jumpRevision = 0
    @State private var returnFocusRevision = 0
    @State private var inputError: String?
    @State private var selected: EPGStationGuideSelection?
    @State private var pendingReservation: EPGStationGuideSelection?
    @State private var reservationRoute: EPGStationGuideSelection?
    @StateObject private var store = EPGStationProgramGuideStore()
    @FocusState private var refreshFocused: Bool

#if DEBUG
    private var runtimeAddress: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--epgstation-url"),
              index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
#endif

    private var effectiveAddress: String {
#if DEBUG
        return runtimeAddress ?? address
#else
        return address
#endif
    }

    private var requestKey: String {
        "\(effectiveAddress)|\(broadcast)|\(dayOffset)|\(day.timeIntervalSince1970)|\(revision)"
    }

    private var day: Date {
        GuideGridLayout.televisionDay(containing: Date(), offset: dayOffset)
    }

    private var endOfDay: Date {
        day.addingTimeInterval(24 * 60 * 60)
    }

    private var response: ProgramGuideResponse {
        guard !store.loading, store.loadedRequestKey == requestKey else {
            return ProgramGuideResponse()
        }
        return store.snapshot?.response ?? ProgramGuideResponse()
    }

    private var gridLayout: GuideGridLayout {
        GuideGridLayout(response: response, baseDate: day)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [GuideProgramSearchResult] {
        searchFuturePrograms(query, in: response)
    }

    private var visibleGroups: [GuideChannelPrograms] {
        var seen = Set<String>()
        return response.flattenedChannels.filter { group in
            let channelID = group.channel.id.isEmpty ? group.channel.displayChannelId : group.channel.id
            guard !channelID.isEmpty, seen.insert(channelID).inserted else { return false }
            return !visiblePrograms(in: group).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            EPGStationListHeader("EPGStation番組表") {
                Button("現在") { moveToCurrentDay() }
                Button("更新", action: reload)
                    .disabled(store.loading || effectiveAddress.isEmpty)
                    .focused($refreshFocused)
            }

            connectionControls
            guideControls

            guideContent
                .overlay { guideStatusOverlay }
                .padding(.horizontal, 48)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
        .onAppear {
            guard !prepared else { return }
            prepared = true
            draftAddress = effectiveAddress
        }
        .onChange(of: effectiveAddress) { _, next in
            selected = nil
            pendingReservation = nil
            reservationRoute = nil
            draftAddress = next
            inputError = nil
            dayOffset = 0
        }
        .task(id: requestKey) {
            let expectedRequestKey = requestKey
            let expectedAddress = effectiveAddress
            let expectedDay = day
            let expectedBroadcast = broadcast
            guard !Task.isCancelled else { return }
            guard store.loadedRequestKey != expectedRequestKey else { return }
            guard !expectedAddress.isEmpty else {
                store.cancel(clear: true)
                return
            }
            store.load(
                requestKey: expectedRequestKey,
                address: expectedAddress,
                startAt: expectedDay.timeIntervalSince1970 * 1000,
                endAt: expectedDay.addingTimeInterval(24 * 60 * 60).timeIntervalSince1970 * 1000,
                broadcast: expectedBroadcast
            )
        }
        .sheet(item: $selected, onDismiss: detailDismissed) { selection in
            EPGStationProgramGuideDetailView(
                selection: selection,
                onReserve: {
                    pendingReservation = selection
                    selected = nil
                }
            )
        }
        .sheet(item: $reservationRoute, onDismiss: {
            reservationRoute = nil
            returnFocusRevision += 1
        }) { route in
            EPGStationReservationEditor(
                address: route.address,
                original: nil,
                initialProgram: route.sourceProgram,
                onSaved: { reservationRoute = nil }
            )
        }
    }

    private var connectionControls: some View {
        HStack(spacing: 18) {
            TextField("EPGStation URL（例：http://ホスト:8888）", text: $draftAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: 620)
            Button("接続", action: connect)
                .disabled(store.loading)
            if let inputError {
                Text(inputError)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 18)
    }

    private var guideControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                Picker("放送波", selection: $broadcast) {
                    ForEach(EPGStationGuideBroadcast.allCases, id: \.self) { value in
                        Text(broadcastName(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)

                Picker("表示", selection: $presentation) {
                    Text("番組表").tag("grid")
                    Text("一覧").tag("list")
                }
                .pickerStyle(.menu)

                Button("前の日") { changeDay(-1) }
                    .disabled(dayOffset == 0 || store.loading)
                Text(epgStationGuideDay(day)).monospacedDigit()
                Button("次の日") { changeDay(1) }
                    .disabled(dayOffset == 6 || store.loading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField("番組・チャンネルを検索", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: .infinity)

            if isSearching {
                Text("選択中の日・放送波の、これから始まる番組を検索します。空白はAND、読点・カンマはOR。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var guideContent: some View {
        if !isSearching, presentation == "grid", !response.channels.isEmpty {
            GuideGridView(
                layout: gridLayout,
                jumpRevision: jumpRevision,
                returnFocusRevision: returnFocusRevision,
                onSelect: { program, channel in openProgram(program, channel: channel) },
                onLeaveGrid: { refreshFocused = true }
            )
            .id(requestKey)
        } else {
            List {
                if isSearching {
                    ForEach(Array(searchResults.enumerated()), id: \.offset) { _, result in
                        programButton(result.program, channel: result.channel, showChannel: true)
                    }
                } else {
                    ForEach(visibleGroups, id: \.channel.id) { group in
                        Section(group.channel.name) {
                            ForEach(visiblePrograms(in: group)) { program in
                                programButton(program, channel: group.channel, showChannel: false)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var guideStatusOverlay: some View {
        if store.loading {
            VStack(spacing: 22) {
                ProgressView("番組表を読み込んでいます…")
                Button("読み込みを中止") { store.cancel() }
            }
            .padding(42)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else if let error = store.error {
            VStack(spacing: 22) {
                Text(error).multilineTextAlignment(.center)
                Button("再試行", action: reload)
            }
            .padding(42)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else if store.cancelled {
            VStack(spacing: 22) {
                Text("読み込みを中止しました。")
                Button("再試行", action: reload)
            }
            .padding(42)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else if effectiveAddress.isEmpty {
            Text("EPGStationの接続先を入力してください。")
                .foregroundStyle(.secondary)
                .padding(42)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else if !hasContent {
            Text(isSearching ? "検索条件に一致する番組がありません。" : "該当する番組がありません。")
                .foregroundStyle(.secondary)
                .padding(42)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var hasContent: Bool {
        if isSearching { return !searchResults.isEmpty }
        if presentation == "grid" { return gridLayout.columns.contains { !$0.entries.isEmpty } }
        return !visibleGroups.isEmpty
    }

    private func visiblePrograms(in group: GuideChannelPrograms) -> [GuideProgram] {
        var seen = Set<String>()
        let rangeStart = day
        let rangeEnd = endOfDay
        return group.programs.filter { program in
            guard !program.id.isEmpty,
                  seen.insert(program.id).inserted,
                  let start = program.startDate,
                  let end = program.endDate,
                  end > rangeStart,
                  start < rangeEnd else { return false }
            return true
        }
        .sorted {
            let lhs = $0.startDate ?? .distantFuture
            let rhs = $1.startDate ?? .distantFuture
            if lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }
    }

    private func programButton(_ program: GuideProgram, channel: GuideChannel, showChannel: Bool) -> some View {
        Button { openProgram(program, channel: channel) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(epgStationGuideTime(program.startDate) + " – " + epgStationGuideTime(program.endDate))
                        .monospacedDigit()
                    if showChannel { Text(channel.name) }
                    if let start = program.startDate, start <= Date(), let end = program.endDate, end > Date() {
                        Text("放送中").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(program.title).font(.headline).lineLimit(2)
                if !program.description.isEmpty {
                    Text(program.description).font(.caption).lineLimit(2)
                }
            }
        }
    }

    private func openProgram(_ program: GuideProgram, channel: GuideChannel) {
        guard !store.loading,
              store.loadedRequestKey == requestKey,
              let sourceProgram = sourceProgram(for: program) else {
            inputError = "番組情報を取得できません。番組表を更新してください。"
            return
        }
        selected = EPGStationGuideSelection(
            program: program,
            channel: channel,
            sourceProgram: sourceProgram,
            address: effectiveAddress
        )
    }

    private func sourceProgram(for program: GuideProgram) -> EPGStationScheduleProgram? {
        store.snapshot?.sourcePrograms[program.id]
    }

    private func detailDismissed() {
        if let pendingReservation {
            self.pendingReservation = nil
            reservationRoute = pendingReservation
        } else {
            returnFocusRevision += 1
        }
    }

    private func changeDay(_ amount: Int) {
        dayOffset = min(6, max(0, dayOffset + amount))
        jumpRevision += 1
    }

    private func moveToCurrentDay() {
        dayOffset = 0
        jumpRevision += 1
        reload()
    }

    private func reload() {
        guard !effectiveAddress.isEmpty else {
            store.cancel(clear: true)
            return
        }
        revision += 1
    }

    private func connect() {
        let next = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try EPGStationClient(address: next)
            inputError = nil
#if DEBUG
            if runtimeAddress != nil {
                reload()
                return
            }
#endif
            if address == next {
                reload()
            } else {
                address = next
            }
        } catch {
            inputError = error.localizedDescription
        }
    }

    private func broadcastName(_ value: EPGStationGuideBroadcast) -> String {
        switch value {
        case .all: return "すべて"
        case .terrestrial: return "地デジ"
        case .bs: return "BS"
        case .cs: return "CS"
        case .sky: return "SKY"
        case .bs4K: return "BS4K"
        case .cs4K: return "CS4K"
        }
    }
}

private struct EPGStationGuideSelection: Identifiable {
    let program: GuideProgram
    let channel: GuideChannel
    let sourceProgram: EPGStationScheduleProgram
    let address: String

    var id: String { "epgstation.program.\(sourceProgram.id)" }
}

private struct EPGStationProgramGuideDetailView: View {
    let selection: EPGStationGuideSelection
    let onReserve: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var mutation = EPGStationMutationStore.shared
    @FocusState private var focusedAction: Action?
    private enum Action: Hashable { case reserve, close }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                EPGStationListHeader("番組詳細") {
                    if canReserve {
                        Button("録画予約", action: onReserve)
                            .disabled(mutation.busy || mutation.pending != nil)
                            .focused($focusedAction, equals: .reserve)
                    }
                    Button("閉じる") { dismiss() }
                        .focused($focusedAction, equals: .close)
                }
                List {
                    Section("番組") {
                        Text(selection.sourceProgram.name)
                            .font(.title3)
                            .focusable()
                        Text(selection.channel.name)
                            .font(.headline)
                            .focusable()
                        Text(epgStationSchedule(
                            start: selection.sourceProgram.startAt,
                            end: selection.sourceProgram.endAt
                        ))
                        .focusable()
                        Text(selection.sourceProgram.isFree ? "無料放送" : "有料放送")
                            .foregroundStyle(selection.sourceProgram.isFree ? Color.secondary : Color.orange)
                            .focusable()
                    }
                    if let description = selection.sourceProgram.description, !description.isEmpty {
                        Section("説明") {
                            Text(description).focusable()
                        }
                    }
                    if let extended = selection.sourceProgram.extended, !extended.isEmpty {
                        Section("番組詳細") {
                            Text(extended).focusable()
                        }
                    }
                    if let rawExtended = selection.sourceProgram.rawExtended, !rawExtended.isEmpty {
                        Section("番組情報") {
                            ForEach(rawExtended.keys.sorted(), id: \.self) { heading in
                                VStack(alignment: .leading, spacing: 6) {
                                    if !heading.isEmpty { Text(heading).font(.subheadline) }
                                    Text(rawExtended[heading] ?? "")
                                }
                                .focusable()
                            }
                        }
                    }
                    if mutation.pending != nil {
                        Section {
                            Text("前の予約操作の結果が未確認です。予約一覧で結果を確認してから、次の予約操作を行ってください。")
                                .foregroundStyle(.orange)
                                .focusable()
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("")
        }
        .defaultFocus($focusedAction,
                      canReserve && !mutation.busy && mutation.pending == nil ? .reserve : .close,
                      priority: .userInitiated)
        .onExitCommand { dismiss() }
    }

    private var canReserve: Bool {
        selection.sourceProgram.endAt > Date().timeIntervalSince1970 * 1000
    }
}

private func epgStationGuideTime(_ date: Date?) -> String {
    guard let date else { return "時刻未定" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func epgStationGuideDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "M月d日(E)"
    return formatter.string(from: date)
}
