import RingonomiCore
import SwiftUI

/// The choice and player share one presentation. A dialog attached to the
/// browser's offscreen navigation root cannot reliably present on tvOS.
struct SMBResumePlaybackView: View {
    let item: FilePlaybackSelection
    let onBeginning: () -> Void
    let onContinuousDisplayChanged: (Bool) -> Void
    let onProgress: (Double, Double?, Bool) -> Void

    @State private var selectedItem: FilePlaybackSelection?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var resumeFocused: Bool

    init(item: FilePlaybackSelection, onBeginning: @escaping () -> Void,
         onContinuousDisplayChanged: @escaping (Bool) -> Void,
         onProgress: @escaping (Double, Double?, Bool) -> Void) {
        self.item = item
        self.onBeginning = onBeginning
        self.onContinuousDisplayChanged = onContinuousDisplayChanged
        self.onProgress = onProgress
        _selectedItem = State(initialValue: item.smbResumeBookmark == nil ? item : nil)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let selectedItem {
                FilePlaybackView(item: selectedItem,
                    onContinuousDisplayChanged: onContinuousDisplayChanged,
                    onProgress: onProgress)
            } else {
                resumeChoice
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var resumeChoice: some View {
        VStack(spacing: 26) {
            Text("続きから再生しますか？")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(item.title)
                .font(.title3).lineLimit(2).truncationMode(.middle)
            Text("前回の位置 \(resumeTime)")
                .foregroundStyle(.secondary).monospacedDigit()
            Button("続きから再生") { selectedItem = item }
                .focused($resumeFocused)
            Button("先頭から再生") {
                onBeginning()
                // Construct the new selection once. Recomputing it in body
                // would change its UUID and restart the decoder on updates.
                selectedItem = FilePlaybackSelection(url: item.url, title: item.title,
                    identity: item.identity, smbConnection: item.smbConnection)
            }
            Button("キャンセル", role: .cancel) { dismiss() }
        }
        .padding(60)
        .frame(maxWidth: 900)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .defaultFocus($resumeFocused, true)
        .onExitCommand { dismiss() }
    }

    private var resumeTime: String {
        guard let seconds = item.smbResumeBookmark?.seconds,
              let whole = Int(exactly: seconds.rounded(.down)), whole >= 0 else { return "保存位置" }
        return String(format: "%02lld:%02lld:%02lld", Int64(whole / 3600),
                      Int64((whole / 60) % 60), Int64(whole % 60))
    }
}
