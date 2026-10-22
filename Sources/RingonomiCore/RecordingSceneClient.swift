import Foundation

public extension RingonomiClient {
    /// Fetch the tiled scene image for a recorded program.
    ///
    /// The image is returned as-is so the application can choose when and how
    /// to decode it.  The request still goes through the backend byte
    /// transport, which applies the configured token and redirect policy.
    func recordingSceneImage(
        recordingID: Int,
        using session: URLSession = .shared
    ) async throws -> Data {
        guard recordingID > 0 else {
            throw RecordingLibraryError.invalidIdentifier
        }

        var request = URLRequest(
            url: endpoint(["api", "videos", String(recordingID), "thumbnail", "tiled"])
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        return try await readRecordingSceneResponse(
            request: request,
            maximumBytes: 16 * 1024 * 1024,
            contentType: .image,
            using: session
        )
    }

    /// Fetch the recorded-program metadata needed to resolve scene images.
    /// This deliberately uses the streaming backend transport rather than the
    /// general recording method, whose response bound is intentionally a
    /// separate concern.
    func recordingSceneRecording(
        id: Int,
        using session: URLSession = .shared
    ) async throws -> Recording {
        guard id > 0 else {
            throw RecordingLibraryError.invalidIdentifier
        }

        var request = URLRequest(url: endpoint(["api", "videos", String(id)]))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let data = try await readRecordingSceneResponse(
            request: request,
            maximumBytes: 4 * 1024 * 1024,
            contentType: .optionalJSON,
            using: session
        )

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let recording = try decoder.decode(Recording.self, from: data)
            guard recording.id == id else {
                throw RecordingLibraryError.invalidResponse
            }
            return recording
        } catch let error as RecordingLibraryError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConnectionError.invalidResponse
        }
    }
}

private enum RecordingSceneContentType {
    case image
    case optionalJSON
}

private extension RingonomiClient {
    func readRecordingSceneResponse(
        request: URLRequest,
        maximumBytes: Int,
        contentType: RecordingSceneContentType,
        using session: URLSession
    ) async throws -> Data {
        try Task.checkCancellation()
        let bytesAndResponse: (BackendResponseStream, URLResponse)
        do {
            bytesAndResponse = try await backendBytes(for: request, using: session)
        } catch {
            // URLSession may surface cancellation before AsyncBytes is
            // returned as URLError.cancelled.  Normalize only cancellation of
            // this task; an independently cancelled URLSession remains its
            // original error.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        let (bytes, response) = bytesAndResponse
        // Keep this immediately after acquiring AsyncBytes: HTTP status,
        // headers, decoding, cancellation, and every other exit path must
        // release the underlying URLSession task.
        defer { bytes.cancel() }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw ConnectionError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw (200..<300).contains(http.statusCode)
                ? ConnectionError.invalidResponse
                : ConnectionError.http(http.statusCode)
        }
        guard Self.accepts(contentType: contentType, response: http) else {
            throw ConnectionError.invalidResponse
        }
        let declaredLength = response.expectedContentLength
        guard declaredLength < 0 || declaredLength <= Int64(maximumBytes) else {
            throw ConnectionError.invalidResponse
        }

        var data = Data()
        if declaredLength > 0 {
            data.reserveCapacity(min(Int(declaredLength), maximumBytes))
        }
        do {
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw ConnectionError.invalidResponse
                }
                data.append(byte)
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard !data.isEmpty else {
            throw ConnectionError.invalidResponse
        }
        return data
    }

    static func accepts(
        contentType: RecordingSceneContentType,
        response: HTTPURLResponse
    ) -> Bool {
        let mediaType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch contentType {
        case .image:
            return ["image/webp", "image/png", "image/jpeg"].contains(mediaType)
        case .optionalJSON:
            // Some test/proxy layers omit Content-Type, so JSON is validated
            // by decoding when the header is absent.  A present header must
            // still describe JSON rather than an unrelated payload.
            guard let mediaType else { return true }
            return mediaType == "application/json"
        }
    }
}
