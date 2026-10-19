import Foundation

#if canImport(TVVLCKit)
@preconcurrency import TVVLCKit

/// Owns a stopped VLC player after its delegate and drawable have been detached.
///
/// The owner transfers the native reference once.  The transfer is delayed by
/// one main-queue turn so the caller's teardown stack has unwound, then the
/// final native release runs on a utility queue instead of the UI actor.
final class StoppedVLCPlayerRetirement: @unchecked Sendable {
    enum Context: Sendable {
        case file
        case live
    }

    private static let queue = DispatchQueue(
        label: "app.ringonomitv.vlc-player-retirement",
        qos: .utility
    )

    private let context: Context
    private var player: VLCMediaPlayer?
    private var retainedResources: [AnyObject]
    private var didScheduleRelease = false

    init(_ player: VLCMediaPlayer, context: Context, retainedResources: [AnyObject] = []) {
        self.player = player
        self.context = context
        self.retainedResources = retainedResources
    }

    func releaseAfterCurrentTurn(onRelease: @escaping @MainActor @Sendable () -> Void) {
        guard !didScheduleRelease else { return }
        didScheduleRelease = true

        // Let the caller's stack unwind before the final native reference is
        // released. The completion itself only reads its owner on MainActor.
        DispatchQueue.main.async {
            Self.queue.async {
                self.releasePlayer()
                Task { @MainActor in onRelease() }
            }
        }
    }

    private func releasePlayer() {
#if DEBUG
        NSLog("\(debugPrefix): release-begin")
#endif
        player = nil
        // Authentication providers must outlive the decoder's final callback.
        retainedResources = []
#if DEBUG
        NSLog("\(debugPrefix): release-returned")
#endif
    }

#if DEBUG
    private var debugPrefix: String {
        switch context {
        case .file: return "RingonomiFileReload"
        case .live: return "RingonomiLiveRetirement"
        }
    }
#endif
}
#endif
