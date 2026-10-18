import Foundation

/// 音声と映像が1秒間継続して準備できるまで、開始直後の短いバーストを隠す。
public struct PlaybackReadinessGate: Sendable {
    private var previousPictures = 0
    private var advancingSamples = 0
    private var stableSince: Double?
    private var lastAdvance: Double?
    public init() {}
    public mutating func reset() {
        previousPictures = 0; advancingSamples = 0
        stableSince = nil; lastAdvance = nil
    }
    public mutating func update(hasVideo: Bool, pictures: Int, audioReady: Bool,
                                at time: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard hasVideo, audioReady, pictures > 0, pictures < 100_000_000 else {
            reset()
            return false
        }
        if pictures < previousPictures || lastAdvance.map({ time - $0 > 0.75 || time < $0 }) == true {
            reset()
        }
        if pictures > previousPictures {
            advancingSamples += 1
            if stableSince == nil { stableSince = time }
            lastAdvance = time
        }
        previousPictures = pictures
        return advancingSamples >= 2 && time - (stableSince ?? time) >= 1
    }
}
