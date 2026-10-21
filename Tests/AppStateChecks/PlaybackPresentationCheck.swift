import Foundation

// Only the immutable selections are substituted. The presentation store and
// SwiftUI observable state are compiled directly from the application sources.
struct Playback { let id = UUID(); let title = "Recording fixture" }
struct MirakurunPlaybackSelection { let id = UUID(); let title = "Live fixture" }

@main
struct PlaybackPresentationCheck {
    struct CheckFailure: Error { let message: String }
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message: message) }
        checks += 1
    }
    @MainActor static func waitForRequest(_ store: PlaybackPresentationStore) async throws -> UUID {
        for _ in 0..<100 {
            if let request = store.closeRequest { return request }
            await Task.yield()
        }
        throw CheckFailure(message: "close request was not issued")
    }
    @MainActor static func main() async throws {
        let store = PlaybackPresentationStore()
        let first = Playback(), second = MirakurunPlaybackSelection(), third = Playback()
        store.present(first)
        try expect(store.current?.id == first.id, "initial selection")
        store.setMiniPlayer(true, for: first.id)
        store.setTransport(PlaybackTransportState(isPaused: false, canToggle: true), for: first.id)
        store.toggleDetachedPause(); store.toggleDetachedPause()
        try expect(store.togglePauseRequest == 2, "coalesced remote presses preserve parity")
        store.presentMirakurun(second)
        let request = try await waitForRequest(store)
        try expect(store.current?.id == first.id, "replacement waits for native stop")
        try expect(store.beginClosing(first.id) == request, "manual and queued close share token")
        store.present(third)
        try expect(store.closeRequest == request, "later selection does not invalidate stop token")
        store.didClose(first.id, request: UUID(), success: true)
        try expect(store.current?.id == first.id, "foreign request ignored")
        store.didClose(UUID(), request: request, success: true)
        try expect(store.current?.id == first.id, "foreign session ignored")
        store.didClose(first.id, request: request, success: false)
        try expect(store.current?.id == first.id && store.closeRequest == nil, "failed stop keeps old session")
        store.presentMirakurun(second)
        let retry = try await waitForRequest(store)
        try expect(retry != request, "failed stop retry has new token")
        store.didClose(first.id, request: request, success: true)
        try expect(store.closeRequest == retry, "late old completion ignored during retry")
        store.didClose(first.id, request: retry, success: true)
        try expect(store.current?.id == second.id && store.current?.konomi == nil, "Mirakurun installed after matching ack")
        try expect(!store.exposesLibrary && store.transport == PlaybackTransportState(), "new session presentation reset")
        store.didClose(first.id, request: retry, success: true)
        store.setMiniPlayer(true, for: first.id)
        store.setTransport(PlaybackTransportState(isPaused: true, canToggle: true), for: first.id)
        store.setNotice("stale", for: first.id)
        try expect(store.current?.id == second.id && !store.exposesLibrary && store.notice == nil, "stale callbacks cannot mutate successor")
        store.setMiniPlayer(true, for: second.id)
        store.restoreInline()
        try expect(!store.isMiniPlayer && store.restoreRequest != nil, "restore retains decoder selection")
        try expect(store.current?.id == second.id, "restore keeps session identity")

        // Changing the origin connection must also cancel a not-yet-started item.
        store.present(third)
        let cancellation = try await waitForRequest(store)
        store.cancelSession(third.id)
        store.didClose(second.id, request: cancellation, success: true)
        try expect(store.current == nil, "invalidated pending origin never starts")
        store.presentMirakurun(second)
        store.cancelSession(first.id)
        try expect(store.closeRequest == nil, "unrelated connection does not stop playback")
        store.cancelSession(second.id)
        let cancelCurrent = try await waitForRequest(store)
        store.didClose(second.id, request: cancelCurrent, success: true)
        try expect(store.current == nil, "current origin can be cancelled")

        // All backend handoff waiters share one request and complete after its ack.
        store.present(first)
        let waiter1 = Task { @MainActor in await store.stopForAnotherPlayer() }
        let wait1 = try await waitForRequest(store)
        let waiter2 = Task { @MainActor in await store.stopForAnotherPlayer() }
        for _ in 0..<20 { await Task.yield() }
        try expect(store.closeRequest == wait1, "parallel waiters coalesce")
        store.didClose(first.id, request: wait1, success: true)
        let stopped1 = await waiter1.value, stopped2 = await waiter2.value
        try expect(stopped1 && stopped2 && store.current == nil, "all waiters observe successful empty host")

        // A newer root selection takes precedence over a legacy modal handoff.
        store.present(first)
        let displacedWaiter = Task { @MainActor in await store.stopForAnotherPlayer() }
        let displacedRequest = try await waitForRequest(store)
        store.presentMirakurun(second)
        store.didClose(first.id, request: displacedRequest, success: true)
        let displacedResult = await displacedWaiter.value
        try expect(!displacedResult && store.current?.id == second.id, "handoff cannot create decoder over queued root session")

        let failedWaiter = Task { @MainActor in await store.stopForAnotherPlayer() }
        let failedRequest = try await waitForRequest(store)
        store.didClose(second.id, request: failedRequest, success: false)
        let failedResult = await failedWaiter.value
        try expect(!failedResult && store.current?.id == second.id, "native stop failure denies successor")

        let cancelledWaiter = Task { @MainActor in await store.stopForAnotherPlayer() }
        let cancelledRequest = try await waitForRequest(store)
        cancelledWaiter.cancel()
        let cancelledResult = await cancelledWaiter.value
        try expect(!cancelledResult, "cancelled handoff returns without leaked continuation")
        store.didClose(second.id, request: cancelledRequest, success: true)
        try expect(store.current == nil, "stop remains valid after a waiter cancels")
        print("PASS: \(checks) playback presentation checks")
    }
}
