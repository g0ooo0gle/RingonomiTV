import Foundation

/// The broadcast scope accepted by EPGStation's schedule endpoint.
///
/// The endpoint uses one Boolean query item per terrestrial, satellite, and
/// network channel group.  Keeping the scope as a closed type prevents a
/// caller from accidentally requesting an incomplete flag set.
public enum EPGStationGuideBroadcast: CaseIterable, Codable, Hashable, Sendable {
    case all
    case terrestrial
    case bs
    case cs
    case sky
    case bs4K
    case cs4K
}

private enum EPGStationGuideQuery {
    static let fixedFlags = ["GR", "BS", "CS", "SKY", "BS4K", "CS4K"]
    static let networkFlags = (1...40).map { "NW\($0)" }
    static let allFlags = fixedFlags + networkFlags
    static let maximumWindowMilliseconds: Double = 24 * 60 * 60 * 1_000

    static func isSafeMilliseconds(_ value: Double) -> Bool {
        value.isFinite &&
            value.rounded() == value &&
            value >= 0 &&
            value <= Double(EPGStationValueRules.maximumSafeJSONInteger)
    }

    static func enabledFlags(for scope: EPGStationGuideBroadcast) -> Set<String> {
        switch scope {
        case .all:
            return Set(allFlags)
        case .terrestrial:
            return Set(["GR"] + networkFlags)
        case .bs:
            return ["BS"]
        case .cs:
            return ["CS"]
        case .sky:
            return ["SKY"]
        case .bs4K:
            return ["BS4K"]
        case .cs4K:
            return ["CS4K"]
        }
    }
}

public extension EPGStationClient {
    /// Fetch EPGStation's channel-grouped program guide for a bounded range.
    ///
    /// `startAt` and `endAt` are Unix timestamps in milliseconds.  The
    /// server may return programs that overlap the requested range; preserving
    /// those entries is important for a guide row that spans either boundary.
    func programGuide(
        startAt: Double,
        endAt: Double,
        broadcast: EPGStationGuideBroadcast = .all
    ) async throws -> [EPGStationSchedule] {
        guard EPGStationGuideQuery.isSafeMilliseconds(startAt),
              EPGStationGuideQuery.isSafeMilliseconds(endAt),
              endAt > startAt,
              endAt - startAt <= EPGStationGuideQuery.maximumWindowMilliseconds else {
            throw EPGStationError.invalidRequest
        }

        let enabledFlags = EPGStationGuideQuery.enabledFlags(for: broadcast)
        var queryItems = [
            URLQueryItem(name: "startAt", value: String(Int(startAt))),
            URLQueryItem(name: "endAt", value: String(Int(endAt))),
            URLQueryItem(name: "isHalfWidth", value: "true"),
            URLQueryItem(name: "needsRawExtended", value: "true")
        ]
        queryItems.append(contentsOf: EPGStationGuideQuery.allFlags.map { flag in
            URLQueryItem(
                name: flag,
                value: enabledFlags.contains(flag) ? "true" : "false"
            )
        })

        let data = try await data(
            for: endpoint(["api", "schedules"], queryItems: queryItems)
        )

        do {
            let schedules = try JSONDecoder().decode([EPGStationSchedule].self, from: data)
            var channelIDs = Set<Int>(minimumCapacity: schedules.count)
            var programIDs = Set<Int>()
            for schedule in schedules {
                guard channelIDs.insert(schedule.channel.id).inserted else {
                    throw EPGStationError.invalidResponse
                }
                for program in schedule.programs {
                    guard program.channelID == schedule.channel.id,
                          programIDs.insert(program.id).inserted else {
                        throw EPGStationError.invalidResponse
                    }
                }
            }
            return schedules
        } catch let error as EPGStationError {
            throw error
        } catch {
            throw EPGStationError.invalidResponse
        }
    }
}
