import RingonomiCore
import SwiftUI

struct SMBPlaybackSession: Identifiable {
    let item: FilePlaybackSelection
    let resumeID: SMBResumeID
    let connectionID: UUID
    var id: UUID { item.id }
    var title: String { item.title }
}

/// File playback stays outside directory navigation so closing it returns to
/// the same folder and search. Shares never acquire a live-stream session.
struct SMBPlaybackLibraryView: View {
    @State private var error: String?
    @EnvironmentObject private var resumeStore: SMBResumeStore
    @EnvironmentObject private var presentation: PlaybackPresentationStore

    private var playbackActive: Bool {
        presentation.current?.backend == .smb || presentation.closeRequest != nil
    }

    var body: some View {
        SMBLibraryView(playbackActive: playbackActive,
                       isConnectionInUse: { presentation.usesSMBConnection($0) }) { connection, entry in
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
                presentation.presentSMB(SMBPlaybackSession(item: item, resumeID: id,
                                                          connectionID: connection.id))
            } catch {
                self.error = "このファイルを開けませんでした。フォルダーを更新して再試行してください。"
            }
        }
        .alert("ファイルを開けません", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("閉じる", role: .cancel) { error = nil } }
        message: { Text(error ?? "") }
    }
}
