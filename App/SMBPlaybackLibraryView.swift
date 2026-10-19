import CryptoKit
import RingonomiCore
import SwiftUI

/// File playback stays outside directory navigation so closing it returns to
/// the same folder and search. Shares never acquire a live-stream session.
struct SMBPlaybackLibraryView: View {
    @State private var playback: FilePlaybackSelection?
    @State private var error: String?
    @StateObject private var idleTimer = PlaybackIdleTimer()
    @StateObject private var resume = SMBResumeStore()

    var body: some View {
        SMBLibraryView { connection, entry in
            do {
                let key = SMBResumeStore.key(connection: connection, path: entry.path)
                playback = FilePlaybackSelection(
                    url: try connection.url(for: entry.path), title: entry.name,
                    resumePosition: resume.position(for: key) ?? 0,
                    identity: key, smbConnection: connection)
            } catch {
                self.error = "このファイルを開けませんでした。フォルダーを更新して再試行してください。"
            }
        }
        .fullScreenCover(item: $playback) { item in
            FilePlaybackView(item: item,
                onContinuousDisplayChanged: { idleTimer.setNeedsContinuousDisplay($0) },
                onProgress: { seconds, duration, ended in
                    guard let key = item.identity else { return }
                    resume.save(key: key, seconds: seconds, duration: duration, ended: ended)
                })
        }
        .onChange(of: playback) { _, item in
            if item == nil { idleTimer.setNeedsContinuousDisplay(false) }
        }
        .onDisappear { idleTimer.setNeedsContinuousDisplay(false) }
        .alert("ファイルを開けません", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("閉じる", role: .cancel) { error = nil } }
        message: { Text(error ?? "") }
    }
}

@MainActor
private final class SMBResumeStore: ObservableObject {
    private let defaults: UserDefaults
    private let storageKey = "smb.resume.v1"
    private var archive: RecordingResumeArchive

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archive = defaults.data(forKey: storageKey).flatMap {
            guard $0.count <= 512 * 1024 else { return nil }
            return try? JSONDecoder().decode(RecordingResumeArchive.self, from: $0)
        } ?? RecordingResumeArchive()
    }

    static func key(connection: SMBConnection, path: SMBRelativePath) -> String {
        let value = connection.stableKey(for: path)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func position(for key: String) -> Double? {
        guard let entry = archive.entry(for: key) else { return nil }
        return RecordingResumePolicy.candidate(entry: entry, duration: nil)
    }

    func save(key: String, seconds: Double, duration: Double?, ended: Bool) {
        guard let seconds = RecordingResumePolicy.clamp(seconds: seconds, duration: duration) else { return }
        if seconds < 5 || RecordingResumePolicy.shouldClear(
            seconds: seconds, duration: duration, status: nil, reachedEnd: ended) {
            guard archive.entry(for: key) != nil else { return }
            archive.remove(for: key)
        } else {
            archive.set(RecordingResumeEntry(seconds: seconds), for: key)
        }
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
