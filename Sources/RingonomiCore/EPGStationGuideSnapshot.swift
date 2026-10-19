import Foundation

/// A guide response that keeps the display model and the original
/// EPGStation program objects together.
///
/// ``ProgramGuideResponse`` is convenient for the common guide grid, while
/// ``sourcePrograms`` lets a reservation flow recover EPGStation's numeric
/// program/channel identifiers and millisecond timestamps without parsing a
/// namespaced display identifier back into an integer.
public struct EPGStationGuideSnapshot: Sendable, Equatable {
    public let response: ProgramGuideResponse
    public let sourcePrograms: [String: EPGStationScheduleProgram]

    public init(schedules: [EPGStationSchedule]) throws {
        var channelIDs = Set<Int>(minimumCapacity: schedules.count)
        var programIDs = Set<Int>()
        var guideChannels: [GuideChannelPrograms] = []
        var sourcePrograms: [String: EPGStationScheduleProgram] = [:]

        guideChannels.reserveCapacity(schedules.count)

        for schedule in schedules {
            let sourceChannel = schedule.channel
            guard channelIDs.insert(sourceChannel.id).inserted else {
                throw EPGStationError.invalidResponse
            }

            let guideChannelID = Self.channelID(sourceChannel.id)
            let guideChannel = GuideChannel(
                id: guideChannelID,
                displayChannelId: String(sourceChannel.id),
                networkId: sourceChannel.networkID,
                serviceId: sourceChannel.serviceID,
                transportStreamId: nil,
                remoconId: sourceChannel.remoteControlKeyID,
                channelNumber: sourceChannel.remoteControlKeyID.map { String($0) } ?? "",
                type: sourceChannel.channelType,
                name: sourceChannel.name,
                terrestrialRegions: [],
                jikkyoForce: nil,
                isSubchannel: false,
                isRadiochannel: false,
                // EPGStation live playback is not connected to this guide yet.
                isWatchable: false,
                isDisplay: true
            )

            var guidePrograms: [GuideProgram] = []
            guidePrograms.reserveCapacity(schedule.programs.count)

            for sourceProgram in schedule.programs {
                guard sourceProgram.channelID == sourceChannel.id,
                      programIDs.insert(sourceProgram.id).inserted,
                      let startDate = Self.date(milliseconds: sourceProgram.startAt),
                      let endDate = Self.date(milliseconds: sourceProgram.endAt) else {
                    throw EPGStationError.invalidResponse
                }

                let guideProgramID = Self.programID(sourceProgram.id)
                let guideProgram = GuideProgram(
                    id: guideProgramID,
                    channelId: guideChannelID,
                    networkId: sourceChannel.networkID,
                    serviceId: sourceChannel.serviceID,
                    eventId: nil,
                    title: sourceProgram.name,
                    description: sourceProgram.description ?? "",
                    detail: Self.detail(for: sourceProgram),
                    startDate: startDate,
                    endDate: endDate,
                    duration: (sourceProgram.endAt - sourceProgram.startAt) / 1000,
                    isFree: sourceProgram.isFree,
                    genres: Self.genres(for: sourceProgram),
                    videoType: nil,
                    videoCodec: nil,
                    videoResolution: nil,
                    primaryAudioType: "",
                    primaryAudioLanguage: "",
                    primaryAudioSamplingRate: "",
                    secondaryAudioType: nil,
                    secondaryAudioLanguage: nil,
                    secondaryAudioSamplingRate: nil,
                    reservation: nil
                )

                guidePrograms.append(guideProgram)
                sourcePrograms[guideProgramID] = sourceProgram
            }

            // Keep the server's channel and program order.  The grid performs
            // its own time sort after this lossless conversion.
            guideChannels.append(
                GuideChannelPrograms(channel: guideChannel, programs: guidePrograms)
            )
        }

        self.response = ProgramGuideResponse(channels: guideChannels)
        self.sourcePrograms = sourcePrograms
    }

    /// Namespaced IDs keep numeric EPGStation identifiers separate from
    /// KonomiTV/EDCB identifiers used by the other guide.
    private static func channelID(_ value: Int) -> String {
        "epgstation.channel.\(value)"
    }

    private static func programID(_ value: Int) -> String {
        "epgstation.program.\(value)"
    }

    private static func date(milliseconds value: Double) -> Date? {
        guard value.isFinite,
              value >= 0,
              value <= Double(EPGStationValueRules.maximumSafeJSONInteger) else {
            return nil
        }
        let seconds = value / 1000
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func detail(for program: EPGStationScheduleProgram) -> [String: String] {
        var detail = program.rawExtended ?? [:]

        // rawExtended is an arbitrary server-keyed dictionary.  Use a
        // reserved, collision-safe key for the separate extended string so
        // neither representation overwrites the other.
        if let extended = program.extended {
            let baseKey = "EPGStation:extended"
            var key = baseKey
            var suffix = 1
            while detail[key] != nil {
                key = "\(baseKey)#\(suffix)"
                suffix += 1
            }
            detail[key] = extended
        }
        return detail
    }

    private static func genres(for program: EPGStationScheduleProgram) -> [GuideGenre] {
        [
            (program.genre1, program.subGenre1),
            (program.genre2, program.subGenre2),
            (program.genre3, program.subGenre3)
        ].compactMap { major, subGenre in
            guard major != nil || subGenre != nil else { return nil }

            let majorName = major.flatMap(Self.majorGenreName) ?? ""
            let middle = subGenre.map { "EPGStation subGenre \($0)" } ?? ""

            // An unknown major code is retained by sourcePrograms but is not
            // given a made-up Japanese name in the normalized display model.
            guard major == nil || !majorName.isEmpty else { return nil }
            return GuideGenre(major: majorName, middle: middle)
        }
    }

    /// ARIB major genre names used by EPGStation's rule editor.
    private static func majorGenreName(_ value: Int) -> String? {
        switch value {
        case 0: return "ニュース・報道"
        case 1: return "スポーツ"
        case 2: return "情報・ワイドショー"
        case 3: return "ドラマ"
        case 4: return "音楽"
        case 5: return "バラエティ"
        case 6: return "映画"
        case 7: return "アニメ・特撮"
        case 8: return "ドキュメンタリー・教養"
        case 9: return "劇場・公演"
        case 10: return "趣味・教育"
        case 11: return "福祉"
        case 12, 13: return "予約"
        case 14: return "拡張"
        case 15: return "その他"
        default: return nil
        }
    }
}
