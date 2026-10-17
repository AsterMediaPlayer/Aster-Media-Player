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

/// How channels were stored before they moved to playlist tags: the chosen
/// playlists' ids in order, comma-joined, with each one's mode and logo.
/// Read once, to move them to tags (`ChannelMigration`).
nonisolated enum PlaylistChannelList {
    static func ids(from stored: String) -> [String] {
        var seen = Set<String>()
        return stored.split(separator: ",").map(String.init).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func encode(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    /// Each channel's mode, stored as `id=blocks,…`; a channel missing from
    /// it uses Rotation.
    static func modes(from stored: String) -> [String: ChannelMode] {
        var modes: [String: ChannelMode] = [:]
        for pair in stored.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, let mode = ChannelMode(rawValue: parts[1]) { modes[parts[0]] = mode }
        }
        return modes
    }

    static func encode(_ modes: [String: ChannelMode]) -> String {
        modes.filter { $0.value != .rotation }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ",")
    }
}

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
    /// From the `channel-name=` tag; nil for the playlist's own name.
    var customName: String?

    var id: String { playlist.id }
    var name: String { customName ?? playlist.displayTitle }
    var mode: ChannelMode { lineup.mode }

    /// What's on now, and from how far in.
    func airing(at date: Date = Date()) -> ScheduledProgram? {
        ChannelSchedule.airing(channelId: id, items: items, lineup: lineup, at: date)
    }

    func programs(from: Date, to: Date) -> [ScheduledProgram] {
        ChannelSchedule.programs(channelId: id, items: items, lineup: lineup, from: from, to: to)
    }
}

/// What's on a channel now, as something to play. The Channels tab registers
/// the channels it loads, and the players ask here what's next when a movie
/// or episode ends, so a channel stays with its schedule.
enum ChannelTuner {
    private static var channels: [String: PlaylistChannel] = [:]

    static func register(_ loaded: [PlaylistChannel]) {
        for channel in loaded { channels[channel.id] = channel }
    }

    static func channel(_ id: String) -> PlaylistChannel? {
        channels[id]
    }

    /// What's on `channelId` at `date`, from as far in as it's got. Just
    /// after `finishedItemId` ends, a viewer who paused is a little behind
    /// the schedule and it may still be "on"; what follows it then plays
    /// from the start, rather than the last minutes of it again.
    static func live(channelId: String, at date: Date = Date(), after finishedItemId: String? = nil) -> (item: BaseItem, entry: PlaybackQueueItem)? {
        guard let channel = channels[channelId], var program = channel.airing(at: date) else { return nil }
        var offset = program.offset(at: date)
        if let finishedItemId, program.item.id == finishedItemId,
           let next = channel.programs(from: program.end, to: program.end.addingTimeInterval(1)).first {
            program = next
            offset = 0
        }
        let entry = PlaybackQueueItem(itemId: program.item.id, startTicks: Int64(offset * 10_000_000), channelId: channelId)
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

    /// Finds the playlists tagged as channels and loads their movies and
    /// episodes, in channel-number order. A tagged playlist with neither is
    /// left out.
    func load(client: JellyfinClient, force: Bool = false) async {
        errorMessage = nil
        do {
            let tagged = Self.taggedChannels(in: try await client.playlists(mediaType: "Video"))
            let numbers = ChannelTags.numbers(for: tagged.map { ($0.playlist.id, $0.tags.name ?? $0.playlist.displayTitle, $0.tags.number) })
            let stale = tagged.map(\.playlist).filter { playlist in
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
            let built = tagged.compactMap { entry -> PlaylistChannel? in
                let items = (itemCache[entry.playlist.id]?.items ?? []).filter { $0.kind == .movie || $0.kind == .episode }
                guard !items.isEmpty, let number = numbers[entry.playlist.id] else { return nil }
                return PlaylistChannel(playlist: entry.playlist, number: number, items: items, lineup: entry.tags.lineup, showsLogo: entry.tags.showsLogo, showsBug: entry.tags.showsBug, customName: entry.tags.name)
            }
            .sorted { ($0.number, $0.name) < ($1.number, $1.name) }
            channels = built
            ChannelTuner.register(built)
        } catch {
            if channels.isEmpty { errorMessage = error.localizedDescription }
        }
        hasLoaded = true
    }

    /// The playlists among `playlists` tagged as channels, with their tags.
    static func taggedChannels(in playlists: [BaseItem]) -> [(playlist: BaseItem, tags: ChannelTags)] {
        playlists.compactMap { playlist in
            let tags = ChannelTags(tags: playlist.tags)
            return tags.isChannel ? (playlist, tags) : nil
        }
    }
}
