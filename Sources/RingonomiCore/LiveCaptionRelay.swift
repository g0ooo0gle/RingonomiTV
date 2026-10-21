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

/// A loopback MPEG-TS relay that parses captions from the exact chunks sent to
/// the player.  It has one upstream connection per player GET, so caption and
/// video timestamps cannot drift because of separate reads.
public actor LiveCaptionRelay {
    public private(set) var lastFailure: HTTPMediaRelayFailure?

    private let client: RingonomiClient
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

    public init(client: RingonomiClient,
                onBatch: @escaping @Sendable (LiveCaptionBatch) async -> Void) {
        self.client = client
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
        case .failed, .cancelled:
            lastFailure = .connection
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
        connection.start(queue: queue)
        let client = client
        let source = source
        let callback = onBatch
        let streamID = relayStreamID
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let failure = await Self.serve(connection, origin: origin, routePath: routePath,
                                            source: source, client: client, streamID: streamID,
                                            onBatch: callback,
                                            acquireGET: { [weak self] in await self?.acquireGET(id) ?? false })
            try? await Self.finish(connection)
            connection.cancel()
            await self?.releaseGET(id)
            await self?.finished(id, failure: failure)
        }
        connections[id] = (connection, task)
    }

    private func finished(_ id: UUID, failure: HTTPMediaRelayFailure?) {
        connections.removeValue(forKey: id)
        if !stopped, let failure { lastFailure = failure }
    }

    private func acquireGET(_ id: UUID) -> Bool {
        guard activeGET == nil else { return false }
        activeGET = id
        return true
    }

    private func releaseGET(_ id: UUID) {
        if activeGET == id { activeGET = nil }
    }

    private static func serve(_ connection: NWConnection, origin: URL, routePath: String,
                              source: URL?, client: RingonomiClient, streamID: UUID,
                              onBatch: @escaping @Sendable (LiveCaptionBatch) async -> Void,
                              acquireGET: @escaping @Sendable () async -> Bool)
        async -> HTTPMediaRelayFailure? {
        var sentHeaders = false
        do {
            let header = try await readHeader(from: connection)
            let request = try HTTPMediaRelayRequest(header: header, origin: origin)
            guard request.url.path(percentEncoded: true) == routePath else {
                throw HLSRelayError.invalidRoute
            }
            guard let source else { throw HLSRelayError.stopped }
            if request.isHead {
                try await send(responseHeader(status: 200, fields: [
                    "Content-Type": "video/mp2t",
                    "Accept-Ranges": "bytes"
                ]), to: connection)
                return nil
            }
            guard await acquireGET() else {
                try await send(responseHeader(status: 503, fields: ["Content-Length": "0"]), to: connection)
                return nil
            }
            if let range = request.range,
               range.start != 0 || range.end != nil {
                try await send(responseHeader(status: 416, fields: [
                    "Content-Length": "0",
                    "Content-Range": "bytes */*"
                ]), to: connection)
                return nil
            }

            var upstream = URLRequest(url: source)
            upstream.httpMethod = "GET"
            upstream.timeoutInterval = 30
            upstream.setValue("video/mp2t", forHTTPHeaderField: "Accept")
            upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            upstream.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if request.range != nil { upstream.setValue("bytes=0-", forHTTPHeaderField: "Range") }
            let (stream, response) = try await client.backendBytes(for: upstream)
            defer { stream.cancel() }
            guard let http = response as? HTTPURLResponse else { throw HTTPMediaRelayFailure.connection }
            guard http.statusCode == 200 || (request.range != nil && http.statusCode == 206) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw HTTPMediaRelayFailure.authenticationRequired
                }
                throw HTTPMediaRelayFailure.connection
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            let mime = http.mimeType?.lowercased()
            guard contentType?.split(separator: ";", maxSplits: 1).first.map(String.init) == "video/mp2t"
                    || mime == "video/mp2t" else {
                throw HTTPMediaRelayFailure.connection
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard encoding == nil || encoding == "identity" else { throw HTTPMediaRelayFailure.connection }
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

                for await chunk in captionStream {
                    guard !Task.isCancelled, !captionState.isLost else { break }
                    let captions = parser.append(chunk)
                    guard !Task.isCancelled, !captionState.isLost else { break }

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

            var iterator = stream.makeAsyncIterator()
            while let chunk = try await iterator.nextChunk(maximumBytes: 32 * 1024) {
                try Task.checkCancellation()
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
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch let failure as HTTPMediaRelayFailure {
            if !sentHeaders {
                try? await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
            }
            return failure
        } catch let error as HTTPBasicTransportError {
            if !sentHeaders {
                try? await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
            }
            return error == .authenticationRequired ? .authenticationRequired : .connection
        } catch let error as ConnectionError {
            if !sentHeaders {
                try? await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
            }
            return error == .http(401) || error == .http(403) ? .authenticationRequired : .connection
        } catch {
            if !sentHeaders {
                try? await send(responseHeader(status: 502, fields: ["Content-Length": "0"]), to: connection)
            }
            return .connection
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
                    if error != nil { continuation.resume(throwing: HLSRelayError.invalidRoute) }
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
                    if error != nil { continuation.resume(throwing: HLSRelayError.invalidRoute) }
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
                    if error != nil { continuation.resume(throwing: HLSRelayError.invalidRoute) }
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
