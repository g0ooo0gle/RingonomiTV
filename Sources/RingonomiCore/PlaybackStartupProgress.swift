import Foundation

/// 再生開始の待機先だけを示す。接続先や認証情報は保持しない。
public enum PlaybackStartupPhase: String, Sendable, Equatable {
    case waitingForMedia
    case preparingPlayer
    case waitingForRequest
    case waitingForResponse
    case waitingForData
    case decoding
    case buffering

    public var timeoutMessage: String {
        switch self {
        case .waitingForMedia:
            return "画質の切り替えがタイムアウトしました。再試行してください。"
        case .preparingPlayer:
            return "再生の準備がタイムアウトしました。再試行してください。"
        case .waitingForRequest:
            return "再生を開始できませんでした。もう一度お試しください。"
        case .waitingForResponse:
            return "サーバーの応答がタイムアウトしました。接続を確認して再試行してください。"
        case .waitingForData:
            return "映像データを受信できませんでした。接続を確認して再試行してください。"
        case .decoding:
            return "映像と音声の準備がタイムアウトしました。再試行してください。"
        case .buffering:
            return "映像の読み込みが進みませんでした。接続を確認して再試行してください。"
        }
    }

    fileprivate var connectionFailureMessage: String {
        switch self {
        case .waitingForMedia:
            return "画質を切り替えられませんでした。再試行してください。"
        case .preparingPlayer, .waitingForRequest:
            return "再生を開始できませんでした。もう一度お試しください。"
        case .waitingForResponse:
            return "サーバーから応答を受け取れませんでした。接続を確認して再試行してください。"
        case .waitingForData:
            return "映像データを受信できませんでした。接続を確認して再試行してください。"
        case .decoding:
            return "映像と音声の準備が完了しませんでした。再試行してください。"
        case .buffering:
            return "映像の読み込みが中断されました。接続を確認して再試行してください。"
        }
    }

    fileprivate var timeout: Double {
        switch self {
        case .waitingForMedia, .waitingForRequest: return 15
        default: return 30
        }
    }
}

/// リレー内のGET試行番号を伴う、不変の進捗スナップショット。
public struct PlaybackStartupProgress: Sendable, Equatable {
    public let phase: PlaybackStartupPhase
    public let attempt: UInt64

    public init(phase: PlaybackStartupPhase, attempt: UInt64 = 0) {
        self.phase = phase
        self.attempt = attempt
    }
}

/// 通信の進行と再生準備完了は別扱いにする。Readyの判断は
/// PlaybackReadinessGateへ委ね、ここでは待機期限と世代だけを扱う。
public struct LivePlaybackStartupDeadline: Sendable {
    public private(set) var currentPhase: PlaybackStartupPhase?
    private var generation: Int?
    private var startedAt = 0.0
    private var phaseStartedAt = 0.0
    private var transportAttempt: UInt64?
    private let totalTimeout = 45.0

    public init() {}

    public mutating func begin(generation: Int, phase: PlaybackStartupPhase = .preparingPlayer,
                               at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard time.isFinite else { invalidate(); return }
        self.generation = generation
        currentPhase = phase
        startedAt = time
        phaseStartedAt = time
        transportAttempt = nil
    }

    /// 旧プレーヤーの停止待ちやリレーの起動待ちが終わるまで、
    /// 「プレーヤーから要求が来ない」という期限を開始しない。
    public mutating func playerStarted(generation: Int, usesRelay: Bool,
                                       at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard self.generation == generation, currentPhase == .preparingPlayer,
              time.isFinite, time >= phaseStartedAt else { return }
        currentPhase = usesRelay ? .waitingForRequest : .decoding
        phaseStartedAt = time
        transportAttempt = nil
    }

    public mutating func observe(_ progress: PlaybackStartupProgress?, generation: Int,
                                 at time: Double = ProcessInfo.processInfo.systemUptime) {
        guard self.generation == generation, let progress, let phase = currentPhase,
              phase != .preparingPlayer, phase != .waitingForMedia, phase != .buffering,
              time.isFinite, time >= phaseStartedAt else { return }
        switch progress.phase {
        case .waitingForRequest, .waitingForResponse, .waitingForData, .decoding: break
        default: return
        }
        // 旧GETの遅延通知が新しい試行の期限を変更しないようにする。
        if let attempt = transportAttempt, progress.attempt < attempt { return }
        guard progress.phase != phase || transportAttempt != progress.attempt else { return }
        currentPhase = progress.phase
        transportAttempt = progress.attempt
        phaseStartedAt = time
        // 接続を繰り返しても、開始全体の45秒という上限は延長しない。
    }

    public func timedOutPhase(generation: Int,
                              at time: Double = ProcessInfo.processInfo.systemUptime) -> PlaybackStartupPhase? {
        guard self.generation == generation, let phase = currentPhase, time.isFinite,
              time >= startedAt, time >= phaseStartedAt else { return nil }
        return time - phaseStartedAt >= phase.timeout || time - startedAt >= totalTimeout
            ? phase : nil
    }

    /// 通信側の期限や切断が先に確定しても、待機していた段階を保つ。
    /// HTTPエラーや切断をタイムアウトと断定せず、認証・形式エラーは維持する。
    public func failureMessage(for failure: HTTPMediaRelayFailure) -> String {
        guard failure == .connection, let phase = currentPhase else {
            return failure.localizedDescription
        }
        return phase.connectionFailureMessage
    }

    public mutating func finish(generation: Int) {
        guard self.generation == generation else { return }
        invalidate()
    }

    public mutating func invalidate() {
        generation = nil
        currentPhase = nil
        transportAttempt = nil
    }
}
