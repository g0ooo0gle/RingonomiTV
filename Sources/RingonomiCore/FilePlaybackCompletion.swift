/// Native EOF can also mean that a file stream stopped supplying data.
/// Only a position accepted after video readiness can confirm completion.
public enum FilePlaybackCompletion {
    public static func confirmsEnd(
        duration: Double?,
        trustedSeconds: Double?,
        hasPresentedCurrentPosition: Bool,
        verifiedEndSeek: Bool = false
    ) -> Bool {
        guard let duration, duration.isFinite, duration > 0 else { return false }
        // The caller separately checked the applied end-seek target, native
        // position, and decoded output from this input before passing this.
        if verifiedEndSeek { return true }
        guard hasPresentedCurrentPosition,
              let trustedSeconds,
              trustedSeconds.isFinite, trustedSeconds >= 0 else { return false }
        let tolerance = max(0.75, min(2, duration * 0.01))
        return abs(duration - trustedSeconds) <= tolerance
    }
}

/// Compatibility name for clients using the original shared-file policy.
public typealias SMBPlaybackCompletion = FilePlaybackCompletion
