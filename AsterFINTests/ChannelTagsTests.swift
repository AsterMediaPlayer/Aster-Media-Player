//
//  ChannelTagsTests.swift
//  AsterFINTests
//
//  Reading and writing a channel's settings as playlist tags: whatever the
//  case, with bad values falling back to defaults, every other tag kept,
//  and channel numbers handed out when a playlist doesn't have one.
//

import Testing
@testable import AsterFIN

struct ChannelTagsTests {
    @Test func aPlaylistWithoutTagsIsNoChannel() {
        let tags = ChannelTags(tags: nil)
        #expect(!tags.isChannel)
        #expect(tags.number == nil)
        #expect(tags.mode == .rotation)
        #expect(!tags.showsLogo)
    }

    @Test func allTheTagsAreRead() {
        let tags = ChannelTags(tags: ["Family", "asterfin:channel", "asterfin:number=101", "asterfin:mode=blocks", "asterfin:logo=on"])
        #expect(tags == ChannelTags(isChannel: true, number: 101, mode: .blocks, showsLogo: true))
    }

    @Test func caseAndSpacesDontMatter() {
        let tags = ChannelTags(tags: [" AsterFIN:Channel ", "ASTERFIN:MODE=Sequential", "asterfin:Logo = ON"])
        #expect(tags.isChannel)
        #expect(tags.mode == .sequential)
        #expect(tags.showsLogo)
    }

    @Test func badValuesFallBackToDefaults() {
        let tags = ChannelTags(tags: ["asterfin:channel", "asterfin:number=abc", "asterfin:number=-4", "asterfin:mode=loud"])
        #expect(tags.isChannel)
        #expect(tags.number == nil)
        #expect(tags.mode == .rotation)
    }

    @Test func offTurnsThingsOff() {
        let tags = ChannelTags(tags: ["asterfin:channel=off", "asterfin:logo=no"])
        #expect(!tags.isChannel)
        #expect(!tags.showsLogo)
    }

    @Test func writingKeepsEveryOtherTag() {
        let existing = ["Family", "asterfin:channel", "asterfin:theme=retro", "asterfin:mode=shuffle", "Halloween"]
        let written = ChannelTags(isChannel: true, number: 7, mode: .blocks).applied(to: existing)
        #expect(written == [
            "Family", "asterfin:theme=retro", "Halloween", "asterfin:channel", "asterfin:number=7", "asterfin:mode=blocks",
            "asterfin:reshuffle=day", "asterfin:blocks=2-4", "asterfin:seed=0", "asterfin:logo=off", "asterfin:bug=off",
            "asterfin:bug-location=bottom-right", "asterfin:bug-size=100%", "asterfin:bug-hide=off", "asterfin:bug-opacity=45%", "asterfin:type=all",
        ])
        #expect(ChannelTags(tags: written) == ChannelTags(isChannel: true, number: 7, mode: .blocks))
    }

    /// Defaults are written too, so every setting shows in Jellyfin.
    @Test func everySettingIsWritten() {
        let defaults = ["asterfin:mode=rotation", "asterfin:reshuffle=day", "asterfin:blocks=2-4", "asterfin:seed=0", "asterfin:logo=off", "asterfin:bug=off", "asterfin:bug-location=bottom-right", "asterfin:bug-size=100%", "asterfin:bug-hide=off", "asterfin:bug-opacity=45%", "asterfin:type=all"]
        #expect(ChannelTags(isChannel: true).applied(to: []) == ["asterfin:channel"] + defaults)
        #expect(ChannelTags().applied(to: ["asterfin:channel", "Family"]) == ["Family", "asterfin:channel=off"] + defaults)
        #expect(ChannelTags(tags: ChannelTags(isChannel: true).applied(to: [])) == ChannelTags(isChannel: true))
    }

    @Test func aKeyLeftToItsDefaultIsNoticed() {
        #expect(ChannelTags.sets("logo", in: ["asterfin:channel", "AsterFIN:Logo=off"]))
        #expect(!ChannelTags.sets("logo", in: ["asterfin:channel", "logo=on"]))
        #expect(!ChannelTags.sets("logo", in: nil))
    }

    @Test func turningAChannelOffKeepsItsSettings() {
        let off = ChannelTags(isChannel: false, number: 3, mode: .shuffle, showsLogo: true).applied(to: [])
        #expect(!ChannelTags(tags: off).isChannel)
        var back = ChannelTags(tags: off)
        back.isChannel = true
        #expect(back == ChannelTags(isChannel: true, number: 3, mode: .shuffle, showsLogo: true))
    }

    @Test func unnumberedChannelsComeAfterTheRestByName() {
        let numbers = ChannelTags.numbers(for: [
            ("a", "Zebra TV", nil),
            ("b", "Tooniverse", 5),
            ("c", "Apple TV", nil),
            ("d", "Sitcoms", 2),
        ])
        #expect(numbers == ["b": 5, "d": 2, "c": 6, "a": 7])
    }

    @Test func clashingNumbersAreKept() {
        let numbers = ChannelTags.numbers(for: [("a", "One", 3), ("b", "Two", 3)])
        #expect(numbers == ["a": 3, "b": 3])
    }

    // MARK: Reshuffle, seed, blocks, bug and name

    @Test func theNewerTagsAreRead() {
        let tags = ChannelTags(tags: [
            "asterfin:channel", "asterfin:reshuffle=Week", "asterfin:seed=3", "asterfin:blocks=3-6",
            "asterfin:bug=on", "asterfin:channel-name=Tooniverse 90s",
        ])
        #expect(tags.reshuffle == .week)
        #expect(tags.seed == 3)
        #expect(tags.blocks == 3...6)
        #expect(tags.showsBug)
        #expect(tags.name == "Tooniverse 90s")
        #expect(tags.lineup == ChannelLineup(mode: .rotation, reshuffle: .week, seed: 3, blocks: 3...6))
    }

    @Test func theNameKeepsItsCaseAndAnyEquals() {
        #expect(ChannelTags(tags: ["ASTERFIN:CHANNEL-NAME=  KTV = Kids TV "]).name == "KTV = Kids TV")
        #expect(ChannelTags(tags: ["asterfin:channel-name="]).name == nil)
    }

    @Test func badNewerValuesFallBackToDefaults() {
        let tags = ChannelTags(tags: ["asterfin:reshuffle=hourly", "asterfin:seed=lots", "asterfin:blocks=6-3"])
        #expect(tags.reshuffle == .day)
        #expect(tags.seed == 0)
        #expect(tags.blocks == 2...4)
        #expect(tags.lineup == ChannelLineup())
        #expect(ChannelTags(tags: ["asterfin:seed=-2"]).seed == 0)
        #expect(ChannelTags(tags: ["asterfin:blocks=0"]).blocks == 2...4)
        #expect(ChannelTags(tags: ["asterfin:blocks=21"]).blocks == 2...4)
        #expect(ChannelTags(tags: ["asterfin:blocks=3-"]).blocks == 2...4)
        #expect(ChannelTags(tags: ["asterfin:blocks=4"]).blocks == 4...4)
    }

    @Test func theNewerTagsRoundTrip() {
        let tags = ChannelTags(isChannel: true, mode: .blocks).with {
            $0.reshuffle = .month
            $0.seed = 2
            $0.blocks = 4...4
            $0.showsBug = true
            $0.name = "Late Night"
        }
        let written = tags.applied(to: ["Family"])
        #expect(written == [
            "Family", "asterfin:channel", "asterfin:mode=blocks", "asterfin:reshuffle=month", "asterfin:blocks=4",
            "asterfin:seed=2", "asterfin:logo=off", "asterfin:bug=on", "asterfin:bug-location=bottom-right", "asterfin:bug-size=100%", "asterfin:bug-hide=off", "asterfin:bug-opacity=45%", "asterfin:type=all",
            "asterfin:channel-name=Late Night",
        ])
        #expect(ChannelTags(tags: written) == tags)
    }

    @Test func theBugsCornerAndSizeAreRead() {
        let tags = ChannelTags(tags: ["asterfin:bug=on", "asterfin:bug-location=Top-Left", "asterfin:bug-size=150%"])
        #expect(tags.bugCorner == .topLeft)
        #expect(tags.bugSize == 150)
        #expect(ChannelTags(tags: ["asterfin:bug-size=75"]).bugSize == 75)
        #expect(ChannelTags(tags: ["asterfin:bug-size=500%"]).bugSize == 100)
        #expect(ChannelTags(tags: ["asterfin:bug-size=big"]).bugSize == 100)
        #expect(ChannelTags(tags: ["asterfin:bug-location=middle"]).bugCorner == .bottomRight)
        let written = tags.with { $0.isChannel = true }.applied(to: [])
        #expect(written.contains("asterfin:bug-location=top-left"))
        #expect(written.contains("asterfin:bug-size=150%"))
        #expect(ChannelTags(tags: written) == tags.with { $0.isChannel = true })
    }

    @Test func theBugCanHideItself() {
        #expect(ChannelTags(tags: ["asterfin:bug-hide=30"]).bugHideAfter == 30)
        #expect(ChannelTags(tags: ["asterfin:bug-hide=45s"]).bugHideAfter == 45)
        #expect(ChannelTags(tags: ["asterfin:bug-hide=off", "asterfin:bug-opacity=45%", "asterfin:type=all"]).bugHideAfter == 0)
        #expect(ChannelTags(tags: ["asterfin:bug-hide=soon"]).bugHideAfter == 0)
        #expect(ChannelTags(tags: ["asterfin:bug-hide=99999"]).bugHideAfter == 0)
        let written = ChannelTags(isChannel: true).with { $0.bugHideAfter = 30 }.applied(to: [])
        #expect(written.contains("asterfin:bug-hide=30"))
        #expect(ChannelTags(tags: written).bugHideAfter == 30)
    }

    // MARK: Genre channels

    @Test func genresTypeAndLibrariesAreRead() {
        let tags = ChannelTags(tags: [
            "asterfin:channel", "asterfin:genre=Horror", "asterfin:GENRE=Thriller, Mystery", "asterfin:genre=horror",
            "asterfin:type=Shows", "asterfin:library=TV Shows", "asterfin:library=Anime",
        ])
        #expect(tags.genres == ["Horror", "Thriller", "Mystery"])
        #expect(tags.content == .shows)
        #expect(tags.libraries == ["TV Shows", "Anime"])
        #expect(ChannelTags(tags: ["asterfin:type=cartoons"]).content == .all)
    }

    @Test func genresRoundTrip() {
        let tags = ChannelTags(isChannel: true).with {
            $0.genres = ["Action & Adventure", "Comedy"]
            $0.content = .movies
            $0.libraries = ["Movies"]
        }
        let written = tags.applied(to: ["Family"])
        #expect(written.contains("asterfin:genre=Action & Adventure"))
        #expect(written.contains("asterfin:genre=Comedy"))
        #expect(written.contains("asterfin:type=movies"))
        #expect(written.contains("asterfin:library=Movies"))
        #expect(ChannelTags(tags: written) == tags)
    }

    @Test func genreTitlesJoinThePlaylistsOwnOnce() {
        func item(_ id: String) -> BaseItem { BaseItem(id: id, name: id, type: ItemKind.movie.rawValue) }
        let merged = ChannelsModel.merged([item("b"), item("a")], [item("a"), item("c"), item("b"), item("d")])
        #expect(merged.map(\.id) == ["b", "a", "c", "d"])
    }

    @Test func theBugsOpacityIsRead() {
        #expect(ChannelTags(tags: ["asterfin:bug-opacity=60%"]).bugOpacity == 60)
        #expect(ChannelTags(tags: ["asterfin:bug-opacity=100"]).bugOpacity == 100)
        #expect(ChannelTags(tags: ["asterfin:bug-opacity=0%"]).bugOpacity == 45)
        #expect(ChannelTags(tags: ["asterfin:bug-opacity=solid"]).bugOpacity == 45)
        let written = ChannelTags(isChannel: true).with { $0.bugOpacity = 75 }.applied(to: [])
        #expect(written.contains("asterfin:bug-opacity=75%"))
        #expect(ChannelTags(tags: written).bugOpacity == 75)
    }

    @Test func networksCollectionsYearsAndRatingsAreRead() {
        let tags = ChannelTags(tags: [
            "asterfin:channel", "asterfin:network=NBC", "asterfin:network=Cartoon Network, Inc.",
            "asterfin:collection=Star Wars Collection", "asterfin:years=1985-1999", "asterfin:rating=TV-PG, PG",
        ])
        #expect(tags.networks == ["NBC", "Cartoon Network, Inc."])
        #expect(tags.collections == ["Star Wars Collection"])
        #expect(tags.years == 1985...1999)
        #expect(tags.ratings == ["TV-PG", "PG"])
        #expect(tags.hasSources)
        #expect(ChannelTags(tags: ["asterfin:years=1994"]).years == 1994...1994)
        #expect(ChannelTags(tags: ["asterfin:years=1999-1985"]).years == 1985...1999)
        #expect(ChannelTags(tags: ["asterfin:years=eighties"]).years == nil)
        #expect(!ChannelTags(tags: ["asterfin:channel", "asterfin:years=1994"]).hasSources)
    }

    @Test func weightsAndLengthsAreRead() {
        let tags = ChannelTags(tags: [
            "asterfin:weight=Friends:2", "asterfin:weight=Star Trek: The Next Generation:3", "asterfin:weight=Cheers:9",
            "asterfin:weight=Frasier", "asterfin:min-length=20", "asterfin:max-length=60",
        ])
        #expect(tags.weights.map(\.show) == ["Friends", "Star Trek: The Next Generation", "Cheers"])
        #expect(tags.weights.map(\.weight) == [2, 3, 5])
        #expect(tags.minLength == 20)
        #expect(tags.maxLength == 60)
        #expect(tags.lineup.weights == ["friends": 2, "star trek: the next generation": 3, "cheers": 5])
        #expect(tags.lineup.minLength == 1200)
        #expect(tags.lineup.maxLength == 3600)
        #expect(ChannelTags(tags: ["asterfin:min-length=0"]).minLength == nil)
    }

    @Test func theNewTagsRoundTrip() {
        let tags = ChannelTags(isChannel: true).with {
            $0.networks = ["NBC"]
            $0.collections = ["Cars Collection"]
            $0.years = 1980...1989
            $0.ratings = ["TV-PG", "PG"]
            $0.weights = [ChannelTags.ShowWeight(show: "Friends", weight: 2)]
            $0.minLength = 15
            $0.maxLength = 45
        }
        let written = tags.applied(to: ["Family"])
        #expect(written.contains("asterfin:network=NBC"))
        #expect(written.contains("asterfin:collection=Cars Collection"))
        #expect(written.contains("asterfin:years=1980-1989"))
        #expect(written.contains("asterfin:weight=Friends:2"))
        #expect(written.contains("asterfin:min-length=15"))
        #expect(written.contains("asterfin:max-length=45"))
        #expect(written.contains("Family"))
        #expect(ChannelTags(tags: written) == tags)
        // Unset, they aren't written.
        let plain = ChannelTags(isChannel: true).applied(to: [])
        #expect(!plain.contains { $0.hasPrefix("asterfin:years") || $0.hasPrefix("asterfin:min-length") || $0.hasPrefix("asterfin:max-length") })
    }

    @Test func aCollectionsTitlesAreFiltered() {
        func item(_ kind: ItemKind, year: Int?, rating: String?) -> BaseItem {
            var item = BaseItem(id: "\(kind.rawValue)-\(year ?? 0)-\(rating ?? "")", name: "x", type: kind.rawValue)
            item.productionYear = year
            item.officialRating = rating
            return item
        }
        let tags = ChannelTags(tags: ["asterfin:collection=x", "asterfin:years=1980-1989", "asterfin:rating=pg", "asterfin:type=movies"])
        #expect(ChannelsModel.passes(item(.movie, year: 1984, rating: "PG"), tags))
        #expect(!ChannelsModel.passes(item(.movie, year: 1994, rating: "PG"), tags))
        #expect(!ChannelsModel.passes(item(.movie, year: 1984, rating: "R"), tags))
        #expect(!ChannelsModel.passes(item(.movie, year: nil, rating: "PG"), tags))
        #expect(!ChannelsModel.passes(item(.series, year: 1984, rating: "PG"), tags))
        #expect(ChannelsModel.passes(item(.series, year: 2001, rating: nil), ChannelTags(tags: ["asterfin:collection=x"])))
        #expect(!ChannelsModel.passes(item(.audioBook, year: 2001, rating: nil), ChannelTags(tags: ["asterfin:collection=x"])))
    }

    @Test func tagsFromTheNewNameAreReadToo() {
        let tags = ChannelTags(tags: ["aster:channel", "Aster:Number=7", "aster:mode=blocks"])
        #expect(tags.isChannel)
        #expect(tags.number == 7)
        #expect(tags.mode == .blocks)
        // Saving replaces them rather than adding a second set.
        let written = tags.applied(to: ["aster:channel", "aster:number=7", "Family"])
        #expect(!written.contains { $0.lowercased().hasPrefix("aster:") })
        #expect(written.contains("asterfin:number=7"))
        #expect(written.contains("Family"))
    }
}
