import Foundation
@preconcurrency import Network

public struct LiveCaptionBatch: Sendable {
    public let streamID: UUID
    public let captions: [MPEGTSARIBCaption]
    public let firstVideoTicks: Int64?
    public let firstClockTicks: Int64?
    public let currentClockTicks: Int64?
    public let discontinuitySequence: UInt64
    /// False means that the bounded caption queue overflowed and the
    /// consumer deliberately discarded queued bytes.  The video relay keeps
    /// running, but callers must clear any captions until a new generation is
    /// attached.
    public let isSynchronized: Bool

    public init(streamID: UUID, captions: [MPEGTSARIBCaption], firstVideoTicks: Int64?,
                firstClockTicks: Int64?, currentClockTicks: Int64?, discontinuitySequence: UInt64,
                isSynchronized: Bool = true) {
        self.streamID = streamID
        self.captions = captions
        self.firstVideoTicks = firstVideoTicks
        self.firstClockTicks = firstClockTicks
        self.currentClockTicks = currentClockTicks
        self.discontinuitySequence = discontinuitySequence
        self.isSynchronized = isSynchronized
    }
}

/// Small lock-protected state shared by the video producer and caption
/// consumer.  It intentionally contains no stream data, so the lock is held
/// only for flag transitions and never across an await.
private final class LiveCaptionStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var lost = false
    private var lossNotificationDelivered = false

    func markLost() {
        lock.lock()
        lost = true
        lock.unlock()
    }

    var isLost: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lost
    }

    func takeLossNotification() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lost, !lossNotificationDelivered else { return false }
        lossNotificationDelivered = true
        return true
    }
}

/// Errors caused by the loopback client or its request must never be
/// reported as an upstream media failure. VLC can close a GET while it
/// reconnects or while playback is paused.
private enum LiveCaptionLocalError: Error {
    case disconnected
}

/// Bridges NWConnection's callback-style terminal state to the detached
/// serving task. Without this, a paused/reconnecting VLC client can close its
/// loopback GET while the upstream async body is idle, leaving activeGET held
/// until the next upstream chunk arrives.
private final class LiveCaptionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// A loopback MPEG-TS relay that parses captions from the exact chunks sent to
/// the player.  It has one upstream connection per player GET, so caption and
/// video timestamps cannot drift because of separate reads.
public actor LiveCaptionRelay {
    public private(set) var lastFailure: HTTPMediaRelayFailure?

    /// Unlike an HLS playlist relay, this relay owns one persistent raw TS
    /// request. Losing its upstream is terminal for the current playback
    /// generation; a new decoder GET starts a new attempt.
    nonisolated var failurePolicy: PlaybackMediaFailurePolicy { .connectionIsTerminal }

    private let client: RingonomiClient
    private let session: URLSession
    private let onBatch: @Sendable (LiveCaptionBatch) async -> Void
    private let queue = DispatchQueue(label: "app.ringonomitv.live-caption-relay")
    private var listener: NWListener?
    private var startup: CheckedContinuation<URL, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var routePath: String?
    private var source: URL?
    private var stopped = false
    private var activeGET: UUID?
    private let relayStreamID = UUID()
    private var connections: [UUID: (NWConnection, Task<Void, Never>)] = [:]

#if DEBUG
    private static func debugLog(_ message: String) {
        print("[LiveCaptionRelay] \(message)")
    }

    /// Read only whether a request contains a Range field. The value itself
    /// is deliberately never included in diagnostics.
    private static func debugHeaderContainsField(_ header: Data, name: String) -> Bool {
        guard let text = String(data: header, encoding: .ascii) else { return false }
        return text.components(separatedBy: "\r\n")
            .dropFirst()
            .contains { $0.lowercased().hasPrefix("\(name.lowercased()):") }
    }

    private static func debugSyncCandidateCount(in data: Data) -> Int {
        data.reduce(into: 0) { count, byte in
            if byte == 0x47 { count += 1 }
        }
    }

    private static func debugFailureName(_ failure: HTTPMediaRelayFailure) -> String {
        switch failure {
        case .authenticationRequired: return "authenticationRequired"
        case .unsupportedPlaylist: return "unsupportedPlaylist"
        case .connection: return "connection"
        }
    }
#endif

    public init(client: RingonomiClient, session: URLSession = .shared,
                onBatch: @escaping @Sendable (LiveCaptionBatch) async -> Void) {
        self.client = client
        self.session = session
        self.onBatch = onBatch
    }

    deinit {
        listener?.cancel()
        startupTimeout?.cancel()
        startup?.resume(throwing: HLSRelayError.stopped)
        for (connection, task) in connections.values {
            task.cancel()
            connection.cancel()
        }
    }

    /// Starts a media relay and returns an opaque loopback URL for VLC or
    /// AVPlayer. No credentials are placed in this URL.
    public func start(source: URL) async throws -> URL {
        guard !stopped, listener == nil else { throw HLSRelayError.stopped }
        guard Self.isAllowedLiveSource(source, relativeTo: client.baseURL) else {
            throw HLSRelayError.invalidRoute
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            lastFailure = .connection
            throw HTTPMediaRelayFailure.connection
        }
        self.listener = listener
        self.source = source
        self.lastFailure = nil
        self.routePath = "/live/\(UUID().uuidString.lowercased())/stream.ts"
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                startupTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    await self?.startupTimedOut()
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { await self.stop() }
        }
    }

    /// PlaybackMediaRelaying-compatible entry point. Live transport is a
    /// single raw media resource; playlist relays are intentionally rejected.
    public func start(source: URL, kind: HTTPMediaResourceKind) async throws -> URL {
        guard kind == .media else { throw HLSRelayError.invalidRoute }
        return try await start(source: source)
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        startupTimeout?.cancel()
        startupTimeout = nil
        startup?.resume(throwing: HLSRelayError.stopped)
        startup = nil
        listener?.cancel()
        listener = nil
        source = nil
        routePath = nil
        activeGET = nil
        for (connection, task) in connections.values {
            task.cancel()
            connection.cancel()
        }
        connections.removeAll()
    }

    private func startupTimedOut() {
        guard startup != nil else { return }
        lastFailure = .connection
        stop()
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard startup != nil,
                  let port = listener?.port,
                  let routePath,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(routePath)") else {
                lastFailure = .connection
                stop()
                return
            }
            startupTimeout?.cancel()
            startupTimeout = nil
            startup?.resume(returning: url)
            startup = nil
#if DEBUG
            Self.debugLog("listener ready")
#endif
        case .failed, .cancelled:
            lastFailure = .connection
#if DEBUG
            Self.debugLog("listener unavailable failure=connection")
#endif
            stop()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 2,
              let routePath,
              let port = listener?.port,
              let origin = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
            connection.cancel()
            return
        }
        let id = UUID()
        let taskBox = LiveCaptionTaskBox()
        connection.stateUpdateHandler = { [weak taskBox] state in
            switch state {
            case .failed, .cancelled:
                taskBox?.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        let client = client
        let session = session
        let source = source
        let callback = onBatch
        let streamID = relayStreamID
        let task = Task.detached(priority: .userInitiated) { [weak self, taskBox] in
            let failure = await Self.serve(connection, origin: origin, routePath: routePath,
                                            source: source, client: client, session: session, streamID: streamID,
                                            onBatch: callback, taskBox: taskBox,
                                            acquireGET: { [weak self] in await self?.acquireGET(id) ?? false })
            try? await Self.finish(connection)
            connection.cancel()
            await self?.finished(id, failure: failure)
        }
        connections[id] = (connection, task)
        taskBox.install(task)
    }

    private func finished(_ id: UUID, failure: HTTPMediaRelayFailure?) {
        connections.removeValue(forKey: id)
        // Release the active GET and publish its failure as one actor-isolated
        // operation. If a stale task returns after its lease was superseded
        // or the relay was stopped, it must not clear/report current state.
        guard activeGET == id else { return }
        activeGET = nil
        if !stopped, let failure { lastFailure = failure }
    }

    private func acquireGET(_ id: UUID) -> Bool {
        // A connection accepted just before stop can reach this actor after
        // the listener has been torn down. Do not let that stale task open a
        // new authenticated upstream request during relay retirement.
        guard !stopped, activeGET == nil else { return false }
        activeGET = id
        // A new decoder request is a new attempt. Do not expose a previous
        // request's connection failure to the monitor for this attempt.
        lastFailure = nil
        return true
    }

    private static func serve(_ connection: NWConnection, origin: URL, routePath: String,
                              source: URL?, client: RingonomiClient, session: URLSession, streamID: UUID,
                              onBatch: @escaping @Sendable (LiveCaptionBatch) async -> Void,
                              taskBox: LiveCaptionTaskBox,
                              acquireGET: @escaping @Sendable () async -> Bool)
        async -> HTTPMediaRelayFailure? {
        var sentHeaders = false
#if DEBUG
        var debugSentHeaders = false
        var debugEOF = false
        var debugForwardedBytes = 0
        var debugFailure = "none"
        var debugFirstChunkLogged = false
        defer {
            Self.debugLog("connection end sentHeaders=\(debugSentHeaders) eof=\(debugEOF) forwardedBytes=\(debugForwardedBytes) failure=\(debugFailure)")
        }
#endif
        do {
            let header = try await readHeader(from: connection)
#if DEBUG
            let hasRangeHeader = Self.debugHeaderContainsField(header, name: "range")
#endif
            let request: HTTPMediaRelayRequest
            do {
                request = try HTTPMediaRelayRequest(header: header, origin: origin)
            } catch {
#if DEBUG
                Self.debugLog("request rejected range=\(hasRangeHeader ? "present" : "none")")
#endif
                throw error
            }
            guard request.url.path(percentEncoded: true) == routePath else {
#if DEBUG
                Self.debugLog("request rejected route")
#endif
                throw HLSRelayError.invalidRoute
            }
#if DEBUG
            let method = request.isHead ? "HEAD" : "GET"
            let rangeDecision: String
            if request.isHead {
                rangeDecision = hasRangeHeader ? "ignored" : "none"
            } else if let range = request.range {
                rangeDecision = range.start == 0 && range.end == nil ? "accepted" : "rejected"
            } else {
                rangeDecision = hasRangeHeader ? "rejected" : "none"
            }
            Self.debugLog("request accepted method=\(method) range=\(hasRangeHeader ? "present" : "none") decision=\(rangeDecision)")
#endif
            guard let source else { throw HLSRelayError.stopped }
            if request.isHead {
                try await send(responseHeader(status: 200, fields: [
                    "Content-Type": "video/mp2t",
                    "Accept-Ranges": "bytes"
                ]), to: connection)
#if DEBUG
                debugSentHeaders = true
#endif
                return nil
            }
            guard await acquireGET() else {
                try await send(responseHeader(status: 503, fields: ["Content-Length": "0"]), to: connection)
#if DEBUG
                debugSentHeaders = true
                debugFailure = "busy"
#endif
                return nil
            }
            if let range = request.range,
               range.start != 0 || range.end != nil {
                try await send(responseHeader(status: 416, fields: [
                    "Content-Length": "0",
                    "Content-Range": "bytes */*"
                ]), to: connection)
#if DEBUG
                debugSentHeaders = true
                debugFailure = "rangeRejected"
#endif
                return nil
            }

            // The first receive may have returned bytes after the request
            // terminator. Treat a body or pipelined request as a local client
            // disconnect before opening the authenticated upstream request.
            if Self.hasRequestBytesAfterHeader(header) {
                taskBox.cancel()
                throw LiveCaptionLocalError.disconnected
            }
            try Task.checkCancellation()
            // Register exactly one receive after header/route/range validation
            // and GET leasing. A peer FIN, receive error, or any extra inbound
            // byte cancels this serving task so the upstream iterator is also
            // released. The initial readHeader receive has already completed.
            Self.startPeerMonitor(on: connection, taskBox: taskBox)

            var upstream = URLRequest(url: source)
            upstream.httpMethod = "GET"
            upstream.timeoutInterval = 30
            upstream.setValue("video/mp2t", forHTTPHeaderField: "Accept")
            upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            upstream.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if request.range != nil { upstream.setValue("bytes=0-", forHTTPHeaderField: "Range") }
            let (stream, response) = try await client.backendBytes(for: upstream, using: session)
            defer { stream.cancel() }
            guard let http = response as? HTTPURLResponse else {
#if DEBUG
                debugFailure = "connection"
                Self.debugLog("upstream status=invalid mimeMPEGTS=false encodingAllowed=false")
#endif
                throw HTTPMediaRelayFailure.connection
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            let mime = http.mimeType?.lowercased()
            let mimeIsMPEGTS = contentType?.split(separator: ";", maxSplits: 1).first.map(String.init) == "video/mp2t"
                    || mime == "video/mp2t"
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            let encodingAllowed = encoding == nil || encoding == "identity"
#if DEBUG
            Self.debugLog("upstream status=\(http.statusCode) mimeMPEGTS=\(mimeIsMPEGTS) encodingAllowed=\(encodingAllowed)")
#endif
            guard http.statusCode == 200 || (request.range != nil && http.statusCode == 206) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw HTTPMediaRelayFailure.authenticationRequired
                }
                throw HTTPMediaRelayFailure.connection
            }
            guard mimeIsMPEGTS else {
                throw HTTPMediaRelayFailure.connection
            }
            guard encodingAllowed else { throw HTTPMediaRelayFailure.connection }
            if http.statusCode == 206 {
                guard request.range != nil,
                      let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                      Self.isInitialContentRange(contentRange) else {
                    throw HTTPMediaRelayFailure.connection
                }
            }

            var fields = ["Content-Type": "video/mp2t"]
            if http.statusCode == 206,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               Self.safeHeader(contentRange) {
                fields["Content-Range"] = contentRange
            }
            try await send(responseHeader(status: http.statusCode, fields: fields), to: connection)
            sentHeaders = true
#if DEBUG
            debugSentHeaders = true
#endif

            // Keep caption parsing behind a bounded queue. The producer below
            // must never await a MainActor callback: an unresponsive UI may
            // lose captions, but it must not stall the MPEG-TS decoder.
            let captionState = LiveCaptionStreamState()
            let (captionStream, captionContinuation) = AsyncStream<Data>.makeStream(
                bufferingPolicy: .bufferingOldest(64)
            )
            let captionTask = Task.detached(priority: .userInitiated) {
                var parser = MPEGTSARIBParser()
                var lastNotificationUptime: UInt64?
                var lastPublishedSequence = parser.discontinuitySequence
                var hadClock = false
#if DEBUG
                var loggedTimeline = false
#endif

                for await chunk in captionStream {
                    guard !Task.isCancelled, !captionState.isLost else { break }
                    let captions = parser.append(chunk)
                    guard !Task.isCancelled, !captionState.isLost else { break }
#if DEBUG
                    if !loggedTimeline,
                       (parser.firstClockTicks != nil || parser.firstVideoTicks != nil) {
                        Self.debugLog("parser timeline firstClock=\(parser.firstClockTicks != nil) firstVideoPTS=\(parser.firstVideoTicks != nil)")
                        loggedTimeline = true
                    }
#endif

                    let now = DispatchTime.now().uptimeNanoseconds
                    let firstClockAcquired = !hadClock && parser.firstClockTicks != nil
                    let sequenceChanged = parser.discontinuitySequence != lastPublishedSequence
                    let heartbeat = lastNotificationUptime.map {
                        now &- $0 >= 1_000_000_000
                    } ?? false
                    if firstClockAcquired || !captions.isEmpty || sequenceChanged || heartbeat {
                        let batch = LiveCaptionBatch(
                            streamID: streamID,
                            captions: captions,
                            firstVideoTicks: parser.firstVideoTicks,
                            firstClockTicks: parser.firstClockTicks,
                            currentClockTicks: parser.currentClockTicks,
                            discontinuitySequence: parser.discontinuitySequence
                        )
                        hadClock = parser.firstClockTicks != nil
                        lastPublishedSequence = parser.discontinuitySequence
                        lastNotificationUptime = now
                        await onBatch(batch)
                    }
                }

                if !Task.isCancelled, captionState.takeLossNotification() {
                    let batch = LiveCaptionBatch(
                        streamID: streamID,
                        captions: [],
                        firstVideoTicks: parser.firstVideoTicks,
                        firstClockTicks: parser.firstClockTicks,
                        currentClockTicks: parser.currentClockTicks,
                        discontinuitySequence: parser.discontinuitySequence,
                        isSynchronized: false
                    )
                    await onBatch(batch)
                }
            }
            defer {
                // The owner closes both sides together on EOF, transport
                // failure, and stop. This prevents a queued caption batch from
                // outliving the media connection generation.
                captionContinuation.finish()
                // After an overflow, let the consumer drain its termination
                // path once so it can emit the single unsynchronized status.
                // A cancelled producer (stop/replacement) still cancels it
                // immediately; the generation owner will discard any result.
                if Task.isCancelled || !captionState.isLost {
                    captionTask.cancel()
                }
            }

            // Cancelling the serving task must also cancel URLSession's
            // underlying data task while its next byte is still pending.
            // Waiting for defer alone can leave the GET lease occupied.
            return try await withTaskCancellationHandler {
                var iterator = stream.makeAsyncIterator()
                while let chunk = try await iterator.nextChunk(maximumBytes: 32 * 1024) {
                    try Task.checkCancellation()
    #if DEBUG
                    if !debugFirstChunkLogged {
                        debugFirstChunkLogged = true
                        Self.debugLog("firstChunk size=\(chunk.count) syncCandidates=\(Self.debugSyncCandidateCount(in: chunk))")
                    }
    #endif
                    if case .dropped = captionContinuation.yield(chunk) {
                        // bufferingOldest(64) bounds the queue to at most 2 MiB
                        // chunks. Once a chunk is dropped, queued bytes no longer
                        // form a complete caption timeline; discard them all.
    #if DEBUG
                        print("[LiveCaptionRelay] caption queue overflow; video continues")
    #endif
                        captionState.markLost()
                        captionContinuation.finish()
                    }
                    try Task.checkCancellation()
                    try await send(chunk, to: connection)
    #if DEBUG
                    debugForwardedBytes += chunk.count
    #endif
                }
                // Async iterator nil can mean a clean upstream EOF, but it can
                // also be the cancellation representation of URLSession bytes.
                // Check before classifying it as a terminal upstream failure.
                try Task.checkCancellation()
    #if DEBUG
                debugEOF = true
                debugFailure = "upstreamEOF"
    #endif
                // The live source is expected to remain open. A clean upstream
                // EOF is therefore a terminal connection failure, unlike a
                // loopback client cancellation handled below.
                return .connection
            } onCancel: {
                stream.cancel()
            }
        } catch is CancellationError {
#if DEBUG
            debugFailure = "cancelled"
#endif
            return nil
        } catch is LiveCaptionLocalError {
#if DEBUG
            debugFailure = "localClient"
#endif
            if !sentHeaders {
                try? await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
            }
            return nil
        } catch let error as HLSRelayError where error == .invalidRoute {
#if DEBUG
            debugFailure = "localRequest"
#endif
            // Bad HEAD/Range/routes and malformed loopback requests must not
            // poison the upstream failure state. Preserve the existing 502
            // response contract, but leave the relay available for a new GET.
            if !sentHeaders {
                try? await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
            }
            return nil
        } catch let error as HLSRelayError where error == .stopped {
#if DEBUG
            debugFailure = "stopped"
#endif
            return nil
        } catch let failure as HTTPMediaRelayFailure {
#if DEBUG
            debugFailure = Self.debugFailureName(failure)
#endif
            // The upstream response has already been classified at this
            // point.  A player can close the loopback connection as soon as
            // it receives the 502 headers, which cancels the serving task
            // while that response is being flushed.  Do not lose the
            // upstream failure just because that local cancellation raced
            // with publication; `finished` still suppresses it when the
            // relay itself is stopped.
            if !sentHeaders {
                do {
                    try await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
#if DEBUG
                    debugSentHeaders = true
#endif
                } catch { }
            }
            return failure
        } catch let error as HTTPBasicTransportError {
#if DEBUG
            debugFailure = error == .authenticationRequired ? "authenticationRequired" : "connection"
#endif
            if Task.isCancelled {
#if DEBUG
                debugFailure = "cancelled"
#endif
                return nil
            }
            if !sentHeaders {
                do {
                    try await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
#if DEBUG
                    debugSentHeaders = true
#endif
                } catch { }
            }
            return Task.isCancelled ? nil
                : (error == .authenticationRequired ? .authenticationRequired : .connection)
        } catch let error as ConnectionError {
#if DEBUG
            debugFailure = error == .http(401) || error == .http(403)
                ? "authenticationRequired" : "connection"
#endif
            if Task.isCancelled {
#if DEBUG
                debugFailure = "cancelled"
#endif
                return nil
            }
            if !sentHeaders {
                do {
                    try await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
#if DEBUG
                    debugSentHeaders = true
#endif
                } catch { }
            }
            return Task.isCancelled ? nil
                : (error == .http(401) || error == .http(403) ? .authenticationRequired : .connection)
        } catch {
#if DEBUG
            debugFailure = "connection"
#endif
            // URLSession.AsyncBytes used by the anonymous/Bearer path can
            // surface a task cancellation as URLError.cancelled instead of
            // CancellationError. Task cancellation here is always initiated
            // by the loopback connection or relay stop; an unsolicited
            // upstream error leaves the task uncancelled and remains fatal.
            if Task.isCancelled {
#if DEBUG
                debugFailure = "cancelled"
#endif
                return nil
            }
            if !sentHeaders {
                do {
                    try await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
#if DEBUG
                    debugSentHeaders = true
#endif
                } catch { }
            }
            return Task.isCancelled ? nil : .connection
        }
    }

    private static func isAllowedLiveSource(_ source: URL, relativeTo baseURL: URL) -> Bool {
        guard source.baseURL == nil,
              source.user == nil, source.password == nil,
              source.query == nil, source.fragment == nil,
              BackendURLRules.sameOrigin(source, baseURL) else { return false }
        let path = source.path(percentEncoded: true)
        guard BackendURLRules.isSafePercentEncodedPath(path) else { return false }
        let basePath = BackendURLRules.canonicalBasePath(baseURL.path(percentEncoded: true))
        let prefix = basePath + "api/streams/live/"
        guard path.hasPrefix(prefix) else { return false }
        let suffix = String(path.dropFirst(prefix.count))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              !components[0].isEmpty, !components[1].isEmpty,
              components[2] == "mpegts",
              suffix.utf8.count <= 512 else { return false }
        return true
    }

    private static func isInitialContentRange(_ value: String) -> Bool {
        guard safeHeader(value), value.lowercased().hasPrefix("bytes ") else { return false }
        let fields = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let dash = fields[0].firstIndex(of: "-"),
              fields[0].prefix(upTo: dash) == "0",
              dash < fields[0].index(before: fields[0].endIndex) else { return false }
        let end = fields[0][fields[0].index(after: dash)...]
        guard end.allSatisfy({ $0.isNumber }) else { return false }
        return fields[1] == "*" || fields[1].allSatisfy({ $0.isNumber })
    }

    private static func hasRequestBytesAfterHeader(_ header: Data) -> Bool {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = header.range(of: terminator) else { return false }
        return range.upperBound < header.endIndex
    }

    private static func startPeerMonitor(on connection: NWConnection,
                                         taskBox: LiveCaptionTaskBox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            // There is no valid request data after the initial GET header. A
            // callback therefore means peer EOF/error or body/pipeline bytes.
            // Cancelling only the serving task keeps local disconnects out of
            // the relay's upstream failure state.
            taskBox.cancel()
        }
    }

    private static func readHeader(from connection: NWConnection) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var data = Data()
                while data.count < HTTPMediaRelayRequest.maximumHeaderBytes {
                    let chunk = try await receive(from: connection)
                    guard !chunk.isEmpty else { throw HLSRelayError.invalidRoute }
                    data.append(chunk)
                    if data.range(of: Data("\r\n\r\n".utf8)) != nil { return data }
                }
                throw HLSRelayError.invalidRoute
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { throw CancellationError() }
                connection.cancel()
                throw HLSRelayError.invalidRoute
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw CancellationError() }
            return data
        }
    }

    private static func receive(from connection: NWConnection) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if error != nil { continuation.resume(throwing: LiveCaptionLocalError.disconnected) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
        } onCancel: { connection.cancel() }
    }

    private static func send(_ data: Data, to connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: LiveCaptionLocalError.disconnected) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }

    private static func finish(_ connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: LiveCaptionLocalError.disconnected) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }

    private static func responseHeader(status: Int, fields: [String: String]) -> Data {
        let reason = [200: "OK", 206: "Partial Content", 416: "Range Not Satisfiable", 503: "Service Unavailable"][status] ?? "Bad Gateway"
        var lines = ["HTTP/1.1 \(status) \(reason)", "Connection: close", "Cache-Control: no-store"]
        for key in fields.keys.sorted() {
            guard let value = fields[key], safeHeader(value) else { continue }
            lines.append("\(key): \(value)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private static func safeHeader(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024
            && value.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }
}

extension LiveCaptionRelay: PlaybackMediaRelaying {}
