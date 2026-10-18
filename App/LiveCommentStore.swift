import SwiftUI
import RingonomiCore

@MainActor
final class LiveCommentStore: ObservableObject {
    @Published private(set) var comments: [PlaybackComment] = []
    @Published private(set) var status: String?
    @Published private(set) var loading = false
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var clock = LiveCommentClock(now: ProcessInfo.processInfo.systemUptime)
    private var window = LiveCommentWindow()
    private var delay = 2.0
    private var mayDisplay = false
    private var receivedCount = 0
    private var connectedAt: Double?

    var currentSeconds: Double { clock.seconds(at: ProcessInfo.processInfo.systemUptime) }

    func updatePlaybackState(playing: Bool, delay: Double) {
        self.delay = delay.isFinite ? min(10, max(0, delay)) : 2
        if playing && !mayDisplay {
            // Drop pending arrivals on resume rather than replaying a burst.
            window.removeAll(keepingSeenIDs: true)
            comments = []
        }
        let wasPlaying = clock.isPlaying
        mayDisplay = playing
        clock.setPlaying(playing, at: ProcessInfo.processInfo.systemUptime)
#if DEBUG
        if wasPlaying != playing {
            print("RingonomiLiveCommentsClock: playing=\(playing) seconds=\(String(format: "%.3f", currentSeconds))")
        }
#endif
    }

    func run(client: RingonomiClient, channelID: String) async {
        cancel()
        let expected = generation
        window.removeAll()
        clock.reset(at: ProcessInfo.processInfo.systemUptime)
        comments = []
        receivedCount = 0
        loading = true
        status = "実況：接続しています…"
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.tick(generation: expected) }
                group.addTask { await self.receive(client: client, channelID: channelID, generation: expected) }
                await group.next()
                group.cancelAll()
            }
        }
        work = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if generation == expected { work = nil }
        if !Task.isCancelled, generation == expected {
            loading = false
            window.removeAll(keepingSeenIDs: true)
            comments = []
        }
    }

    private func receive(client: RingonomiClient, channelID: String, generation expected: UUID) async {
        var attempts = 0
        while !Task.isCancelled, generation == expected {
            do {
                connectedAt = nil
                let info = try await client.liveComments(channelID: channelID)
                try Task.checkCancellation()
                guard generation == expected else { return }
                try await LiveCommentTransport().run(info: info) { [weak self] event in
                    await self?.accept(event, generation: expected)
                }
            } catch {
                guard !Task.isCancelled, generation == expected else { return }
                loading = false
                let transportError = error as? LiveCommentTransportError
                let retryable = transportError?.canReconnect ?? isTemporaryRequestFailure(error)
                guard retryable else {
                    status = transportError?.errorDescription ?? "実況に接続できません。実況メニューから再接続できます。"
                    return
                }
                if let connectedAt, ProcessInfo.processInfo.systemUptime - connectedAt >= 30 { attempts = 0 }
                attempts = min(attempts + 1, 6)
                let wait = max(3, transportError?.retryAfter ?? min(60, 3 * pow(2, Double(attempts - 1))))
                status = "実況：接続が途切れました。\(Int(wait))秒後に再接続します。"
#if DEBUG
                print("RingonomiLiveComments: reconnect wait=\(Int(wait))")
#endif
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                guard !Task.isCancelled, generation == expected else { return }
                loading = true
                status = "実況：再接続しています…"
            }
        }
    }

    private func isTemporaryRequestFailure(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case ConnectionError.http(let code) = error { return code >= 500 || code == 429 }
        return false
    }

    private func accept(_ event: LiveCommentTransportEvent, generation expected: UUID) {
        guard generation == expected, !Task.isCancelled else { return }
        switch event {
        case .ready: break // Wait for rf:0 before declaring the live stream ready.
        case .historyFinished:
            connectedAt = ProcessInfo.processInfo.systemUptime
            loading = false
            status = nil
#if DEBUG
            print("RingonomiLiveComments: connected")
#endif
        case .chat(let chat):
            guard mayDisplay else { return }
            let now = currentSeconds
            guard let comment = try? chat.playbackComment(at: now + delay) else { return }
            // Thread+number identifies normal arrivals; timestamp distinguishes
            // compatible servers that omit either of those optional fields.
            let id = "\(chat.threadID ?? ""):\(chat.number ?? -1):\(chat.serverTime)"
            if window.append(id: id, comment: comment, at: now) {
                receivedCount += 1
#if DEBUG
                if receivedCount == 1 { print("RingonomiLiveComments: first arrival") }
#endif
            }
        }
    }

    private func tick(generation expected: UUID) async {
        while !Task.isCancelled, generation == expected {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard generation == expected, !Task.isCancelled else { return }
            let now = currentSeconds
            // Rollover keeps long sessions well below PlaybackComment's bound.
            if now > 86_400 {
                window.removeAll(keepingSeenIDs: true)
                clock.reset(at: ProcessInfo.processInfo.systemUptime)
            } else { window.prune(at: now) }
            let next = window.comments
            if comments != next { comments = next }
        }
    }

    func disable() {
        cancel()
        window.removeAll()
        comments = []
        status = nil
        loading = false
    }

    /// Cancel actual sockets through the structured transport task. Avoid
    /// publishing while SwiftUI is dismantling the playback view.
    func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
    }
}
