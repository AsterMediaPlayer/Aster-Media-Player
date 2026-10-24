//
//  ChannelGroupingTests.swift
//  AsterFINTests
//
//  Channel groups: each in order of its lowest number, its channels by
//  number, the ungrouped under "Other", and nothing at all until some
//  channel has a group.
//

import Testing
@testable import AsterFIN

struct ChannelGroupingTests {
    /// A channel id, as "number" or "number:group", in number order.
    private func make(_ channels: [String]) -> (grouping: ChannelGrouping, ordered: [String])? {
        ChannelGrouping.make(channels, id: { $0 }, groupOf: { channel in
            let parts = channel.split(separator: ":", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : nil
        })
    }

    @Test func noGroupsMeansNoGrouping() {
        #expect(make(["1", "2", "3"]) == nil)
    }

    @Test func groupsGoInOrderOfTheirLowestNumber() throws {
        let made = try #require(make(["1:Kids", "2:Anime", "3:Kids", "4:Movies", "5:Anime"]))
        #expect(made.grouping.names == ["Kids", "Anime", "Movies"])
        #expect(made.ordered == ["1:Kids", "3:Kids", "2:Anime", "5:Anime", "4:Movies"])
    }

    @Test func ungroupedChannelsAreOtherRankedLikeAnyGroup() throws {
        let made = try #require(make(["1", "2:Kids", "3", "4:Anime"]))
        #expect(made.grouping.names == ["Other", "Kids", "Anime"])
        #expect(made.ordered == ["1", "3", "2:Kids", "4:Anime"])
        #expect(made.grouping.group(of: "3") == ChannelGrouping.other)
    }

    @Test func aGroupsChannelsKeepTheirNumberOrder() throws {
        let made = try #require(make(["200:Kids", "201:Kids", "300:Anime", "301:Anime", "202:Kids"]))
        #expect(made.ordered == ["200:Kids", "201:Kids", "202:Kids", "300:Anime", "301:Anime"])
        #expect(made.grouping.channels(made.ordered, in: "Kids") == ["200:Kids", "201:Kids", "202:Kids"])
    }

    @Test func theGroupTagIsReadAndWritten() {
        let tags = ChannelTags(tags: ["aster:channel", "aster:group=  Late Night  "])
        #expect(tags.group == "Late Night")
        #expect(tags.applied(to: ["aster:channel"]).last == "aster:group=Late Night")
        #expect(ChannelTags(tags: ["aster:channel", "aster:group="]).group == nil)
    }
}
