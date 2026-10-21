import RingonomiCore
import SwiftUI

private struct SMBPlaybackSession: Identifiable, Equatable {
    let item: FilePlaybackSelection
    let resumeID: SMBResumeID
    var id: UUID { item.id }
}

/// File playback stays outside directory navigation so closing it returns to
/// the same folder and search. Shares never acquire a live-stream session.
struct SMBPlaybackLibraryView: View {
    @State private var playback: SMBPlaybackSession?
    @State private var error: String?
    @StateObject private var resumeStore = SMBResumeStore.playbackStore()
    @StateObject private var idleTimer = PlaybackIdleTimer()

    var body: some View {
        SMBLibraryView(playbackActive: playback != nil) { connection, entry in
            do {
                let id = SMBResumeID(connection: connection, entry: entry)
                let bookmark = resumeStore.bookmark(for: id)
#if DEBUG
                print("RingonomiSMBResume: candidate=\(bookmark != nil)")
#endif
                let item = FilePlaybackSelection(
                    url: try connection.url(for: entry.path), title: entry.name,
                    identity: id.storageKey, smbConnection: connection,
                    smbResumeBookmark: bookmark)
                let session = SMBPlaybackSession(item: item, resumeID: id)
                playback = session
            } catch {
                self.error = "このファイルを開けませんでした。フォルダーを更新して再試行してください。"
            }
        }
        .fullScreenCover(item: $playback) { session in
            PlaybackHandoffView {
                SMBResumePlaybackView(item: session.item,
                    onBeginning: { resumeStore.remove(session.resumeID) },
                    onContinuousDisplayChanged: { needed in
                        guard playback?.id == session.id else { return }
                        idleTimer.setNeedsContinuousDisplay(needed)
                    },
                    onProgress: { seconds, duration, ended in
                        // Capture this session's ID, never the current selection.
                        resumeStore.save(session.resumeID, seconds: seconds,
                                         duration: duration, reachedEnd: ended)
                    })
            }
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
