import Foundation

/// The kind of KonomiTV write represented by a local recovery journal entry.
///
/// The journal is intentionally client-side metadata. It does not add an
/// idempotency key to the server request; KonomiTV versions in use do not
/// provide that guarantee.
public enum ReservationMutationTarget: String, Codable, Equatable, Sendable {
    case reservation
    case keywordReservation
    case unknown
}

public enum ReservationMutationAction: String, Codable, Equatable, Sendable {
    case add
    case update
    case delete
    case unknown
}

/// A write intent persisted immediately before a mutation is sent.
///
/// `isRecoveryEntry` is used when the previous journal could not be decoded.
/// Such an entry must remain visible until the user has reviewed the relevant
/// lists; it must never be silently discarded during launch.
public struct ReservationMutationIntent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let address: String
    public let target: ReservationMutationTarget
    public let action: ReservationMutationAction
    public let subjectID: Int?
    public let title: String
    public let startedAt: Date
    public let isRecoveryEntry: Bool

    public init(
        id: UUID = UUID(),
        address: String,
        target: ReservationMutationTarget,
        action: ReservationMutationAction,
        subjectID: Int? = nil,
        title: String,
        startedAt: Date = Date(),
        isRecoveryEntry: Bool = false
    ) {
        self.id = id
        self.address = address
        self.target = target
        self.action = action
        self.subjectID = subjectID
        self.title = title
        self.startedAt = startedAt
        self.isRecoveryEntry = isRecoveryEntry
    }

    /// A recoverable marker used when the persisted entry is malformed.
    public static func recoveryEntry(now: Date = Date()) -> Self {
        Self(
            address: "",
            target: .unknown,
            action: .unknown,
            title: "前の予約操作の記録を読み込めませんでした",
            startedAt: now,
            isRecoveryEntry: true
        )
    }
}

/// Whether a failed mutation is known to have been rejected or may have been
/// accepted by the server. The latter must keep the journal and block a
/// duplicate write until a fresh list has been reviewed.
public enum ReservationMutationFailureDisposition: Equatable, Sendable {
    case explicitRejection
    case outcomeUnknown
}

public enum ReservationMutationFailureClassifier {
    /// Classify errors from the KonomiTV client conservatively.
    ///
    /// Only a server-side 4xx response (or a local request validation/encoding
    /// failure that proves no request was sent) clears the journal. 5xx,
    /// malformed success bodies, transport failures, redirects, and
    /// cancellation remain outcome-unknown.
    public static func disposition(for error: Error) -> ReservationMutationFailureDisposition {
        if let error = error as? ReservationError {
            switch error {
            case .http(let status, _):
                // A timeout, retryable request, or rate limit does not prove
                // that the server rejected the write. Keep those entries
                // recoverable even though they use a 4xx status.
                if status == 408 || status == 425 || status == 429 {
                    return .outcomeUnknown
                }
                return (400..<500).contains(status) ? .explicitRejection : .outcomeUnknown
            case .invalidProgramID, .requestEncoding:
                return .explicitRejection
            case .invalidResponse, .emptyCreatedReservation, .outcomeUnknown:
                return .outcomeUnknown
            }
        }
        return .outcomeUnknown
    }
}
