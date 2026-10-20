//
//  ChannelFlick.swift
//  AsterFIN
//
//  Flicking through channels while one plays, as on a cable box: Up opens
//  a row of channels along the bottom, the one playing in the middle with
//  what's on it, and left and right go round them (from the highest back to
//  the lowest). Select changes channel. Live TV goes through its channels
//  in the guide's order; the Channels tab through its own, by number.
//  On a Channels-tab channel, Up picks Go to Episode (or Movie): what's on,
//  played on its own as from its show's page.
//

import Foundation
import Observation

/// A channel in the row, and what's on it now.
nonisolated struct FlickChannel: Identifiable, Equatable, Sendable {
    let id: String
    let number: String?
    let name: String
    let logoURL: URL?
    /// A Channels-tab channel's bug, shown beside what's on.
    var bugURL: URL? = nil
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
    /// The library item on, for Go to Episode; nil on Live TV, whose
    /// programmes aren't in the library.
    var itemId: String? = nil
    var isMovie = false

    func progress(at date: Date) -> Double? {
        guard let start, let end, end > start, start <= date, date < end else { return nil }
        return date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    /// "12 min left", "1 hr, 5 min left"; nil once it's over.
    func timeLeft(at date: Date) -> String? {
        guard let end, end > date else { return nil }
        let minutes = max(1, Int((end.timeIntervalSince(date) / 60).rounded(.up)))
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " left"
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
    private(set) var currentId: String
    /// Go to Episode is picked, above the row, rather than the channel.
    private(set) var isOnGoTo = false

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

    /// The picked channel's programme can be gone to on its own.
    var canGoTo: Bool { selectedChannel?.now?.itemId != nil }

    /// Moves along the row, going round from the last to the first; back
    /// down from Go to Episode, if it was picked.
    func move(by step: Int) {
        guard !channels.isEmpty else { return }
        isOnGoTo = false
        selected = ((selected + step) % channels.count + channels.count) % channels.count
    }

    /// Up to Go to Episode, where there's one; down back to the row.
    func pickGoTo(_ on: Bool) {
        isOnGoTo = on && canGoTo
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
        if !canGoTo { isOnGoTo = false }
    }

    /// Another channel is playing now (the iPhone's dial and list keep one
    /// model across channel changes); the selection stays where it is.
    func playing(_ channelId: String) {
        currentId = channelId
    }

    /// Back to the channel playing.
    func selectCurrent() {
        isOnGoTo = false
        selected = channels.firstIndex { $0.id == currentId } ?? 0
    }

    /// Picks a channel by id (a row tapped in the iPhone's channel list).
    func select(_ channelId: String) {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        isOnGoTo = false
        selected = index
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
            let program = channel.airing(at: now).map { airing -> FlickProgram in
                // In the break after it: what's coming up, from now to its start.
                if channel.segment(at: now)?.role.isBreak == true, let next = channel.airing(at: airing.end) {
                    let (title, subtitle) = Self.titles(of: next.item)
                    return FlickProgram(
                        title: "Break",
                        subtitle: "Up next: " + ([title, subtitle].compactMap { $0 }.joined(separator: " · ")),
                        overview: next.item.overview,
                        start: channel.segments(from: airing.start, to: now).first { $0.role.isBreak }?.start,
                        end: next.start,
                        imageURL: client.landscapeURL(for: next.item, width: 480),
                        itemId: next.item.id,
                        isMovie: next.item.kind == .movie
                    )
                }
                let item = airing.item
                let (title, subtitle) = Self.titles(of: item)
                return FlickProgram(
                    title: title,
                    subtitle: subtitle,
                    overview: item.overview,
                    start: airing.start,
                    end: airing.end,
                    imageURL: client.landscapeURL(for: item, width: 480),
                    itemId: item.id,
                    isMovie: item.kind == .movie
                )
            }
            let picture = channel.logoURL(client: client, maxWidth: 560)
            return FlickChannel(
                id: channel.id,
                number: "\(channel.number)",
                name: channel.name,
                logoURL: channel.showsLogo ? picture : nil,
                // The picture is a logo when it's the bug or the logo.
                bugURL: channel.showsBug || channel.showsLogo ? picture : nil,
                now: program
            )
        }
    }

    /// A show's name and "S2, E5 · Name", or a movie's name alone.
    private static func titles(of item: BaseItem) -> (title: String, subtitle: String?) {
        guard item.kind == .episode else { return (item.displayTitle, nil) }
        let subtitle = [item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · ")
        return (item.seriesName ?? item.displayTitle, subtitle.isEmpty ? nil : subtitle)
    }
}
