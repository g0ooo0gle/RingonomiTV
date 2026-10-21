import SwiftUI

/// Keeps the playback subtree mounted while PiP exposes the library below it.
/// A replacement waits for the old session's native PiP stop acknowledgment.
@MainActor
final class PlaybackPresentationStore: ObservableObject {
    @Published private(set) var current: Playback?
    @Published private(set) var closeRequest: UUID?
    @Published private(set) var restoreRequest: UUID?
    @Published private(set) var togglePauseRequest: UInt64 = 0
    @Published private(set) var transport = PlaybackTransportState()
    @Published private(set) var isDetached = false
    @Published private(set) var notice: String?
    private var pending: Playback?
    private var hasPending = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func present(_ playback: Playback?) {
        guard let current else {
            self.current = playback
            return
        }
        guard playback?.id != current.id else { return }
        pending = playback
        hasPending = true
        closeRequest = UUID()
    }

    func setDetached(_ detached: Bool, for id: UUID) {
        guard current?.id == id else { return }
        isDetached = detached
    }

    func setNotice(_ notice: String?, for id: UUID) {
        guard current?.id == id else { return }
        self.notice = notice
    }

    func setTransport(_ state: PlaybackTransportState, for id: UUID) {
        guard current?.id == id else { return }
        transport = state
    }

    func togglePictureInPicturePause() {
        guard current != nil, isDetached, closeRequest == nil, transport.canToggle else { return }
        // SwiftUI can coalesce multiple inputs into one render. A counter
        // preserves their parity instead of losing all but the last UUID.
        togglePauseRequest &+= 1
    }

    func restoreInline() {
        guard current != nil, isDetached, closeRequest == nil else { return }
        restoreRequest = UUID()
    }

    func didClose(_ id: UUID, success: Bool) {
        guard current?.id == id else { return }
        closeRequest = nil
        if success {
            current = hasPending ? pending : nil
            isDetached = false
            restoreRequest = nil
            notice = nil
            togglePauseRequest = 0
            transport = PlaybackTransportState()
        }
        pending = nil
        hasPending = false
        let completions = Array(waiters.values)
        waiters.removeAll()
        for completion in completions { completion.resume(returning: success) }
    }

    func stopForAnotherPlayer() async -> Bool {
        guard current != nil else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                waiters[id] = continuation
                present(nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }
}

struct PlaybackTransportState: Equatable {
    var isPaused = false
    var canToggle = false
}

struct PlaybackHandoff: Sendable {
    var stopPrevious: @MainActor @Sendable () async -> Bool = { true }
}

private struct PlaybackHandoffKey: EnvironmentKey {
    static let defaultValue = PlaybackHandoff()
}

extension EnvironmentValues {
    var playbackHandoff: PlaybackHandoff {
        get { self[PlaybackHandoffKey.self] }
        set { self[PlaybackHandoffKey.self] = newValue }
    }
}

/// Backend players wait before creating any decoder, even when their modal
/// presentation was requested from a library visible underneath PiP.
struct PlaybackHandoffView<Content: View>: View {
    @Environment(\.playbackHandoff) private var handoff
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var failed = false
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View {
        Group {
            if ready { content() }
            else {
                VStack(spacing: 28) {
                    if failed { Text("前の再生を終了できませんでした。小窓を閉じてからお試しください。") }
                    else { ProgressView("前の再生を終了しています…") }
                    Button("閉じる") { dismiss() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            }
        }
        .task {
            guard !ready else { return }
            let stopped = await handoff.stopPrevious()
            guard !Task.isCancelled else { return }
            ready = stopped
            failed = !stopped
        }
    }
}
