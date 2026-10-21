import Foundation

internal protocol PlaybackMediaRelaying: Sendable {
    func start(source: URL, kind: HTTPMediaResourceKind) async throws -> URL
    func stop() async
    var lastFailure: HTTPMediaRelayFailure? { get async }
}

extension HTTPMediaRelay: PlaybackMediaRelaying {}

/// One decoder owns one connection. A replacement waits for the previous
/// relay to stop, and an older completion cannot replace the current URL.
@MainActor
public final class PlaybackMediaConnection: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let makeRelay: @Sendable () throws -> (any PlaybackMediaRelaying)?
    private var liveClient: RingonomiClient?
    private var captionSink: (@MainActor @Sendable (LiveCaptionBatch) -> Void)?
    private let failurePollInterval: Duration
    private var generation = UUID()
    private var relay: (any PlaybackMediaRelaying)?
    private var retirement: Task<Void, Never>?
    private var monitor: Task<Void, Never>?

    public convenience init(client: RingonomiClient) {
        self.init(makeRelay: { try client.makeAuthenticatedMediaRelay() })
    }

    /// Live TS bytes are inspected before the same bytes reach the decoder.
    public convenience init(liveClient: RingonomiClient,
                            onCaptionBatch: @escaping @MainActor @Sendable (LiveCaptionBatch) -> Void) {
        self.init(makeRelay: { nil })
        self.liveClient = liveClient
        captionSink = onCaptionBatch
    }

    internal init(makeRelay: @escaping @Sendable () throws -> (any PlaybackMediaRelaying)?,
                  failurePollInterval: Duration = .milliseconds(250)) {
        self.makeRelay = makeRelay
        self.failurePollInterval = failurePollInterval
    }

    deinit {
        monitor?.cancel()
        let previous = retirement
        let relay = relay
        Task { await previous?.value; await relay?.stop() }
    }

    public func resolve(source: URL, kind: HTTPMediaResourceKind,
                        onFailure: @escaping @MainActor @Sendable (HTTPMediaRelayFailure) -> Void) async throws -> URL {
        invalidate()
        let expected = generation
        await retirement?.value
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        let candidate: (any PlaybackMediaRelaying)?
        if let liveClient {
            candidate = LiveCaptionRelay(client: liveClient) { [weak self] batch in
                guard !Task.isCancelled else { return }
                await self?.receive(batch, generation: expected)
            }
        } else {
            candidate = try makeRelay()
        }
        guard let relay = candidate else { return source }
        self.relay = relay
        return try await withTaskCancellationHandler {
            do {
                let local = try await relay.start(source: source, kind: kind)
                try Task.checkCancellation()
                guard generation == expected else { throw CancellationError() }
                monitor = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: self?.failurePollInterval ?? .milliseconds(250)) }
                        catch { return }
                        guard let self, self.generation == expected else { return }
                        let failure = await relay.lastFailure
                        guard self.generation == expected, !Task.isCancelled else { return }
                        // Players may recover a missed segment or a transient
                        // transport error. Only nonrecoverable relay policy
                        // errors replace the decoder's existing error handling.
                        if failure == .authenticationRequired || failure == .unsupportedPlaylist {
                            onFailure(failure!)
                            return
                        }
                    }
                }
                return local
            } catch {
                await relay.stop()
                if generation == expected { self.relay = nil }
                if Task.isCancelled || generation != expected { throw CancellationError() }
                // Listener failure/timeout also ends a relay. It is a real
                // startup failure unless this caller retired the generation.
                if (error as? HLSRelayError) == .stopped { throw HTTPMediaRelayFailure.connection }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.invalidate(ifCurrent: expected) }
        }
    }

    /// Synchronously retires the generation before scheduling network cleanup.
    /// The decoder can call this from stop, quality, and lifecycle callbacks.
    public func invalidate() {
        generation = UUID()
        monitor?.cancel(); monitor = nil
        if let relay {
            self.relay = nil
            let previous = retirement
            retirement = Task { await previous?.value; await relay.stop() }
        }
    }

    public func stop() async {
        invalidate()
        await retirement?.value
    }

    private func receive(_ batch: LiveCaptionBatch, generation expected: UUID) {
        guard generation == expected, !Task.isCancelled else { return }
        captionSink?(batch)
    }

    private func invalidate(ifCurrent expected: UUID) {
        guard generation == expected else { return }
        invalidate()
    }

    nonisolated public var description: String { "PlaybackMediaConnection(<redacted>)" }
    nonisolated public var debugDescription: String { description }
    nonisolated public var customMirror: Mirror { Mirror(self, unlabeledChildren: ["<redacted>"]) }
}
