import Foundation

public struct PlaybackAudioOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let preferenceKey: String?

    public init(id: String, name: String, preferenceKey: String? = nil) {
        self.id = id
        self.name = name
        self.preferenceKey = preferenceKey
    }
}

/// An engine track ID and its optional display label. Negative IDs denote
/// disabled audio in VLC and never become a selectable audio option.
public struct PlaybackAudioDescriptor: Equatable, Sendable {
    public let trackID: Int
    public let name: String?

    public init(trackID: Int, name: String?) {
        self.trackID = trackID
        self.name = name
    }
}

/// A generation-scoped view of the native audio tracks.
///
/// VLC may reuse an engine track identifier after a broadcast track list is
/// rebuilt.  A `PlaybackAudioOption` created by `PlaybackAudioCatalog.options`
/// intentionally remains source-scoped for compatibility, so controllers that
/// keep a menu open must use this type.  Its option IDs include the catalog
/// generation and therefore cannot be accepted after the native list changes.
public struct PlaybackAudioCatalogGeneration: Equatable, Sendable {
    public let sourceID: UUID
    public let generation: UInt64
    public let options: [PlaybackAudioOption]
    public let isUsable: Bool

    private let rawIDsByOptionID: [String: Int32]
    private let normalizedSignature: [NormalizedEntry]
    private let wasOversized: Bool

    fileprivate struct NormalizedEntry: Equatable, Sendable {
        let trackID: Int
        let name: String?
    }

    /// Creates the first generation for a native source. Empty and oversized
    /// lists are represented as unusable generations so a controller can drop
    /// pending/recovery state immediately instead of retaining stale IDs.
    public init(sourceID: UUID, descriptors: [PlaybackAudioDescriptor]) {
        self.init(sourceID: sourceID, descriptors: descriptors, generation: 1)
    }

    private init(sourceID: UUID,
                 descriptors: [PlaybackAudioDescriptor],
                 generation: UInt64) {
        self.sourceID = sourceID
        self.generation = generation
        self.wasOversized = descriptors.count > PlaybackAudioCatalog.maximumTracks

        let normalized = PlaybackAudioCatalog.normalizedEntries(from: descriptors)
        self.normalizedSignature = normalized

        guard !wasOversized else {
            self.options = []
            self.rawIDsByOptionID = [:]
            self.isUsable = false
            return
        }

        var builtOptions: [PlaybackAudioOption] = []
        var rawIDs: [String: Int32] = [:]
        builtOptions.reserveCapacity(normalized.count)
        for entry in normalized {
            // Native VLC track indices are Int32. Do not expose an option
            // that can never be sent back to the engine.
            guard let rawID = Int32(exactly: entry.trackID) else { continue }
            let optionID = PlaybackAudioCatalog.generationOptionID(
                sourceID: sourceID,
                generation: generation,
                trackID: entry.trackID
            )
            let displayName = entry.name ?? "音声 \(builtOptions.count + 1)"
            let option = PlaybackAudioOption(
                id: optionID,
                name: displayName,
                preferenceKey: entry.name
            )
            builtOptions.append(option)
            rawIDs[optionID] = rawID
        }
        self.options = builtOptions
        self.rawIDsByOptionID = rawIDs
        self.isUsable = !builtOptions.isEmpty
    }

    /// Returns this generation unchanged for an identical normalized catalog,
    /// or a new generation when source, track ID, label, or order changes.
    public func replacing(sourceID: UUID,
                          descriptors: [PlaybackAudioDescriptor]) -> Self {
        let candidateSignature = PlaybackAudioCatalog.normalizedEntries(from: descriptors)
        let candidateOversized = descriptors.count > PlaybackAudioCatalog.maximumTracks
        guard sourceID != self.sourceID
                || candidateSignature != normalizedSignature
                || candidateOversized != wasOversized else {
            return self
        }
        return Self(sourceID: sourceID,
                    descriptors: descriptors,
                    generation: generation &+ 1)
    }

    /// The native ID corresponding to a current-generation option ID.
    public func rawID(for optionID: String) -> Int32? {
        rawIDsByOptionID[optionID]
    }

    /// Returns whether an option/raw-ID pair belongs to this exact generation.
    public func contains(optionID: String, rawID: Int32? = nil) -> Bool {
        guard let mapped = rawIDsByOptionID[optionID] else { return false }
        return rawID == nil || rawID == mapped
    }

    public var isEmpty: Bool { options.isEmpty }
    public var isOversized: Bool { wasOversized }
}

/// The choice is restored by a unique label, never by a reused engine ID.
public enum PlaybackAudioPreferenceMatch: Equatable, Sendable {
    case notRequested
    case matched(id: String)
    case missing
    case ambiguous

    public var selectedID: String? {
        if case .matched(let id) = self { return id }
        return nil
    }

    /// A nonfatal notice: the engine's current audio remains available.
    public var notice: String? {
        switch self {
        case .missing:
            return "選択していた音声はこの配信では利用できません。現在の音声を確認してください。"
        case .ambiguous:
            return "同じ名前の音声が複数あるため復元できません。音声を選び直してください。"
        case .notRequested, .matched:
            return nil
        }
    }
}

public enum PlaybackAudioCatalog {
    public static let maximumTracks = 64

    fileprivate static func generationOptionID(sourceID: UUID,
                                                generation: UInt64,
                                                trackID: Int) -> String {
        "\(sourceID.uuidString):g\(generation):\(trackID)"
    }

    fileprivate static func normalizedEntries(from descriptors: [PlaybackAudioDescriptor])
        -> [PlaybackAudioCatalogGeneration.NormalizedEntry] {
        var seen = Set<Int>()
        return descriptors.compactMap { descriptor in
            guard descriptor.trackID >= 0,
                  seen.insert(descriptor.trackID).inserted else { return nil }
            let name = descriptor.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .init(trackID: descriptor.trackID, name: name.isEmpty ? nil : name)
        }
    }

    /// The source identity prevents a menu left open during a reload from
    /// selecting an unrelated track whose engine ID happens to be reused.
    public static func options(sourceID: UUID, descriptors: [PlaybackAudioDescriptor]) -> [PlaybackAudioOption] {
        guard descriptors.count <= maximumTracks else { return [] }
        return normalizedEntries(from: descriptors).enumerated().map { offset, entry in
            PlaybackAudioOption(id: "\(sourceID.uuidString):\(entry.trackID)",
                                name: entry.name ?? "音声 \(offset + 1)",
                                preferenceKey: entry.name)
        }
    }

    /// Restore a user choice only when the label identifies exactly one
    /// track in the new stream. Otherwise the engine keeps its default.
    public static func preferredID(named name: String?, in options: [PlaybackAudioOption]) -> String? {
        preferenceMatch(named: name, in: options).selectedID
    }

    public static func preferenceMatch(named name: String?, in options: [PlaybackAudioOption]) -> PlaybackAudioPreferenceMatch {
        guard let name else { return .notRequested }
        let matches = options.filter { $0.preferenceKey == name }
        guard let first = matches.first else { return .missing }
        return matches.count == 1 ? .matched(id: first.id) : .ambiguous
    }
}
