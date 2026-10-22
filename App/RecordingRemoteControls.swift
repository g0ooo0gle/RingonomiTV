import AVFoundation
import Foundation
@preconcurrency import MediaPlayer

/// Receives system transport commands only for this recording's PiP session.
@MainActor
final class RecordingRemoteControls {
    enum Command: Sendable { case play, pause, toggle }

    private let player: AVPlayer
    private let onCommand: @MainActor (Command) -> Void
    private let gate = RecordingRemoteCommandGate()
    private var session: MPNowPlayingSession?
    private var generation: UUID?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var lastPublication = Date.distantPast
    private var lastTitle = ""
    private var lastDuration: Double?
    private var lastRate: Double?

    init(player: AVPlayer, onCommand: @escaping @MainActor (Command) -> Void) {
        self.player = player
        self.onCommand = onCommand
    }

    deinit { gate.setGeneration(nil) }

    func activate() {
        guard session == nil else { return }
        let expected = UUID()
        generation = expected
        gate.setGeneration(expected)
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = false
        self.session = session
        lastPublication = .distantPast
        let commands = session.remoteCommandCenter
        register(commands.playCommand, action: .play, generation: expected)
        register(commands.pauseCommand, action: .pause, generation: expected)
        register(commands.togglePlayPauseCommand, action: .toggle, generation: expected)
        session.becomeActiveIfPossible { @Sendable [weak self] active in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
#if DEBUG
                print("RingonomiRecordingRemote: active=\(active)")
#endif
            }
        }
    }

    private func register(_ command: MPRemoteCommand, action: Command, generation expected: UUID) {
        let gate = gate
        command.isEnabled = true
        let target = command.addTarget { @Sendable [weak self, gate] _ in
            // MediaPlayer does not promise a main-actor callback. Reject a
            // retired session synchronously, then validate again on delivery.
            guard gate.accepts(expected) else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.onCommand(action)
            }
            return .success
        }
        targets.append((command, target))
    }

    func update(title: String, seconds: Double, duration: Double?, playing: Bool) {
        guard let session else { return }
        let rate = playing ? 1.0 : 0.0
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard title != lastTitle || duration != lastDuration || rate != lastRate
                || Date().timeIntervalSince(lastPublication) >= 5 else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: seconds.isFinite ? max(0, seconds) : 0,
        ]
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        session.nowPlayingInfoCenter.nowPlayingInfo = info
        lastTitle = title
        lastDuration = duration
        lastRate = rate
        lastPublication = Date()
    }

    func deactivate() {
        gate.setGeneration(nil)
        generation = nil
        for (command, target) in targets {
            command.isEnabled = false
            command.removeTarget(target)
        }
        targets.removeAll()
        session?.nowPlayingInfoCenter.nowPlayingInfo = nil
        session = nil
    }
}

/// Only the generation crosses MediaPlayer's callback queue. All player and
/// session operations remain on the main actor.
private final class RecordingRemoteCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UUID?

    func setGeneration(_ value: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        generation = value
    }

    func accepts(_ expected: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expected
    }
}
