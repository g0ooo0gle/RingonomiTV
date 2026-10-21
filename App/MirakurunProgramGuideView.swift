import SwiftUI
import RingonomiCore

/// Mirakurun owns the guide data and service stream.  A selection retains the
/// original service, so display identifiers never need to be parsed into URLs.
struct MirakurunProgramGuideView: View {
    @AppStorage("mirakurunAddress") private var address = ""
    @AppStorage("mirakurunGuidePresentation") private var presentation = "grid"
    @State private var draftAddress = ""
    @State private var prepared = false
    @State private var broadcast: MirakurunGuideBroadcast = .terrestrial
    @State private var dayOffset = 0
    @State private var query = ""
    @State private var revision = 0
    @State private var jumpRevision = 0
    @State private var returnFocusRevision = 0
    @State private var inputError: String?
    @State private var selected: MirakurunGuideSelection?
    @State private var pendingPlayback: MirakurunPlaybackSelection?
    @EnvironmentObject private var playbackPresentation: PlaybackPresentationStore
    @State private var requestedPlaybackID: UUID?
    @StateObject private var store = MirakurunProgramGuideStore()
    @FocusState private var refreshFocused: Bool

    private var effectiveAddress: String {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--mirakurun-url"), index + 1 < arguments.count {
            let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
#endif
        return address
    }

    private var day: Date { GuideGridLayout.televisionDay(containing: Date(), offset: dayOffset) }
    private var requestKey: String {
        "\(effectiveAddress)|\(broadcast.rawValue)|\(day.timeIntervalSince1970)|\(revision)"
    }
    private var response: ProgramGuideResponse {
        guard !store.loading, store.loadedRequestKey == requestKey else { return ProgramGuideResponse() }
        return store.snapshot?.response ?? ProgramGuideResponse()
    }
    private var layout: GuideGridLayout { GuideGridLayout(response: response, baseDate: day) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var searchResults: [GuideProgramSearchResult] { searchFuturePrograms(query, in: response) }

    var body: some View {
        VStack(spacing: 0) {
            MirakurunGuideHeader("Mirakurun番組表") {
                Button("現在") { dayOffset = 0; jumpRevision += 1; reload() }
                Button("更新", action: reload)
                    .focused($refreshFocused)
                    .disabled(store.loading || effectiveAddress.isEmpty)
            }
            connectionControls
            guideControls
            if let warning = store.warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 80).padding(.bottom, 12)
            }
            guideContent
                .overlay { statusOverlay }
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
            pendingPlayback = nil
            if let requestedPlaybackID {
                playbackPresentation.cancelSession(requestedPlaybackID)
                self.requestedPlaybackID = nil
            }
            draftAddress = next
            dayOffset = 0
            inputError = nil
        }
        .task(id: requestKey) {
            let expected = requestKey
            guard !Task.isCancelled, store.loadedRequestKey != expected else { return }
            guard !effectiveAddress.isEmpty else { store.cancel(clear: true); return }
            store.load(requestKey: expected, address: effectiveAddress,
                       startDate: day, endDate: day.addingTimeInterval(86_400), broadcast: broadcast)
        }
        .onDisappear {
            if selected == nil, pendingPlayback == nil { store.cancel() }
        }
        .sheet(item: $selected, onDismiss: detailDismissed) { selection in
            MirakurunGuideDetailView(selection: selection) {
                guard selected?.id == selection.id, effectiveAddress == selection.address else { return }
                do {
                    let client = try MirakurunClient(address: selection.address)
                    pendingPlayback = MirakurunPlaybackSelection(
                        url: client.streamURL(for: selection.service), title: selection.channel.name
                    )
                    selected = nil
                } catch { inputError = error.localizedDescription }
            }
        }
        .onChange(of: playbackPresentation.current?.id) { previous, _ in
            guard let requestedPlaybackID, previous == requestedPlaybackID else { return }
            self.requestedPlaybackID = nil
            returnFocusRevision += 1
        }
    }

    private var connectionControls: some View {
        HStack(spacing: 18) {
            TextField("Mirakurun URL（例：http://ホスト:40772）", text: $draftAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .frame(maxWidth: 620)
            Button("接続", action: connect).disabled(store.loading)
            if let inputError { Text(inputError).foregroundStyle(.red).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 80).padding(.bottom, 18)
    }

    private var guideControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                Picker("放送波", selection: $broadcast) {
                    ForEach(MirakurunGuideBroadcast.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                Picker("表示", selection: $presentation) {
                    Text("番組表").tag("grid")
                    Text("一覧").tag("list")
                }.pickerStyle(.menu)
                Spacer(minLength: 20)
                Button("前の日") { changeDay(-1) }.disabled(dayOffset == 0 || store.loading)
                Text(MirakurunGuideDate.day(day)).monospacedDigit()
                Button("次の日") { changeDay(1) }.disabled(dayOffset == 6 || store.loading)
            }
            TextField("番組・チャンネルを検索", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if isSearching {
                Text("選択中の日・放送波の、これから始まる番組を検索します。空白はAND、読点・カンマはOR。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 80).padding(.bottom, 18)
    }

    @ViewBuilder private var guideContent: some View {
        if !isSearching, presentation == "grid", !response.channels.isEmpty {
            GuideGridView(layout: layout, jumpRevision: jumpRevision,
                          returnFocusRevision: returnFocusRevision,
                          onSelect: openProgram, onLeaveGrid: { refreshFocused = true })
                .id(requestKey)
        } else {
            List {
                if isSearching {
                    ForEach(Array(searchResults.enumerated()), id: \.offset) { _, result in
                        programButton(result.program, channel: result.channel, showChannel: true)
                    }
                } else {
                    ForEach(response.flattenedChannels.filter { !$0.programs.isEmpty }, id: \.channel.id) { group in
                        AppSection(verbatim: group.channel.name) {
                            ForEach(group.programs.sorted {
                                if $0.startDate != $1.startDate {
                                    return ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture)
                                }
                                return $0.id < $1.id
                            }) { program in
                                programButton(program, channel: group.channel, showChannel: false)
                            }
                        }
                    }
                }
            }.listStyle(.plain)
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        if store.loading {
            statusCard {
                ProgressView("番組表を読み込んでいます…")
                if store.totalServices > 0 {
                    Text("\(store.completedServices) / \(store.totalServices) チャンネル")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Button("読み込みを中止") { store.cancel() }
            }
        } else if let error = store.error {
            statusCard { Text(error).multilineTextAlignment(.center); Button("再試行", action: reload) }
        } else if store.cancelled {
            statusCard { Text("読み込みを中止しました。"); Button("再試行", action: reload) }
        } else if effectiveAddress.isEmpty {
            statusCard { Text("Mirakurunの接続先を入力してください。") }
        } else if isSearching ? searchResults.isEmpty : !response.flattenedChannels.contains(where: { !$0.programs.isEmpty }) {
            statusCard { Text(isSearching ? "検索条件に一致する番組がありません。" : "該当する番組がありません。") }
        }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 22, content: content).padding(42)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func programButton(_ program: GuideProgram, channel: GuideChannel, showChannel: Bool) -> some View {
        Button { openProgram(program, channel) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(MirakurunGuideDate.time(program.startDate) + " – " + MirakurunGuideDate.time(program.endDate))
                    if showChannel { Text(channel.name) }
                }.font(.caption).foregroundStyle(.secondary)
                Text(program.title).font(.headline).lineLimit(2)
                if !program.description.isEmpty { Text(program.description).font(.caption).lineLimit(2) }
            }
        }
    }

    private func openProgram(_ program: GuideProgram, _ channel: GuideChannel) {
        guard !store.loading, store.loadedRequestKey == requestKey,
              let service = store.snapshot?.servicesByChannelID[channel.id] else {
            inputError = "番組情報を取得できません。番組表を更新してください。"
            return
        }
        selected = MirakurunGuideSelection(program: program, channel: channel,
                                           service: service, address: effectiveAddress)
    }

    private func detailDismissed() {
        if let next = pendingPlayback {
            pendingPlayback = nil
            requestedPlaybackID = next.id
            playbackPresentation.presentMirakurun(next)
        } else { returnFocusRevision += 1 }
    }

    private func changeDay(_ amount: Int) {
        dayOffset = min(6, max(0, dayOffset + amount))
        jumpRevision += 1
    }

    private func reload() {
        guard !effectiveAddress.isEmpty else { store.cancel(clear: true); return }
        revision += 1
    }

    private func connect() {
        let next = draftAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try MirakurunClient(address: next)
            inputError = nil
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--mirakurun-url") { reload(); return }
#endif
            if address == next { reload() } else { address = next }
        } catch { inputError = error.localizedDescription }
    }
}

private struct MirakurunGuideSelection: Identifiable {
    let program: GuideProgram
    let channel: GuideChannel
    let service: MirakurunService
    let address: String
    var id: String { program.id }
}

private struct MirakurunGuideDetailView: View {
    let selection: MirakurunGuideSelection
    let onWatch: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var action: Action?
    private enum Action: Hashable { case watch, close }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MirakurunGuideHeader("番組詳細") {
                    Button("このチャンネルを視聴", action: onWatch).focused($action, equals: .watch)
                    Button("閉じる") { dismiss() }.focused($action, equals: .close)
                }
                List {
                    AppSection("番組") {
                        Text(selection.program.title).font(.title3).focusable()
                        Text(selection.channel.name).font(.headline).focusable()
                        Text(MirakurunGuideDate.schedule(selection.program)).focusable()
                        Text(selection.program.isFree ? "無料放送" : "有料放送").focusable()
                    }
                    if !selection.program.description.isEmpty {
                        AppSection("説明") { Text(selection.program.description).focusable() }
                    }
                    if !selection.program.detail.isEmpty {
                        AppSection("番組詳細") {
                            ForEach(selection.program.detail.keys.sorted(), id: \.self) { heading in
                                VStack(alignment: .leading, spacing: 6) {
                                    if !heading.isEmpty { Text(heading).font(.subheadline) }
                                    Text(selection.program.detail[heading] ?? "")
                                }.focusable()
                            }
                        }
                    }
                }.listStyle(.plain)
            }.navigationTitle("")
        }
        .defaultFocus($action, .watch, priority: .userInitiated)
        .onExitCommand { dismiss() }
    }
}

private struct MirakurunGuideHeader<Actions: View>: View {
    let title: String
    let actions: Actions
    init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.actions = actions()
    }
    var body: some View {
        HStack(spacing: 24) {
            Text(title).font(.title2).lineLimit(2).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 24)
            HStack(spacing: 16) { actions }
        }.padding(.horizontal, 80).padding(.top, 12).padding(.bottom, 24)
    }
}

private enum MirakurunGuideDate {
    static func time(_ date: Date?) -> String { format(date, "HH:mm") }
    static func day(_ date: Date) -> String { format(date, "M月d日(E)") }
    static func schedule(_ program: GuideProgram) -> String {
        format(program.startDate, "M/d(E) HH:mm") + " – " + format(program.endDate, "M/d(E) HH:mm")
    }
    private static func format(_ date: Date?, _ pattern: String) -> String {
        guard let date else { return "時刻未定" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
