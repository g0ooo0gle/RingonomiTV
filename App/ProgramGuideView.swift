import SwiftUI
import RingonomiCore

/// 番組表の取得と詳細表示。検索は取得した一日分の番組に対して行う。
struct ProgramGuideView: View {
    let address: String
    @ObservedObject var reservations: ReservationStore
    let onPlay: (GuideChannel) -> Void
    @State private var channelType = "GR"
    @State private var dayOffset = 0
    @State private var query = ""
    @State private var guide = ProgramGuideResponse()
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0
    @State private var selected: GuideSelection?
    @State private var pendingPlayback: GuideChannel?
    @State private var pendingReservation: GuideReservationSelection?
    @State private var editingReservation: GuideReservationSelection?
    @AppStorage("guidePresentation") private var presentation = "grid"
    @AppStorage("guideSubchannels") private var includeSubchannels = false
    @State private var jumpRevision = 0
    @State private var returnFocusRevision = 0
    @State private var loadedRequest: String?
    @EnvironmentObject private var playbackPresentation: PlaybackPresentationStore
    @FocusState private var refreshFocused: Bool

    private var requestKey: String { "\(address)|\(channelType)|\(dayOffset)|\(revision)" }
    private var day: Date {
        GuideGridLayout.televisionDay(containing: Date(), offset: dayOffset)
    }
    private var gridLayout: GuideGridLayout {
        GuideGridLayout(response: guide, baseDate: day, includeSubchannels: includeSubchannels)
    }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var searchResults: [GuideProgramSearchResult] { searchFuturePrograms(query, in: guide) }
    private var visibleGroups: [GuideChannelPrograms] {
        var seen = Set<String>()
        return guide.flattenedChannels.filter {
            !$0.channel.id.isEmpty && seen.insert($0.channel.id).inserted && !visiblePrograms($0).isEmpty
        }
    }
    private func visiblePrograms(_ group: GuideChannelPrograms) -> [GuideProgram] {
        var seen = Set<String>()
        return group.programs.filter {
            !$0.id.isEmpty && seen.insert($0.id).inserted && ($0.endDate ?? .distantPast) > Date()
        }.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 24) {
                    Picker("放送波", selection: $channelType) {
                        Text("地デジ").tag("GR")
                        ForEach(["BS", "CS", "CATV", "SKY", "BS4K"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu)
                    Picker("表示", selection: $presentation) {
                        Text("番組表").tag("grid")
                        Text("一覧").tag("list")
                    }.pickerStyle(.menu)
                    Button("前日") { dayOffset = max(0, dayOffset - 1) }.disabled(dayOffset == 0)
                    Text(guideDay(day)).monospacedDigit()
                    Button("翌日") { dayOffset = min(6, dayOffset + 1) }.disabled(dayOffset == 6)
                    Button("現在") { dayOffset = 0; jumpRevision += 1 }
                    Button("更新") { revision += 1 }.disabled(loading).focused($refreshFocused)
                }
                TextField("番組・チャンネルを検索", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if isSearching {
                    Text("選択中の日・放送波の、これから始まる番組を検索します。空白はAND、読点・カンマはOR。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                guideContent.overlay {
                    if loading {
                        ProgressView("番組表を読み込んでいます…")
                    } else if let error {
                        VStack(spacing: 24) {
                            Text(error).multilineTextAlignment(.center)
                            Button("再試行") { revision += 1 }
                        }.padding(40)
                    } else if !hasContent {
                        Text(address.isEmpty ? "設定で視聴サーバーに接続してください。" : "該当する番組がありません。")
                            .foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 40)
            .task(id: requestKey) { await load() }
            .sheet(item: $selected, onDismiss: {
                if let channel = pendingPlayback {
                    pendingPlayback = nil
                    onPlay(channel)
                } else if let reservation = pendingReservation {
                    pendingReservation = nil
                    editingReservation = reservation
                } else { returnFocusRevision += 1 }
            }) { selection in
                GuideProgramDetail(selection: selection, address: address, reservations: reservations) {
                    pendingReservation = nil
                    pendingPlayback = selection.channel
                    selected = nil
                } onReserve: {
                    pendingPlayback = nil
                    pendingReservation = GuideReservationSelection(selection: selection,
                        original: reservations.reservation(for: selection.program.id))
                    selected = nil
                }
            }
            .sheet(item: $editingReservation, onDismiss: { returnFocusRevision += 1 }) { item in
                ReservationEditor(address: address, store: reservations, program: item.selection.program,
                                  channel: item.selection.channel, original: item.original)
            }
        }
    }
    private func leaveGridForBack() {
        if playbackPresentation.exposesLibrary {
            playbackPresentation.requestControlsFocus()
        } else {
            refreshFocused = true
        }
    }

    private var hasContent: Bool {
        if isSearching { return !searchResults.isEmpty }
        if presentation == "grid" { return gridLayout.columns.contains { !$0.entries.isEmpty } }
        return !visibleGroups.isEmpty
    }
    @ViewBuilder private var guideContent: some View {
        if !isSearching, presentation == "grid", !guide.channels.isEmpty {
            GuideGridView(layout: gridLayout, jumpRevision: jumpRevision, returnFocusRevision: returnFocusRevision) { program, channel in
                selected = GuideSelection(program: program, channel: channel)
            } onLeaveGrid: {
                refreshFocused = true
            } onExitGrid: {
                leaveGridForBack()
            }.id(requestKey + "|\(includeSubchannels)")
        } else {
            List {
                if isSearching {
                    ForEach(Array(searchResults.enumerated()), id: \.offset) { _, result in
                        programButton(result.program, channel: result.channel, showChannel: true)
                    }
                } else {
                    ForEach(visibleGroups, id: \.channel.id) { group in
                        AppSection(verbatim: group.channel.name) {
                            ForEach(visiblePrograms(group)) { program in
                                programButton(program, channel: group.channel, showChannel: false)
                            }
                        }
                    }
                }
            }
        }
    }
    private func programButton(_ program: GuideProgram, channel: GuideChannel, showChannel: Bool) -> some View {
        Button { selected = GuideSelection(program: program, channel: channel) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(guideTime(program.startDate) + " – " + guideTime(program.endDate)).monospacedDigit()
                    if showChannel { Text(channel.name) }
                    if let start = program.startDate, start <= Date() { Text("放送中") }
                }.font(.caption).foregroundStyle(.secondary)
                Text(program.title).font(.headline).lineLimit(2)
                Text(program.description).font(.caption).lineLimit(2)
            }
        }
    }
    @MainActor private func load() async {
        let expected = requestKey
        // tvOSの詳細画面から戻るだけでは読み直さず、選択位置とスクロールを保つ。
        guard loadedRequest != expected else { return }
        guide = ProgramGuideResponse()
        error = nil
        guard !address.isEmpty else { loading = false; return }
        loading = true
        defer { if expected == requestKey { loading = false } }
        do {
            let client = try RingonomiClient.connected(to: address)
            let end = day.addingTimeInterval(86400)
            let result = try await client.programGuide(start: day, end: end, type: channelType)
            guard !Task.isCancelled, expected == requestKey else { return }
            guide = result
            loadedRequest = expected
#if DEBUG
            print("RingonomiGuideReady: channels=\(result.channels.count)")
#endif
        } catch {
            guard !Task.isCancelled, expected == requestKey else { return }
            self.error = "番組表を読み込めませんでした。\(error.localizedDescription)"
        }
    }
}

private struct GuideSelection: Identifiable {
    let id = UUID()
    let program: GuideProgram
    let channel: GuideChannel
}
private struct GuideReservationSelection: Identifiable {
    let id = UUID()
    let selection: GuideSelection
    let original: Reservation?
}
private struct GuideProgramDetail: View {
    let selection: GuideSelection
    let address: String
    @ObservedObject var reservations: ReservationStore
    let onPlay: () -> Void
    let onReserve: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(selection.program.title).font(.title2)
                    Text(selection.channel.name).font(.headline)
                    Text(guideTime(selection.program.startDate) + " – " + guideTime(selection.program.endDate))
                    Text(selection.program.description)
                    ForEach(selection.program.detail.keys.sorted(), id: \.self) { heading in
                        Text(heading).font(.headline)
                        Text(selection.program.detail[heading] ?? "")
                    }
                    if !selection.program.genres.isEmpty {
                        Text(selection.program.genres.map(\.major).joined(separator: " / "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if selection.channel.isWatchable {
                        Button("このチャンネルを見る", action: onPlay)
                    }
                    if (selection.program.endDate ?? .distantPast) > Date() {
                        Button(reservations.reservation(for: selection.program.id) == nil ? "録画予約" : "予約を変更") { onReserve() }
                            .disabled(reservations.loading || reservations.saving || reservations.error != nil)
                        if let error = reservations.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("予約情報を再試行") { Task { await reservations.refresh(address: address) } }
                        }
                    }
                    Button("閉じる") { dismiss() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(60)
            }
        }
        .task { await reservations.refresh(address: address) }
    }
}
private func guideTime(_ date: Date?) -> String {
    guard let date else { return "時刻未定" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}
private func guideDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "M月d日(E)"
    return formatter.string(from: date)
}
