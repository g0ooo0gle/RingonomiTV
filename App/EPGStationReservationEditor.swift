import SwiftUI
import RingonomiCore

struct EPGStationReservationEditor: View {
    let address: String
    let original: EPGStationReservation?
    let initialProgram: EPGStationScheduleProgram?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = EPGStationReservationEditorStore()
    @ObservedObject private var mutation = EPGStationMutationStore.shared
    @State private var mode = CreationMode.program
    @State private var channelID: Int?
    @State private var program: EPGStationScheduleProgram?
    @State private var name = ""
    @State private var start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 3600)
    @State private var end = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 5400)
    @State private var directory = ""
    @State private var allowEndLack = false
    @State private var programDay = epgStationCalendar.startOfDay(for: Date())
    @State private var message: String?
    @State private var showingFailure = false
    @State private var confirm = false
    @State private var submitting = false
    @State private var prepared = false
    @State private var submitTask: Task<Void, Never>?

    private enum CreationMode: String, CaseIterable {
        case program = "番組を選ぶ"
        case time = "時刻を指定"
    }

    init(address: String, original: EPGStationReservation?,
         initialProgram: EPGStationScheduleProgram? = nil, onSaved: @escaping () -> Void) {
        self.address = address
        self.original = original
        self.initialProgram = initialProgram
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                EPGStationListHeader(original == nil ? "EPGStation予約を追加" : "EPGStation予約を変更") {
                    EmptyView()
                }
                editorForm
            }
            .disabled(submitting)
            .navigationTitle("")
            .interactiveDismissDisabled(submitting)
            .onExitCommand(perform: close)
            .confirmationDialog(original == nil ? "この内容で録画予約しますか？" : "録画設定の変更を保存しますか？", isPresented: $confirm, titleVisibility: .visible) {
                Button(original == nil ? "予約する" : "保存する", action: beginSave)
                Button("戻って修正", role: .cancel) {}
            } message: { Text(confirmationText) }
            .alert("予約操作の結果を確認してください", isPresented: $showingFailure) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text(message ?? "予約操作の結果を確認できませんでした。予約一覧を確認してください。")
            }
            .onAppear {
                guard !prepared else { return }
                prepared = true
                if let original { allowEndLack = original.allowEndLack }
                else {
                    if let initialProgram {
                        channelID = initialProgram.channelID
                        program = initialProgram
                        programDay = epgStationCalendar.startOfDay(for: Date(timeIntervalSince1970: initialProgram.startAt / 1000))
                    }
                    store.load(address: address)
                }
            }
            .onChange(of: store.channels) { _, values in
                if channelID == nil { channelID = values.first?.id }
            }
            .onDisappear {
                // tvOS may call onDisappear while a child NavigationLink is visible.
                // Keep the editor store alive across that transition; its StateObject
                // lifetime ends with the editor, and save tasks must never be cancelled
                // by a confirmation or child-screen transition.
                guard !submitting, !confirm, !showingFailure else { return }
                submitTask?.cancel()
            }
        }
    }

    private var editorForm: some View {
        Form {
            if let original {
                Section {
                    Text(original.name).font(.title3)
                    Text(epgStationSchedule(start: original.startAt, end: original.endAt))
                    Text("番組・日時・保存先・変換設定は現在の内容を保持します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                AppSection("録画設定") {
                    Toggle("番組末尾の切れを許可", isOn: $allowEndLack)
                }
            } else if store.loading {
                ProgressView("放送局と保存先を読み込んでいます…")
                Button("閉じる", action: close)
            } else if let error = store.error {
                Text(error).foregroundStyle(.red)
                Button("再試行") { store.load(address: address) }
            } else {
                creationFields
            }
            if let message {
                Section { Text(message).foregroundStyle(.red).focusable() }
            }
            if mutation.pending != nil, !submitting {
                Section {
                    Text("前の操作結果が未確認です。予約一覧へ戻り、結果を確認してください。")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                if submitting { ProgressView("予約の処理結果を確認しています…") }
                Button(original == nil ? "内容を確認して予約" : "変更内容を確認") { prepareConfirmation() }
                    .disabled(submitting || mutation.busy || mutation.pending != nil || (original == nil && (store.loading || store.error != nil)))
                Button("閉じる", action: close).disabled(submitting)
            }
        }
    }

    private var creationFields: some View {
        Group {
            AppSection("録画する番組") {
                Picker("予約方法", selection: $mode) {
                    ForEach(CreationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                NavigationLink("放送局：" + channelName) {
                    EPGStationChoiceList(title: "放送局", values: store.channels.map { ($0.id, $0.halfWidthName ?? $0.name) }, selection: channelID) { value in
                        channelID = value
                        program = nil
                    }
                }
                if mode == .program {
                    NavigationLink(program?.name ?? "録画する番組を選択") {
                        programPicker
                    }.disabled(channelID == nil)
                    if let program {
                        Text(epgStationSchedule(start: program.startAt, end: program.endAt))
                        if !program.isFree { Text("有料放送の番組です。").foregroundStyle(.orange) }
                    }
                } else {
                    TextField("番組名", text: $name)
                    EPGStationDateTimeField(title: "開始", date: $start)
                    EPGStationDateTimeField(title: "終了", date: $end)
                }
            }
            AppSection("録画設定") {
                NavigationLink("保存先：" + (directory.isEmpty ? "サーバーの既定" : directory)) {
                    EPGStationChoiceList(title: "保存先", values: [("", "サーバーの既定")] + store.directories.map { ($0, $0) }, selection: directory) { directory = $0 }
                }
                Toggle("番組末尾の切れを許可", isOn: $allowEndLack)
            }
        }
    }

    private var programPicker: some View {
        List {
            Section {
                Text(reservationDate(programDay))
                HStack {
                    Button("前の日") { changeProgramDay(-1) }
                        .disabled(programDay <= epgStationCalendar.startOfDay(for: Date()))
                    Button("次の日") { changeProgramDay(1) }
                        .disabled(programDay >= epgStationCalendar.startOfDay(for: Date()).addingTimeInterval(7 * 86400))
                }
            }
            if store.loadingPrograms {
                ProgressView("番組を読み込んでいます…")
            } else if let error = store.programError {
                Text(error).foregroundStyle(.red)
                Button("再試行", action: loadPrograms)
            } else if store.programs.isEmpty {
                Text("この日に予約できる番組はありません。")
                Button("再読み込み", action: loadPrograms)
            } else {
                ForEach(store.programs) { item in
                    EPGStationScheduleProgramChoice(program: item) { program = item }
                }
            }
        }
        .navigationTitle("録画する番組")
        .onAppear(perform: loadPrograms)
    }

    private var channelName: String {
        guard let channelID, let item = store.channels.first(where: { $0.id == channelID }) else { return "選択してください" }
        return item.halfWidthName ?? item.name
    }

    private var confirmationText: String {
        if let original {
            return original.name + "\n" + epgStationSchedule(start: original.startAt, end: original.endAt) + "\n番組末尾の切れ：" + (allowEndLack ? "許可" : "許可しない")
        }
        let title = mode == .program ? program?.name ?? "" : name
        let from = mode == .program ? program?.startAt ?? 0 : start.timeIntervalSince1970 * 1000
        let to = mode == .program ? program?.endAt ?? 0 : end.timeIntervalSince1970 * 1000
        return title + "\n" + channelName + "\n" + epgStationSchedule(start: from, end: to) + "\n保存先：" + (directory.isEmpty ? "サーバーの既定" : directory)
    }

    private func prepareConfirmation() {
        do {
            if original == nil { _ = try creationRequest() }
            message = nil
            showingFailure = false
            confirm = true
        } catch {
            message = error.localizedDescription
            showingFailure = true
        }
    }

    private func creationRequest() throws -> EPGStationCreationDraft {
        guard let channelID else { throw ReservationUIError("放送局を選択してください。") }
        let save = directory.isEmpty ? nil : EPGStationReservationSaveOption(parentDirectoryName: directory)
        if mode == .program {
            guard let program, program.channelID == channelID,
                  program.endAt > Date().timeIntervalSince1970 * 1000 else {
                throw ReservationUIError("これから録画できる番組を選択してください。")
            }
            return EPGStationCreationDraft(program: program, time: nil, options: .init(allowEndLack: allowEndLack, saveOption: save))
        }
        guard start > Date(), end > start, end.timeIntervalSince(start) <= 86400 else {
            throw ReservationUIError("開始は現在より先に、終了は開始から24時間以内に設定してください。")
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 16 * 1024,
              !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ReservationUIError("番組名を入力してください。改行・制御文字は使用できません。")
        }
        return EPGStationCreationDraft(program: nil, time: .init(name: title, channelID: channelID, startAt: (start.timeIntervalSince1970 * 1000).rounded(), endAt: (end.timeIntervalSince1970 * 1000).rounded()), options: .init(allowEndLack: allowEndLack, saveOption: save))
    }

    private func beginSave() {
        guard !submitting else { return }
        submitting = true
        message = nil
        showingFailure = false
        submitTask = Task { await save() }
    }

    @MainActor private func save() async {
        defer { submitting = false }
        do {
            let client = try EPGStationClient(address: address)
            if let original {
                try await mutation.perform(address: address, title: original.name, action: "変更", reservationID: original.id, schedule: epgStationSchedule(start: original.startAt, end: original.endAt), prepare: {
                    let latest = try await client.reservation(id: original.id)
                    try epgStationRequireSameReservation(original, latest)
                    guard latest.allowEndLack == original.allowEndLack else {
                        throw ReservationUIError("録画設定が別の画面で変更されました。詳細を更新してから開き直してください。")
                    }
                    let config = try await client.config()
                    try epgStationValidatePreservedOptions(latest, config: config)
                    return latest
                }, send: { latest in
                    let options = EPGStationReservationEditOptions(preserving: latest, allowEndLack: allowEndLack)
                    try await client.updateReservation(id: latest.id, options: options)
                    do {
                        let verified = try await client.reservation(id: latest.id)
                        try epgStationRequireSameReservation(latest, verified)
                        guard EPGStationReservationEditOptions(preserving: verified) == options else {
                            throw EPGStationWriteError.outcomeUnknown
                        }
                    } catch { throw EPGStationWriteError.outcomeUnknown }
                })
            } else {
                let request = try creationRequest()
                try await mutation.perform(address: address, title: mode == .program ? program?.name ?? "" : name, action: "追加", schedule: confirmationText, prepare: {
                    // Validate the selected channel and storage again immediately before submission.
                    let channels = try await client.channels()
                    guard channels.contains(where: { $0.id == channelID }) else {
                        throw ReservationUIError("放送局が見つかりません。画面を開き直してください。")
                    }
                    let config = try await client.config()
                    guard directory.isEmpty || config.recordedDirectories.contains(directory) else {
                        throw ReservationUIError("保存先が変更されました。画面を開き直してください。")
                    }
                    if let selected = request.program {
                        let day = epgStationCalendar.startOfDay(for: Date(timeIntervalSince1970: selected.startAt / 1000))
                        let schedules = try await client.channelSchedule(channelID: selected.channelID, startAt: day.timeIntervalSince1970 * 1000)
                        guard let current = schedules.flatMap(\.programs).first(where: { $0.id == selected.id }),
                              current.channelID == selected.channelID, current.startAt == selected.startAt,
                              current.endAt == selected.endAt, current.name == selected.name, current.isFree == selected.isFree else {
                            throw ReservationUIError("番組情報が変更されました。番組を選び直してください。")
                        }
                    }
                    try await epgStationCheckDuplicate(client: client, draft: request)
                    // Revalidate the user-entered time after all network checks and immediately
                    // before returning the draft that will be journaled and submitted.
                    _ = try creationRequest()
                    return request
                }, send: { request in
                    let identifier: Int
                    if let program = request.program {
                        identifier = try await client.createReservation(programID: program.id, options: request.options)
                    } else if let time = request.time {
                        identifier = try await client.createTimeSpecifiedReservation(name: time.name, channelID: time.channelID, startAt: time.startAt, endAt: time.endAt, options: request.options)
                    } else { throw EPGStationWriteError.invalidRequest }
                    do {
                        let verified = try await client.reservation(id: identifier)
                        guard request.matches(verified), request.matchesOptions(verified) else {
                            throw EPGStationWriteError.outcomeUnknown
                        }
                    } catch { throw EPGStationWriteError.outcomeUnknown }
                })
            }
#if DEBUG
            print("RingonomiEPGStationMutation: saved")
#endif
            onSaved()
            dismiss()
        } catch {
            message = error.localizedDescription
            if mutation.pending != nil {
                message = "操作結果を確認できませんでした。再送せず予約一覧を確認してください。"
            }
            showingFailure = true
        }
    }

    private func loadPrograms() {
        guard let channelID else { return }
        store.loadPrograms(address: address, channelID: channelID, day: programDay)
    }

    private func changeProgramDay(_ days: Int) {
        program = nil
        programDay = epgStationCalendar.date(byAdding: .day, value: days, to: programDay) ?? programDay
        loadPrograms()
    }

    private func close() {
        guard !submitting else { return }
        dismiss()
    }
}

func epgStationSchedule(start: Double, end: Double) -> String {
    reservationDate(Date(timeIntervalSince1970: start / 1000)) + " – " + reservationDate(Date(timeIntervalSince1970: end / 1000))
}

func epgStationRequireSameReservation(_ original: EPGStationReservation, _ latest: EPGStationReservation) throws {
    guard original.id == latest.id, original.programID == latest.programID,
          original.channelID == latest.channelID, original.startAt == latest.startAt,
          original.endAt == latest.endAt, original.ruleID == latest.ruleID,
          original.isTimeSpecified == latest.isTimeSpecified else {
        throw ReservationUIError("予約の内容が変わりました。詳細を更新してから開き直してください。")
    }
}

private struct EPGStationCreationDraft: Sendable {
    let program: EPGStationScheduleProgram?
    let time: EPGStationReservationTimeSpecifiedOption?
    let options: EPGStationReservationEditOptions

    func matchesOptions(_ item: EPGStationReservation) -> Bool {
        guard item.allowEndLack == options.allowEndLack else { return false }
        if let save = options.saveOption {
            guard item.parentDirectoryName == save.parentDirectoryName,
                  item.directory == save.directory, item.recordedFormat == save.recordedFormat else { return false }
        }
        if let tags = options.tags, item.tags != tags { return false }
        if let encode = options.encodeOption,
           EPGStationReservationEditOptions(preserving: item).encodeOption != encode { return false }
        return true
    }

    func matches(_ reservation: EPGStationReservation) -> Bool {
        if let program {
            return reservation.programID == program.id && reservation.channelID == program.channelID
                && reservation.startAt == program.startAt && reservation.endAt == program.endAt
        }
        guard let time else { return false }
        return reservation.isTimeSpecified && reservation.channelID == time.channelID
            && reservation.startAt == time.startAt && reservation.endAt == time.endAt
            && reservation.name == time.name
    }
}

private func epgStationCheckDuplicate(client: EPGStationClient, draft: EPGStationCreationDraft) async throws {
    var offset = 0
    var seen = Set<Int>()
    while true {
        try Task.checkCancellation()
        let page = try await client.reservations(offset: offset, limit: 200)
        guard page.total <= 20_000, page.reservations.allSatisfy({ seen.insert($0.id).inserted }) else {
            throw ReservationUIError("予約一覧を安全に確認できません。接続先の一覧を確認してください。")
        }
        guard !page.reservations.contains(where: { draft.matches($0) }) else {
            throw ReservationUIError("同じ番組・日時の予約がすでにあります。予約一覧から確認してください。")
        }
        offset += page.reservations.count
        if offset >= page.total { return }
        guard !page.reservations.isEmpty else {
            throw ReservationUIError("予約一覧が変更されました。もう一度内容を確認してください。")
        }
    }
}

private func epgStationValidatePreservedOptions(_ item: EPGStationReservation, config: EPGStationConfig) throws {
    let modes = [item.encodeMode1, item.encodeMode2, item.encodeMode3].compactMap { $0 }.filter { !$0.isEmpty }
    let directories = [item.parentDirectoryName, item.encodeParentDirectoryName1, item.encodeParentDirectoryName2, item.encodeParentDirectoryName3].compactMap { $0 }.filter { !$0.isEmpty }
    guard modes.allSatisfy(config.encodeModes.contains), directories.allSatisfy(config.recordedDirectories.contains) else {
        throw ReservationUIError("保存先または変換設定がサーバーの現在の設定と一致しません。EPGStation側で予約を確認してください。")
    }
}
