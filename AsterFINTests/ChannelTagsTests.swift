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
            "aster:bug-location=bottom-right", "aster:bug-size=100%", "aster:bug-hide=off",
        ])
        #expect(ChannelTags(tags: written) == ChannelTags(isChannel: true, number: 7, mode: .blocks))
    }

    /// Defaults are written too, so every setting shows in Jellyfin.
    @Test func everySettingIsWritten() {
        let defaults = ["aster:mode=rotation", "aster:reshuffle=day", "aster:blocks=2-4", "aster:seed=0", "aster:logo=off", "aster:bug=off", "aster:bug-location=bottom-right", "aster:bug-size=100%", "aster:bug-hide=off"]
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
            "aster:seed=2", "aster:logo=off", "aster:bug=on", "aster:bug-location=bottom-right", "aster:bug-size=100%", "aster:bug-hide=off",
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
        #expect(ChannelTags(tags: ["aster:bug-hide=off"]).bugHideAfter == 0)
        #expect(ChannelTags(tags: ["aster:bug-hide=soon"]).bugHideAfter == 0)
        #expect(ChannelTags(tags: ["aster:bug-hide=99999"]).bugHideAfter == 0)
        let written = ChannelTags(isChannel: true).with { $0.bugHideAfter = 30 }.applied(to: [])
        #expect(written.contains("aster:bug-hide=30"))
        #expect(ChannelTags(tags: written).bugHideAfter == 30)
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
}
