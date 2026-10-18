import Foundation

/// The small set of events that the live-comment store needs from the
/// receive-only transport.  Comment bodies stay in the typed Core model and
/// are never written to logs by this layer.
public enum LiveCommentTransportEvent: Sendable {
    case ready
    case historyFinished
    case chat(LiveComment)
}

public typealias LiveCommentEventHandler = @Sendable (LiveCommentTransportEvent) async -> Void

public enum LiveCommentTransportStream: Sendable {
    case watch
    case comment
}

/// Failures from the two live-comment sockets.  The associated Core error
/// values let the store apply its retry policy without exposing a URL, token,
/// thread key, or server response body.
public enum LiveCommentTransportError: Error, LocalizedError, Sendable {
    case unavailable
    case watchHandshakeTimedOut
    case commentHandshakeTimedOut
    case idleTimeout(stream: LiveCommentTransportStream)
    case watchError(code: LiveWatchErrorCode)
    case watchDisconnected(reason: LiveDisconnectReason)
    case reconnectRequested(waitTime: Double?)
    case roomChanged
    case commentThreadFailed(resultCode: Int)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "このチャンネルでは実況を利用できません。"
        case .watchHandshakeTimedOut:
            return "実況セッションの開始に時間がかかっています。"
        case .commentHandshakeTimedOut:
            return "実況コメントの開始に時間がかかっています。"
        case .idleTimeout:
            return "実況サーバーからの応答がありません。"
        case .watchError(let code):
            return code.uiMessage
        case .watchDisconnected(let reason):
            return reason.uiMessage
        case .reconnectRequested:
            return "実況セッションを再接続しています。"
        case .roomChanged:
            return "実況ルームが切り替わりました。"
        case .commentThreadFailed:
            return "実況コメントの受信を開始できませんでした。"
        case .connectionClosed:
            return "実況サーバーとの接続が終了しました。"
        }
    }

    /// Whether the caller may create a fresh session for this failure.
    public var canReconnect: Bool {
        switch self {
        case .unavailable, .commentThreadFailed:
            return false
        case .watchError(let code):
            return code.canReconnect
        case .watchDisconnected(let reason):
            return reason.canReconnect
        case .watchHandshakeTimedOut, .commentHandshakeTimedOut, .idleTimeout, .reconnectRequested,
             .roomChanged, .connectionClosed:
            return true
        }
    }

    /// A server-provided reconnect delay, already bounded by Core.
    public var retryAfter: Double? {
        guard case .reconnectRequested(let waitTime) = self else { return nil }
        return waitTime
    }
}

/// Receive-only NX-Jikkyo transport.
///
/// The watch socket is used only for the protocol's required control messages
/// (`startWatching`, `pong`, and `keepSeat`).  The comment socket never sends
/// chat messages; it only sends the initial thread request and receives the
/// server stream.  A fresh instance is cheap and should be used for each
/// channel/session generation.
public struct LiveCommentTransport: Sendable {
    public static let watchHandshakeTimeout: TimeInterval = 15
    /// The comment thread must reach `rf:0` within this initial window.  A
    /// silent comment stream after that point is valid and is kept alive by
    /// the watch socket's control traffic.
    public static let commentHandshakeTimeout: TimeInterval = 15
    public static let receiveIdleTimeout: TimeInterval = 90
    public static let commentPingInterval: TimeInterval = 30
    public static let commentPongTimeout: TimeInterval = 10
    private static let maximumMessageBytes = LiveCommentProtocol.maximumFrameBytes

    public init() {}

    public func run(
        info: JikkyoWebSocketInfo,
        onEvent: @escaping LiveCommentEventHandler
    ) async throws {
        guard let watchURL = info.watchSessionURL,
              let commentURL = info.commentSessionURL else {
            throw LiveCommentTransportError.unavailable
        }

        let resources = SocketResources()
        try await withTaskCancellationHandler(operation: {
            try await runSession(
                watchURL: watchURL,
                commentURL: commentURL,
                resources: resources,
                onEvent: onEvent
            )
        }, onCancel: {
            // URLSessionWebSocketTask.receive() is not guaranteed to stop just
            // because its surrounding Swift Task was cancelled.  Closing the
            // actual sockets makes cancellation observable by both loops.
            resources.cancelAll()
        })
    }

    private func runSession(
        watchURL: URL,
        commentURL: URL,
        resources: SocketResources,
        onEvent: @escaping LiveCommentEventHandler
    ) async throws {
        try Task.checkCancellation()
        let session = Self.makeSession()
        resources.setSession(session)
        defer { resources.cancelAll() }

        let watch = session.webSocketTask(with: watchURL)
        watch.maximumMessageSize = Self.maximumMessageBytes
        resources.setWatch(watch)
        watch.resume()

        let watchSender = WebSocketSender(watch)
        let room = try await startWatchAndWaitForRoom(
            socket: watch,
            sender: watchSender,
            resources: resources
        )
        try Task.checkCancellation()

        // KonomiTV's API supplies the NX-Jikkyo comment endpoint separately.
        // The messageServer URI inside `room` is retained by Core for the
        // thread metadata, but is not used as a second untrusted endpoint.
        let comment = session.webSocketTask(
            with: commentURL,
            protocols: ["msg.nicovideo.jp#json"]
        )
        comment.maximumMessageSize = Self.maximumMessageBytes
        resources.setComment(comment)
        comment.resume()

        let commentSender = WebSocketSender(comment)
        let handshake = try commentHandshakeData(for: room)
        try await sendWithTimeout(
            data: handshake,
            through: commentSender,
            resources: resources,
            timeout: Self.commentHandshakeTimeout,
            timeoutError: .commentHandshakeTimedOut
        )

        try await runSocketPair(
            watch: watch,
            watchSender: watchSender,
            initialThreadID: room.threadID,
            comment: comment,
            resources: resources,
            onEvent: onEvent
        )
    }

    private func startWatchAndWaitForRoom(
        socket: URLSessionWebSocketTask,
        sender: WebSocketSender,
        resources: SocketResources
    ) async throws -> LiveCommentRoom {
        try await withThrowingTaskGroup(of: LiveCommentRoom.self) { group in
            group.addTask {
                let startData = try LiveWatchCommand.startWatching(reconnect: false).encoded()
                try await self.send(data: startData, through: sender)
                return try await self.readRoom(
                    socket: socket,
                    sender: sender,
                    resources: resources
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.watchHandshakeTimeout))
                throw LiveCommentTransportError.watchHandshakeTimedOut
            }

            do {
                guard let room = try await group.next() else {
                    throw LiveCommentTransportError.connectionClosed
                }
                group.cancelAll()
                return room
            } catch {
                group.cancelAll()
                resources.cancelAll()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
    }

    private func readRoom(
        socket: URLSessionWebSocketTask,
        sender: WebSocketSender,
        resources: SocketResources
    ) async throws -> LiveCommentRoom {
        while !Task.isCancelled {
            let data = try await receiveData(from: socket, stream: .watch)
            guard data.count <= Self.maximumMessageBytes else {
                continue
            }
            guard let message = try? LiveWatchMessage(data: data) else {
                // A malformed control frame must not surface its raw payload
                // or take down an otherwise healthy session.
                continue
            }

            switch message {
            case .seat(let interval):
                installSeatKeeper(
                    interval: interval,
                    sender: sender,
                    resources: resources
                )
            case .ping:
                try await send(.pong, through: sender)
            case .room(let room):
                return room
            case .error(let code):
                throw LiveCommentTransportError.watchError(code: code)
            case .reconnect(let waitTime):
                throw LiveCommentTransportError.reconnectRequested(waitTime: waitTime)
            case .disconnect(let reason):
                throw LiveCommentTransportError.watchDisconnected(reason: reason)
            case .unknown:
                continue
            }
        }
        throw CancellationError()
    }

    private func runSocketPair(
        watch: URLSessionWebSocketTask,
        watchSender: WebSocketSender,
        initialThreadID: String,
        comment: URLSessionWebSocketTask,
        resources: SocketResources,
        onEvent: @escaping LiveCommentEventHandler
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer {
                // Do this before waiting for the group to drain: cancelling a
                // Swift Task alone may leave URLSession's receive suspended.
                resources.cancelAll()
                group.cancelAll()
            }

            group.addTask {
                try await self.watchLoop(
                    socket: watch,
                    sender: watchSender,
                    initialThreadID: initialThreadID,
                    resources: resources
                )
            }
            group.addTask {
                try await self.commentLoop(
                    socket: comment,
                    resources: resources,
                    onEvent: onEvent
                )
            }

            group.addTask {
                try await self.monitorCommentConnection(socket: comment, resources: resources)
            }

            do {
                guard let _ = try await group.next() else {
                    throw LiveCommentTransportError.connectionClosed
                }
                if Task.isCancelled { throw CancellationError() }
                throw LiveCommentTransportError.connectionClosed
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
    }

    private func watchLoop(
        socket: URLSessionWebSocketTask,
        sender: WebSocketSender,
        initialThreadID: String,
        resources: SocketResources
    ) async throws {
        while !Task.isCancelled {
            let data = try await receiveDataWithIdleTimeout(
                from: socket,
                stream: .watch,
                resources: resources
            )
            guard data.count <= Self.maximumMessageBytes else {
                continue
            }
            guard let message = try? LiveWatchMessage(data: data) else {
                continue
            }

            switch message {
            case .seat(let interval):
                installSeatKeeper(
                    interval: interval,
                    sender: sender,
                    resources: resources
                )
            case .ping:
                try await send(.pong, through: sender)
            case .room(let room):
                if room.threadID != initialThreadID {
                    throw LiveCommentTransportError.roomChanged
                }
                // NX-Jikkyo can repeat the same room message.  It is not a
                // new comment session and must not trigger a reconnect.
            case .error(let code):
                throw LiveCommentTransportError.watchError(code: code)
            case .reconnect(let waitTime):
                throw LiveCommentTransportError.reconnectRequested(waitTime: waitTime)
            case .disconnect(let reason):
                throw LiveCommentTransportError.watchDisconnected(reason: reason)
            case .unknown:
                continue
            }
        }
        throw CancellationError()
    }

    /// Quiet channels are valid. WebSocket control pings verify the comment
    /// connection independently of comment arrivals and the watch socket.
    private func monitorCommentConnection(
        socket: URLSessionWebSocketTask,
        resources: SocketResources
    ) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(Self.commentPingInterval))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        socket.sendPing { error in
                            if error != nil { continuation.resume(throwing: LiveCommentTransportError.connectionClosed) }
                            else { continuation.resume() }
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(Self.commentPongTimeout))
                    throw LiveCommentTransportError.idleTimeout(stream: .comment)
                }
                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    // Cancelling the socket completes an outstanding ping's
                    // handler, allowing the structured group to drain.
                    resources.cancelAll()
                    group.cancelAll()
                    throw error
                }
            }
        }
        throw CancellationError()
    }

    private func commentLoop(
        socket: URLSessionWebSocketTask,
        resources: SocketResources,
        onEvent: @escaping LiveCommentEventHandler
    ) async throws {
        var historyFinished = false
        var readyEmitted = false
        let historyDeadline = ProcessInfo.processInfo.systemUptime + Self.commentHandshakeTimeout

        while !Task.isCancelled {
            let data: Data
            if historyFinished {
                // A channel with no comments is healthy.  Watch pings and
                // seat messages are the session liveness signal; imposing a
                // comment receive timeout would reconnect quiet channels.
                data = try await receiveData(from: socket, stream: .comment)
            } else {
                let remaining = historyDeadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    resources.cancelAll()
                    throw LiveCommentTransportError.commentHandshakeTimedOut
                }
                data = try await receiveDataWithIdleTimeout(
                    from: socket,
                    stream: .comment,
                    resources: resources,
                    timeout: remaining,
                    timeoutError: .commentHandshakeTimedOut
                )
            }
            guard data.count <= Self.maximumMessageBytes else {
                continue
            }
            guard let message = try? LiveCommentMessage(data: data) else {
                // Invalid JSON, unknown control frames, and malformed chats
                // are isolated to this frame by the Core decoder.
                continue
            }

            switch message {
            case .thread(let resultCode):
                guard resultCode == 0 else {
                    throw LiveCommentTransportError.commentThreadFailed(resultCode: resultCode)
                }
                if !readyEmitted {
                    readyEmitted = true
                    await onEvent(.ready)
                }
            case .historyFinished:
                if !historyFinished {
                    historyFinished = true
                    await onEvent(.historyFinished)
                }
            case .chat(let comment):
                // The initial response can contain history before rf:0.  Live
                // overlay state must begin only after the history terminator.
                guard historyFinished else { continue }
                await onEvent(.chat(comment))
            case .ping, .ignored, .unknown:
                continue
            }
        }
        throw CancellationError()
    }

    private func installSeatKeeper(
        interval: TimeInterval,
        sender: WebSocketSender,
        resources: SocketResources
    ) {
        let task = Task { [resources] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    try Task.checkCancellation()
                    let data = try LiveWatchCommand.keepSeat.encoded()
                    try await sender.send(data)
                }
            } catch is CancellationError {
                return
            } catch {
                // A failed keepSeat is a failed watch session.  Closing both
                // sockets lets the task group report one bounded failure.
                resources.cancelAll()
            }
        }
        resources.replaceSeatTask(task)
    }

    private func send(_ command: LiveWatchCommand, through sender: WebSocketSender) async throws {
        let data: Data
        do {
            data = try command.encoded()
        } catch {
            throw LiveCommentTransportError.connectionClosed
        }
        try await send(data: data, through: sender)
    }

    private func send(data: Data, through sender: WebSocketSender) async throws {
        do {
            try await sender.send(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Keep URLSession's transport error out of the UI and retry log.
            if Task.isCancelled { throw CancellationError() }
            throw LiveCommentTransportError.connectionClosed
        }
    }

    private func sendWithTimeout(
        data: Data,
        through sender: WebSocketSender,
        resources: SocketResources,
        timeout: TimeInterval,
        timeoutError: LiveCommentTransportError
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.send(data: data, through: sender)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw timeoutError
            }

            do {
                guard let _ = try await group.next() else {
                    throw LiveCommentTransportError.connectionClosed
                }
                group.cancelAll()
            } catch {
                resources.cancelAll()
                group.cancelAll()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
    }

    private func receiveData(
        from socket: URLSessionWebSocketTask,
        stream: LiveCommentTransportStream
    ) async throws -> Data {
        do {
            let message = try await socket.receive()
            switch message {
            case .data(let data):
                return data
            case .string(let string):
                return Data(string.utf8)
            @unknown default:
                throw LiveCommentTransportError.connectionClosed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LiveCommentTransportError {
            throw error
        } catch {
            // Do not propagate URLSession's error text; it can include
            // connection details that are not safe for the UI or logs.
            if Task.isCancelled { throw CancellationError() }
            switch stream {
            case .watch, .comment:
                throw LiveCommentTransportError.connectionClosed
            }
        }
    }

    private func receiveDataWithIdleTimeout(
        from socket: URLSessionWebSocketTask,
        stream: LiveCommentTransportStream,
        resources: SocketResources,
        timeout: TimeInterval? = nil,
        timeoutError: LiveCommentTransportError? = nil
    ) async throws -> Data {
        let timeout = timeout ?? Self.receiveIdleTimeout
        let timeoutError = timeoutError ?? .idleTimeout(stream: stream)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.receiveData(from: socket, stream: stream)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw timeoutError
            }

            do {
                guard let data = try await group.next() else {
                    throw LiveCommentTransportError.connectionClosed
                }
                group.cancelAll()
                return data
            } catch {
                // Stop the underlying receive before the group scope waits for
                // the cancelled child.  This is the important distinction
                // from merely calling Task.cancel().
                resources.cancelAll()
                group.cancelAll()
                throw error
            }
        }
    }

    private func commentHandshakeData(for room: LiveCommentRoom) throws -> Data {
        // The Core contract uses res_from=0 so the initial chat frames are
        // drained only until the server's rf:0 terminator.
        return try room.commentHandshakeData(resFrom: 0)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = nil
        // Both WebSocket tasks set `maximumMessageSize` to
        // `maximumMessageBytes` before resume.  The receive-side guard also
        // protects text frames after UTF-8 conversion.  Keep URLSession's
        // request timeout disabled so a quiet comment stream is not closed;
        // watch traffic supplies liveness and has the explicit 90-second
        // receive bound above.
        configuration.timeoutIntervalForRequest = 0
        configuration.timeoutIntervalForResource = 0
        return URLSession(configuration: configuration)
    }
}

private actor WebSocketSender {
    private let socket: URLSessionWebSocketTask

    init(_ socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    func send(_ data: Data) async throws {
        // NX-Jikkyo's protocol frames are JSON text frames.  Sending the
        // encoded bytes as a binary WebSocket frame is not accepted by every
        // compatible server, even though the payload itself is valid JSON.
        guard let text = String(data: data, encoding: .utf8) else {
            throw LiveCommentTransportError.connectionClosed
        }
        try await socket.send(.string(text))
    }
}

private final class SocketResources: @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var watch: URLSessionWebSocketTask?
    private var comment: URLSessionWebSocketTask?
    private var seatTask: Task<Void, Never>?
    private var cancelled = false

    func setSession(_ value: URLSession) {
        lock.lock()
        let install = !cancelled
        if install { session = value }
        lock.unlock()
        if !install { value.invalidateAndCancel() }
    }

    func setWatch(_ value: URLSessionWebSocketTask) {
        lock.lock()
        let install = !cancelled
        if install { watch = value }
        lock.unlock()
        if !install { value.cancel(with: .goingAway, reason: nil) }
    }

    func setComment(_ value: URLSessionWebSocketTask) {
        lock.lock()
        let install = !cancelled
        if install { comment = value }
        lock.unlock()
        if !install { value.cancel(with: .goingAway, reason: nil) }
    }

    func replaceSeatTask(_ value: Task<Void, Never>) {
        lock.lock()
        let previous = seatTask
        if cancelled {
            seatTask = nil
        } else {
            seatTask = value
        }
        let shouldCancel = cancelled
        lock.unlock()
        previous?.cancel()
        if shouldCancel { value.cancel() }
    }

    func cancelAll() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let currentSession = session
        let currentWatch = watch
        let currentComment = comment
        let currentSeat = seatTask
        session = nil
        watch = nil
        comment = nil
        seatTask = nil
        lock.unlock()

        currentSeat?.cancel()
        currentWatch?.cancel(with: .goingAway, reason: nil)
        currentComment?.cancel(with: .goingAway, reason: nil)
        currentSession?.invalidateAndCancel()
    }
}
