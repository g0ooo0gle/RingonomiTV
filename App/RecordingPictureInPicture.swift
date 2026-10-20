import AVKit
import SwiftUI

/// Owns only this player's PiP session. It never stops another app's PiP.
@MainActor
final class RecordingPictureInPicture: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    @Published private(set) var isDetached = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var notice: String?
    @Published private(set) var restoreRequest: UUID?
    @Published private(set) var endedWhileDetached: UUID?

    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var stopCompletion: ((Bool) -> Void)?
    private var restoreCompletion: ((Bool) -> Void)?
    private var deadline: Task<Void, Never>?
    private var stopToken = UUID()
    private var returningInline = false
    private var isStarting = false
    private var isStopping = false

    var ownsPlayback: Bool { isStarting || isActive || isStopping }
    var usesSystemTransport: Bool { isActive && !isStopping }

    func attach(to layer: AVPlayerLayer) {
        guard isSupported, controller?.playerLayer !== layer, !ownsPlayback else { return }
        possibleObservation?.invalidate()
        controller?.delegate = nil
        controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        possibleObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshPossible() }
        }
    }

    private func refreshPossible() {
        isPossible = controller?.isPictureInPicturePossible == true
#if DEBUG
        print("RingonomiPiP: supported=\(isSupported) possible=\(isPossible) active=\(isActive)")
#endif
    }

    func start() {
        guard let controller, isSupported, isPossible, !ownsPlayback else {
            notice = "この録画ではまだPiPを開始できません。再生準備後にお試しください。"
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            notice = "PiPの音声を準備できませんでした。全画面で視聴を続けられます。"
            return
        }
        notice = nil
        returningInline = false
        isStarting = true
        isTransitioning = true
        controller.startPictureInPicture()
    }

    func returnToInline() {
        guard ownsPlayback else { return }
        returningInline = true
        isDetached = false
        requestNativeStop()
    }

    /// The presentation must stay alive until the system confirms teardown.
    /// A timeout reports failure and keeps the old player, rather than
    /// destroying a live PiP source or starting a second decoder.
    func stopBeforeClosing(_ completion: @escaping (Bool) -> Void) {
        guard stopCompletion == nil else { completion(false); return }
        guard ownsPlayback else { completion(true); return }
        returningInline = false
        stopCompletion = completion
        let expected = UUID()
        stopToken = expected
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.stopToken == expected, self.stopCompletion != nil else { return }
            self.notice = "PiPの終了を確認できませんでした。小窓を閉じてから再度お試しください。"
            self.finishClose(success: false)
        }
        requestNativeStop()
    }

    private func requestNativeStop() {
        // tvOS stopPictureInPicture can stop other applications too. Call it
        // only for a session which this controller has actually started.
        guard !isStarting, let controller, isActive || controller.isPictureInPictureActive else { return }
        guard !isStopping else { return }
        isStopping = true
        isTransitioning = true
        controller.stopPictureInPicture()
    }

    private func finishClose(success: Bool) {
        deadline?.cancel()
        deadline = nil
        let completion = stopCompletion
        stopCompletion = nil
        completion?(success)
    }

    func completeRestore(_ restored: Bool, request: UUID) {
        guard restoreRequest == request else { return }
        let completion = restoreCompletion
        restoreCompletion = nil
        restoreRequest = nil
        completion?(restored)
    }

    func invalidate() {
        // Normal view teardown only follows the didStop handshake.
        guard !ownsPlayback else { return }
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller?.delegate = nil
        controller = nil
        deadline?.cancel()
        deadline = nil
        restoreCompletion?(false)
        restoreCompletion = nil
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pictureInPictureController === controller else { return }
        isStarting = true
        isTransitioning = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pictureInPictureController === controller else { return }
        isStarting = false
        isActive = true
        isTransitioning = false
        isDetached = stopCompletion == nil && !returningInline
#if DEBUG
        print("RingonomiPiP: started detached=\(isDetached)")
#endif
        if stopCompletion != nil || returningInline { requestNativeStop() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard pictureInPictureController === controller else { return }
        isStarting = false
        isActive = false
        isStopping = false
        isDetached = false
        isTransitioning = false
        notice = "PiPを開始できませんでした。全画面で視聴を続けられます。"
        finishClose(success: true)
#if DEBUG
        print("RingonomiPiP: start-failed")
#endif
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pictureInPictureController === controller else { return }
        isStopping = true
        isTransitioning = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pictureInPictureController === controller else { return }
        let shouldClose = isDetached && !returningInline && stopCompletion == nil
        isStarting = false
        isActive = false
        isStopping = false
        isDetached = false
        isTransitioning = false
        returningInline = false
        if shouldClose { endedWhileDetached = UUID() }
        finishClose(success: true)
#if DEBUG
        print("RingonomiPiP: stopped close=\(shouldClose)")
#endif
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard pictureInPictureController === controller, stopCompletion == nil else {
            completionHandler(false)
            return
        }
        restoreCompletion?(false)
        returningInline = true
        isDetached = false
        restoreCompletion = completionHandler
        restoreRequest = UUID()
    }
}
