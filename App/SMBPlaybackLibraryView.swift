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
    @State private var pendingResume: SMBPlaybackSession?
    @State private var error: String?
    @StateObject private var resumeStore = SMBResumeStore.playbackStore()
    @StateObject private var idleTimer = PlaybackIdleTimer()

    private var libraryContent: some View {
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
                if bookmark != nil { pendingResume = session }
                else { playback = session }
            } catch {
                self.error = "このファイルを開けませんでした。フォルダーを更新して再試行してください。"
            }
        }
    }

    // Keep the presenter outside the browser's own share-delete dialog. Both
    // can otherwise resolve to the same navigation presentation anchor.
    private var resumePresentationAnchor: some View {
        Color.clear.frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        .confirmationDialog("続きから再生しますか？", isPresented: Binding(
            get: { pendingResume != nil },
            set: { if !$0 { pendingResume = nil } }
        ), titleVisibility: .visible, presenting: pendingResume) { session in
            Button("前回の続きから（\(resumeTime(session.item.smbResumeBookmark?.seconds))）") {
                pendingResume = nil
                playback = session
            }
            Button("先頭から再生") {
                resumeStore.remove(session.resumeID)
                pendingResume = nil
                playback = SMBPlaybackSession(item: FilePlaybackSelection(
                    url: session.item.url, title: session.item.title,
                    identity: session.item.identity, smbConnection: session.item.smbConnection),
                    resumeID: session.resumeID)
            }
            Button("キャンセル", role: .cancel) { pendingResume = nil }
        }
        .alert("ファイルを開けません", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("閉じる", role: .cancel) { error = nil } }
        message: { Text(error ?? "") }
    }

    var body: some View {
        ZStack {
            libraryContent
            resumePresentationAnchor
        }
        .fullScreenCover(item: $playback) { session in
            FilePlaybackView(item: session.item,
                onContinuousDisplayChanged: { idleTimer.setNeedsContinuousDisplay($0) },
                onProgress: { seconds, duration, ended in
                    // Capture this session's ID, never the current selection.
                    resumeStore.save(session.resumeID, seconds: seconds,
                                     duration: duration, reachedEnd: ended)
                })
        }
        .onChange(of: playback) { _, item in
            if item == nil { idleTimer.setNeedsContinuousDisplay(false) }
        }
        .onDisappear { idleTimer.setNeedsContinuousDisplay(false) }

    }

    private func resumeTime(_ seconds: Double?) -> String {
        guard let seconds, let whole = Int(exactly: seconds.rounded(.down)), whole >= 0 else {
            return "保存位置"
        }
        return String(format: "%02lld:%02lld:%02lld", Int64(whole / 3600), Int64((whole / 60) % 60), Int64(whole % 60))
    }
}
