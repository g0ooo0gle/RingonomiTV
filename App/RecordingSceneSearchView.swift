import SwiftUI
import RingonomiCore

/// A small page keeps image and focus work bounded even for long recordings.
struct RecordingSceneSearchView: View {
    let client: RingonomiClient
    let recordingID: Int
    let fileID: Int?
    let position: Double
    let onSelect: (Double) -> Void
    let onClose: () -> Void
    @StateObject private var store = RecordingSceneSearchStore()
    @State private var reload = 0
    @FocusState private var focus: Focus?
    private enum Focus: Hashable {
        case interval, previous, next, current, close, retry, scene(Int)
    }

    var body: some View {
        VStack(spacing: 22) {
            Text("シーンサーチ").font(.title2)
            Text("映像を選ぶと、その位置へ移動します。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Picker("間隔", selection: Binding(get: { store.interval }, set: { store.selectInterval($0) })) {
                    ForEach([10, 30, 60, 120, 300, 600], id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds)秒" : "\(seconds / 60)分").tag(seconds)
                    }
                }
                .focused($focus, equals: .interval)
                .disabled(store.loading || store.cards.isEmpty)
                Button("前のページ") { store.movePage(by: -1) }
                    .focused($focus, equals: .previous)
                    .disabled(store.pageIndex == 0 || store.loading || store.cards.isEmpty)
                Button("次のページ") { store.movePage(by: 1) }
                    .focused($focus, equals: .next)
                    .disabled(store.pageIndex + 1 >= store.pageCount || store.loading || store.cards.isEmpty)
                Button("現在位置") { store.moveToCurrentPosition(position) }
                    .focused($focus, equals: .current)
                    .disabled(store.loading || store.cards.isEmpty)
                Button("戻る", action: onClose).focused($focus, equals: .close)
            }
            .focusSection()
            if store.loading {
                Spacer()
                ProgressView("シーン画像を読み込み中…")
                Spacer()
            } else if let message = store.message {
                Spacer()
                Text(message).multilineTextAlignment(.center)
                Button("再試行") { reload &+= 1 }.focused($focus, equals: .retry)
                Spacer()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(350), spacing: 38), count: 3), spacing: 26) {
                    ForEach(store.cards) { card in
                        Button { onSelect(card.scene.timeSeconds) } label: {
                            VStack(spacing: 8) {
                                Image(decorative: card.image, scale: 1)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: 320, height: 180)
                                Text(Playback.timestamp(card.scene.timeSeconds)).monospacedDigit()
                            }.padding(8)
                        }
                        .focused($focus, equals: .scene(card.id))
                        .accessibilityLabel("\(Playback.timestamp(card.scene.timeSeconds))から再生")
                    }
                }
                .focusSection()
                Text("\(store.pageIndex + 1) / \(store.pageCount)ページ")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 72).padding(.vertical, 54)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.97))
        .onAppear { focus = .close }
        .task(id: reload) {
            await store.load(client: client, recordingID: recordingID, fileID: fileID, position: position)
            guard !Task.isCancelled else { return }
            focus = store.preferredSceneID.map(Focus.scene) ?? .retry
        }
        .onChange(of: store.preferredSceneID) { _, id in
            if let id { focus = .scene(id) }
        }
        .onChange(of: focus) { _, target in
            if case let .scene(id) = target { store.focusScene(id) }
        }
        .onExitCommand(perform: onClose)
        .onPlayPauseCommand { }
        .onDisappear { store.cancel() }
    }
}
