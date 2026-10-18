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

public enum PlaybackAudioCatalog {
    public static let maximumTracks = 64

    /// The source identity prevents a menu left open during a reload from
    /// selecting an unrelated track whose engine ID happens to be reused.
    public static func options(sourceID: UUID, descriptors: [PlaybackAudioDescriptor]) -> [PlaybackAudioOption] {
        guard descriptors.count <= maximumTracks else { return [] }
        var seen = Set<Int>()
        return descriptors.compactMap { descriptor in
            guard descriptor.trackID >= 0, seen.insert(descriptor.trackID).inserted else { return nil }
            let name = descriptor.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PlaybackAudioOption(id: "\(sourceID.uuidString):\(descriptor.trackID)",
                                       name: name.isEmpty ? "音声 \(seen.count)" : name,
                                       preferenceKey: name.isEmpty ? nil : name)
        }
    }

    /// Restore a user choice only when the label identifies exactly one
    /// track in the new stream. Otherwise the engine keeps its default.
    public static func preferredID(named name: String?, in options: [PlaybackAudioOption]) -> String? {
        guard let name else { return nil }
        let matches = options.filter { $0.preferenceKey == name }
        return matches.count == 1 ? matches[0].id : nil
    }
}
