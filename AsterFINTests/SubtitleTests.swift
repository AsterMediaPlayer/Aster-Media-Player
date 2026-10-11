//
//  SubtitleTests.swift
//  AsterFINTests
//
//  The app's own subtitle handling: decoding Jellyfin's JSON cue list,
//  cleaning cue text, and finding the cue under the playhead.
//

import Foundation
import Testing
@testable import AsterFIN

struct SubtitleTests {

    @Test func parsesJellyfinTrackEvents() throws {
        let json = """
        {"TrackEvents":[
          {"Id":"2","Text":"Second","StartPositionTicks":50000000,"EndPositionTicks":70000000},
          {"Id":"1","Text":"<i>First</i> line\\r\\nnext","StartPositionTicks":10000000,"EndPositionTicks":30000000},
          {"Id":"3","Text":"   ","StartPositionTicks":80000000,"EndPositionTicks":90000000}
        ]}
        """
        let cues = try SubtitleCue.parse(json: Data(json.utf8))
        #expect(cues.count == 2)
        #expect(cues[0] == SubtitleCue(start: 1, end: 3, text: "First line\nnext"))
        #expect(cues[1] == SubtitleCue(start: 5, end: 7, text: "Second"))
    }

    @Test func cleansMarkupAndEntities() {
        #expect(SubtitleCue.plainText("{\\an8}<b>Tom &amp; Jerry</b><br/>&quot;Hi&quot;") == "Tom & Jerry\n\"Hi\"")
        #expect(SubtitleCue.plainText("one\\Ntwo") == "one\ntwo")
        #expect(SubtitleCue.plainText("<c.yellow>&lt;tag&gt;</c>") == "<tag>")
    }

    @Test func findsCuesUnderThePlayhead() {
        let cues = [
            SubtitleCue(start: 1, end: 3, text: "A"),
            SubtitleCue(start: 2.5, end: 4, text: "B"),
            SubtitleCue(start: 10, end: 12, text: "C"),
        ]
        #expect(SubtitleCue.text(at: 0.5, in: cues) == nil)
        #expect(SubtitleCue.text(at: 1, in: cues) == "A")
        #expect(SubtitleCue.text(at: 2.7, in: cues) == "A\nB")
        #expect(SubtitleCue.text(at: 3.5, in: cues) == "B")
        #expect(SubtitleCue.text(at: 5, in: cues) == nil)
        #expect(SubtitleCue.text(at: 11, in: cues) == "C")
        #expect(SubtitleCue.text(at: 12, in: cues) == nil)
        #expect(SubtitleCue.text(at: 1, in: []) == nil)
    }

    @Test func normalizesLanguageCodes() {
        #expect(LanguageTag.bcp47(from: "eng") == "en")
        #expect(LanguageTag.bcp47(from: "jpn") == "ja")
        #expect(LanguageTag.bcp47(from: "de") == "de")
        #expect(LanguageTag.bcp47(from: nil) == "und")
        #expect(LanguageTag.sameLanguage("eng", "en"))
        #expect(!LanguageTag.sameLanguage("eng", "jpn"))
        #expect(!LanguageTag.sameLanguage(nil, "en"))
    }
}
