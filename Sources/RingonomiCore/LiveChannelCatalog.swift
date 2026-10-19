import Foundation

/// The broadcast family used by the live-channel picker.
public enum LiveChannelBroadcast: String, CaseIterable, Codable, Sendable {
    case all
    case gr
    case bs
    case cs
    case catv
    case sky
    case bs4k
    case other

    public var title: String {
        switch self {
        case .all: return "すべて"
        case .gr: return "地上波"
        case .bs: return "BS"
        case .cs: return "CS"
        case .catv: return "CATV"
        case .sky: return "SKY"
        case .bs4k: return "BS4K"
        case .other: return "その他"
        }
    }
}

/// The local order used for the live-channel picker.
public enum LiveChannelSortOrder: String, CaseIterable, Codable, Sendable {
    case serverOrder
    case name
    case favoritesFirst

    public var title: String {
        switch self {
        case .serverOrder: return "サーバー順"
        case .name: return "名前順"
        case .favoritesFirst: return "お気に入りを先頭"
        }
    }
}

/// Local-only live-channel filtering and sorting options.
public struct LiveChannelQuery: Equatable, Sendable {
    public let search: String
    public let broadcast: LiveChannelBroadcast
    public let favoritesOnly: Bool
    public let sort: LiveChannelSortOrder

    public init(
        search: String = "",
        broadcast: LiveChannelBroadcast = .all,
        favoritesOnly: Bool = false,
        sort: LiveChannelSortOrder = .serverOrder
    ) {
        self.search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        self.broadcast = broadcast
        self.favoritesOnly = favoritesOnly
        self.sort = sort
    }
}

/// Pure filtering and ordering for the KonomiTV live-channel list.
///
/// The server response remains the source of truth. This helper only applies
/// local preferences, so it can be used by tvOS UI code without another
/// network request or a retained catalog.
public enum LiveChannelCatalog {
    public static func channels(
        _ channels: [Channel],
        query: LiveChannelQuery = LiveChannelQuery(),
        favoriteIDs: Set<String> = []
    ) -> [Channel] {
        let terms = searchTerms(query.search)
        var result: [(index: Int, channel: Channel)] = []
        var seenDisplayIDs = Set<String>(minimumCapacity: channels.count)
        result.reserveCapacity(channels.count)

        for (index, channel) in channels.enumerated() {
            guard channel.isWatchable, channel.isDisplay else { continue }
            // A filter must not replace the first server record with a
            // conflicting duplicate of the same channel.
            guard seenDisplayIDs.insert(channel.displayChannelId).inserted else { continue }
            guard query.broadcast == .all || broadcast(for: channel) == query.broadcast else { continue }
            guard !query.favoritesOnly || favoriteIDs.contains(channel.displayChannelId) else { continue }
            if !terms.isEmpty {
                let searchable = searchableText(for: channel)
                guard terms.allSatisfy({ searchable.contains($0) }) else { continue }
            }
            result.append((index, channel))
        }

        switch query.sort {
        case .serverOrder:
            break
        case .name:
            result.sort { lhs, rhs in
                let comparison = lhs.channel.name.localizedStandardCompare(rhs.channel.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.index < rhs.index
            }
        case .favoritesFirst:
            // Stable partition: a user's server order is preserved within
            // both the favorite and non-favorite sections.
            result = result.filter { favoriteIDs.contains($0.channel.displayChannelId) }
                + result.filter { !favoriteIDs.contains($0.channel.displayChannelId) }
        }

        return result.map { $0.channel }
    }

    /// Resolves the API type first, then uses channel-number/display-ID
    /// prefixes for older responses that omit type metadata.
    public static func broadcast(for channel: Channel) -> LiveChannelBroadcast {
        if let type = normalized(channel.type),
           let resolved = broadcast(forPrefix: type) {
            return resolved
        }
        for value in [channel.channelNumber, channel.displayChannelId].compactMap(normalized) {
            if let resolved = broadcast(forPrefix: value) { return resolved }
        }
        return .other
    }

    private static func searchTerms(_ value: String) -> [String] {
        let normalized = folded(value)
        return normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func searchableText(for channel: Channel) -> String {
        [channel.name, channel.displayChannelId, channel.channelNumber ?? "", channel.programPresent?.title ?? ""]
            .map { folded($0) }
            .joined(separator: " ")
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "ja_JP")
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func broadcast(forPrefix value: String) -> LiveChannelBroadcast? {
        let prefix = folded(value).uppercased()
        // BS4K must precede BS because it has the latter as a prefix.
        if prefix.hasPrefix("BS4K") { return .bs4k }
        if prefix.hasPrefix("CATV") { return .catv }
        if prefix.hasPrefix("SKY") { return .sky }
        if prefix.hasPrefix("GR") { return .gr }
        if prefix.hasPrefix("BS") { return .bs }
        if prefix.hasPrefix("CS") { return .cs }
        return nil
    }
}
