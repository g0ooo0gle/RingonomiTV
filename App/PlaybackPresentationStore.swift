import SwiftUI

enum PlaybackBackend {
    case konomi
    case mirakurun
    case epgStationRecording
    case epgStationLive
    case smb
}

/// The selected backend keeps its own decoder and transport semantics.
enum PlaybackSession: Identifiable {
    case konomi(Playback)
    case mirakurun(MirakurunPlaybackSelection)
    case epgStationRecording(EPGStationPlaybackSession)
    case epgStationLive(EPGStationLivePlaybackSelection)
    case smb(SMBPlaybackSession)

    var id: UUID {
        switch self {
        case .konomi(let item): item.id
        case .mirakurun(let item): item.id
        case .epgStationRecording(let item): item.id
        case .epgStationLive(let item): item.id
        case .smb(let item): item.id
        }
    }
    var title: String {
        switch self {
        case .konomi(let item): item.title
        case .mirakurun(let item): item.title
        case .epgStationRecording(let item): item.title
        case .epgStationLive(let item): item.title
        case .smb(let item): item.title
        }
    }
    var backend: PlaybackBackend {
        switch self {
        case .konomi: .konomi
        case .mirakurun: .mirakurun
        case .epgStationRecording: .epgStationRecording
        case .epgStationLive: .epgStationLive
        case .smb: .smb
        }
    }
    var smbConnectionID: UUID? {
        if case .smb(let item) = self { item.connectionID } else { nil }
    }
    var konomi: Playback? {
        if case .konomi(let item) = self { item } else { nil }
    }
}

/// Keeps the playback subtree mounted while PiP exposes the library below it.
/// A replacement waits for the old session's native PiP stop acknowledgment.
@MainActor
final class PlaybackPresentationStore: ObservableObject {
    @Published private(set) var current: PlaybackSession?
    @Published private(set) var closeRequest: UUID?
    @Published private(set) var restoreRequest: UUID?
    @Published private(set) var controlsFocusRequest: UUID?
    @Published private(set) var togglePauseRequest: UInt64 = 0
    @Published private(set) var transport = PlaybackTransportState()
    @Published private(set) var isDetached = false
    @Published private(set) var isMiniPlayer = false
    var exposesLibrary: Bool { isDetached || isMiniPlayer }
    @Published private(set) var notice: String?
    private var pending: PlaybackSession?
    private var hasPending = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func present(_ playback: Playback?) {
        presentSession(playback.map(PlaybackSession.konomi))
    }

    func presentMirakurun(_ playback: MirakurunPlaybackSelection) {
        presentSession(.mirakurun(playback))
    }

    func presentEPGStationRecording(_ playback: EPGStationPlaybackSession) {
        presentSession(.epgStationRecording(playback))
    }

    func presentEPGStationLive(_ playback: EPGStationLivePlaybackSelection) {
        presentSession(.epgStationLive(playback))
    }

    func presentSMB(_ playback: SMBPlaybackSession) {
        presentSession(.smb(playback))
    }

    /// A queued file already owns its connection snapshot, even before decoding.
    func usesSMBConnection(_ id: UUID) -> Bool {
        current?.smbConnectionID == id || pending?.smbConnectionID == id
    }

    private func presentSession(_ playback: PlaybackSession?) {
        guard let current else {
            self.current = playback
            return
        }
        guard playback?.id != current.id else { return }
        pending = playback
        hasPending = true
        _ = beginClosing(current.id)
    }

    /// One token covers a manual close and any replacement queued during it.
    func beginClosing(_ id: UUID) -> UUID? {
        guard current?.id == id else { return nil }
        if closeRequest == nil { closeRequest = UUID() }
        return closeRequest
    }

    /// Connection changes can invalidate a selection still waiting for handoff.
    func cancelSession(_ id: UUID) {
        if current?.id == id {
            // Invalidating the origin must not discard a newer selection
            // from a different backend already waiting for this stop.
            if !hasPending { pending = nil; hasPending = true }
            _ = beginClosing(id)
        } else if pending?.id == id { pending = nil; hasPending = true }
    }

    /// Invalidate both selected and queued items belonging to one connection.
    func cancelSessions(for backend: PlaybackBackend) {
        if let pending, pending.backend == backend { cancelSession(pending.id) }
        if let current, current.backend == backend { cancelSession(current.id) }
    }

    func setDetached(_ detached: Bool, for id: UUID) {
        guard current?.id == id else { return }
        isDetached = detached
        if detached { isMiniPlayer = false }
    }

    func setMiniPlayer(_ active: Bool, for id: UUID) {
        guard current?.id == id, closeRequest == nil, !isDetached else { return }
        isMiniPlayer = active
    }

    func setNotice(_ notice: String?, for id: UUID) {
        guard current?.id == id else { return }
        self.notice = notice
    }

    func setTransport(_ state: PlaybackTransportState, for id: UUID) {
        guard current?.id == id else { return }
        transport = state
    }

    func toggleDetachedPause() {
        guard current != nil, exposesLibrary, closeRequest == nil, transport.canToggle else { return }
        // SwiftUI can coalesce multiple inputs into one render. A counter
        // preserves their parity instead of losing all but the last UUID.
        togglePauseRequest &+= 1
    }

    /// A guide captures directional movement within its time grid. Menu can
    /// return focus to the exposed playback controls without walking to day end.
    func requestControlsFocus() {
        guard current != nil, exposesLibrary, closeRequest == nil else { return }
        controlsFocusRequest = UUID()
    }

    func restoreInline() {
        guard current != nil, exposesLibrary, closeRequest == nil else { return }
        isMiniPlayer = false
        restoreRequest = UUID()
    }

    func didClose(_ id: UUID, request: UUID, success: Bool) {
        guard current?.id == id, closeRequest == request else { return }
        closeRequest = nil
        if success {
            current = hasPending ? pending : nil
            isDetached = false
            isMiniPlayer = false
            restoreRequest = nil
            controlsFocusRequest = nil
            notice = nil
            togglePauseRequest = 0
            transport = PlaybackTransportState()
        }
        pending = nil
        hasPending = false
        let completions = Array(waiters.values)
        waiters.removeAll()
        for completion in completions { completion.resume(returning: success && current == nil) }
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
