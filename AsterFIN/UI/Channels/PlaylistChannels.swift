//
//  PlaylistChannels.swift
//  AsterFIN
//
//  The Channels tab's channels: Jellyfin video playlists tagged as channels
//  (see `ChannelTags`), so every device finds the same ones. Each plays its
//  movies and episodes on a schedule worked out from the clock (see
//  `ChannelSchedule`).
//

import Foundation
import Observation

/// A playlist as a channel: its number and name, the movies and episodes it
/// plays, and how its shows take turns.
nonisolated struct PlaylistChannel: Identifiable, Hashable, Sendable {
    let playlist: BaseItem
    let number: Int
    let items: [BaseItem]
    var lineup = ChannelLineup()
    /// The guide shows the playlist's picture as the channel's logo.
    var showsLogo = false
    /// The players show the playlist's picture in a corner, as a network's bug.
    var showsBug = false
    var bugCorner: BugCorner = .bottomRight
    /// The bug's size, as a percentage of the usual.
    var bugSize = 100
    /// Seconds the bug shows after tuning in or a programme starting; 0 for always.
    var bugHideAfter = 0
    /// How solid the bug is, in percent.
    var bugOpacity = ChannelTags.defaultBugOpacity
    /// From the `channel-name=` tag; nil for the playlist's own name.
    var customName: String?
    /// The bumpers, promos and interstitials its breaks play; none for a
    /// channel without breaks.
    var breakClips = ChannelBreakClips.none
    /// The series' clear logo, when the playlist is all one series' episodes:
    /// the channel's logo and bug then, rather than the playlist's picture.
    var seriesLogo: SeriesLogo?

    nonisolated struct SeriesLogo: Hashable, Sendable {
        let itemId: String
        let tag: String
    }

    var id: String { playlist.id }

    /// The picture the channel's logo and bug show: its one series' clear
    /// logo, else the playlist's picture; nil with neither.
    func logoURL(client: JellyfinClient, maxWidth: Int) -> URL? {
        if let seriesLogo {
            return client.imageURL(itemId: seriesLogo.itemId, kind: .logo, tag: seriesLogo.tag, maxWidth: maxWidth)
        }
        return playlist.imageTags?["Primary"].map {
            client.imageURL(itemId: playlist.id, kind: .primary, tag: $0, maxWidth: maxWidth)
        }
    }

    /// The clear logo of the one series `items` are all episodes of; nil for
    /// a playlist with movies, several series, or a series without a logo.
    static func seriesLogo(of items: [BaseItem]) -> SeriesLogo? {
        guard let first = items.first, let seriesId = first.seriesId,
              items.allSatisfy({ $0.kind == .episode && $0.seriesId == seriesId }),
              let logoItem = items.lazy.compactMap(\.parentLogoItemId).first,
              let tag = items.lazy.compactMap(\.parentLogoImageTag).first else { return nil }
        return SeriesLogo(itemId: logoItem, tag: tag)
    }
    var name: String { customName ?? playlist.displayTitle }
    var mode: ChannelMode { lineup.mode }

    /// The programme on now, its break included, as the guide shows it.
    func airing(at date: Date = Date()) -> ScheduledProgram? {
        programs(from: date, to: date.addingTimeInterval(1)).first
    }

    /// The programmes, each with the break after it, as the guide shows them.
    func programs(from: Date, to: Date) -> [ScheduledProgram] {
        ChannelSchedule.programs(channelId: id, items: items, lineup: lineup, breaks: breakClips, from: from, to: to)
    }

    /// In a break: the programme it leads into; nil during a programme.
    func programmeAfterBreak(at date: Date = Date()) -> ScheduledProgram? {
        guard segment(at: date)?.role.isBreak == true, let current = airing(at: date) else { return nil }
        return airing(at: current.end)
    }

    /// What's playing now, programme or break clip, and from how far in.
    func segment(at date: Date = Date()) -> ScheduledProgram? {
        segments(from: date, to: date.addingTimeInterval(1)).first
    }

    /// Everything the channel plays, programmes and break clips alike.
    func segments(from: Date, to: Date) -> [ScheduledProgram] {
        ChannelSchedule.segments(channelId: id, items: items, lineup: lineup, breaks: breakClips, from: from, to: to)
    }
}

/// What's on a channel now, as something to play. The Channels tab registers
/// the channels it loads, and the players ask here what's next when a movie
/// or episode ends, so a channel stays with its schedule.
enum ChannelTuner {
    private static var channels: [String: PlaylistChannel] = [:]
    /// Seconds before a programme's end that tuning in starts the next one.
    static let tooLateToJoin: TimeInterval = 60
    /// The channels as last loaded, in channel-number order.
    private static var order: [String] = []

    /// Takes the full list the Channels tab loaded, in order.
    static func register(_ loaded: [PlaylistChannel]) {
        for channel in loaded { channels[channel.id] = channel }
        order = loaded.map(\.id)
    }

    /// The channels in number order, for flicking through them.
    static var orderedChannels: [PlaylistChannel] {
        order.compactMap { channels[$0] }
    }

    static func channel(_ id: String) -> PlaylistChannel? {
        channels[id]
    }

    /// What's on `channelId` at `date`, from as far in as it's got. Just
    /// after `finishedItemId` ends, a viewer who paused is a little behind
    /// the schedule and it may still be "on"; what follows it then plays
    /// from the start, rather than the last minutes of it again.
    static func live(channelId: String, at date: Date = Date(), after finishedItemId: String? = nil) -> (item: BaseItem, entry: PlaybackQueueItem)? {
        guard let channel = channels[channelId], var program = channel.segment(at: date) else { return nil }
        var offset = program.offset(at: date)
        // Joining with under a minute left (a quarter of a short clip)
        // starts what's next instead: the last seconds can fall after the
        // file's final keyframe, with nothing to start the picture from.
        let almostOver = program.end.timeIntervalSince(date) < min(Self.tooLateToJoin, program.duration / 4)
        if almostOver || (finishedItemId != nil && program.item.id == finishedItemId),
           let next = channel.segments(from: program.end, to: program.end.addingTimeInterval(1)).first {
            program = next
            offset = 0
        }
        var entry = PlaybackQueueItem(itemId: program.item.id, startTicks: Int64(offset * 10_000_000), channelId: channelId)
        // A clip cut short to land on the half hour stops where the
        // schedule says, not at its end.
        let length = TimeInterval(program.item.runTimeTicks ?? 0) / 10_000_000
        if program.role.isBreak, program.duration < length - 0.5 {
            entry.channelCutTicks = Int64(program.duration * 10_000_000)
        }
        return (program.item, entry)
    }
}

@Observable
final class ChannelsModel {
    private(set) var channels: [PlaylistChannel] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// Each channel's items as last fetched, with the playlist's item count
    /// then, so a big playlist isn't fetched again unless it changed.
    private var itemCache: [String: (count: Int?, items: [BaseItem])] = [:]
    /// Each genre channel's genre titles as last fetched: what was asked
    /// (genres, type, libraries) and how many the server had, so they're
    /// fetched again only when either changes.
    /// Each source channel's titles (movies and series) and what it plays
    /// from them, by playlist id, with the query that found them.
    private var sourceCache: [String: (query: String, titleIds: [String], items: [BaseItem])] = [:]
    /// Each series' episodes, by series id, shared by every channel playing it.
    private var episodeCache: [String: [BaseItem]] = [:]

    /// Finds the playlists tagged as channels and loads their movies and
    /// episodes, in channel-number order. A tagged playlist with neither is
    /// left out.
    /// Loads the channels `userName` gets (`aster:user=`), every one for nil.
    func load(client: JellyfinClient, userName: String? = nil, force: Bool = false) async {
        errorMessage = nil
        do {
            let playlists = try await client.playlists(mediaType: "Video")
            let tagged = Self.taggedChannels(in: playlists).filter { userName == nil || $0.tags.isShown(to: userName) }
            let numbers = ChannelTags.numbers(for: tagged.map { ($0.playlist.id, $0.tags.name ?? $0.playlist.displayTitle, $0.tags.number) })
            // The playlists of break clips the channels name, fetched with
            // the channels' own.
            let fillers = Dictionary(uniqueKeysWithValues: tagged.map { ($0.playlist.id, Self.fillerPlaylists(named: $0.tags, in: playlists)) })
            var wanted = tagged.map(\.playlist)
            for playlist in fillers.values.joined() where !wanted.contains(where: { $0.id == playlist.id }) {
                wanted.append(playlist)
            }
            let stale = wanted.filter { playlist in
                force || itemCache[playlist.id] == nil || itemCache[playlist.id]?.count != playlist.childCount
            }
            let fetched = await withTaskGroup(of: (String, [BaseItem]?).self) { group in
                for playlist in stale {
                    group.addTask { (playlist.id, try? await client.playlistItems(playlistId: playlist.id)) }
                }
                var found: [String: [BaseItem]] = [:]
                for await (id, items) in group { if let items { found[id] = items } }
                return found
            }
            for playlist in stale {
                if let items = fetched[playlist.id] { itemCache[playlist.id] = (playlist.childCount, items) }
            }
            await loadSources(for: tagged, client: client, force: force)
            let built = tagged.compactMap { entry -> PlaylistChannel? in
                let own = itemCache[entry.playlist.id]?.items ?? []
                let fromSources = entry.tags.hasSources ? (sourceCache[entry.playlist.id]?.items ?? []) : []
                let items = Self.merged(own, fromSources).filter { $0.kind == .movie || $0.kind == .episode }
                guard !items.isEmpty, let number = numbers[entry.playlist.id] else { return nil }
                let clips = entry.tags.hasBreaks
                    ? Self.breakClips(from: (fillers[entry.playlist.id] ?? []).flatMap { self.itemCache[$0.id]?.items ?? [] }, types: entry.tags.fillerTypes)
                    : .none
                return PlaylistChannel(
                    playlist: entry.playlist, number: number, items: items, lineup: entry.tags.lineup,
                    showsLogo: entry.tags.showsLogo, showsBug: entry.tags.showsBug, bugCorner: entry.tags.bugCorner, bugSize: entry.tags.bugSize,
                    bugHideAfter: entry.tags.bugHideAfter, bugOpacity: entry.tags.bugOpacity, customName: entry.tags.name,
                    breakClips: clips,
                    seriesLogo: PlaylistChannel.seriesLogo(of: items)
                )
            }
            .sorted { ($0.number, $0.name) < ($1.number, $1.name) }
            channels = built
            ChannelTuner.register(built)
        } catch {
            if channels.isEmpty { errorMessage = error.localizedDescription }
        }
        hasLoaded = true
    }

    /// Fetches what each channel's genres, networks and collections hold,
    /// where it has any: their movies and series (any of them), narrowed by
    /// its years, ratings and type, and its libraries for genres and
    /// networks. A series brings all its episodes. A channel whose titles
    /// haven't changed keeps what it had.
    private func loadSources(for tagged: [(playlist: BaseItem, tags: ChannelTags)], client: JellyfinClient, force: Bool) async {
        let sourceChannels = tagged.filter { $0.tags.hasSources }
        guard !sourceChannels.isEmpty else { return }
        if force { episodeCache = [:] }
        let needs = (genres: sourceChannels.contains { !$0.tags.genres.isEmpty },
                     networks: sourceChannels.contains { !$0.tags.networks.isEmpty },
                     collections: sourceChannels.contains { !$0.tags.collections.isEmpty })
        async let genreList = needs.genres ? (try? await client.videoGenres()) ?? [] : []
        async let studioList = needs.networks ? (try? await client.videoStudios()) ?? [] : []
        async let collectionList = needs.collections ? (try? await client.collections()) ?? [] : []
        async let libraryList = (try? await client.userViews()) ?? []
        let genreIds = Self.idsByName(await genreList)
        let studioIds = Self.idsByName(await studioList)
        let collectionIds = Self.idsByName(await collectionList)
        let libraryIds = Self.idsByName(await libraryList)

        // First the titles of every channel, which is quick.
        let titles = await withTaskGroup(of: (String, [BaseItem]?).self) { group in
            for entry in sourceChannels {
                let tags = entry.tags
                let genres = tags.genres.compactMap { genreIds[$0.lowercased()] }
                let studios = tags.networks.compactMap { studioIds[$0.lowercased()] }
                let collections = tags.collections.compactMap { collectionIds[$0.lowercased()] }
                // Libraries the server doesn't know are ignored; none left means all.
                let chosen = tags.libraries.compactMap { libraryIds[$0.lowercased()] }
                let parents: [String?] = chosen.isEmpty ? [nil] : chosen
                let types = tags.content.itemTypes
                group.addTask {
                    var found: [BaseItem] = []
                    do {
                        for parent in parents {
                            if !genres.isEmpty {
                                found = ChannelsModel.merged(found, try await client.sourceTitles(genreIds: genres, types: types, parentId: parent, years: tags.years, ratings: tags.ratings))
                            }
                            if !studios.isEmpty {
                                found = ChannelsModel.merged(found, try await client.sourceTitles(studioIds: studios, types: types, parentId: parent, years: tags.years, ratings: tags.ratings))
                            }
                        }
                        // A collection is filtered here, as Jellyfin's filters don't reach into it.
                        for collection in collections {
                            let held = try await client.collectionTitles(collection)
                            found = ChannelsModel.merged(found, held.filter { ChannelsModel.passes($0, tags) })
                        }
                    } catch {
                        return (entry.playlist.id, nil)
                    }
                    return (entry.playlist.id, found)
                }
            }
            var all: [String: [BaseItem]] = [:]
            for await (id, found) in group { if let found { all[id] = found } }
            return all
        }

        // Then the episodes of each series not already known, a few at a time.
        let wanted = Set(titles.values.joined().filter { $0.kind == .series }.map(\.id))
        let missing = Array(wanted.subtracting(episodeCache.keys))
        let fetched = await withTaskGroup(of: (String, [BaseItem]?).self) { group in
            var all: [String: [BaseItem]] = [:]
            var next = missing.makeIterator()
            for _ in 0..<6 {
                guard let id = next.next() else { break }
                group.addTask { (id, try? await client.seriesEpisodes(id)) }
            }
            for await (id, episodes) in group {
                if let episodes { all[id] = episodes }
                if let id = next.next() { group.addTask { (id, try? await client.seriesEpisodes(id)) } }
            }
            return all
        }
        episodeCache.merge(fetched) { _, new in new }

        for entry in sourceChannels {
            // A fetch that failed keeps what was there.
            guard let found = titles[entry.playlist.id] else { continue }
            let tags = entry.tags
            let query = [tags.genres, tags.networks, tags.collections, tags.libraries, tags.ratings,
                         [tags.content.itemTypes, tags.years.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""]]
                .map { $0.joined(separator: "|") }.joined(separator: "/")
            let ids = found.map(\.id)
            if let previous = sourceCache[entry.playlist.id], previous.query == query, previous.titleIds == ids,
               !found.contains(where: { $0.kind == .series && fetched[$0.id] != nil }) {
                continue
            }
            let items = found.flatMap { title -> [BaseItem] in
                title.kind == .series ? (episodeCache[title.id] ?? []) : [title]
            }
            sourceCache[entry.playlist.id] = (query, ids, items)
        }
    }

    /// Whether a title from a collection fits a channel's years, ratings and type.
    nonisolated static func passes(_ item: BaseItem, _ tags: ChannelTags) -> Bool {
        switch item.kind {
        case .movie: if tags.content == .shows { return false }
        case .series: if tags.content == .movies { return false }
        default: return false
        }
        if let years = tags.years {
            guard let year = item.productionYear, years.contains(year) else { return false }
        }
        if !tags.ratings.isEmpty {
            guard let rating = item.officialRating?.lowercased(),
                  tags.ratings.contains(where: { $0.lowercased() == rating }) else { return false }
        }
        return true
    }

    /// The filler playlists (tagged `aster:filler`) a channel's
    /// `filler-playlists=` tags name, matched by name whatever the case; a
    /// name no filler playlist has is left out.
    nonisolated static func fillerPlaylists(named tags: ChannelTags, in playlists: [BaseItem]) -> [BaseItem] {
        let fillers = playlists.filter { ChannelTags.isFillerPlaylist($0.tags) }
        return tags.fillerPlaylists.compactMap { name in
            fillers.first { $0.displayTitle.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Break clips sorted by what each one's own tag says it is, keeping
    /// only the kinds the channel's `filler-types=` asks for; a clip with
    /// no kind tag is left out.
    nonisolated static func breakClips(from items: [BaseItem], types: Set<BreakKind>) -> ChannelBreakClips {
        var clips = ChannelBreakClips()
        for item in items {
            guard let kind = ChannelTags.clipKind(item.tags), types.contains(kind) else { continue }
            switch kind {
            case .bumpers: clips.bumpers.append(item)
            case .promos: clips.promos.append(item)
            case .commercials: clips.commercials.append(item)
            case .trailers: clips.trailers.append(item)
            case .interstitials: clips.interstitials.append(item)
            }
        }
        return clips
    }

    /// Lower-cased names to ids, the first of any name used twice.
    nonisolated static func idsByName(_ items: [BaseItem]) -> [String: String] {
        var ids: [String: String] = [:]
        for item in items {
            let name = item.displayTitle.lowercased()
            if ids[name] == nil { ids[name] = item.id }
        }
        return ids
    }

    /// A channel's own playlist items, then its sources' titles that aren't
    /// already among them.
    nonisolated static func merged(_ own: [BaseItem], _ extra: [BaseItem]) -> [BaseItem] {
        var seen = Set(own.map(\.id))
        return own + extra.filter { seen.insert($0.id).inserted }
    }

    /// The playlists among `playlists` tagged as channels, with their tags.
    static func taggedChannels(in playlists: [BaseItem]) -> [(playlist: BaseItem, tags: ChannelTags)] {
        playlists.compactMap { playlist in
            let tags = ChannelTags(tags: playlist.tags)
            return tags.isChannel ? (playlist, tags) : nil
        }
    }
}
