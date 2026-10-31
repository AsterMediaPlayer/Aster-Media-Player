//
//  SongThemeCacheTests.swift
//  AsterFINTests
//
//  What a show's page keeps between runs: its chapter clips, by how many
//  episodes it had, and what AnimeThemes said about each name; and the
//  batched GraphQL request those names go out in.
//

import Foundation
import Testing
@testable import AsterFIN

struct SongThemeCacheTests {
    private func temporaryFile() -> URL {
        URL.temporaryDirectory.appending(path: "song-themes-\(UUID().uuidString).json")
    }

    private func clip(_ number: Int) -> ThemeClip {
        var episode = BaseItem(id: "e\(number)")
        episode.type = ItemKind.episode.rawValue
        episode.name = "Episode \(number)"
        episode.indexNumber = number
        episode.parentIndexNumber = 1
        episode.chapters = [ChapterInfo(startPositionTicks: 0, name: "OP")]
        return ThemeClip(kind: .opening, season: 1, number: 1, episode: episode, chapterIndex: 0,
                         chapterImageTag: "/library/media/1/chapterImages/1", startTicks: 0, endTicks: 900_000_000,
                         song: KnownTheme(isOpening: true, sequence: 1, songTitle: "Wild Side", artists: ["ALI"], episodes: nil))
    }

    @Test func clipsComeBackSlimForTheSameEpisodeCount() async throws {
        let file = temporaryFile()
        let cache = SongThemeCache(file: file)
        await cache.putClips(server: "plex", seriesId: "6357", version: 48, clips: [clip(1)])

        // Read back by another instance: it's the file that holds them.
        let again = SongThemeCache(file: file)
        let kept = try #require(await again.clips(server: "plex", seriesId: "6357", version: 48))
        #expect(kept.count == 1)
        #expect(kept[0].chapterImageTag == "/library/media/1/chapterImages/1")
        #expect(kept[0].episode.name == "Episode 1")
        // The chapters and the song aren't kept: the song is named afresh.
        #expect(kept[0].episode.chapters == nil)
        #expect(kept[0].song == nil)
        // More episodes, or another server: read the chapters again.
        #expect(await again.clips(server: "plex", seriesId: "6357", version: 49) == nil)
        #expect(await again.clips(server: "emby", seriesId: "6357", version: 48) == nil)
    }

    @Test func showsExpireAndNothingFoundExpiresSooner() async {
        let file = temporaryFile()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(now: start)
        let cache = SongThemeCache(file: file) { clock.now }
        let beastars = [ShowCandidate(slug: "beastars", year: 2019, themes: [], aniDBIds: [14070])]
        await cache.putShows(server: "plex", ["Beastars": beastars, "Nothing": []])

        #expect(await cache.shows(server: "plex", name: "BEASTARS ") == beastars)
        #expect(await cache.shows(server: "plex", name: "Nothing") == [])
        // Four days on: the empty answer is asked again, the full one kept.
        clock.now = start.addingTimeInterval(4 * 24 * 60 * 60)
        #expect(await cache.shows(server: "plex", name: "Nothing") == nil)
        #expect(await cache.shows(server: "plex", name: "Beastars") == beastars)
        // A month on: everything is asked again.
        clock.now = start.addingTimeInterval(31 * 24 * 60 * 60)
        #expect(await cache.shows(server: "plex", name: "Beastars") == nil)
    }

    @Test func clearingForgetsOneServer() async {
        let cache = SongThemeCache(file: temporaryFile())
        await cache.putShows(server: "plex", ["A": [ShowCandidate(slug: "a", year: 2020, themes: [])]])
        await cache.putShows(server: "emby", ["A": [ShowCandidate(slug: "a", year: 2020, themes: [])]])
        await cache.clear(server: "plex")
        #expect(await cache.shows(server: "plex", name: "A") == nil)
        #expect(await cache.shows(server: "emby", name: "A") != nil)
    }

    /// Each name is its own `search`, aliased, with its names as variables.
    @Test func theBatchQueryAsksForEachName() {
        let query = AnimeThemesLookup.query(count: 2)
        #expect(query.hasPrefix("query($n0:String!,$n1:String!){"))
        #expect(query.contains("s0:search(search:$n0,first:5){anime{slug year"))
        #expect(query.contains("s1:search(search:$n1,first:5){"))
    }

    /// A reply with two names: one found (its AniDB id, songs and episodes
    /// read), one AnimeThemes left out (nil, not "no shows").
    @Test func theBatchReplyIsReadInOrder() throws {
        let json = #"""
        {"data":{"s0":{"anime":[{"slug":"beastars","year":2019,"resources":{"nodes":[{"site":"ANIDB","externalId":14070},{"site":"MAL","externalId":"39195"}]},
          "animethemes":[{"type":"OP","sequence":null,"song":{"title":{"romaji":"Wild Side"},"performances":[{"artist":{"name":{"main":"ALI"}}}]},"animethemeentries":[{"episodes":null}]},
                         {"type":"ED","sequence":1,"song":{"title":{"romaji":"Le zoo"},"performances":[{"artist":{"name":{"main":"YURiKA"}}}]},"animethemeentries":[{"episodes":"2, 5, 8-9"}]},
                         {"type":"IN","sequence":1,"song":null,"animethemeentries":[]}]}]},
         "s1":null}}
        """#
        let reply = try JSONDecoder().decode(AnimeThemesLookup.GraphReply.self, from: Data(json.utf8))
        let parsed = AnimeThemesLookup.parse(try #require(reply.data), count: 2)
        #expect(parsed.count == 2)
        let beastars = try #require(parsed[0]?.first)
        #expect(beastars.slug == "beastars")
        #expect(beastars.aniDBIds == [14070])
        #expect(beastars.themes.map(\.songTitle) == ["Wild Side", "Le zoo"])
        #expect(beastars.themes[0].sequence == 1)
        #expect(beastars.themes[1].episodes == "2, 5, 8-9")
        #expect(beastars.themes[1].artists == ["YURiKA"])
        #expect(parsed[1] == nil)
    }
}

/// A clock the tests move by hand.
private final class Clock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}
