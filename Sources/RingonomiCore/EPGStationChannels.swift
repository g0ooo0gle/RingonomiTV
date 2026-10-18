import Foundation

/// A channel returned by EPGStation.
public struct EPGStationChannel: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let halfWidthName: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, halfWidthName
    }

    public init(
        id: Int,
        name: String,
        halfWidthName: String? = nil
    ) throws {
        guard EPGStationValueRules.isPositiveIdentifier(id),
              EPGStationValueRules.isSafeText(name, maximumBytes: 16 * 1024, allowEmpty: false),
              halfWidthName.map({ EPGStationValueRules.isSafeText($0, maximumBytes: 16 * 1024) }) ?? true else {
            throw EPGStationError.invalidResponse
        }
        self.id = id
        self.name = name
        self.halfWidthName = halfWidthName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(Int.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            halfWidthName: container.decodeIfPresent(String.self, forKey: .halfWidthName)
        )
    }
}
