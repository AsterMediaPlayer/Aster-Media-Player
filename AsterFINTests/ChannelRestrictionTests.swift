//
//  ChannelRestrictionTests.swift
//  AsterFINTests
//
//  A channel with anything on it the user's parental controls hold back is
//  left out. The numbers are Jellyfin 12's for a user capped at PG: the
//  Sitcoms playlist lists 824 titles but sends 349.
//

import Foundation
import Testing
@testable import AsterFIN

struct ChannelRestrictionTests {
    private func playlist(listing count: Int) throws -> BaseItem {
        try JSONDecoder().decode(BaseItem.self, from: Data(#"{"Id":"p1","Name":"Channel","Type":"Playlist","ChildCount":\#(count)}"#.utf8))
    }

    private let pg = UserPolicy(maxParentalRating: 10)
    private let unrestricted = UserPolicy()
    private let ratings = [
        ParentalRating(name: "G", score: 0),
        ParentalRating(name: "PG", score: 10),
        ParentalRating(name: "TV-PG", score: 10),
        ParentalRating(name: "PG-13", score: 13),
        ParentalRating(name: "TV-MA", score: 17, subScore: 1),
    ]

    @Test func aPlaylistMissingTitlesIsHidden() throws {
        let tags = ChannelTags(tags: ["aster:channel"])
        #expect(ChannelsModel.isHeldBack(try playlist(listing: 824), tags: tags, fetched: 349, policy: pg, ratings: []))
        #expect(!ChannelsModel.isHeldBack(try playlist(listing: 29), tags: tags, fetched: 29, policy: pg, ratings: []))
        // The server refused the playlist outright.
        #expect(ChannelsModel.isHeldBack(try playlist(listing: 35), tags: tags, fetched: nil, policy: pg, ratings: []))
    }

    @Test func anUnrestrictedUserGetsEveryChannel() throws {
        let tags = ChannelTags(tags: ["aster:channel", "aster:genre=Horror"])
        // A missing file shouldn't cost an administrator the channel.
        #expect(!ChannelsModel.isHeldBack(try playlist(listing: 10), tags: tags, fetched: 9, policy: unrestricted, ratings: ratings))
    }

    @Test func aGenreChannelNeedsRatingsWithinTheCap() throws {
        let empty = try playlist(listing: 0)
        let open = ChannelTags(tags: ["aster:channel", "aster:genre=Horror"])
        #expect(ChannelsModel.isHeldBack(empty, tags: open, fetched: 0, policy: pg, ratings: ratings))
        let family = ChannelTags(tags: ["aster:channel", "aster:genre=Animation", "aster:rating=G,PG,TV-PG"])
        #expect(!ChannelsModel.isHeldBack(empty, tags: family, fetched: 0, policy: pg, ratings: ratings))
        let teen = ChannelTags(tags: ["aster:channel", "aster:genre=Animation", "aster:rating=PG,PG-13"])
        #expect(ChannelsModel.isHeldBack(empty, tags: teen, fetched: 0, policy: pg, ratings: ratings))
        // A rating the server doesn't know can't be cleared.
        let unknown = ChannelTags(tags: ["aster:channel", "aster:genre=Animation", "aster:rating=Kids"])
        #expect(ChannelsModel.isHeldBack(empty, tags: unknown, fetched: 0, policy: pg, ratings: ratings))
    }

    @Test func otherRestrictionsHideGenreChannels() throws {
        let family = ChannelTags(tags: ["aster:channel", "aster:genre=Animation", "aster:rating=G"])
        let blocked = UserPolicy(maxParentalRating: 10, blockedTags: ["gore"])
        #expect(ChannelsModel.isHeldBack(try playlist(listing: 0), tags: family, fetched: 0, policy: blocked, ratings: ratings))
        let someLibraries = UserPolicy(enableAllFolders: false)
        #expect(ChannelsModel.isHeldBack(try playlist(listing: 0), tags: family, fetched: 0, policy: someLibraries, ratings: ratings))
    }

    @Test func decodesTheServersRatingsAndPolicy() throws {
        let ratings = try JSONDecoder().decode([ParentalRating].self, from: Data(#"[{"Name":"TV-MA","Value":17,"RatingScore":{"score":17,"subScore":1}},{"Name":"PG","Value":10}]"#.utf8))
        #expect(ratings.map(\.score) == [17, 10])
        #expect(ratings.map(\.subScore) == [1, nil])
        let policy = try JSONDecoder().decode(UserPolicy.self, from: Data(#"{"MaxParentalRating":10,"BlockedTags":[],"AllowedTags":[],"BlockUnratedItems":[],"EnableAllFolders":true}"#.utf8))
        #expect(policy.restrictsContent && !policy.restrictsBeyondRating)
        let open = try JSONDecoder().decode(UserPolicy.self, from: Data(#"{"BlockedTags":[],"AllowedTags":[],"BlockUnratedItems":[],"EnableAllFolders":true}"#.utf8))
        #expect(!open.restrictsContent)
    }
}
