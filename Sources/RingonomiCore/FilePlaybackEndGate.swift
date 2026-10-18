import Foundation

/// Confirms an apparent end of a file playback stream after a bounded stall.
///
/// Native VLC can report a normalized position of `1` and a zero remaining
/// time while its state is still buffering.  This gate requires independent
/// duration/position evidence and then waits for the time, video-frame count,
/// and played-audio count to remain unchanged for two seconds.  It is a pure
/// state machine; the caller supplies the completed-recording duration and
/// decides what to do after the gate opens.
public struct FilePlaybackEndGate: Sendable {
    public static let requiredStableSeconds: TimeInterval = 2

    private var stableSince: TimeInterval?
    private var lastCurrentSeconds: Double?
    private var lastDisplayedPictures: Int?
    private var lastPlayedAudioBuffers: Int?
    private var lastSampleTime: TimeInterval?

    public init() {}

    public mutating func reset() {
        stableSince = nil
        lastCurrentSeconds = nil
        lastDisplayedPictures = nil
        lastPlayedAudioBuffers = nil
        lastSampleTime = nil
    }

    /// Returns true only after a confirmed near-end sample has stopped making
    /// progress for the required bounded interval.
    public mutating func update(
        currentSeconds: Double?,
        duration: Double?,
        position: Double,
        remainingSeconds: Double?,
        isPaused: Bool,
        hasPendingSeek: Bool,
        displayedPictures: Int,
        playedAudioBuffers: Int,
        at: TimeInterval
    ) -> Bool {
        guard let currentSeconds,
              currentSeconds.isFinite,
              currentSeconds >= 0,
              let duration,
              duration.isFinite,
              duration > 0,
              position.isFinite,
              position >= 1,
              let remainingSeconds,
              remainingSeconds.isFinite,
              abs(remainingSeconds) <= 0.05,
              !isPaused,
              !hasPendingSeek,
              displayedPictures > 0,
              playedAudioBuffers >= 0,
              at.isFinite else {
            reset()
            return false
        }

        let nearEndTolerance = max(0.75, min(2.0, duration * 0.01))
        guard abs(duration - currentSeconds) <= nearEndTolerance else {
            reset()
            return false
        }

        if let lastSampleTime, at <= lastSampleTime {
            reset()
            return false
        }

        let sameSample = lastCurrentSeconds == currentSeconds
            && lastDisplayedPictures == displayedPictures
            && lastPlayedAudioBuffers == playedAudioBuffers

        if sameSample, let stableSince {
            self.lastSampleTime = at
            return at - stableSince >= Self.requiredStableSeconds
        }

        // Any time, frame, or audio progress starts a fresh bounded stall
        // window.  A newly valid sample also starts the first window.
        self.stableSince = at
        self.lastCurrentSeconds = currentSeconds
        self.lastDisplayedPictures = displayedPictures
        self.lastPlayedAudioBuffers = playedAudioBuffers
        self.lastSampleTime = at
        return false
    }
}
