import Foundation

/// A single-consumer API body with the same cancellation entry point for
/// anonymous/Bearer and scoped Basic transports. The Basic stream retains its
/// connection and sanitizes errors without exposing the underlying task.
public struct BackendResponseStream: Sendable, AsyncSequence, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public typealias Element = UInt8
    private enum Storage: Sendable {
        case standard(URLSession.AsyncBytes)
        case basic(HTTPBasicResponseStream)
    }
    private let storage: Storage

    internal init(_ bytes: URLSession.AsyncBytes) { storage = .standard(bytes) }
    internal init(_ bytes: HTTPBasicResponseStream) { storage = .basic(bytes) }

    public func cancel() {
        switch storage {
        case .standard(let bytes): bytes.task.cancel()
        case .basic(let bytes): bytes.cancel()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        switch storage {
        case .standard(let bytes): AsyncIterator(standard: bytes.makeAsyncIterator())
        case .basic(let bytes): AsyncIterator(basic: bytes.makeAsyncIterator())
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol, CustomStringConvertible,
        CustomDebugStringConvertible, CustomReflectable {
        private var standard: URLSession.AsyncBytes.AsyncIterator?
        private var basic: HTTPBasicResponseStream.AsyncIterator?
        fileprivate init(standard: URLSession.AsyncBytes.AsyncIterator) { self.standard = standard }
        fileprivate init(basic: HTTPBasicResponseStream.AsyncIterator) { self.basic = basic }

        public mutating func next() async throws -> UInt8? {
            if basic != nil { return try await basic!.next() }
            return try await standard!.next()
        }

        /// Reads a bounded chunk while preserving the same single-consumer
        /// and cancellation semantics as `next()`.
        public mutating func nextChunk(maximumBytes: Int = 32 * 1024) async throws -> Data? {
            guard (1...(256 * 1024)).contains(maximumBytes) else {
                throw HTTPBasicTransportError.invalidLimit
            }
            // The Basic stream already has a bounded implementation that
            // preserves its cancellation state. Keep that path intact. The
            // URLSession path can read directly from AsyncBytes, avoiding a
            // second async wrapper for every byte in a live MPEG-TS chunk.
            if basic != nil {
                return try await basic!.nextChunk(maximumBytes: maximumBytes)
            }
            try Task.checkCancellation()
            var data = Data()
            data.reserveCapacity(maximumBytes)
            while data.count < maximumBytes {
                try Task.checkCancellation()
                guard let byte = try await standard!.next() else { break }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data.isEmpty ? nil : data
        }
        public var description: String { "BackendResponseStream.AsyncIterator(<redacted>)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, unlabeledChildren: ["<redacted>"]) }
    }

    public var description: String { "BackendResponseStream(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: ["<redacted>"]) }
}
