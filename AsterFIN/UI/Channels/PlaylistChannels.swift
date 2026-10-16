//
//  PlaylistChannels.swift
//  AsterFIN
//
//  The Channels tab's channels: Jellyfin video playlists picked in Settings ›
//  Channels, in the order chosen there, saved on this device with each one's
//  mode. Each plays its movies and episodes on a schedule worked out from the
//  clock (see `ChannelSchedule`).
//

import Foundation
import Observation

/// The chosen playlists' ids, in channel order, stored comma-joined.
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
    var mode: ChannelMode = .rotation

    var id: String { playlist.id }
    var name: String { playlist.displayTitle }

    /// What's on now, and from how far in.
    func airing(at date: Date = Date()) -> ScheduledProgram? {
        ChannelSchedule.airing(channelId: id, items: items, mode: mode, at: date)
    }

    func programs(from: Date, to: Date) -> [ScheduledProgram] {
        ChannelSchedule.programs(channelId: id, items: items, mode: mode, from: from, to: to)
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
    private var loadedFor: [String] = []

    /// Loads the chosen playlists and their movies and episodes, in channel
    /// order. A playlist that's gone from the server, or has neither, is left out.
    func load(ids: [String], modes: [String: ChannelMode], client: JellyfinClient, force: Bool = false) async {
        guard force || ids != loadedFor || !hasLoaded else {
            // Only the modes changed: no need to fetch again.
            if channels.contains(where: { $0.mode != (modes[$0.id] ?? .rotation) }) {
                channels = channels.map { channel in
                    var changed = channel
                    changed.mode = modes[channel.id] ?? .rotation
                    return changed
                }
                ChannelTuner.register(channels)
            }
            return
        }
        errorMessage = nil
        do {
            let playlists = try await client.playlists(mediaType: "Video")
            let byId = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let chosen = ids.compactMap { byId[$0] }
            let contents = await withTaskGroup(of: (String, [BaseItem]).self) { group in
                for playlist in chosen {
                    group.addTask { (playlist.id, (try? await client.playlistItems(playlistId: playlist.id)) ?? []) }
                }
                var found: [String: [BaseItem]] = [:]
                for await (id, items) in group { found[id] = items }
                return found
            }
            var built: [PlaylistChannel] = []
            for playlist in chosen {
                let items = (contents[playlist.id] ?? []).filter { $0.kind == .movie || $0.kind == .episode }
                guard !items.isEmpty else { continue }
                built.append(PlaylistChannel(playlist: playlist, number: built.count + 1, items: items, mode: modes[playlist.id] ?? .rotation))
            }
            channels = built
            ChannelTuner.register(built)
            loadedFor = ids
        } catch {
            if channels.isEmpty { errorMessage = error.localizedDescription }
        }
        hasLoaded = true
    }
}
