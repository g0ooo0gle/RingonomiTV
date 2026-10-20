import SwiftUI
import RingonomiCore

struct RecordingSettingsDraft {
    var settings: RecordSettings
    var startMargin: String
    var endMargin: String
    var tuner: String

    init(settings: RecordSettings) {
        self.settings = settings
        startMargin = settings.startMargin.map(String.init) ?? ""
        endMargin = settings.endMargin.map(String.init) ?? ""
        tuner = settings.forcedTunerID.map(String.init) ?? ""
    }

    func validatedSettings() throws -> RecordSettings {
        var result = settings
        result.startMargin = try optionalInteger(startMargin, label: "開始マージン")
        result.endMargin = try optionalInteger(endMargin, label: "終了マージン")
        result.forcedTunerID = try optionalInteger(tuner, label: "チューナーID", nonnegative: true)
        return result
    }
}

func optionalInteger(_ input: String, label: String, nonnegative: Bool = false) throws -> Int? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    guard let value = Int(text), !nonnegative || value >= 0 else {
        throw ReservationUIError("\(label)は\(nonnegative ? "0以上の" : "")整数で入力してください。")
    }
    return value
}

struct RecordingSettingsFields: View {
    @Binding var draft: RecordingSettingsDraft

    var body: some View {
        Group {
            AppSection("基本設定") {
                Toggle("この予約を有効にする", isOn: $draft.settings.isEnabled)
                Picker("優先度", selection: $draft.settings.priority) {
                    ForEach(1...5, id: \.self) { Text($0 == 3 ? "3（通常）" : String($0)).tag($0) }
                }
                TextField("開始マージン（秒・空欄はサーバー既定）", text: $draft.startMargin)
                TextField("終了マージン（秒・空欄はサーバー既定）", text: $draft.endMargin)
                Picker("録画方式", selection: $draft.settings.recordingMode) {
                    Text("指定サービス").tag("SpecifiedService")
                    Text("指定サービス・復号なし").tag("SpecifiedServiceWithoutDecoding")
                    Text("全サービス").tag("AllServices")
                    Text("全サービス・復号なし").tag("AllServicesWithoutDecoding")
                    Text("視聴のみ").tag("View")
                    if !["SpecifiedService", "SpecifiedServiceWithoutDecoding", "AllServices", "AllServicesWithoutDecoding", "View"].contains(draft.settings.recordingMode) {
                        Text(draft.settings.recordingMode).tag(draft.settings.recordingMode)
                    }
                }
                Toggle("イベントリレーを追従", isOn: $draft.settings.isEventRelayFollowEnabled)
                Toggle("ぴったり録画", isOn: $draft.settings.isExactRecordingEnabled)
            }
            AppSection("詳細設定") {
                recordingModePicker("字幕", selection: $draft.settings.captionRecordingMode)
                recordingModePicker("データ放送", selection: $draft.settings.dataBroadcastingRecordingMode)
                Toggle("ワンセグを別ファイルへ保存", isOn: $draft.settings.isOnesegSeparateOutputEnabled)
                Toggle("連続する番組を一つのファイルへ保存", isOn: $draft.settings.isSequentialRecordingInSingleFileEnabled)
                TextField("使用チューナーID（空欄は自動）", text: $draft.tuner)
                Text(draft.settings.recordingFolders.isEmpty ? "保存先：サーバーの既定フォルダー" : "保存先：\(draft.settings.recordingFolders.count)件の既存設定を保持")
                    .font(.caption).foregroundStyle(.secondary)
                Text("録画後の動作・保存先・スクリプトなど、この画面で変更しない設定は保持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func recordingModePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("サーバー既定").tag("Default")
            Text("記録する").tag("Enable")
            Text("記録しない").tag("Disable")
            if !["Default", "Enable", "Disable"].contains(selection.wrappedValue) { Text(selection.wrappedValue).tag(selection.wrappedValue) }
        }
    }
}
