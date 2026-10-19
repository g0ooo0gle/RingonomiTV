import Foundation

/// A display-ready guide assembled from the services and programs returned by
/// Mirakurun.  The source models remain available so a caller can build a
/// stream or service action without parsing a namespaced guide identifier.
public struct MirakurunGuideSnapshot: Sendable, Equatable {
    public let response: ProgramGuideResponse
    public let services: [MirakurunService]
    public let programs: [MirakurunProgram]
    public let servicesByChannelID: [String: MirakurunService]
    public let programsByID: [String: MirakurunProgram]
    public let startDate: Date
    public let endDate: Date

    /// Build a guide for the half-open date interval `[startDate, endDate)`.
    ///
    /// Mirakurun returns milliseconds since the Unix epoch.  Programs with a
    /// zero duration are kept in the source response by the API, but cannot
    /// occupy a guide cell and are therefore omitted from the display model.
    /// All other programs must belong to one of the supplied services before
    /// date filtering is applied; silently placing a program in the wrong
    /// channel would make a later stream selection unsafe.
    public init(
        services: [MirakurunService],
        programs: [MirakurunProgram],
        startDate: Date,
        endDate: Date
    ) throws {
        let startSeconds = startDate.timeIntervalSince1970
        let endSeconds = endDate.timeIntervalSince1970
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              endSeconds > startSeconds else {
            throw MirakurunError.invalidResponse
        }

        var serviceIDs = Set<Int>(minimumCapacity: services.count)
        var serviceByItemID: [Int: MirakurunService] = [:]
        serviceByItemID.reserveCapacity(services.count)
        for service in services {
            guard serviceIDs.insert(service.id).inserted,
                  serviceByItemID[service.id] == nil else {
                throw MirakurunError.invalidResponse
            }
            serviceByItemID[service.id] = service
        }

        var programIDs = Set<Int>(minimumCapacity: programs.count)
        var filteredPrograms: [MirakurunProgram] = []
        filteredPrograms.reserveCapacity(programs.count)
        var sourcePrograms: [String: MirakurunProgram] = [:]
        sourcePrograms.reserveCapacity(programs.count)

        for program in programs {
            guard programIDs.insert(program.id).inserted,
                  let serviceItemID = MirakurunServiceKey.serviceItemID(
                      networkID: program.networkID,
                      serviceID: program.serviceID
                  ),
                  serviceByItemID[serviceItemID] != nil else {
                throw MirakurunError.invalidResponse
            }

            // Keep every validated source record for later service/detail
            // actions, including events outside the selected day and the
            // zero-duration records that cannot occupy a grid cell.
            sourcePrograms[Self.programID(program.id)] = program

            // A zero-duration event has no visual interval.  Drop it after
            // validating its service identity so malformed cross-service data
            // can never be hidden by display filtering.
            guard program.duration > 0 else { continue }
            let programStart = program.startAt / 1000
            let programEnd = program.endAt / 1000
            guard programStart.isFinite,
                  programEnd.isFinite,
                  programEnd > programStart else {
                throw MirakurunError.invalidResponse
            }
            guard programStart < endSeconds, programEnd > startSeconds else {
                continue
            }

            filteredPrograms.append(program)
        }

        var guideChannels: [GuideChannelPrograms] = []
        guideChannels.reserveCapacity(services.count)
        var servicesByChannelID: [String: MirakurunService] = [:]
        servicesByChannelID.reserveCapacity(services.count)

        for service in services {
            let guideChannelID = Self.channelID(service.id)
            let guideChannel = Self.guideChannel(for: service, id: guideChannelID)
            servicesByChannelID[guideChannelID] = service

            let guidePrograms = filteredPrograms.compactMap { program -> GuideProgram? in
                guard let serviceItemID = MirakurunServiceKey.serviceItemID(
                    networkID: program.networkID,
                    serviceID: program.serviceID
                ), serviceItemID == service.id else { return nil }
                return Self.guideProgram(for: program, channelID: guideChannelID)
            }
            guideChannels.append(
                GuideChannelPrograms(channel: guideChannel, programs: guidePrograms)
            )
        }

        self.response = ProgramGuideResponse(
            channels: guideChannels,
            dateRange: ProgramGuideDateRange(earliest: startDate, latest: endDate)
        )
        self.services = services
        self.programs = filteredPrograms
        self.servicesByChannelID = servicesByChannelID
        self.programsByID = sourcePrograms
        self.startDate = startDate
        self.endDate = endDate
    }

    /// The namespaced ID used by `GuideChannel.id` for a Mirakurun service.
    public static func channelID(for service: MirakurunService) -> String {
        channelID(service.id)
    }

    /// The namespaced ID used by `GuideProgram.id` for a Mirakurun program.
    public static func programID(for program: MirakurunProgram) -> String {
        programID(program.id)
    }

    private static func channelID(_ id: Int) -> String {
        "mirakurun.service.\(id)"
    }

    private static func programID(_ id: Int) -> String {
        "mirakurun.program.\(id)"
    }

    private static func guideChannel(for service: MirakurunService, id: String) -> GuideChannel {
        GuideChannel(
            id: id,
            displayChannelId: String(service.id),
            networkId: service.networkID,
            serviceId: service.serviceID,
            transportStreamId: service.transportStreamID,
            remoconId: service.remoteControlKeyID,
            channelNumber: service.channel?.channel ?? "",
            type: service.channel?.type ?? "",
            name: service.name,
            terrestrialRegions: [],
            jikkyoForce: nil,
            isSubchannel: false,
            isRadiochannel: false,
            isWatchable: true,
            isDisplay: true
        )
    }

    private static func guideProgram(
        for program: MirakurunProgram,
        channelID: String
    ) -> GuideProgram {
        let startDate = Date(timeIntervalSince1970: program.startAt / 1000)
        let endDate = Date(timeIntervalSince1970: program.endAt / 1000)
        let mainAudio = program.audios.first(where: { $0.isMain == true }) ?? program.audios.first
        let secondaryAudio = program.audios.first(where: { $0.isMain == false })

        return GuideProgram(
            id: programID(program.id),
            channelId: channelID,
            networkId: program.networkID,
            serviceId: program.serviceID,
            eventId: program.eventID,
            title: program.name ?? "",
            description: program.description ?? "",
            detail: program.extended ?? [:],
            startDate: startDate,
            endDate: endDate,
            duration: program.duration / 1000,
            isFree: program.isFree,
            genres: genres(for: program.genres),
            videoType: program.video?.type,
            videoCodec: nil,
            videoResolution: program.video?.resolution,
            primaryAudioType: audioType(mainAudio),
            primaryAudioLanguage: audioLanguage(mainAudio),
            primaryAudioSamplingRate: audioSamplingRate(mainAudio),
            secondaryAudioType: audioTypeOptional(secondaryAudio),
            secondaryAudioLanguage: audioLanguageOptional(secondaryAudio),
            secondaryAudioSamplingRate: audioSamplingRateOptional(secondaryAudio),
            reservation: nil
        )
    }

    private static func genres(for source: [MirakurunProgramGenre]) -> [GuideGenre] {
        source.compactMap { genre in
            let major = genre.lv1.flatMap(majorGenreName) ?? ""
            let middle = genre.lv2.map { "Mirakurun subGenre \($0)" } ?? ""
            guard !major.isEmpty || !middle.isEmpty else { return nil }
            return GuideGenre(major: major, middle: middle)
        }
    }

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

    private static func audioType(_ audio: MirakurunProgramAudio?) -> String {
        audio?.componentType.map(String.init) ?? ""
    }

    private static func audioLanguage(_ audio: MirakurunProgramAudio?) -> String {
        audio?.langs.first ?? ""
    }

    private static func audioSamplingRate(_ audio: MirakurunProgramAudio?) -> String {
        audio?.samplingRate.map(String.init) ?? ""
    }

    private static func audioTypeOptional(_ audio: MirakurunProgramAudio?) -> String? {
        audio?.componentType.map(String.init)
    }

    private static func audioLanguageOptional(_ audio: MirakurunProgramAudio?) -> String? {
        audio?.langs.first
    }

    private static func audioSamplingRateOptional(_ audio: MirakurunProgramAudio?) -> String? {
        audio?.samplingRate.map(String.init)
    }
}
