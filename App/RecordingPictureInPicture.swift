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
    private var startDeadline: Task<Void, Never>?
    private weak var inlineLayer: AVPlayerLayer?
    private var sessionGeneration = UUID()
    private var restoreGeneration: UUID?
    private var isStarting = false
    private var isStopping = false
    private var ownsAudioSession = false

    var ownsPlayback: Bool { isStarting || isActive || isStopping }
    var usesSystemTransport: Bool { isActive && !isStopping }

    func attach(to layer: AVPlayerLayer) {
        guard isSupported, controller?.playerLayer !== layer, !ownsPlayback else { return }
        possibleObservation?.invalidate()
        controller?.delegate = nil
        inlineLayer = layer
        // The playback category must be active before tvOS evaluates whether
        // PiP is possible; the start button depends on that evaluation.
        _ = prepareAudioSession()
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

    private func prepareAudioSession() -> Bool {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
            ownsAudioSession = true
            return true
        } catch {
            notice = "PiPの音声を準備できませんでした。全画面で視聴を続けられます。"
            return false
        }
    }

    /// Called after the recording player has released its item, never merely
    /// when PiP returns inline and the same recording continues playing.
    func releaseAudioSession() {
        guard ownsAudioSession, !ownsPlayback else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        } catch {
            // Teardown is best effort; retain ownership so a later stop can retry.
        }
    }

    func start() {
        guard let controller, isSupported, isPossible, !ownsPlayback else {
            notice = "この録画ではまだPiPを開始できません。再生準備後にお試しください。"
            return
        }
        guard prepareAudioSession() else { return }
        cancelRestore()
        sessionGeneration = UUID()
        notice = nil
        returningInline = false
        isStarting = true
        isTransitioning = true
        controller.startPictureInPicture()
        let expected = sessionGeneration
        startDeadline?.cancel()
        startDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.sessionGeneration == expected, self.isStarting else { return }
            if let native = self.controller, native.isPictureInPictureActive {
                // Native state is authoritative even if its callback was lost.
                self.pictureInPictureControllerDidStartPictureInPicture(native)
            } else {
                // Release this unstarted controller, without tvOS's global
                // stop API, so a missing callback cannot strand the inline UI.
                self.controller?.delegate = nil
                self.possibleObservation?.invalidate()
                self.possibleObservation = nil
                self.controller = nil
                self.isStarting = false
                self.isTransitioning = false
                self.isDetached = false
                self.isPossible = false
                self.notice = "PiPの開始がタイムアウトしました。全画面で視聴を続けられます。"
                if let layer = self.inlineLayer { self.attach(to: layer) }
                self.finishClose(success: true)
            }
        }
    }

    func returnToInline() {
        guard ownsPlayback else { return }
        returningInline = true
        isDetached = false
        isTransitioning = true
        beginStopDeadline()
        requestNativeStop()
    }

    /// The presentation must stay alive until the system confirms teardown.
    /// A timeout reports failure and keeps the old player, rather than
    /// destroying a live PiP source or starting a second decoder.
    func stopBeforeClosing(_ completion: @escaping (Bool) -> Void) {
        guard stopCompletion == nil else { completion(false); return }
        guard ownsPlayback else { completion(true); return }
        returningInline = false
        cancelRestore()
        stopCompletion = completion
        beginStopDeadline()
        requestNativeStop()
    }

    private func beginStopDeadline() {
        let expected = UUID()
        stopToken = expected
        let expectedSession = sessionGeneration
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, !Task.isCancelled, self.stopToken == expected,
                  self.sessionGeneration == expectedSession else { return }
            if let native = self.controller, !native.isPictureInPictureActive, !self.isStarting {
                self.pictureInPictureControllerDidStopPictureInPicture(native)
                return
            }
            // Keep an active source alive and make the next explicit stop
            // retry possible even if the native completion never arrived.
            self.cancelRestore()
            self.isStarting = false
            self.isStopping = false
            self.isTransitioning = false
            self.isActive = true
            // Preserve the return intent: a delayed native stop must restore
            // inline playback, rather than treat the user's return as Close.
            self.isDetached = true
            self.notice = "PiPの終了を確認できませんでした。小窓を閉じるか、もう一度お試しください。"
            self.finishClose(success: false)
        }
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
        stopToken = UUID()
        deadline?.cancel()
        deadline = nil
        let completion = stopCompletion
        stopCompletion = nil
        completion?(success)
    }

    func completeRestore(_ restored: Bool, request: UUID) {
        guard restoreRequest == request, restoreGeneration == sessionGeneration else { return }
        let completion = restoreCompletion
        restoreCompletion = nil
        restoreRequest = nil
        restoreGeneration = nil
        completion?(restored)
    }

    private func cancelRestore() {
        let completion = restoreCompletion
        restoreCompletion = nil
        restoreRequest = nil
        restoreGeneration = nil
        completion?(false)
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
        startDeadline?.cancel()
        startDeadline = nil
        cancelRestore()
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pictureInPictureController === controller else { return }
        isStarting = true
        isTransitioning = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pictureInPictureController === controller else { return }
        startDeadline?.cancel()
        startDeadline = nil
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
        startDeadline?.cancel()
        startDeadline = nil
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
        if deadline == nil { beginStopDeadline() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pictureInPictureController === controller else { return }
        let shouldClose = isDetached && !returningInline && stopCompletion == nil
        startDeadline?.cancel()
        startDeadline = nil
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
        restoreGeneration = sessionGeneration
        restoreRequest = UUID()
        isTransitioning = true
        beginStopDeadline()
    }
}
