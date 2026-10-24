//
//  ChannelGroups.swift
//  AsterFIN
//
//  Channels in named groups, like a cable guide's: Kids, Anime, Movies. A
//  group goes in order of its lowest channel number, its channels by number
//  within it, and channels without one go under "Other". Until some channel
//  has a group there are none, and everything stays as it was. Used by the
//  Channels tab (the `aster:group=` tag) and Live TV (groups the Aster
//  Channels plugin keeps).
//

import Foundation

nonisolated struct ChannelGrouping: Equatable, Sendable {
    /// The group for channels that have none, once some channel has one.
    static let other = "Other"

    /// Every channel's group, by channel id.
    let groups: [String: String]
    /// The groups in order.
    let names: [String]

    func group(of channelId: String) -> String? {
        groups[channelId]
    }

    /// The channels in group order (a group's channels kept in the order
    /// given, which should be by number); nil when no channel has a group.
    /// `groupOf` is each channel's own group, or nil.
    static func make<Channel>(_ channels: [Channel], id: (Channel) -> String, groupOf: (Channel) -> String?) -> (grouping: ChannelGrouping, ordered: [Channel])? {
        guard channels.contains(where: { groupOf($0) != nil }) else { return nil }
        var groups: [String: String] = [:]
        var names: [String] = []
        for channel in channels {
            let name = groupOf(channel) ?? other
            groups[id(channel)] = name
            // Channels come by number, so a group's first channel is its lowest.
            if !names.contains(name) { names.append(name) }
        }
        let rank = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        // A stable sort, so each group keeps its channels' order.
        let ordered = channels.enumerated().sorted { a, b in
            let rankA = rank[groups[id(a.element)] ?? other] ?? 0
            let rankB = rank[groups[id(b.element)] ?? other] ?? 0
            return rankA != rankB ? rankA < rankB : a.offset < b.offset
        }.map(\.element)
        return (ChannelGrouping(groups: groups, names: names), ordered)
    }

    /// The ids, in the order given, of the channels in `group`.
    func channels(_ ids: [String], in group: String) -> [String] {
        ids.filter { groups[$0] == group }
    }
}
