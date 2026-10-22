import SwiftUI
import RingonomiCore

/// Owns the recording metadata used by the chapter and commercial-skip card.
///
/// The view task is allowed to be cancelled when the playback overlay closes.
/// A UUID generation keeps a cancelled or slower response from publishing into
/// the next recording, while the ID check protects against a changed file on
/// the same server.
@MainActor
final class RecordingChapterStore: ObservableObject {
    @Published private(set) var timeline: RecordingChapterTimeline?
    @Published private(set) var isComplete = false
    @Published private(set) var fetching = false
    @Published private(set) var error: String?

    private var generation = UUID()

    func load(client: RingonomiClient, recordingID: Int, fileID: Int?,
              controller: RecordingPlaybackController) async {
        let expected = UUID()
        generation = expected
        fetching = true
        error = nil
        isComplete = false
        timeline = nil
        controller.configureCommercialTimeline(nil, isComplete: false)
        defer {
            if generation == expected { fetching = false }
        }

        do {
            let detail = try await client.fetch(["api", "videos", String(recordingID)], as: Recording.self)
            guard !Task.isCancelled, generation == expected else { return }
            guard detail.id == recordingID,
                  fileID == nil || detail.recordedVideo.id == fileID else {
                error = "録画情報が更新されています。録画一覧から開き直してください。"
                return
            }

            let nextIsComplete = detail.recordedVideo.status == "Recorded"
            let nextTimeline = RecordingChapterTimeline(
                duration: detail.recordedVideo.duration,
                sections: detail.recordedVideo.cmSections ?? []
            )
            guard !Task.isCancelled, generation == expected else { return }
            isComplete = nextIsComplete
            timeline = nextTimeline
            controller.configureCommercialTimeline(nextTimeline, isComplete: nextIsComplete)
            if nextTimeline == nil {
                error = "録画時間の情報を取得できませんでした。"
            }
#if DEBUG
            print("RingonomiChaptersReady: count=\(nextTimeline?.chapters.count ?? 0) commercials=\(nextTimeline?.commercialSections.count ?? 0)")
#endif
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == expected else { return }
            timeline = nil
            self.error = "チャプター情報を取得できませんでした。"
        }
    }

    /// Invalidates a pending response when the playback owner closes its view.
    func cancel() {
        generation = UUID()
        fetching = false
        timeline = nil
        isComplete = false
        error = nil
    }
}

/// A focus-stable card for chapter navigation and commercial skipping.
///
/// The card owns a bounded scroll region and an explicit focus identity for
/// every actionable row. This avoids the native Menu focus reset seen on older
/// Apple TV hardware when a chapter list is longer than the visible area.
struct RecordingChapterCard: View {
    private enum Choice: Hashable {
        case undo
        case automatic
        case previous
        case next
        case chapter(Int)
        case reload
        case close

        var identifier: String {
            switch self {
            case .undo: return "undo"
            case .automatic: return "automatic"
            case .previous: return "previous"
            case .next: return "next"
            case .chapter(let id): return "chapter.\(id)"
            case .reload: return "reload"
            case .close: return "close"
            }
        }
    }

    private struct ContentRevision: Equatable {
        let rows: [Choice]
        let fetching: Bool
        let error: String?
        let isComplete: Bool
    }

    @ObservedObject var store: RecordingChapterStore
    let position: Double
    @Binding var automaticSkip: Bool
    let canUndo: Bool
    let onUndo: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onChapter: (Double) -> Void
    let onReload: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedChoice: Choice?
    @State private var didSetInitialFocus = false

    private var initialChoice: Choice {
        canUndo ? .undo : .automatic
    }

    private var chapters: [RecordingChapter] {
        guard let timeline = store.timeline,
              !timeline.commercialSections.isEmpty else { return [] }
        return timeline.chapters
    }

    private var rowIDs: [Choice] {
        [.undo, .automatic, .previous, .next]
            + chapters.map { .chapter($0.id) }
            + [.reload, .close]
    }

    private var currentChapterID: Int? {
        guard position.isFinite, let chapter = chapters.first(where: {
            position >= $0.startTime && position < $0.endTime
        }) else { return nil }
        return chapter.id
    }

    private var hasBoundaries: Bool {
        store.timeline?.hasChapterBoundaries == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("チャプターとCM")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        actionButton(
                            "直前のCMスキップを戻す",
                            choice: .undo,
                            disabled: !canUndo,
                            action: onUndo
                        )

                        actionButton(
                            automaticSkip ? "CM自動スキップ：オン" : "CM自動スキップ：オフ",
                            choice: .automatic,
                            selected: automaticSkip,
                            action: { automaticSkip.toggle() }
                        )

                        if store.timeline != nil, !store.isComplete {
                            Text("自動スキップは録画完了後に利用できます")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 4)
                        }

                        Divider()

                        actionButton(
                            hasBoundaries ? "前のチャプター" : "1分戻る",
                            choice: .previous,
                            action: onPrevious
                        )
                        actionButton(
                            hasBoundaries ? "次のチャプター" : "3分進む",
                            choice: .next,
                            action: onNext
                        )

                        Divider()
                        chapterContent

                        Divider()

                        actionButton(
                            "情報を再取得",
                            choice: .reload,
                            disabled: store.fetching,
                            action: onReload
                        )
                        actionButton("戻る", choice: .close, action: onClose)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
                }
                .frame(height: scrollHeight)
                .task {
                    guard !didSetInitialFocus else { return }
                    didSetInitialFocus = true
                    focusedChoice = initialChoice
                    scroll(to: initialChoice, using: proxy)
                }
                .task(id: ContentRevision(rows: rowIDs, fetching: store.fetching,
                                          error: store.error, isComplete: store.isComplete)) {
                    // Loading, errors and refreshed rows can change content
                    // height without moving focus. Scroll after that layout
                    // update so the focused button remains fully visible.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll(to: focusedChoice, using: proxy)
                }
                .onChange(of: focusedChoice) { _, newChoice in
                    scroll(to: newChoice, using: proxy)
#if DEBUG
                    print("RingonomiChapterCardFocus: \(newChoice?.identifier ?? "none")")
#endif
                }
                .onChange(of: rowIDs) { _, updatedIDs in
                    guard let focusedChoice,
                          !updatedIDs.contains(focusedChoice) else { return }
                    let fallback = initialChoice
                    self.focusedChoice = fallback
                    scroll(to: fallback, using: proxy)
                }
                .onChange(of: canUndo) { _, enabled in
                    guard !enabled, focusedChoice == .undo else { return }
                    let fallback = Choice.automatic
                    focusedChoice = fallback
                    scroll(to: fallback, using: proxy)
                }
                .onChange(of: store.fetching) { _, isFetching in
                    guard isFetching, focusedChoice == .reload else { return }
                    focusedChoice = .close
                    scroll(to: .close, using: proxy)
                }
            }
        }
        .padding(40)
        .frame(width: 720)
        .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .focusSection()
        .defaultFocus($focusedChoice, initialChoice)
        .onExitCommand(perform: onClose)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: automaticSkip)
    }

    @ViewBuilder
    private var chapterContent: some View {
        if store.fetching {
            Text("チャプター情報を取得中…")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        } else if let error = store.error {
            Text(error)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        } else if chapters.isEmpty {
            Text("CM区間情報はありません")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        } else {
            ForEach(chapters) { chapter in
                chapterButton(chapter)
            }
        }
    }

    @ViewBuilder
    private func chapterButton(_ chapter: RecordingChapter) -> some View {
        let selected = currentChapterID == chapter.id
        Button {
            onChapter(chapter.startTime)
        } label: {
            HStack(alignment: .top, spacing: 16) {
                Text("\(chapter.id + 1) · \(Playback.timestamp(chapter.startTime)) · \(chapter.isCommercial ? "CM" : "本編")")
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Text("現在位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .focused($focusedChoice, equals: .chapter(chapter.id))
        .accessibilityLabel("\(chapter.id + 1) \(chapter.isCommercial ? "CM" : "本編")")
        .accessibilityValue(selected ? "現在位置" : Playback.timestamp(chapter.startTime))
        .accessibilityIdentifier("playback.chapter.\(chapter.id)")
        .id(Choice.chapter(chapter.id))
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        choice: Choice,
        selected: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard !disabled else { return }
            action()
        } label: {
            HStack(spacing: 16) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Text("✓")
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .focused($focusedChoice, equals: choice)
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "選択中" : disabled ? "利用不可" : "利用可能")
        .accessibilityIdentifier("playback.chapterChoice.\(choice.identifier)")
        .id(choice)
    }

    private var scrollHeight: CGFloat {
        let rows = CGFloat(max(6, rowIDs.count))
        return min(480, max(300, rows * 72))
    }

    private func scroll(to choice: Choice?, using proxy: ScrollViewProxy) {
        guard let choice else { return }
        if reduceMotion {
            proxy.scrollTo(choice, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                proxy.scrollTo(choice, anchor: .center)
            }
        }
    }
}
