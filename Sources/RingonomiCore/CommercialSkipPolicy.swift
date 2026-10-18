import Foundation

/// A small state machine for automatically leaving a known commercial block.
///
/// The player calls ``automaticSeekTarget(timeline:at:enabled:isPlayingReady:)``
/// from its normal time/ready updates.  The policy only returns a target when
/// the clock is inside a validated commercial interval and the player is
/// actually ready to seek.  It never performs a seek or starts a timer itself.
public struct CommercialSkipPolicy: Equatable, Sendable {
    /// Leave this much of the tail of a recording untouched.  Seeking to the
    /// exact end can cause AVPlayer to clamp back to the end repeatedly.
    public static let minimumTailMargin: Double = 0.5

    /// The interval most recently returned as an automatic seek target.
    /// Exposed for diagnostics and UI state; callers should not mutate it.
    public private(set) var handledInterval: CommercialSection?

    private var suppressedInterval: CommercialSection?

    public init() {
        handledInterval = nil
        suppressedInterval = nil
    }

    /// Returns one safe seek target when the current position is inside a CM
    /// interval.  `isPlayingReady` must be false while paused, loading, or in
    /// a failed player state; this prevents a stale time callback from
    /// initiating a seek during a transition.
    public mutating func automaticSeekTarget(
        timeline: RecordingChapterTimeline,
        at seconds: Double,
        enabled: Bool,
        isPlayingReady: Bool
    ) -> Double? {
        guard enabled, isPlayingReady else { return nil }
        guard timeline.duration.isFinite,
              timeline.duration > 0,
              seconds.isFinite,
              seconds >= 0,
              seconds < timeline.duration else {
            return nil
        }

        clearStaleSuppression(for: timeline, at: seconds)
        guard timeline.hasCommercialSections,
              timeline.hasChapterBoundaries,
              let section = timeline.commercialSections.first(where: {
                  seconds >= $0.startTime && seconds < $0.endTime
              }) else {
            return nil
        }

        if suppressedInterval == section || handledInterval == section {
            return nil
        }

        // A trailing section has no safe target before EOF.  Treating it as
        // handled would make a later deliberate reset surprising, so simply
        // leave it ineligible each time.
        let safeEnd = timeline.duration - Self.minimumTailMargin
        guard safeEnd.isFinite,
              safeEnd > 0,
              section.endTime <= safeEnd,
              section.endTime > seconds else {
            return nil
        }

        handledInterval = section
        return section.endTime
    }

    /// Clears the once-per-interval guard after an explicit user seek.  A
    /// backwards seek can therefore trigger the same CM skip intentionally.
    public mutating func resetAfterManualSeek() {
        handledInterval = nil
        suppressedInterval = nil
    }

    /// Clears all policy state, normally when switching to another recording.
    public mutating func reset() {
        resetAfterManualSeek()
    }

    /// Suppresses automatic skipping for the interval containing `seconds`.
    /// This is useful when the user presses an Undo action after an automatic
    /// skip.  The suppression expires once playback passes that interval's
    /// end; an explicit manual reset clears it immediately.
    public mutating func suppressCurrentInterval(
        in timeline: RecordingChapterTimeline,
        at seconds: Double
    ) {
        guard timeline.duration.isFinite,
              timeline.duration > 0,
              seconds.isFinite,
              seconds >= 0,
              seconds < timeline.duration,
              let section = timeline.commercialSections.first(where: {
                  seconds >= $0.startTime && seconds < $0.endTime
              }) else {
            return
        }
        suppressedInterval = section
        handledInterval = section
    }

    private mutating func clearStaleSuppression(
        for timeline: RecordingChapterTimeline,
        at seconds: Double
    ) {
        guard let suppressedInterval else { return }
        guard timeline.commercialSections.contains(suppressedInterval) else {
            self.suppressedInterval = nil
            if handledInterval == suppressedInterval {
                handledInterval = nil
            }
            return
        }
        if seconds >= suppressedInterval.endTime {
            self.suppressedInterval = nil
            if handledInterval == suppressedInterval {
                handledInterval = nil
            }
        }
    }
}
