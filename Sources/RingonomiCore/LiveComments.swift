import Foundation

/// Errors raised while decoding or constructing the receive-only live-comment
/// protocol.  Error descriptions intentionally never include server URLs,
/// comment bodies, thread keys, or reconnect tokens.
public enum LiveCommentError: Error, LocalizedError, Equatable, Sendable {
    case invalidJSON
    case jsonTooDeep
    case frameTooLarge
    case invalidMessage
    case invalidWebSocketURL
    case invalidRoom
    case invalidThread
    case invalidHistoryRequest
    case invalidInterval
    case invalidRetryWait
    case invalidChat
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "実況サーバーのメッセージを読み取れません。"
        case .jsonTooDeep: return "実況サーバーのメッセージ構造が深すぎます。"
        case .frameTooLarge: return "実況サーバーのメッセージが大きすぎます。"
        case .invalidMessage: return "実況サーバーのメッセージ形式が不正です。"
        case .invalidWebSocketURL: return "実況サーバーの接続先が不正です。"
        case .invalidRoom: return "実況ルーム情報が不正です。"
        case .invalidThread: return "実況スレッド情報が不正です。"
        case .invalidHistoryRequest: return "実況履歴の取得範囲が不正です。"
        case .invalidInterval: return "実況セッションの維持間隔が不正です。"
        case .invalidRetryWait: return "実況の再接続待ち時間が不正です。"
        case .invalidChat: return "実況コメントの形式が不正です。"
        case .encodingFailed: return "実況サーバーへの要求を作成できません。"
        }
    }
}

/// Bounds shared by both NX-Jikkyo WebSocket streams.
public enum LiveCommentProtocol {
    public static let maximumFrameBytes = 64 * 1024
    public static let maximumJSONDepth = 16
    public static let maximumURLBytes = 4 * 1024
    public static let maximumThreadIdentifierLength = 1_024
    public static let maximumThreadKeyLength = 2_048
    public static let maximumControlCodeLength = 128
    public static let maximumKeepSeatInterval = 600.0
    public static let minimumKeepSeatInterval = 1.0
    public static let maximumRetryWait = 300.0
    public static let maximumHistoryRequest = 1_000
    public static let maximumServerTime = 10_000_000_000.0
}

/// WebSocket URLs returned by KonomiTV's `/api/channels/{id}/jikkyo` API.
/// The endpoint may return null for a channel without実況 support.
public struct JikkyoWebSocketInfo: Decodable, Equatable, Sendable {
    public let watchSessionURL: URL?
    public let nicoliveWatchSessionURL: URL?
    public let nicoliveWatchSessionError: String?
    public let commentSessionURL: URL?
    public let isNXJikkyoExclusive: Bool

    private enum CodingKeys: String, CodingKey {
        case watchSessionURL = "watch_session_url"
        case nicoliveWatchSessionURL = "nicolive_watch_session_url"
        case nicoliveWatchSessionError = "nicolive_watch_session_error"
        case commentSessionURL = "comment_session_url"
        case isNXJikkyoExclusive = "is_nxjikkyo_exclusive"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.watchSessionURL),
              container.contains(.commentSessionURL),
              container.contains(.isNXJikkyoExclusive) else {
            throw LiveCommentError.invalidMessage
        }

        let watchRaw = try Self.requiredNullableString(container, key: .watchSessionURL)
        let commentRaw = try Self.requiredNullableString(container, key: .commentSessionURL)
        let nicoliveRaw = try Self.optionalString(container, key: .nicoliveWatchSessionURL)
        let errorRaw = try Self.optionalString(container, key: .nicoliveWatchSessionError)

        watchSessionURL = try validatedWebSocketURL(watchRaw)
        commentSessionURL = try validatedWebSocketURL(commentRaw)
        nicoliveWatchSessionURL = try validatedWebSocketURL(nicoliveRaw)
        nicoliveWatchSessionError = Self.normalizedDetail(errorRaw)
        do {
            isNXJikkyoExclusive = try container.decode(Bool.self, forKey: .isNXJikkyoExclusive)
        } catch {
            throw LiveCommentError.invalidMessage
        }
    }

    private static func requiredNullableString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> String? {
        do {
            return try container.decode(String?.self, forKey: key)
        } catch {
            throw LiveCommentError.invalidMessage
        }
    }

    private static func optionalString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        do {
            return try container.decode(String?.self, forKey: key)
        } catch {
            throw LiveCommentError.invalidMessage
        }
    }

    private static func normalizedDetail(_ value: String?) -> String? {
        guard let value else { return nil }
        var result = String()
        result.reserveCapacity(min(value.count, 4_096))
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                pendingSpace = true
                continue
            }
            if pendingSpace, !result.isEmpty { result.append(" ") }
            let scalarText = String(scalar)
            guard result.utf8.count + scalarText.utf8.count <= 4_096 else { break }
            result.append(contentsOf: scalarText)
            pendingSpace = false
        }
        return result.isEmpty ? nil : result
    }
}

/// A watch-session error code mapped to a finite UI-safe set.
public enum LiveWatchErrorCode: String, Equatable, Sendable {
    case connectError = "CONNECT_ERROR"
    case contentNotReady = "CONTENT_NOT_READY"
    case noThreadAvailable = "NO_THREAD_AVAILABLE"
    case noRoomAvailable = "NO_ROOM_AVAILABLE"
    case noPermission = "NO_PERMISSION"
    case notOnAir = "NOT_ON_AIR"
    case broadcastNotFound = "BROADCAST_NOT_FOUND"
    case internalServerError = "INTERNAL_SERVERERROR"
    case serviceTemporarilyUnavailable = "SERVICE_TEMPORARILY_UNAVAILABLE"
    case unknown

    fileprivate init(serverValue: String) {
        self = Self(rawValue: serverValue) ?? .unknown
    }

    public var canReconnect: Bool {
        switch self {
        case .connectError, .contentNotReady, .internalServerError, .serviceTemporarilyUnavailable:
            return true
        case .noThreadAvailable, .noRoomAvailable, .noPermission, .notOnAir, .broadcastNotFound, .unknown:
            return false
        }
    }

    public var uiMessage: String {
        switch self {
        case .connectError: return "実況サーバーに接続できません。"
        case .contentNotReady: return "実況を配信できる状態ではありません。"
        case .noThreadAvailable: return "実況スレッドを取得できません。"
        case .noRoomAvailable: return "実況ルームを取得できません。"
        case .noPermission: return "実況サーバーへのアクセス権限がありません。"
        case .notOnAir: return "現在、実況対象の番組は放送中ではありません。"
        case .broadcastNotFound: return "実況対象の番組が見つかりません。"
        case .internalServerError, .serviceTemporarilyUnavailable:
            return "実況サーバーで一時的なエラーが発生しています。"
        case .unknown: return "実況サーバーでエラーが発生しています。"
        }
    }
}

/// A watch-session disconnect reason mapped to a finite UI-safe set.
public enum LiveDisconnectReason: String, Equatable, Sendable {
    case takeover = "TAKEOVER"
    case noPermission = "NO_PERMISSION"
    case endProgram = "END_PROGRAM"
    case pingTimeout = "PING_TIMEOUT"
    case tooManyConnections = "TOO_MANY_CONNECTIONS"
    case tooManyWatchings = "TOO_MANY_WATCHINGS"
    case crowded = "CROWDED"
    case maintenanceIn = "MAINTENANCE_IN"
    case serviceTemporarilyUnavailable = "SERVICE_TEMPORARILY_UNAVAILABLE"
    case unknown

    fileprivate init(serverValue: String) {
        self = Self(rawValue: serverValue) ?? .unknown
    }

    public var canReconnect: Bool {
        switch self {
        case .pingTimeout, .maintenanceIn, .serviceTemporarilyUnavailable, .crowded, .unknown:
            return true
        case .takeover, .noPermission, .endProgram, .tooManyConnections, .tooManyWatchings:
            return false
        }
    }

    public var uiMessage: String {
        switch self {
        case .takeover: return "実況番組から切断されました。"
        case .noPermission: return "実況セッションの権限がありません。"
        case .endProgram: return "実況番組が終了しました。"
        case .pingTimeout: return "実況サーバーとの接続確認に失敗しました。"
        case .tooManyConnections: return "実況サーバーへの接続数上限に達しました。"
        case .tooManyWatchings: return "実況視聴数の上限に達しました。"
        case .crowded: return "実況番組が混雑しています。"
        case .maintenanceIn: return "実況サーバーはメンテナンス中です。"
        case .serviceTemporarilyUnavailable, .unknown:
            return "実況サーバーで一時的なエラーが発生しています。"
        }
    }
}

/// Data needed to open the NX-Jikkyo message server.  The thread key is kept
/// private and is used only while producing the initial receive request.
public struct LiveCommentRoom: Equatable, Sendable {
    public let threadID: String
    public let messageServerURL: URL
    public let vposBaseTime: Date?

    private let threadKey: String?

    public init(
        threadID: String,
        messageServerURL: URL,
        vposBaseTime: Date? = nil
    ) throws {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty,
              normalizedThreadID.utf8.count <= LiveCommentProtocol.maximumThreadIdentifierLength else {
            throw LiveCommentError.invalidThread
        }
        guard let validated = try? validatedWebSocketURL(messageServerURL.absoluteString) else {
            throw LiveCommentError.invalidWebSocketURL
        }
        self.threadID = normalizedThreadID
        self.messageServerURL = validated
        self.vposBaseTime = vposBaseTime
        self.threadKey = nil
    }

    fileprivate init(
        threadID: String,
        messageServerURL: URL,
        vposBaseTime: Date?,
        threadKey: String?
    ) throws {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty,
              normalizedThreadID.utf8.count <= LiveCommentProtocol.maximumThreadIdentifierLength else {
            throw LiveCommentError.invalidThread
        }
        guard let validated = try? validatedWebSocketURL(messageServerURL.absoluteString) else {
            throw LiveCommentError.invalidWebSocketURL
        }
        let trimmedKey = threadKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Anonymous NX sessions commonly carry an empty yourPostKey.  Treat
        // that as absent so the receive-only handshake still works.
        let normalizedKey = trimmedKey?.isEmpty == true ? nil : trimmedKey
        guard normalizedKey?.utf8.count ?? 0 <= LiveCommentProtocol.maximumThreadKeyLength else {
            throw LiveCommentError.invalidThread
        }
        self.threadID = normalizedThreadID
        self.messageServerURL = validated
        self.vposBaseTime = vposBaseTime
        self.threadKey = normalizedKey
    }

    /// Creates the initial receive-only request for the message server.
    /// `res_from` is bounded and defaults to the 100 most recent comments.
    public func commentHandshakeData(resFrom: Int = -100) throws -> Data {
        // Negative values request bounded history; zero is the live-only
        // request used when reconnecting without replaying old comments.
        guard (-LiveCommentProtocol.maximumHistoryRequest ... 0).contains(resFrom) else {
            throw LiveCommentError.invalidHistoryRequest
        }

        let value = CommentHandshake(
            ping: [
                .init(content: "rs:0"),
                .init(content: "ps:0")
            ],
            thread: CommentThread(
                version: "20061206",
                thread: threadID,
                threadKey: threadKey,
                userID: "",
                resFrom: resFrom
            ),
            finalPings: [
                .init(content: "pf:0"),
                .init(content: "rf:0")
            ]
        )
        do {
            let data = try JSONEncoder().encode(value.entries)
            guard data.count <= LiveCommentProtocol.maximumFrameBytes else {
                throw LiveCommentError.frameTooLarge
            }
            return data
        } catch let error as LiveCommentError {
            throw error
        } catch {
            throw LiveCommentError.encodingFailed
        }
    }
}

/// Messages accepted on the NX-Jikkyo watch WebSocket.
public enum LiveWatchMessage: Equatable, Sendable {
    case seat(keepInterval: Double)
    case ping
    case room(LiveCommentRoom)
    case error(LiveWatchErrorCode)
    case reconnect(waitTime: Double?)
    case disconnect(LiveDisconnectReason)
    case unknown

    public init(data: Data) throws {
        let object = try LiveJSON.object(from: data)
        guard let type = object.string(forKey: "type"),
              type.utf8.count <= LiveCommentProtocol.maximumControlCodeLength else {
            throw LiveCommentError.invalidMessage
        }

        switch type {
        case "seat":
            guard let value = object.object(forKey: "data")?.number(forKey: "keepIntervalSec"),
                  value.isFinite,
                  (LiveCommentProtocol.minimumKeepSeatInterval ... LiveCommentProtocol.maximumKeepSeatInterval).contains(value)
            else { throw LiveCommentError.invalidInterval }
            self = .seat(keepInterval: value)

        case "ping":
            self = .ping

        case "room":
            guard let dataObject = object.object(forKey: "data"),
                  let threadID = dataObject.string(forKey: "threadId"),
                  let messageServer = dataObject.object(forKey: "messageServer"),
                  let uri = messageServer.string(forKey: "uri") else {
                throw LiveCommentError.invalidRoom
            }
            let threadKey = dataObject.string(forKey: "yourPostKey")
            let baseTime: Date?
            if let raw = dataObject.string(forKey: "vposBaseTime") {
                baseTime = parseISO8601(raw)
                guard baseTime != nil else { throw LiveCommentError.invalidRoom }
            } else {
                baseTime = nil
            }
            guard let url = try? validatedWebSocketURL(uri) else {
                throw LiveCommentError.invalidWebSocketURL
            }
            self = .room(try LiveCommentRoom(
                threadID: threadID,
                messageServerURL: url,
                vposBaseTime: baseTime,
                threadKey: threadKey
            ))

        case "error":
            guard let code = object.object(forKey: "data")?.string(forKey: "code"),
                  code.utf8.count <= LiveCommentProtocol.maximumControlCodeLength else {
                throw LiveCommentError.invalidMessage
            }
            self = .error(LiveWatchErrorCode(serverValue: code))

        case "reconnect":
            let wait: Double?
            if let dataObject = object.object(forKey: "data") {
                if let value = dataObject.number(forKey: "waitTimeSec") {
                    guard value.isFinite, value >= 0, value <= LiveCommentProtocol.maximumRetryWait else {
                        throw LiveCommentError.invalidRetryWait
                    }
                    wait = value
                } else if dataObject.contains("waitTimeSec") {
                    throw LiveCommentError.invalidRetryWait
                } else {
                    wait = nil
                }
            } else {
                wait = nil
            }
            self = .reconnect(waitTime: wait)

        case "disconnect":
            guard let reason = object.object(forKey: "data")?.string(forKey: "reason"),
                  reason.utf8.count <= LiveCommentProtocol.maximumControlCodeLength else {
                throw LiveCommentError.invalidMessage
            }
            self = .disconnect(LiveDisconnectReason(serverValue: reason))

        default:
            self = .unknown
        }
    }

    public var isReconnectable: Bool {
        switch self {
        case .error(let code): return code.canReconnect
        case .reconnect: return true
        case .disconnect(let reason): return reason.canReconnect
        case .seat, .ping, .room, .unknown: return false
        }
    }

    public var uiMessage: String? {
        switch self {
        case .error(let code): return code.uiMessage
        case .disconnect(let reason): return reason.uiMessage
        case .reconnect: return "実況サーバーに再接続しています。"
        case .seat, .ping, .room, .unknown: return nil
        }
    }
}

/// A typed command sent to the NX-Jikkyo watch session.
public enum LiveWatchCommand: Equatable, Sendable {
    case startWatching(reconnect: Bool)
    case pong
    case keepSeat

    public func encoded() throws -> Data {
        do {
            let data: Data
            switch self {
            case .startWatching(let reconnect):
                data = try JSONEncoder().encode(StartWatchingCommand(reconnect: reconnect))
            case .pong:
                data = try JSONEncoder().encode(SimpleWatchCommand(type: "pong"))
            case .keepSeat:
                data = try JSONEncoder().encode(SimpleWatchCommand(type: "keepSeat"))
            }
            guard data.count <= LiveCommentProtocol.maximumFrameBytes else {
                throw LiveCommentError.frameTooLarge
            }
            return data
        } catch let error as LiveCommentError {
            throw error
        } catch {
            throw LiveCommentError.encodingFailed
        }
    }
}

/// One safe, receive-only chat item from the NX-Jikkyo message server.
public struct LiveComment: Equatable, Sendable {
    public let threadID: String?
    public let number: Int?
    public let serverTime: Double
    public let text: String
    public let position: PlaybackCommentPosition
    public let size: PlaybackCommentSize
    public let colorRGB: UInt32
    public let isYourPost: Bool

    public init(
        threadID: String? = nil,
        number: Int? = nil,
        serverTime: Double,
        text: String,
        position: PlaybackCommentPosition = .right,
        size: PlaybackCommentSize = .medium,
        colorRGB: UInt32 = 0xFF_EA_EA,
        isYourPost: Bool = false
    ) throws {
        let normalizedThread = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedThread == nil || normalizedThread?.isEmpty == false,
              normalizedThread?.utf8.count ?? 0 <= LiveCommentProtocol.maximumThreadIdentifierLength else {
            throw LiveCommentError.invalidChat
        }
        guard number == nil || (0 ... Int(Int32.max)).contains(number!) else {
            throw LiveCommentError.invalidChat
        }
        guard serverTime.isFinite,
              serverTime >= 0,
              serverTime <= LiveCommentProtocol.maximumServerTime else {
            throw LiveCommentError.invalidChat
        }

        // PlaybackComment owns the established text/color bounds and
        // normalization rules.  The temporary time is intentional: chat.date
        // is an epoch timestamp, while playback time is file-relative.
        let normalized = try PlaybackComment(
            time: 0,
            position: position,
            size: size,
            colorRGB: colorRGB,
            text: text
        )
        guard normalizedThread != nil || number != nil else {
            throw LiveCommentError.invalidChat
        }
        self.threadID = normalizedThread
        self.number = number
        self.serverTime = serverTime
        self.text = normalized.text
        self.position = position
        self.size = size
        self.colorRGB = colorRGB
        self.isYourPost = isYourPost
    }

    /// Converts a live arrival to the current media clock.  This does not use
    /// `serverTime` as playback time because NX-Jikkyo's `date` is epoch time.
    public func playbackComment(at seconds: Double) throws -> PlaybackComment {
        try PlaybackComment(
            time: seconds,
            position: position,
            size: size,
            colorRGB: colorRGB,
            text: text
        )
    }
}

/// Messages accepted on the NX-Jikkyo comment WebSocket.
public enum LiveCommentMessage: Equatable, Sendable {
    case thread(resultCode: Int)
    case historyFinished
    case ping
    case chat(LiveComment)
    case ignored
    case unknown

    public init(data: Data) throws {
        let object = try LiveJSON.object(from: data)
        // The Nico-compatible comment protocol identifies messages by their
        // top-level member (`thread`, `ping`, or `chat`); unlike the watch
        // protocol it does not wrap them in a `type` member.
        if object.contains("thread") {
            guard let result = object.object(forKey: "thread")?.int(forKey: "resultcode"),
                  (-1_000_000 ... 1_000_000).contains(result) else {
                throw LiveCommentError.invalidThread
            }
            self = .thread(resultCode: result)
            return
        }

        if object.contains("ping") {
            if object.object(forKey: "ping")?.string(forKey: "content") == "rf:0" {
                self = .historyFinished
            } else {
                self = .ping
            }
            return
        }

        if object.contains("chat") {
            guard let chatObject = object.object(forKey: "chat") else {
                self = .ignored
                return
            }
            guard let comment = try? LiveCommentParser.parse(chatObject) else {
                self = .ignored
                return
            }
            self = .chat(comment)
            return
        }

        self = .unknown
    }
}

// MARK: - Private protocol implementation

private struct StartWatchingCommand: Encodable {
    let type = "startWatching"
    let data: StartWatchingData

    init(reconnect: Bool) {
        data = StartWatchingData(reconnect: reconnect)
    }
}

private struct StartWatchingData: Encodable {
    let reconnect: Bool
}

private struct SimpleWatchCommand: Encodable {
    let type: String
}

private struct CommentHandshake {
    let ping: [CommentPing]
    let thread: CommentThread
    let finalPings: [CommentPing]

    var entries: [CommentHandshakeEntry] {
        [
            .ping(ping[0]),
            .ping(ping[1]),
            .thread(thread),
            .ping(finalPings[0]),
            .ping(finalPings[1])
        ]
    }
}

private struct CommentHandshakeEntry: Encodable {
    private let pingValue: CommentPing?
    private let threadValue: CommentThread?

    static func ping(_ value: CommentPing) -> Self {
        Self(pingValue: value, threadValue: nil)
    }

    static func thread(_ value: CommentThread) -> Self {
        Self(pingValue: nil, threadValue: value)
    }

    private init(pingValue: CommentPing?, threadValue: CommentThread?) {
        self.pingValue = pingValue
        self.threadValue = threadValue
    }

    private enum CodingKeys: String, CodingKey { case ping, thread }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let pingValue {
            try container.encode(pingValue, forKey: .ping)
        } else if let threadValue {
            try container.encode(threadValue, forKey: .thread)
        } else {
            throw LiveCommentError.encodingFailed
        }
    }
}

private struct CommentPing: Encodable {
    let content: String
}

private struct CommentThread: Encodable {
    let version: String
    let thread: String
    let threadKey: String?
    let userID: String
    let resFrom: Int

    private enum CodingKeys: String, CodingKey {
        case version, thread, threadKey = "threadkey", userID = "user_id", resFrom = "res_from"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(thread, forKey: .thread)
        try container.encode(threadKey, forKey: .threadKey)
        try container.encode(userID, forKey: .userID)
        try container.encode(resFrom, forKey: .resFrom)
    }
}

private enum LiveCommentParser {
    static func parse(_ object: [String: RawJSONValue]) throws -> LiveComment {
        let threadID = object.string(forKey: "thread")
            ?? object.int(forKey: "thread").map { String($0) }
        let number = object.int(forKey: "no")
        guard let serverTime = object.number(forKey: "date"),
              let text = object.string(forKey: "content") else {
            throw LiveCommentError.invalidChat
        }

        let premium = object.stringOrNumber(forKey: "premium")
        if isOperatorCommand(text, premium: premium) {
            throw LiveCommentError.invalidChat
        }

        let appearance = parseMail(object.string(forKey: "mail"))
        let isYourPost = object.bool(forKey: "yourpost")
            ?? object.int(forKey: "yourpost").map { $0 != 0 }
            ?? false
        return try LiveComment(
            threadID: threadID,
            number: number,
            serverTime: serverTime,
            text: text,
            position: appearance.position,
            size: appearance.size,
            colorRGB: appearance.colorRGB,
            isYourPost: isYourPost
        )
    }

    private struct Appearance {
        let position: PlaybackCommentPosition
        let size: PlaybackCommentSize
        let colorRGB: UInt32
    }

    private static func parseMail(_ rawMail: String?) -> Appearance {
        var position: PlaybackCommentPosition = .right
        var size: PlaybackCommentSize = .medium
        var colorRGB: UInt32 = 0xFF_EA_EA

        guard let rawMail else {
            return Appearance(position: position, size: size, colorRGB: colorRGB)
        }

        for commandSubstring in rawMail.split(whereSeparator: { $0.isWhitespace }) {
            let command = String(commandSubstring)
            if command == "184" { continue }
            switch command.lowercased() {
            case "ue": position = .top
            case "naka": position = .right
            case "shita": position = .bottom
            case "big": size = .big
            case "medium": size = .medium
            case "small": size = .small
            default:
                if let parsed = parseColor(command) { colorRGB = parsed }
            }
        }
        return Appearance(position: position, size: size, colorRGB: colorRGB)
    }

    private static func parseColor(_ raw: String) -> UInt32? {
        let standard: [String: UInt32] = [
            "white": 0xFF_EA_EA, "red": 0xF0_28_40, "pink": 0xFD_7E_80,
            "orange": 0xFD_A7_08, "yellow": 0xFF_E1_33, "green": 0x64_DD_17,
            "cyan": 0x00_D4_F5, "blue": 0x47_63_FF, "purple": 0xD5_00_F9,
            "black": 0x1E_13_10, "white2": 0xCC_CC_99, "niconicowhite": 0xCC_CC_99,
            "red2": 0xCC_00_33, "truered": 0xCC_00_33, "pink2": 0xFF_33_CC,
            "orange2": 0xFF_66_00, "passionorange": 0xFF_66_00,
            "yellow2": 0x99_99_00, "madyellow": 0x99_99_00,
            "green2": 0x00_CC_66, "elementalgreen": 0x00_CC_66,
            "cyan2": 0x00_CC_CC, "blue2": 0x33_99_FF, "marineblue": 0x33_99_FF,
            "purple2": 0x66_33_CC, "nobleviolet": 0x66_33_CC, "black2": 0x66_66_66
        ]
        if let value = standard[raw.lowercased()] { return value }

        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#" else { return nil }
        return UInt32(value.dropFirst(), radix: 16)
    }

    private static func isOperatorCommand(_ text: String, premium: String?) -> Bool {
        guard premium == "3" else { return false }
        let characters = Array(text)
        guard characters.first == "/", characters.count >= 2 else { return false }
        guard characters[1].asciiLetter else { return false }
        var index = 2
        while index < characters.count,
              characters[index].asciiLetter || characters[index].asciiDigit
                || characters[index] == "_" || characters[index] == "-" {
            index += 1
        }
        return index == characters.count || characters[index].isWhitespace
    }
}

private func parseISO8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

private func validatedWebSocketURL(_ rawValue: String?) throws -> URL? {
    guard let rawValue else { return nil }
    let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty,
          raw.utf8.count <= LiveCommentProtocol.maximumURLBytes,
          let url = URL(string: raw),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          scheme == "ws" || scheme == "wss",
          let host = components.host,
          !host.isEmpty,
          components.user == nil,
          components.password == nil,
          components.fragment == nil,
          components.port.map({ (1 ... 65_535).contains($0) }) ?? true else {
        throw LiveCommentError.invalidWebSocketURL
    }
    return url
}

private enum LiveJSON {
    static func object(from data: Data) throws -> [String: RawJSONValue] {
        guard data.count <= LiveCommentProtocol.maximumFrameBytes else {
            throw LiveCommentError.frameTooLarge
        }
        try validateDepth(data)
        let value: RawJSONValue
        do {
            value = try JSONDecoder().decode(RawJSONValue.self, from: data)
        } catch {
            throw LiveCommentError.invalidJSON
        }
        guard case .object(let object) = value else {
            throw LiveCommentError.invalidMessage
        }
        return object
    }

    private static func validateDepth(_ data: Data) throws {
        var stack: [UInt8] = []
        stack.reserveCapacity(LiveCommentProtocol.maximumJSONDepth)
        var inString = false
        var escaped = false

        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B || byte == 0x5B { // { or [
                stack.append(byte)
                if stack.count > LiveCommentProtocol.maximumJSONDepth {
                    throw LiveCommentError.jsonTooDeep
                }
            } else if byte == 0x7D || byte == 0x5D { // } or ]
                guard let opening = stack.popLast(),
                      (opening == 0x7B && byte == 0x7D) || (opening == 0x5B && byte == 0x5D) else {
                    throw LiveCommentError.invalidJSON
                }
            }
        }

        guard !inString, !escaped, stack.isEmpty else {
            throw LiveCommentError.invalidJSON
        }
    }
}

private extension RawJSONValue {
    var liveString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var liveNumber: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }

    var liveInt: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value) where value.isFinite && value.rounded() == value:
            return Int(exactly: value)
        default: return nil
        }
    }

    var liveBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

private extension Dictionary where Key == String, Value == RawJSONValue {
    func value(forKey key: String) -> RawJSONValue? { self[key] }

    func contains(_ key: String) -> Bool { self[key] != nil }

    func string(forKey key: String) -> String? {
        self[key]?.liveString
    }

    func number(forKey key: String) -> Double? {
        self[key]?.liveNumber
    }

    func int(forKey key: String) -> Int? {
        self[key]?.liveInt
    }

    func bool(forKey key: String) -> Bool? {
        self[key]?.liveBool
    }

    func object(forKey key: String) -> [String: RawJSONValue]? {
        guard case .object(let value) = self[key] else { return nil }
        return value
    }

    func stringOrNumber(forKey key: String) -> String? {
        if let string = string(forKey: key) { return string }
        if let number = number(forKey: key), number.isFinite {
            if number.rounded() == number {
                return Int(exactly: number).map { String($0) }
            }
            return String(number)
        }
        return nil
    }
}

private extension Character {
    var asciiLetter: Bool {
        ("a" ... "z").contains(self) || ("A" ... "Z").contains(self)
    }

    var asciiDigit: Bool {
        ("0" ... "9").contains(self)
    }
}
