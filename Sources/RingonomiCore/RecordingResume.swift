import CryptoKit
import Foundation

/// Stable identity for a saved recording position.
///
/// A server can reuse a numeric recorded-video ID over time, so the ID is
/// combined with the normalized server and the program start-time token.  The
/// endpoint itself is never written to the bookmark payload.
public struct RecordingResumeID: Codable, Hashable, Sendable {
    /// SHA-256 of the normalized server origin and reverse-proxy path.
    public let serverKey: String
    /// The recorded-video identifier used by the stream endpoint.
    public let videoID: Int
    /// The server's program start-time token, when available.
    public let recordingStartTime: String?

    public init(serverURL: URL, videoID: Int, recordingStartTime: String?) {
        let normalizedServer = Self.normalizedServerString(serverURL)
        self.serverKey = Self.sha256Hex(normalizedServer)
        self.videoID = videoID
        let trimmed = recordingStartTime?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recordingStartTime = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Alias matching the API field name used by `Recording`.
    public var startTime: String? { recordingStartTime }

    /// Alias making the recorded-video identity explicit at call sites.
    public var recordedVideoID: Int { videoID }

    /// A deterministic UserDefaults/archive key with no raw server endpoint.
    public var storageKey: String {
        let startToken = recordingStartTime.map(Self.sha256Hex) ?? "none"
        return "ringonomi.resume.v1.\(serverKey).\(videoID).\(startToken)"
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func normalizedServerString(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme,
              let rawHost = components.host else {
            // RingonomiClient rejects malformed addresses before this type is
            // constructed. This fallback still avoids query and fragment data
            // if a caller creates an ID directly from an unusual URL.
            var fallback = url.absoluteString
            if let queryStart = fallback.firstIndex(of: "?") {
                fallback = String(fallback[..<queryStart])
            }
            if let fragmentStart = fallback.firstIndex(of: "#") {
                fallback = String(fallback[..<fragmentStart])
            }
            return fallback
        }

        let scheme = rawScheme.lowercased()
        var host = rawHost.lowercased()
        // URLComponents returns an IPv6 host without brackets on some SDKs.
        if host.contains(":") && !host.hasPrefix("[") {
            host = "[\(host)]"
        }

        let port: Int?
        switch (scheme, components.port) {
        case ("http", 80), ("https", 443):
            port = nil
        default:
            port = components.port
        }

        // Preserve the reverse-proxy path, but treat root and trailing slashes
        // consistently. Query and fragment are intentionally excluded.
        var path = components.percentEncodedPath
        while path.count > 1, path.last == "/" {
            path.removeLast()
        }
        if path == "/" { path = "" }
        return scheme + "://" + host + (port.map { ":\($0)" } ?? "") + path
    }
}

/// A single local resume bookmark.
public struct RecordingResumeEntry: Codable, Equatable, Sendable {
    public let seconds: Double
    public let updatedAt: Date

    public init(seconds: Double, updatedAt: Date = Date()) {
        self.seconds = seconds
        self.updatedAt = updatedAt
    }
}

/// Pure validation and completion rules shared by the app and tests.
public enum RecordingResumePolicy {
    public static let minimumCandidateSeconds = 5.0

    /// Returns a finite, non-negative position, capped just before a known
    /// duration so AVPlayer is not asked to seek exactly at EOF.
    public static func clamp(seconds: Double, duration: Double?) -> Double? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let nonNegative = max(0, seconds)
        guard let duration, duration.isFinite, duration > 0 else {
            return nonNegative
        }
        let maximum = max(0, duration - 0.25)
        return min(nonNegative, maximum)
    }

    /// Returns a user-visible continuation point only when it is meaningful.
    /// Near-end clearing is status-sensitive and is handled by `shouldClear`.
    public static func candidate(
        entry: RecordingResumeEntry,
        duration: Double?,
        status: String? = nil
    ) -> Double? {
        guard let value = clamp(seconds: entry.seconds, duration: duration),
              value >= minimumCandidateSeconds else { return nil }
        if shouldClear(seconds: value, duration: duration, status: status, reachedEnd: false) {
            return nil
        }
        return value
    }

    /// Determines whether a bookmark should be removed after a playback event.
    /// A growing recording is never considered complete, including when its
    /// current playlist reports an end notification.
    public static func shouldClear(
        seconds: Double,
        duration: Double?,
        status: String?,
        reachedEnd: Bool
    ) -> Bool {
        if status == "Recording" { return false }
        if reachedEnd { return true }
        guard status == "Recorded",
              let duration,
              duration.isFinite,
              duration > 0,
              let value = clamp(seconds: seconds, duration: duration) else {
            return false
        }
        let remaining = max(0, duration - value)
        let tolerance = max(5, min(30, duration * 0.02))
        return remaining <= tolerance
    }
}

/// Codable bookmark state for the App's UserDefaults adapter.
///
/// Decoding is intentionally per-entry: a corrupt bookmark does not discard
/// every other recording's position. The state is bounded to the newest 200
/// entries to keep the local preference payload small.
public struct RecordingResumeArchive: Codable, Equatable, Sendable {
    public private(set) var entries: [String: RecordingResumeEntry]
    public static let defaultMaximumEntries = 200

    public init(
        entries: [String: RecordingResumeEntry] = [:],
        maximumEntries: Int = RecordingResumeArchive.defaultMaximumEntries
    ) {
        self.entries = Self.bounded(entries, maximumEntries: maximumEntries)
    }

    public func entry(for storageKey: String) -> RecordingResumeEntry? {
        entries[storageKey]
    }

    public mutating func set(
        _ entry: RecordingResumeEntry,
        for storageKey: String,
        maximumEntries: Int = RecordingResumeArchive.defaultMaximumEntries
    ) {
        guard RecordingResumePolicy.clamp(seconds: entry.seconds, duration: nil) != nil else {
            entries.removeValue(forKey: storageKey)
            return
        }
        entries[storageKey] = entry
        entries = Self.bounded(entries, maximumEntries: maximumEntries)
    }

    public mutating func remove(for storageKey: String) {
        entries.removeValue(forKey: storageKey)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var decoded: [String: RecordingResumeEntry] = [:]
        for key in container.allKeys {
            guard let entry = try? container.decode(RecordingResumeEntry.self, forKey: key),
                  RecordingResumePolicy.clamp(seconds: entry.seconds, duration: nil) != nil else {
                continue
            }
            decoded[key.stringValue] = entry
        }
        self.entries = Self.bounded(decoded, maximumEntries: Self.defaultMaximumEntries)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, entry) in entries {
            try container.encode(entry, forKey: DynamicCodingKey(key))
        }
    }

    private static func bounded(
        _ source: [String: RecordingResumeEntry],
        maximumEntries: Int
    ) -> [String: RecordingResumeEntry] {
        let limit = max(0, maximumEntries)
        let valid = source.filter { RecordingResumePolicy.clamp(seconds: $0.value.seconds, duration: nil) != nil }
        guard valid.count > limit else { return valid }
        return Dictionary(uniqueKeysWithValues: valid
            .sorted {
                if $0.value.updatedAt != $1.value.updatedAt {
                    return $0.value.updatedAt > $1.value.updatedAt
                }
                return $0.key < $1.key
            }
            .prefix(limit)
            .map { ($0.key, $0.value) })
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
