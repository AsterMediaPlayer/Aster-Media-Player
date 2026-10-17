//
//  ChannelFlick.swift
//  AsterFIN
//
//  Flicking through channels while one plays, as on a cable box: Up opens
//  a row of channels along the bottom, the one playing in the middle with
//  what's on it, and left and right go round them (from the highest back to
//  the lowest). Select changes channel. Live TV goes through its channels
//  in the guide's order; the Channels tab through its own, by number.
//

import Foundation
import Observation

/// A channel in the row, and what's on it now.
nonisolated struct FlickChannel: Identifiable, Equatable, Sendable {
    let id: String
    let number: String?
    let name: String
    let logoURL: URL?
    let now: FlickProgram?
}

nonisolated struct FlickProgram: Equatable, Sendable {
    let title: String
    /// The episode, as "S2, E5 · Name", or its name alone.
    let subtitle: String?
    let overview: String?
    let start: Date?
    let end: Date?
    let imageURL: URL?

    func progress(at date: Date) -> Double? {
        guard let start, let end, end > start, start <= date, date < end else { return nil }
        return date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}

/// Live TV's channels in the guide's order, as the Live TV tab last loaded
/// them, so the player can flick through them.
enum LiveChannelDirectory {
    private(set) static var channels: [BaseItem] = []

    static func register(_ loaded: [BaseItem]) {
        channels = loaded
    }
}

@Observable
final class ChannelFlickModel {
    private(set) var channels: [FlickChannel] = []
    /// The channel picked in the row; the playing one when it opens.
    private(set) var selected = 0
    /// The channel playing now.
    let currentId: String

    @ObservationIgnored private let isLive: Bool

    /// The row for whatever `playback` is playing, or nil when it isn't a
    /// channel. Starts from what's known and refreshes what's on.
    init?(currentLiveChannel: String?, currentChannel: String?, client: JellyfinClient) {
        if let live = currentLiveChannel {
            currentId = live
            isLive = true
            channels = Self.liveChannels(LiveChannelDirectory.channels, client: client)
        } else if let channel = currentChannel {
            currentId = channel
            isLive = false
            channels = Self.playlistChannels(client: client)
        } else {
            return nil
        }
        selectCurrent()
    }

    var selectedChannel: FlickChannel? {
        channels.indices.contains(selected) ? channels[selected] : nil
    }

    /// Moves along the row, going round from the last to the first.
    func move(by step: Int) {
        guard !channels.isEmpty else { return }
        selected = ((selected + step) % channels.count + channels.count) % channels.count
    }

    /// The channel `offset` places from the selected one, going round; nil
    /// when the row is too short for it, so each channel shows once (a
    /// spare one goes on the right).
    func neighbour(_ offset: Int) -> FlickChannel? {
        guard !channels.isEmpty else { return nil }
        let reach = offset > 0 ? channels.count / 2 : (channels.count - 1) / 2
        guard abs(offset) <= reach else { return nil }
        let index = ((selected + offset) % channels.count + channels.count) % channels.count
        return channels[index]
    }

    /// Fetches what's on now, which the list kept for the player may have
    /// had since it loaded. Live TV asks the server again; the Channels
    /// tab's schedules are worked out fresh.
    func refresh(client: JellyfinClient) async {
        let pickedId = selectedChannel?.id
        if isLive {
            guard let loaded = try? await client.channels() else { return }
            let ordered = LiveTVModel.guideOrder(loaded)
            LiveChannelDirectory.register(ordered)
            channels = Self.liveChannels(ordered, client: client)
        } else {
            channels = Self.playlistChannels(client: client)
        }
        if let pickedId, let index = channels.firstIndex(where: { $0.id == pickedId }) {
            selected = index
        } else {
            selectCurrent()
        }
    }

    private func selectCurrent() {
        selected = channels.firstIndex { $0.id == currentId } ?? 0
    }

    private static func liveChannels(_ channels: [BaseItem], client: JellyfinClient) -> [FlickChannel] {
        channels.map { channel in
            let program = channel.currentProgram.map { program in
                FlickProgram(
                    title: program.name ?? "",
                    subtitle: program.episodeTitle.flatMap { $0 == program.name ? nil : $0 },
                    overview: program.overview,
                    start: JellyfinDate.parse(program.startDate),
                    end: JellyfinDate.parse(program.endDate),
                    imageURL: program.imageTags?["Primary"].map { client.imageURL(itemId: program.id, kind: .primary, tag: $0, maxWidth: 480) }
                )
            }
            return FlickChannel(
                id: channel.id,
                number: channel.channelNumber,
                name: channel.displayTitle,
                logoURL: client.channelLogoURL(channel, width: 300),
                now: program
            )
        }
    }

    private static func playlistChannels(client: JellyfinClient) -> [FlickChannel] {
        let now = Date()
        return ChannelTuner.orderedChannels.map { channel in
            let program = channel.airing(at: now).map { airing in
                let item = airing.item
                let isEpisode = item.kind == .episode
                let subtitle = isEpisode ? [item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · ") : nil
                return FlickProgram(
                    title: isEpisode ? (item.seriesName ?? item.displayTitle) : item.displayTitle,
                    subtitle: subtitle?.isEmpty == false ? subtitle : nil,
                    overview: item.overview,
                    start: airing.start,
                    end: airing.end,
                    imageURL: client.landscapeURL(for: item, width: 480)
                )
            }
            let logo = channel.showsLogo ? channel.playlist.imageTags?["Primary"].map {
                client.imageURL(itemId: channel.playlist.id, kind: .primary, tag: $0, maxWidth: 300)
            } : nil
            return FlickChannel(id: channel.id, number: "\(channel.number)", name: channel.name, logoURL: logo, now: program)
        }
    }
}
