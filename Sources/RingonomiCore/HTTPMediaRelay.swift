import Foundation
@preconcurrency import Network

public enum HTTPMediaRelayFailure: Error, LocalizedError, Equatable, Sendable {
    case authenticationRequired
    case unsupportedPlaylist
    case connection

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "接続先の認証情報を確認してから再試行してください。"
        case .unsupportedPlaylist: return "このプレイリストの形式には認証付き再生が対応していません。"
        case .connection: return "再生用の接続に失敗しました。接続先を確認して再試行してください。"
        }
    }
}

/// One playback generation's loopback-only HTTP endpoint. Players receive
/// opaque local URLs; only the scoped upstream transport sees credentials.
public actor HTTPMediaRelay {
    public private(set) var lastFailure: HTTPMediaRelayFailure?
    private let scope: HTTPBasicAuthenticationScope
    private let transport: HTTPBasicTransport
    private let queue = DispatchQueue(label: "app.ringonomitv.media-relay")
    private var listener: NWListener?
    private var routes: HTTPMediaRelayRoutes?
    private var pendingSource: HLSRelayReference?
    private var startup: CheckedContinuation<URL, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var stopped = false
    private var connections: [UUID: (NWConnection, Task<Void, Never>)] = [:]

    public init(scope: HTTPBasicAuthenticationScope, credential: HTTPBasicCredential,
                sessionConfiguration: URLSessionConfiguration? = nil) throws {
        self.scope = scope
        transport = try HTTPBasicTransport(scope: scope, credential: credential,
                                           sessionConfiguration: sessionConfiguration)
    }

    deinit {
        listener?.cancel()
        startupTimeout?.cancel()
        transport.invalidate()
        routes?.invalidate()
        for (connection, task) in connections.values { task.cancel(); connection.cancel() }
    }

    public func start(source: URL, kind: HTTPMediaResourceKind) async throws -> URL {
        guard !stopped, listener == nil else { throw HLSRelayError.stopped }
        guard scope.contains(source) else { throw HTTPBasicAuthenticationError.outsideScope }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw HTTPMediaRelayFailure.connection }
        self.listener = listener
        pendingSource = HLSRelayReference(url: source, kind: kind)
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.listenerChanged(state) } }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                startupTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.stop()
                }
                listener.start(queue: queue)
            }
        } onCancel: { Task { await self.stop() } }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        startupTimeout?.cancel(); startupTimeout = nil
        startup?.resume(throwing: HLSRelayError.stopped); startup = nil
        pendingSource = nil
        listener?.cancel(); listener = nil
        routes?.invalidate(); routes = nil
        transport.invalidate()
        for (connection, task) in connections.values { task.cancel(); connection.cancel() }
        connections.removeAll()
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard startup != nil else { return }
            guard let port = listener?.port, let source = pendingSource,
                  let origin = URL(string: "http://127.0.0.1:\(port.rawValue)") else { stop(); return }
            do {
                let routes = try HTTPMediaRelayRoutes(loopbackOrigin: origin, scope: scope)
                self.routes = routes
                let url = try routes.localURL(for: source.url, kind: source.kind)
                startupTimeout?.cancel(); startupTimeout = nil
                pendingSource = nil
                startup?.resume(returning: url); startup = nil
            } catch { stop() }
        case .failed, .cancelled: stop()
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, let routes, connections.count < 12 else { connection.cancel(); return }
        let id = UUID()
        connection.start(queue: queue)
        let transport = transport
        let scope = scope
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let failure = await Self.serve(connection, routes: routes, scope: scope, transport: transport)
            try? await Self.finish(connection)
            connection.cancel()
            await self?.finished(id, failure: failure)
        }
        connections[id] = (connection, task)
    }

    private func finished(_ id: UUID, failure: HTTPMediaRelayFailure?) {
        connections.removeValue(forKey: id)
        if !stopped, let failure { lastFailure = failure }
    }

    private static func serve(_ connection: NWConnection, routes: HTTPMediaRelayRoutes,
                              scope: HTTPBasicAuthenticationScope, transport: HTTPBasicTransport) async -> HTTPMediaRelayFailure? {
        var sentHeaders = false
        do {
            let header = try await header(from: connection)
            let request = try HTTPMediaRelayRequest(header: header, origin: routes.baseURL)
            let resource = try routes.resolve(request.url)
            var upstream = URLRequest(url: resource.url)
            upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if resource.kind == .playlist {
                if request.isHead {
                    // Content-Length may be omitted from HEAD when it is only
                    // known after generating the body. Avoid a blocking reload.
                    try await send(responseHeader(status: 200, fields: ["Content-Type": "application/vnd.apple.mpegurl", "Accept-Ranges": "bytes"]), to: connection)
                    return nil
                }
                // Rewriting changes byte offsets, so ranges apply to the
                // rewritten body rather than the upstream playlist bytes.
                let (data, response) = try await transport.data(for: upstream)
                guard response.statusCode == 200 else { throw HLSRelayError.invalidPlaylist }
                let playlist = try HLSRelayPlaylist(data: data, sourceURL: resource.url, scope: scope)
                let rewritten = try playlist.rewritten(using: routes)
                let selected: Range<Int>
                do { selected = try request.range?.indices(in: rewritten.count) ?? (0..<rewritten.count) }
                catch {
                    try await send(responseHeader(status: 416, fields: ["Content-Length": "0", "Content-Range": "bytes */\(rewritten.count)"]), to: connection)
                    return nil
                }
                var fields = ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": String(selected.count), "Accept-Ranges": "bytes"]
                if request.range != nil { fields["Content-Range"] = "bytes \(selected.lowerBound)-\(selected.upperBound - 1)/\(rewritten.count)" }
                try await send(responseHeader(status: request.range == nil ? 200 : 206, fields: fields), to: connection)
                sentHeaders = true
                if !request.isHead { try await send(Data(rewritten[selected]), to: connection) }
            } else {
                upstream.httpMethod = request.isHead ? "HEAD" : "GET"
                if let range = request.range { upstream.setValue(range.headerValue, forHTTPHeaderField: "Range") }
                let stream = try await transport.bytes(for: upstream)
                defer { stream.cancel() }
                let response = stream.response
                let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
                guard !["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(mime) else {
                    throw HLSRelayError.unsupportedPlaylist
                }
                let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
                guard encoding == nil || encoding == "identity" else { throw HLSRelayError.unsupportedPlaylist }
                var fields = ["Content-Type": safeHeader(mime) ? mime : "application/octet-stream"]
                let length = response.expectedContentLength
                if length >= 0 { fields["Content-Length"] = String(length) }
                if let range = request.range, response.statusCode != 206 {
                    // Live servers may ignore an initial bytes=0- probe. A
                    // nonzero seek must never turn into a full-file download.
                    guard response.statusCode == 200, range.start == 0, range.end == nil else {
                        throw HTTPBasicTransportError.httpStatus(416)
                    }
                } else if response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes" {
                    fields["Accept-Ranges"] = "bytes"
                }
                if response.statusCode == 206 {
                    guard request.range != nil, let range = response.value(forHTTPHeaderField: "Content-Range"),
                          validContentRange(range, requested: request.range!, length: length) else { throw HLSRelayError.invalidRoute }
                    fields["Content-Range"] = range
                }
                var iterator = stream.makeAsyncIterator()
                var buffer = Data()
                if !request.isHead {
                    while buffer.count < 10, let byte = try await iterator.next() { buffer.append(byte) }
                    let marker = Data("#EXTM3U".utf8)
                    guard !buffer.starts(with: marker),
                          !buffer.starts(with: Data([0xEF, 0xBB, 0xBF]) + marker) else {
                        throw HLSRelayError.unsupportedPlaylist
                    }
                }
                try await send(responseHeader(status: response.statusCode, fields: fields), to: connection)
                sentHeaders = true
                if !request.isHead {
                    var count: Int64 = Int64(buffer.count)
                    while let chunk = try await iterator.nextChunk() {
                        count += Int64(chunk.count)
                        guard length < 0 || count <= length else { throw HTTPBasicTransportError.invalidResponse }
                        if !buffer.isEmpty {
                            buffer.append(chunk)
                            try await send(buffer, to: connection)
                            buffer.removeAll(keepingCapacity: false)
                        } else { try await send(chunk, to: connection) }
                    }
                    guard length < 0 || count == length else { throw HTTPBasicTransportError.invalidResponse }
                    if !buffer.isEmpty { try await send(buffer, to: connection) }
                }
            }
            return nil
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? HLSRelayError) == .stopped { return nil }
            let status: Int
            if let transportError = error as? HTTPBasicTransportError,
               case .httpStatus(let code) = transportError, code == 404 || code == 416 { status = code }
            else { status = 502 }
            if !sentHeaders { try? await send(responseHeader(status: status, fields: ["Content-Length": "0"]), to: connection) }
            if (error as? HTTPBasicTransportError) == .authenticationRequired { return .authenticationRequired }
            if (error as? HLSRelayError) == .unsupportedPlaylist { return .unsupportedPlaylist }
            return .connection
        }
    }

    private static func header(from connection: NWConnection) async throws -> Data {
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
            group.addTask { try await Task.sleep(for: .seconds(5)); connection.cancel(); throw HLSRelayError.invalidRoute }
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
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 416: "Range Not Satisfiable"][status] ?? "Bad Gateway"
        var lines = ["HTTP/1.1 \(status) \(reason)", "Connection: close", "Cache-Control: no-store"]
        for key in fields.keys.sorted() { if safeHeader(fields[key]!) { lines.append(key + ": " + fields[key]!) } }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private static func safeHeader(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 && value.utf8.allSatisfy({ (0x20...0x7E).contains($0) })
    }

    private static func validContentRange(_ value: String, requested: HTTPMediaByteRange, length: Int64) -> Bool {
        guard value.hasPrefix("bytes "), safeHeader(value) else { return false }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let range = try? HTTPMediaByteRange("bytes=" + parts[0]),
              let start = range.start, let end = range.end, end >= start, end - start < Int64.max else { return false }
        let total: Int64?
        if parts[1] == "*" { total = nil }
        else {
            guard let value = Int64(parts[1]), value > end else { return false }
            total = value
        }
        if let requestedStart = requested.start {
            guard start == requestedStart else { return false }
            if let requestedEnd = requested.end {
                guard end == min(requestedEnd, total.map { $0 - 1 } ?? requestedEnd) else { return false }
            } else if let total, end != total - 1 { return false }
        } else {
            guard let total, let suffix = requested.end,
                  start == max(0, total - suffix), end == total - 1 else { return false }
        }
        return length < 0 || end - start + 1 == length
    }
}
