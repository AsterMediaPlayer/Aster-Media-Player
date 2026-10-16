//
//  ChannelGuideSource.swift
//  AsterFIN
//
//  The Channels tab's guide listings, worked out from each channel's
//  schedule rather than fetched, in the shape the Live TV guide draws:
//  a channel item per playlist and a programme item per scheduled movie or
//  episode.
//

import Foundation
import Observation

@Observable
final class ChannelGuideSource: GuideSource {
    let guideStart: Date
    let guideEnd: Date
    /// One guide channel per playlist channel, in channel order.
    let channels: [BaseItem]
    let programs: [String: [BaseItem]]

    private let scheduled: [String: ScheduledProgram]
    private let programIndex: [String: BaseItem]

    init(channels playlistChannels: [PlaylistChannel], now: Date = Date()) {
        let start = GuideModel.floorToHalfHour(now)
        let end = start.addingTimeInterval(24 * 3600)
        guideStart = start
        guideEnd = end

        var channels: [BaseItem] = []
        var programs: [String: [BaseItem]] = [:]
        var scheduled: [String: ScheduledProgram] = [:]
        var programIndex: [String: BaseItem] = [:]
        for channel in playlistChannels {
            var item = BaseItem(id: channel.id, name: channel.name, type: "TvChannel")
            item.channelNumber = "\(channel.number)"
            channels.append(item)

            let row = channel.programs(from: start, to: end).map { program in
                let listing = Self.listing(for: program)
                scheduled[listing.id] = program
                programIndex[listing.id] = listing
                return listing
            }
            programs[channel.id] = row
        }
        self.channels = channels
        self.programs = programs
        self.scheduled = scheduled
        self.programIndex = programIndex
    }

    /// The scheduled movie or episode behind a guide programme.
    func scheduledProgram(withId id: String) -> ScheduledProgram? {
        scheduled[id]
    }

    /// The item with the programme's own id and times, so the guide's cells
    /// tell repeats apart and place it in the timeline. It keeps the item's
    /// overview and the rest for the panel. An episode is listed as the
    /// series, with the episode's name under it, as a TV guide does.
    private static func listing(for program: ScheduledProgram) -> BaseItem {
        var item = program.item
        if item.kind == .episode, let series = item.seriesName {
            item.episodeTitle = item.name
            item.name = series
        }
        item.id = program.id
        item.channelId = program.channelId
        item.startDate = JellyfinDate.string(program.start)
        item.endDate = JellyfinDate.string(program.end)
        return item
    }

    // MARK: GuideSource

    func program(withId id: String) -> BaseItem? {
        programIndex[id]
    }

    func channelId(forProgram id: String) -> String? {
        scheduled[id]?.channelId
    }

    func airingProgram(for channelId: String) -> BaseItem? {
        programs[channelId]?.first { $0.isAiringNow }
    }

    /// Listings already carry everything there is.
    func detail(for program: BaseItem) -> BaseItem { program }
    func hasDetail(for programId: String) -> Bool { true }
    func ensureDetail(for programId: String, client: JellyfinClient) {}
    func ensurePrograms(for channelId: String, client: JellyfinClient) {}

    /// The item's own wide art (an episode's still), looked up by its real id.
    func programImageURL(_ program: BaseItem, width: Int, client: JellyfinClient) -> URL? {
        guard let item = scheduled[program.id]?.item else { return nil }
        return client.landscapeURL(for: item, width: width)
    }

    /// Playlists' pictures are usually a collage, so channels show their name.
    func channelLogoURL(_ channel: BaseItem, width: Int, client: JellyfinClient) -> URL? { nil }
}
