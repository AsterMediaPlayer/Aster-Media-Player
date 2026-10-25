//
//  PlexPlaybackTests.swift
//  AsterFINTests
//
//  Playing from Plex: what to skip (Plex Pass markers, else chapters named
//  for an opening or ending), subtitle files beside the video, and which
//  subtitle tracks the app fetches and which are burned in.
//

import Foundation
import Testing
@testable import AsterFIN

struct PlexPlaybackTests {
    @Test func markersComeFirst() {
        let segments = PlexSegments.segments(
            markers: [PlexMarker(type: "intro", startTimeOffset: 60_000, endTimeOffset: 150_000),
                      PlexMarker(type: "credits", startTimeOffset: 1_300_000, endTimeOffset: 1_400_000)],
            chapters: [PlexChapter(tag: "Opening", startTimeOffset: 135_990, endTimeOffset: 226_000)],
            itemId: "1", durationMilliseconds: 1_422_428)
        #expect(segments.map(\.type) == ["Intro", "Outro"])
        #expect(segments[0].startTicks == 600_000_000)
        #expect(segments[0].endTicks == 1_500_000_000)
    }

    /// The anime episode on the test server: no markers, chapters named
    /// Opening and Ending.
    @Test func namedChaptersStandInForMarkers() {
        let chapters = [
            PlexChapter(tag: "Prologue", startTimeOffset: 1002, endTimeOffset: 135_990),
            PlexChapter(tag: "Opening", startTimeOffset: 135_990, endTimeOffset: 226_000),
            PlexChapter(tag: "As of Today, I'm a Bad Girl!", startTimeOffset: 226_000, endTimeOffset: 545_980),
            PlexChapter(tag: "Ending", startTimeOffset: 1_280_970, endTimeOffset: 1_371_020),
            PlexChapter(tag: "Epilogue", startTimeOffset: 1_371_020, endTimeOffset: 1_422_420),
        ]
        let segments = PlexSegments.segments(markers: [], chapters: chapters, itemId: "6139", durationMilliseconds: 1_422_428)
        #expect(segments.map(\.type) == ["Intro", "Outro"])
        #expect(segments[0].startTicks == 1_359_900_000)
        #expect(segments[0].endTicks == 2_260_000_000)
        #expect(segments[1].startTicks == 12_809_700_000)
    }

    @Test func plainChaptersGiveNothing() {
        let chapters = [PlexChapter(tag: "Chapter 1", startTimeOffset: 0, endTimeOffset: 60_000)]
        #expect(PlexSegments.segments(markers: [], chapters: chapters, itemId: "x", durationMilliseconds: 60_000).isEmpty)
    }

    @Test func srtAndWebVTT() {
        let srt = "1\r\n00:00:01,500 --> 00:00:03,000\r\n<i>Hello</i>\r\nthere\r\n\r\n2\r\n00:01:02,000 --> 00:01:04,250\r\nAgain\r\n"
        let cues = PlexSubtitles.cues(from: srt, codec: "srt")
        #expect(cues == [SubtitleCue(start: 1.5, end: 3, text: "Hello\nthere"), SubtitleCue(start: 62, end: 64.25, text: "Again")])

        let vtt = "WEBVTT\n\n00:05.000 --> 00:06.000 align:start\nShort form\n"
        #expect(PlexSubtitles.cues(from: vtt, codec: "vtt") == [SubtitleCue(start: 5, end: 6, text: "Short form")])
    }

    @Test func assDialogueAsText() {
        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:10.50,0:00:12.00,Default,,0,0,0,,{\\an8}Signs, here\\Nand there
        """
        #expect(PlexSubtitles.cues(from: ass, codec: "ass") == [SubtitleCue(start: 10.5, end: 12, text: "Signs, here\nand there")])
    }

    /// Plex hands out subtitle files beside the video, not tracks inside
    /// it: those are burned in when the stream is converted.
    @Test func onlySubtitleFilesAreFetched() {
        let sidecar = PlexStream(id: 1, streamType: 3, index: 9, codec: "srt", key: "/library/streams/1")
        let embedded = PlexStream(id: 2, streamType: 3, index: 4, codec: "ass")
        let picture = PlexStream(id: 3, streamType: 3, index: 5, codec: "pgs")
        #expect(PlexClient.playbackStream(sidecar).isTextSubtitleStream == true)
        #expect(PlexClient.playbackStream(embedded).isTextSubtitleStream == false)
        #expect(PlexClient.playbackStream(picture).deliveryMethod == "Encode")
        #expect(PlexClient.playbackStream(embedded).index == 4)
    }

    @Test func theFileAndProgressAddresses() {
        let link = PlexLink(accountToken: "a", machineId: "m", connections: [])
        let client = PlexClient(baseURL: URL(string: "http://192.168.1.240:32400")!, accessToken: "tok", userId: "u", link: link)
        let file = client.directStreamURL(itemId: "6139", mediaSourceId: "8696", playSessionId: "s1", container: "mkv")
        #expect(file.path() == "/library/parts/8696/file")
        #expect(file.query()?.contains("X-Plex-Token=tok") == true)
        #expect(client.absoluteURL(serverRelative: "/video/:/transcode/universal/start.m3u8?a=1")?.absoluteString == "http://192.168.1.240:32400/video/:/transcode/universal/start.m3u8?a=1")
    }
}
