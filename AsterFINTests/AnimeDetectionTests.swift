//
//  AnimeDetectionTests.swift
//  AsterFINTests
//
//  How a title and a library are told to be anime on each server: Shoko's
//  match on Jellyfin; on Emby and Plex, which have no Shoko, the anime
//  sites' ids in whatever case the server writes them, the genre, the
//  HAMA agent's guid, and a library's name.
//

import Foundation
import Testing
@testable import AsterFIN

struct AnimeDetectionTests {
    private func item(ids: [String: String]? = nil, genres: [String]? = nil) -> BaseItem {
        var item = BaseItem(id: "1")
        item.providerIds = ids
        item.genres = genres
        return item
    }

    @Test func shokoAndAniDBMarkAnimeWhateverTheCase() {
        #expect(item(ids: ["Shoko": "s1"]).isAnime)
        #expect(item(ids: ["AniDB": "1234"]).isAnime)
        // Emby writes the provider's name in lowercase.
        #expect(item(ids: ["anidb": "1234"]).isAnime)
        #expect(item(ids: ["shoko series": "s1"]).isAnime)
        #expect(!item(ids: ["Tvdb": "1"]).isAnime)
        #expect(!item().isAnime)
    }

    @Test func embyAndPlexAlsoGoByAnimeIdsAndTheGenre() {
        let aniList = item(ids: ["AniList": "99"])
        let genre = item(genres: ["Animation", "Anime"])
        for kind in [ServerKind.emby, .plex] {
            #expect(aniList.isAnime(on: kind))
            #expect(item(ids: ["myanimelist": "7"]).isAnime(on: kind))
            #expect(genre.isAnime(on: kind))
            #expect(!item(ids: ["Tmdb": "1"], genres: ["Animation"]).isAnime(on: kind))
        }
        // On Jellyfin, Shoko's match is the sign.
        #expect(!aniList.isAnime(on: .jellyfin))
        #expect(!genre.isAnime(on: .jellyfin))
        #expect(item(ids: ["AniDB": "1"]).isAnime(on: .jellyfin))
    }

    @Test func aProviderIdIsFoundInAnyCase() {
        #expect(item(ids: ["anidb": "1234"]).providerId("AniDB") == "1234")
        #expect(item(ids: ["AniDB": "1234"]).providerId("anidb") == "1234")
        #expect(item(ids: ["Tvdb": "1"]).providerId("AniDB") == nil)
    }

    @Test func aLibraryNamedForAnime() {
        var library = BaseItem(id: "l")
        library.name = "Anime Movies"
        #expect(library.isNamedForAnime)
        library.name = "TV Shows"
        #expect(!library.isNamedForAnime)
        library.name = nil
        #expect(!library.isNamedForAnime)
    }

    @Test func plexNamesTheAnimeSitesAndReadsTheHamaGuid() throws {
        func ids(_ json: String) throws -> [String: String]? {
            let metadata = try JSONDecoder().decode(PlexReply.self, from: Data(json.utf8)).mediaContainer.metadata![0]
            return PlexMapper.item(metadata).providerIds
        }
        let hama = try ids(#"{"MediaContainer":{"Metadata":[{"ratingKey":"1","type":"show","title":"A","guid":"com.plexapp.agents.hama://anidb-1234?lang=en"}]}}"#)
        #expect(hama?["AniDB"] == "1234")
        let anidb = try ids(#"{"MediaContainer":{"Metadata":[{"ratingKey":"1","type":"show","title":"A","guid":"plex://show/abc","Guid":[{"id":"anidb://99"},{"id":"anilist://5"},{"id":"myanimelist://8"}]}]}}"#)
        #expect(anidb == ["AniDB": "99", "AniList": "5", "MyAnimeList": "8"])
        #expect(try ids(#"{"MediaContainer":{"Metadata":[{"ratingKey":"1","type":"show","title":"A","guid":"plex://show/abc"}]}}"#) == nil)
    }

    /// Chapters named "Title" or "End" count when an episode has no "OP" or
    /// "ED" chapter; beside one, they're the cold open and the preview.
    @Test func looseChapterNamesStandInForMissingOnes() {
        func episode(_ names: [String]) -> BaseItem {
            var item = BaseItem(id: "e1")
            item.type = ItemKind.episode.rawValue
            item.indexNumber = 1
            item.parentIndexNumber = 1
            // Every chapter a minute and a half, the last running to the end.
            item.runTimeTicks = Int64(names.count) * 90 * 10_000_000
            item.chapters = names.enumerated().map { index, name in
                ChapterInfo(startPositionTicks: Int64(index) * 90 * 10_000_000, name: name)
            }
            return item
        }
        let loose = OpeningsEndings.find(in: [episode(["Title", "Part A", "Part B", "End"])])
        #expect(loose.map(\.kind) == [.opening, .ending])
        let definite = OpeningsEndings.find(in: [episode(["Title", "OP", "Part A", "ED", "End"])])
        #expect(definite.map(\.kind) == [.opening, .ending])
        #expect(definite.map(\.chapterIndex) == [1, 3])
    }
}
