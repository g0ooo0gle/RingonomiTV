import Foundation
import XCTest
@testable import RingonomiCore

final class LiveCommentTransportCancellationTests: XCTestCase {
    func testSuccessThenLateCallbacksAreIgnored() async throws {
        let operation = SocketCallbackOperation<Int>()

        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            XCTAssertTrue(operation.install(continuation))
            operation.succeed(7)
        }

        XCTAssertEqual(value, 7)

        // URLSession may deliver a callback after the task already completed.
        // Neither a late failure nor a late cancellation may resume twice.
        operation.fail(LiveCommentTransportError.connectionClosed)
        operation.cancel()
    }

    func testCancellationThenLateSuccessIsReturnedAsCancellation() async {
        let operation = SocketCallbackOperation<Int>()

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                XCTAssertTrue(operation.install(continuation))
                operation.cancel()
                operation.succeed(9)
            }
            XCTFail("cancellation must win over a delayed callback")
        } catch is CancellationError {
            // Expected. The delayed success above was ignored.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        operation.fail(LiveCommentTransportError.connectionClosed)
    }

    func testCancellationBeforeContinuationInstallationDoesNotLeaveItSuspended() async {
        let operation = SocketCallbackOperation<Int>()
        operation.cancel()

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                guard operation.install(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                XCTFail("a cancelled operation must reject a late continuation")
            }
            XCTFail("the rejected continuation must finish with cancellation")
        } catch is CancellationError {
            // Expected. This covers cancellation racing with callback setup.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        operation.succeed(11)
    }

    func testConcurrentSuccessAndCancellationCompleteExactlyOnce() async {
        for iteration in 0..<100 {
            let operation = SocketCallbackOperation<Int>()
            do {
                let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                    XCTAssertTrue(operation.install(continuation))
                    DispatchQueue.concurrentPerform(iterations: 2) { index in
                        if index == 0 {
                            operation.succeed(iteration)
                        } else {
                            operation.cancel()
                        }
                    }
                }
                XCTAssertEqual(value, iteration)
            } catch is CancellationError {
                // Cancellation and callback completion are intentionally raced;
                // exactly one of them must win.
            } catch {
                XCTFail("unexpected error: \(error)")
            }

            // Simulate callbacks arriving after the winner has already
            // completed the continuation. These must remain harmless.
            operation.succeed(iteration + 1)
            operation.fail(LiveCommentTransportError.connectionClosed)
        }
    }
}
