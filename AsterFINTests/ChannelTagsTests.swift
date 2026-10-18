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
        let tags = ChannelTags(tags: ["Family", "aster:channel", "aster:number=101", "aster:mode=blocks", "aster:logo=on"])
        #expect(tags == ChannelTags(isChannel: true, number: 101, mode: .blocks, showsLogo: true))
    }

    @Test func caseAndSpacesDontMatter() {
        let tags = ChannelTags(tags: [" AsterFIN:Channel ", "ASTERFIN:MODE=Sequential", "aster:Logo = ON"])
        #expect(tags.isChannel)
        #expect(tags.mode == .sequential)
        #expect(tags.showsLogo)
    }

    @Test func badValuesFallBackToDefaults() {
        let tags = ChannelTags(tags: ["aster:channel", "aster:number=abc", "aster:number=-4", "aster:mode=loud"])
        #expect(tags.isChannel)
        #expect(tags.number == nil)
        #expect(tags.mode == .rotation)
    }

    @Test func offTurnsThingsOff() {
        let tags = ChannelTags(tags: ["aster:channel=off", "aster:logo=no"])
        #expect(!tags.isChannel)
        #expect(!tags.showsLogo)
    }

    @Test func writingKeepsEveryOtherTag() {
        let existing = ["Family", "aster:channel", "aster:theme=retro", "aster:mode=shuffle", "Halloween"]
        let written = ChannelTags(isChannel: true, number: 7, mode: .blocks).applied(to: existing)
        #expect(written == [
            "Family", "aster:theme=retro", "Halloween", "aster:channel", "aster:number=7", "aster:mode=blocks",
            "aster:reshuffle=day", "aster:blocks=2-4", "aster:seed=0", "aster:logo=off", "aster:bug=off",
            "aster:bug-location=bottom-right", "aster:bug-size=100%", "aster:bug-hide=off", "aster:bug-opacity=45%", "aster:type=all",
        ])
        #expect(ChannelTags(tags: written) == ChannelTags(isChannel: true, number: 7, mode: .blocks))
    }

    /// Defaults are written too, so every setting shows in Jellyfin.
    @Test func everySettingIsWritten() {
        let defaults = ["aster:mode=rotation", "aster:reshuffle=day", "aster:blocks=2-4", "aster:seed=0", "aster:logo=off", "aster:bug=off", "aster:bug-location=bottom-right", "aster:bug-size=100%", "aster:bug-hide=off", "aster:bug-opacity=45%", "aster:type=all"]
        #expect(ChannelTags(isChannel: true).applied(to: []) == ["aster:channel"] + defaults)
        #expect(ChannelTags().applied(to: ["aster:channel", "Family"]) == ["Family", "aster:channel=off"] + defaults)
        #expect(ChannelTags(tags: ChannelTags(isChannel: true).applied(to: [])) == ChannelTags(isChannel: true))
    }

    @Test func aKeyLeftToItsDefaultIsNoticed() {
        #expect(ChannelTags.sets("logo", in: ["aster:channel", "AsterFIN:Logo=off"]))
        #expect(!ChannelTags.sets("logo", in: ["aster:channel", "logo=on"]))
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
            "aster:channel", "aster:reshuffle=Week", "aster:seed=3", "aster:blocks=3-6",
            "aster:bug=on", "aster:channel-name=Tooniverse 90s",
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
        #expect(ChannelTags(tags: ["aster:channel-name="]).name == nil)
    }

    @Test func badNewerValuesFallBackToDefaults() {
        let tags = ChannelTags(tags: ["aster:reshuffle=hourly", "aster:seed=lots", "aster:blocks=6-3"])
        #expect(tags.reshuffle == .day)
        #expect(tags.seed == 0)
        #expect(tags.blocks == 2...4)
        #expect(tags.lineup == ChannelLineup())
        #expect(ChannelTags(tags: ["aster:seed=-2"]).seed == 0)
        #expect(ChannelTags(tags: ["aster:blocks=0"]).blocks == 2...4)
        #expect(ChannelTags(tags: ["aster:blocks=21"]).blocks == 2...4)
        #expect(ChannelTags(tags: ["aster:blocks=3-"]).blocks == 2...4)
        #expect(ChannelTags(tags: ["aster:blocks=4"]).blocks == 4...4)
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
            "Family", "aster:channel", "aster:mode=blocks", "aster:reshuffle=month", "aster:blocks=4",
            "aster:seed=2", "aster:logo=off", "aster:bug=on", "aster:bug-location=bottom-right", "aster:bug-size=100%", "aster:bug-hide=off", "aster:bug-opacity=45%", "aster:type=all",
            "aster:channel-name=Late Night",
        ])
        #expect(ChannelTags(tags: written) == tags)
    }

    @Test func theBugsCornerAndSizeAreRead() {
        let tags = ChannelTags(tags: ["aster:bug=on", "aster:bug-location=Top-Left", "aster:bug-size=150%"])
        #expect(tags.bugCorner == .topLeft)
        #expect(tags.bugSize == 150)
        #expect(ChannelTags(tags: ["aster:bug-size=75"]).bugSize == 75)
        #expect(ChannelTags(tags: ["aster:bug-size=500%"]).bugSize == 100)
        #expect(ChannelTags(tags: ["aster:bug-size=big"]).bugSize == 100)
        #expect(ChannelTags(tags: ["aster:bug-location=middle"]).bugCorner == .bottomRight)
        let written = tags.with { $0.isChannel = true }.applied(to: [])
        #expect(written.contains("aster:bug-location=top-left"))
        #expect(written.contains("aster:bug-size=150%"))
        #expect(ChannelTags(tags: written) == tags.with { $0.isChannel = true })
    }

    @Test func theBugCanHideItself() {
        #expect(ChannelTags(tags: ["aster:bug-hide=30"]).bugHideAfter == 30)
        #expect(ChannelTags(tags: ["aster:bug-hide=45s"]).bugHideAfter == 45)
        #expect(ChannelTags(tags: ["aster:bug-hide=off", "aster:bug-opacity=45%", "aster:type=all"]).bugHideAfter == 0)
        #expect(ChannelTags(tags: ["aster:bug-hide=soon"]).bugHideAfter == 0)
        #expect(ChannelTags(tags: ["aster:bug-hide=99999"]).bugHideAfter == 0)
        let written = ChannelTags(isChannel: true).with { $0.bugHideAfter = 30 }.applied(to: [])
        #expect(written.contains("aster:bug-hide=30"))
        #expect(ChannelTags(tags: written).bugHideAfter == 30)
    }

    // MARK: Genre channels

    @Test func genresTypeAndLibrariesAreRead() {
        let tags = ChannelTags(tags: [
            "aster:channel", "aster:genre=Horror", "aster:GENRE=Thriller, Mystery", "aster:genre=horror",
            "aster:type=Shows", "aster:library=TV Shows", "aster:library=Anime",
        ])
        #expect(tags.genres == ["Horror", "Thriller", "Mystery"])
        #expect(tags.content == .shows)
        #expect(tags.libraries == ["TV Shows", "Anime"])
        #expect(ChannelTags(tags: ["aster:type=cartoons"]).content == .all)
    }

    @Test func genresRoundTrip() {
        let tags = ChannelTags(isChannel: true).with {
            $0.genres = ["Action & Adventure", "Comedy"]
            $0.content = .movies
            $0.libraries = ["Movies"]
        }
        let written = tags.applied(to: ["Family"])
        #expect(written.contains("aster:genre=Action & Adventure"))
        #expect(written.contains("aster:genre=Comedy"))
        #expect(written.contains("aster:type=movies"))
        #expect(written.contains("aster:library=Movies"))
        #expect(ChannelTags(tags: written) == tags)
    }

    @Test func genreTitlesJoinThePlaylistsOwnOnce() {
        func item(_ id: String) -> BaseItem { BaseItem(id: id, name: id, type: ItemKind.movie.rawValue) }
        let merged = ChannelsModel.merged([item("b"), item("a")], [item("a"), item("c"), item("b"), item("d")])
        #expect(merged.map(\.id) == ["b", "a", "c", "d"])
    }

    @Test func theBugsOpacityIsRead() {
        #expect(ChannelTags(tags: ["aster:bug-opacity=60%"]).bugOpacity == 60)
        #expect(ChannelTags(tags: ["aster:bug-opacity=100"]).bugOpacity == 100)
        #expect(ChannelTags(tags: ["aster:bug-opacity=0%"]).bugOpacity == 45)
        #expect(ChannelTags(tags: ["aster:bug-opacity=solid"]).bugOpacity == 45)
        let written = ChannelTags(isChannel: true).with { $0.bugOpacity = 75 }.applied(to: [])
        #expect(written.contains("aster:bug-opacity=75%"))
        #expect(ChannelTags(tags: written).bugOpacity == 75)
    }

    @Test func networksCollectionsYearsAndRatingsAreRead() {
        let tags = ChannelTags(tags: [
            "aster:channel", "aster:network=NBC", "aster:network=Cartoon Network, Inc.",
            "aster:collection=Star Wars Collection", "aster:years=1985-1999", "aster:rating=TV-PG, PG",
        ])
        #expect(tags.networks == ["NBC", "Cartoon Network, Inc."])
        #expect(tags.collections == ["Star Wars Collection"])
        #expect(tags.years == 1985...1999)
        #expect(tags.ratings == ["TV-PG", "PG"])
        #expect(tags.hasSources)
        #expect(ChannelTags(tags: ["aster:years=1994"]).years == 1994...1994)
        #expect(ChannelTags(tags: ["aster:years=1999-1985"]).years == 1985...1999)
        #expect(ChannelTags(tags: ["aster:years=eighties"]).years == nil)
        #expect(!ChannelTags(tags: ["aster:channel", "aster:years=1994"]).hasSources)
    }

    @Test func weightsAndLengthsAreRead() {
        let tags = ChannelTags(tags: [
            "aster:weight=Friends:2", "aster:weight=Star Trek: The Next Generation:3", "aster:weight=Cheers:9",
            "aster:weight=Frasier", "aster:min-length=20", "aster:max-length=60",
        ])
        #expect(tags.weights.map(\.show) == ["Friends", "Star Trek: The Next Generation", "Cheers"])
        #expect(tags.weights.map(\.weight) == [2, 3, 5])
        #expect(tags.minLength == 20)
        #expect(tags.maxLength == 60)
        #expect(tags.lineup.weights == ["friends": 2, "star trek: the next generation": 3, "cheers": 5])
        #expect(tags.lineup.minLength == 1200)
        #expect(tags.lineup.maxLength == 3600)
        #expect(ChannelTags(tags: ["aster:min-length=0"]).minLength == nil)
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
        #expect(written.contains("aster:network=NBC"))
        #expect(written.contains("aster:collection=Cars Collection"))
        #expect(written.contains("aster:years=1980-1989"))
        #expect(written.contains("aster:weight=Friends:2"))
        #expect(written.contains("aster:min-length=15"))
        #expect(written.contains("aster:max-length=45"))
        #expect(written.contains("Family"))
        #expect(ChannelTags(tags: written) == tags)
        // Unset, they aren't written.
        let plain = ChannelTags(isChannel: true).applied(to: [])
        #expect(!plain.contains { $0.hasPrefix("aster:years") || $0.hasPrefix("aster:min-length") || $0.hasPrefix("aster:max-length") })
    }

    @Test func aCollectionsTitlesAreFiltered() {
        func item(_ kind: ItemKind, year: Int?, rating: String?) -> BaseItem {
            var item = BaseItem(id: "\(kind.rawValue)-\(year ?? 0)-\(rating ?? "")", name: "x", type: kind.rawValue)
            item.productionYear = year
            item.officialRating = rating
            return item
        }
        let tags = ChannelTags(tags: ["aster:collection=x", "aster:years=1980-1989", "aster:rating=pg", "aster:type=movies"])
        #expect(ChannelsModel.passes(item(.movie, year: 1984, rating: "PG"), tags))
        #expect(!ChannelsModel.passes(item(.movie, year: 1994, rating: "PG"), tags))
        #expect(!ChannelsModel.passes(item(.movie, year: 1984, rating: "R"), tags))
        #expect(!ChannelsModel.passes(item(.movie, year: nil, rating: "PG"), tags))
        #expect(!ChannelsModel.passes(item(.series, year: 1984, rating: "PG"), tags))
        #expect(ChannelsModel.passes(item(.series, year: 2001, rating: nil), ChannelTags(tags: ["aster:collection=x"])))
        #expect(!ChannelsModel.passes(item(.audioBook, year: 2001, rating: nil), ChannelTags(tags: ["aster:collection=x"])))
    }

    @Test func tagsFromTheOldNameStillRead() {
        let tags = ChannelTags(tags: ["asterfin:channel", "AsterFIN:Number=7", "asterfin:mode=blocks"])
        #expect(tags.isChannel)
        #expect(tags.number == 7)
        #expect(tags.mode == .blocks)
        // Saving writes them under the new name and drops the old ones.
        let written = tags.applied(to: ["asterfin:channel", "asterfin:number=7", "Family"])
        #expect(!written.contains { $0.lowercased().hasPrefix("asterfin:") })
        #expect(written.contains("aster:number=7"))
        #expect(written.contains("Family"))
    }

    @Test func oldTagsAreConverted() {
        let converted = ChannelTags.converted(["asterfin:channel", " AsterFIN:channel-name=Late Night", "Family", "aster:seed=2", "asterfin:future=1"])
        #expect(converted == ["aster:channel", "aster:channel-name=Late Night", "Family", "aster:seed=2", "aster:future=1"])
        #expect(ChannelTags.converted(["aster:channel", "Family"]) == nil)
        #expect(ChannelTags.converted(nil) == nil)
        #expect(ChannelTags(tags: converted) == ChannelTags(tags: ["asterfin:channel", "asterfin:channel-name=Late Night", "asterfin:seed=2"]))
    }

    // MARK: Breaks

    @Test func breakTagsAreRead() {
        let tags = ChannelTags(tags: [
            "aster:channel", "aster:filler-playlists=Hazbin Bumpers", "aster:filler-playlists=80s Ads, Part 1",
            "aster:filler-types=commercials, Bumpers, nonsense", "aster:bumpers-at=out", "aster:break-length=4",
            "aster:promo-count=2", "aster:interstitial-count=0", "aster:break-every=3", "aster:align=:30",
        ])
        #expect(tags.fillerPlaylists == ["Hazbin Bumpers", "80s Ads, Part 1"])
        #expect(tags.fillerTypes == [.commercials, .bumpers])
        #expect(tags.hasBreaks)
        #expect(tags.lineup.breaks == ChannelBreaks(bumpersAt: .out, promoCount: 2, interstitialCount: 0, minutes: 4, every: 3, align: 30))
        // No types it knows means all of them.
        #expect(ChannelTags(tags: ["aster:filler-types=ads"]).fillerTypes == Set(BreakKind.allCases))
        #expect(ChannelTags(tags: ["aster:filler-playlists=Bumpers"]).fillerTypes == Set(BreakKind.allCases))
        // Bad values fall back.
        let bad = ChannelTags(tags: ["aster:align=25", "aster:break-length=99", "aster:promo-count=many", "aster:bumpers-at=sideways", "aster:break-every=0"])
        #expect(bad.breaks == ChannelBreaks())
        #expect(!bad.hasBreaks)
        #expect(ChannelTags(tags: ["aster:align=60m"]).breaks.align == 60)
        #expect(ChannelTags(tags: ["aster:align=off"]).breaks.align == 0)
    }

    @Test func aClipsOwnTagSaysWhatItIs() {
        #expect(ChannelTags.clipKind(["aster:bumper=in"]) == .bumpers)
        #expect(ChannelTags.clipKind(["aster:Bumper=Out"]) == .bumpers)
        #expect(ChannelTags.clipKind(["aster:bumper"]) == .bumpers)
        #expect(ChannelTags.clipKind(["Family", "Aster:Commercial"]) == .commercials)
        #expect(ChannelTags.clipKind(["aster:promos"]) == .promos)
        #expect(ChannelTags.clipKind(["aster:interstitial"]) == .interstitials)
        // A clip that doesn't say isn't anything.
        #expect(ChannelTags.clipKind(["Family"]) == nil)
        #expect(ChannelTags.clipKind(nil) == nil)
        #expect(ChannelTags.bumperSide(["aster:bumper=in"]) == .in)
        #expect(ChannelTags.bumperSide(["aster:bumper=OUT"]) == .out)
        #expect(ChannelTags.bumperSide(["aster:bumper"]) == .both)
        #expect(ChannelTags.bumperSide(["aster:bumper=both"]) == .both)
        // A filler playlist says so.
        #expect(ChannelTags.isFillerPlaylist(["Family", "aster:filler"]))
        #expect(ChannelTags.isFillerPlaylist(["asterfin:Filler"]))
        #expect(!ChannelTags.isFillerPlaylist(["aster:filler=off"]))
        #expect(!ChannelTags.isFillerPlaylist(["aster:channel"]))
        #expect(!ChannelTags.isFillerPlaylist(nil))
    }

    @Test func breakTagsRoundTrip() {
        let tags = ChannelTags(isChannel: true).with {
            $0.fillerPlaylists = ["Hazbin Bumpers", "80s Ads"]
            $0.fillerTypes = [.bumpers, .commercials]
            $0.breaks.align = 30
            $0.breaks.promoCount = 0
        }
        let written = tags.applied(to: ["Family"])
        #expect(written.contains("aster:filler-playlists=Hazbin Bumpers"))
        #expect(written.contains("aster:filler-playlists=80s Ads"))
        #expect(written.contains("aster:filler-types=bumpers,commercials"))
        #expect(written.contains("aster:align=30"))
        #expect(written.contains("aster:break-length=2"))
        #expect(ChannelTags(tags: written) == tags)
        // Without filler playlists, none of the break settings are written.
        #expect(!ChannelTags(isChannel: true).applied(to: []).contains { $0.contains("filler") || $0.contains("break") || $0.contains("align") })
    }

    @Test func fillerClipsAreSortedByTheirOwnTags() {
        func playlist(_ id: String, _ name: String, filler: Bool = true) -> BaseItem {
            var item = BaseItem(id: id, name: name, type: "Playlist")
            item.tags = filler ? ["aster:filler"] : []
            return item
        }
        let playlists = [playlist("a", "Hazbin Bumpers"), playlist("b", "80s Ads"), playlist("c", "Tooniverse", filler: false)]
        let tags = ChannelTags(tags: ["aster:filler-playlists=hazbin bumpers", "aster:filler-playlists=80s Ads", "aster:filler-playlists=Tooniverse", "aster:filler-playlists=Missing"])
        // Only playlists tagged aster:filler count.
        #expect(ChannelsModel.fillerPlaylists(named: tags, in: playlists).map(\.id) == ["a", "b"])

        func clip(_ id: String, _ tags: [String]) -> BaseItem {
            var item = BaseItem(id: id, name: id, type: "Video")
            item.tags = tags
            return item
        }
        let items = [clip("countdown", ["aster:bumper=in"]), clip("kool-aid", ["aster:commercial"]),
                     clip("next-week", ["aster:promo"]), clip("psa", ["aster:interstitial"]), clip("untagged", [])]
        let all = ChannelsModel.breakClips(from: items, types: Set(BreakKind.allCases))
        #expect(all.bumpers.map(\.id) == ["countdown"])
        #expect(all.commercials.map(\.id) == ["kool-aid"])
        #expect(all.promos.map(\.id) == ["next-week"])
        // The untagged clip is left out.
        #expect(all.interstitials.map(\.id) == ["psa"])
        let some = ChannelsModel.breakClips(from: items, types: [.bumpers, .commercials])
        #expect(some.promos.isEmpty && some.interstitials.isEmpty && some.bumpers.count == 1 && some.commercials.count == 1)
    }

    @Test func trailersAreAFillerType() {
        #expect(ChannelTags.clipKind(["aster:trailer"]) == .trailers)
        #expect(ChannelTags(tags: ["aster:filler-types=trailers"]).fillerTypes == [.trailers])
        #expect(ChannelTags(tags: ["aster:trailer-count=3"]).breaks.trailerCount == 3)
        #expect(ChannelTags(tags: ["aster:trailer-count=9"]).breaks.trailerCount == 1)
        // Every kind is written as "all", so a kind added later joins in.
        let all = ChannelTags(isChannel: true).with { $0.fillerPlaylists = ["Clips"] }.applied(to: [])
        #expect(all.contains("aster:filler-types=all"))
        #expect(all.contains("aster:trailer-count=1"))
        #expect(ChannelTags(tags: all).fillerTypes == Set(BreakKind.allCases))
        #expect(ChannelTags(tags: ["aster:filler-types=all"]).fillerTypes == Set(BreakKind.allCases))
        let clips = ChannelsModel.breakClips(from: [{ var item = BaseItem(id: "t", name: "t", type: "Video"); item.tags = ["aster:trailer"]; return item }()], types: Set(BreakKind.allCases))
        #expect(clips.trailers.map(\.id) == ["t"])
    }

    @Test func aChannelCanBeKeptToSomeUsers() {
        let tags = ChannelTags(tags: ["aster:channel", "aster:user=peppy, JD", "aster:users=kobe", "aster:user=peppy"])
        #expect(tags.users == ["peppy", "JD", "kobe"])
        #expect(tags.isShown(to: "Peppy"))
        #expect(tags.isShown(to: "jd"))
        #expect(!tags.isShown(to: "roman"))
        #expect(!tags.isShown(to: nil))
        // No user tag: everyone.
        #expect(ChannelTags(tags: ["aster:channel"]).isShown(to: "roman"))
        #expect(ChannelTags(tags: ["aster:channel"]).isShown(to: nil))
        // Written as one tag, read back the same.
        let written = tags.applied(to: [])
        #expect(written.contains("aster:user=peppy,JD,kobe"))
        #expect(ChannelTags(tags: written).users == tags.users)
        #expect(!ChannelTags(isChannel: true).applied(to: []).contains { $0.hasPrefix("aster:user") })
    }
}
