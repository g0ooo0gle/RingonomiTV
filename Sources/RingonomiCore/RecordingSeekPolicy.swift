import Foundation

/// Recognizes an explicit end seek only for complete recordings with a known
/// media duration. Callers must not substitute a catalog duration hint.
public enum RecordingSeekPolicy {
    public static func isEndTarget(seconds: Double, duration: Double?, status: String?) -> Bool {
        guard status == "Recorded", seconds.isFinite, seconds > 0,
              let duration, duration.isFinite, duration > 0 else { return false }
        // Match the normal resume clamp without classifying a short clip's
        // initial zero position as EOF.
        return seconds >= max(duration / 2, duration - 0.25)
    }
}
