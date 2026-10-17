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
        #expect(written == ["Family", "asterfin:theme=retro", "Halloween", "asterfin:channel", "asterfin:number=7", "asterfin:mode=blocks"])
        #expect(ChannelTags(tags: written) == ChannelTags(isChannel: true, number: 7, mode: .blocks))
    }

    @Test func defaultsAreLeftUnwritten() {
        #expect(ChannelTags(isChannel: true).applied(to: []) == ["asterfin:channel"])
        #expect(ChannelTags().applied(to: ["asterfin:channel", "Family"]) == ["Family"])
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
}
