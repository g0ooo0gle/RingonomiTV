import Foundation
import XCTest
@testable import RingonomiCore

final class ReservationMutationJournalTests: XCTestCase {
    func testIntentRoundTripsAndRecoveryEntryIsExplicit() throws {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let intent = ReservationMutationIntent(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            address: "https://example.invalid/tv",
            target: .keywordReservation,
            action: .update,
            subjectID: 7,
            title: "ニュース",
            startedAt: startedAt
        )

        let decoded = try JSONDecoder().decode(
            ReservationMutationIntent.self,
            from: JSONEncoder().encoded(intent)
        )
        XCTAssertEqual(decoded, intent)
        XCTAssertFalse(decoded.isRecoveryEntry)

        let recovery = ReservationMutationIntent.recoveryEntry(now: startedAt)
        XCTAssertTrue(recovery.isRecoveryEntry)
        XCTAssertEqual(recovery.target, .unknown)
        XCTAssertEqual(recovery.action, .unknown)
        XCTAssertTrue(recovery.address.isEmpty)
    }

    func testOnlyExplicitFourHundredErrorsClearJournal() {
        XCTAssertEqual(
            ReservationMutationFailureClassifier.disposition(for: ReservationError.http(status: 409, detail: nil)),
            .explicitRejection
        )
        XCTAssertEqual(
            ReservationMutationFailureClassifier.disposition(for: ReservationError.requestEncoding),
            .explicitRejection
        )
        XCTAssertEqual(
            ReservationMutationFailureClassifier.disposition(for: ReservationError.http(status: 500, detail: nil)),
            .outcomeUnknown
        )
        for status in [408, 425, 429] {
            XCTAssertEqual(
                ReservationMutationFailureClassifier.disposition(for: ReservationError.http(status: status, detail: nil)),
                .outcomeUnknown,
                "HTTP \(status) can be a retryable or rate-limited response"
            )
        }
        XCTAssertEqual(
            ReservationMutationFailureClassifier.disposition(for: ReservationError.http(status: 404, detail: nil)),
            .explicitRejection
        )
        XCTAssertEqual(
            ReservationMutationFailureClassifier.disposition(for: ReservationError.invalidResponse),
            .outcomeUnknown
        )
        XCTAssertEqual(
            ReservationMutationFailureClassifier.disposition(for: CancellationError()),
            .outcomeUnknown
        )
    }
}

private extension JSONEncoder {
    func encoded<T: Encodable>(_ value: T) throws -> Data { try encode(value) }
}
