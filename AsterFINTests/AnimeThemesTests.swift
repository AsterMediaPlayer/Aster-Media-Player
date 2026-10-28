//
//  AnimeThemesTests.swift
//  AsterFINTests
//
//  The song card from AnimeThemes when there's no OP/ED plugin: its reply
//  (trimmed from the real one for Bad Girl), the episodes each theme plays
//  in, and the card each episode gets.
//

import Foundation
import Testing
@testable import AsterFIN

struct AnimeThemesTests {
    /// A Music tab clip gets its song: Beastars on AnimeThemes has one
    /// opening for the whole season and endings that take turns by episode.
    @Test func aClipGetsTheSongOfItsEpisode() {
        let known = [
            KnownTheme(isOpening: true, sequence: 1, songTitle: "Wild Side", artists: ["ALI"], episodes: nil),
            KnownTheme(isOpening: false, sequence: 1, songTitle: "Le zoo", artists: ["YOASOBI"], episodes: "2, 5, 8-9"),
            KnownTheme(isOpening: false, sequence: 2, songTitle: "Nemureru Honoo", artists: [], episodes: "3, 7, 10"),
        ]
        func clip(_ kind: ThemeClip.Kind, _ number: Int) -> ThemeClip {
            var episode = BaseItem(id: "e\(number)")
            episode.type = ItemKind.episode.rawValue
            episode.indexNumber = number
            return ThemeClip(kind: kind, season: 1, number: 1, episode: episode,
                             chapterIndex: 0, chapterImageTag: nil, startTicks: 0, endTicks: 900_000_000)
        }
        #expect(OpeningsEndings.song(for: clip(.opening, 4), in: known)?.songTitle == "Wild Side")
        #expect(OpeningsEndings.song(for: clip(.ending, 2), in: known)?.songTitle == "Le zoo")
        #expect(OpeningsEndings.song(for: clip(.ending, 3), in: known)?.songTitle == "Nemureru Honoo")
        // An ending AnimeThemes doesn't place in that episode: no song, rather than a wrong one.
        #expect(OpeningsEndings.song(for: clip(.ending, 1), in: known) == nil)
    }

    private let reply = #"""
    {"anime":{"name":"Bad Girl","slug":"bad_girl","year":2025,"animethemes":[
      {"type":"OP","sequence":null,"song":{"title":"Super Big Love!","performances":[{"artist":{"name":"Tenrou-gun"}}]},"animethemeentries":[{"episodes":"1-"}]},
      {"type":"ED","sequence":1,"song":{"title":"BAD SURPRISE","performances":[{"artist":{"name":"Tenrou-gun"}}]},"animethemeentries":[{"episodes":"1-6, 8-"}]},
      {"type":"ED","sequence":2,"song":{"title":"Heart Kakimawashite Ageru♡","performances":[{"artist":{"name":"Miharu Hanai"}}]},"animethemeentries":[{"episodes":"7"}]}
    ]}}
    """#

    private func themes() throws -> [KnownTheme] {
        AnimeThemesLookup.themes(try JSONDecoder().decode(AnimeThemesLookup.AnimeReply.self, from: Data(reply.utf8)).anime)
    }

    @Test func aRepliesThemesAreRead() throws {
        let themes = try themes()
        #expect(themes.count == 3)
        #expect(themes[0] == KnownTheme(isOpening: true, sequence: 1, songTitle: "Super Big Love!", artists: ["Tenrou-gun"], episodes: "1-"))
        #expect(themes[2].artists == ["Miharu Hanai"])
    }

    @Test func episodeRanges() {
        #expect(KnownTheme.ranges("1-6, 8-") == [1...6, 8...Int.max])
        #expect(KnownTheme.ranges("7") == [7...7])
        let ending = KnownTheme(isOpening: false, sequence: 1, songTitle: nil, artists: [], episodes: "1-6, 8-")
        #expect(ending.plays(inEpisode: 6))
        #expect(!ending.plays(inEpisode: 7))
        #expect(ending.plays(inEpisode: 12))
        #expect(ending.plays(inEpisode: nil))
    }

    /// Episode 7 has its own ending; the rest share the first.
    @Test func eachEpisodeGetsItsEnding() throws {
        func card(forEpisode number: Int) throws -> [String] {
            var episode = BaseItem(id: "e\(number)")
            episode.type = ItemKind.episode.rawValue
            episode.seriesName = "Bad Girl"
            episode.indexNumber = number
            episode.parentIndexNumber = 1
            episode.chapters = [
                ChapterInfo(startPositionTicks: 0, name: "Prologue"),
                ChapterInfo(startPositionTicks: 1_359_900_000, name: "Opening"),
                ChapterInfo(startPositionTicks: 2_260_000_000, name: "Part A"),
                ChapterInfo(startPositionTicks: 12_809_700_000, name: "Ending"),
                ChapterInfo(startPositionTicks: 13_710_200_000, name: "Epilogue"),
            ]
            let moments = PlaybackCoordinator.themeMoments(for: episode, segments: [], pluginThemes: [], knownThemes: try themes())
            return moments.map { "\($0.info.kicker): \($0.info.title) · \($0.info.artists ?? "")" }
        }
        #expect(try card(forEpisode: 7) == ["Opening 1: Super Big Love! · Tenrou-gun", "Ending 2: Heart Kakimawashite Ageru♡ · Miharu Hanai"])
        #expect(try card(forEpisode: 3) == ["Opening 1: Super Big Love! · Tenrou-gun", "Ending 1: BAD SURPRISE · Tenrou-gun"])
    }
}
