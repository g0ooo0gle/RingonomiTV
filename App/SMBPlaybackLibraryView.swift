import CryptoKit
import RingonomiCore
import SwiftUI

/// File playback stays outside directory navigation so closing it returns to
/// the same folder and search. Shares never acquire a live-stream session.
struct SMBPlaybackLibraryView: View {
    @State private var playback: FilePlaybackSelection?
    @State private var error: String?
    @StateObject private var idleTimer = PlaybackIdleTimer()

    var body: some View {
        SMBLibraryView(playbackActive: playback != nil) { connection, entry in
            do {
                let identity = connection.stableKey(for: entry.path)
                let key = SHA256.hash(data: Data(identity.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                playback = FilePlaybackSelection(
                    url: try connection.url(for: entry.path), title: entry.name,
                    identity: key, smbConnection: connection)
            } catch {
                self.error = "このファイルを開けませんでした。フォルダーを更新して再試行してください。"
            }
        }
        .fullScreenCover(item: $playback) { item in
            // Resume requires reliable timing metadata from the SMB path.
            // Until then, opening a file deliberately starts at the beginning.
            FilePlaybackView(item: item,
                onContinuousDisplayChanged: { idleTimer.setNeedsContinuousDisplay($0) })
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
