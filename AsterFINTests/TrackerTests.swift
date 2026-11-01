//
//  TrackerTests.swift
//  AsterFINTests
//
//  The tracking accounts' scrambling (a copy for one server user opens
//  only for that user), and reading the sign-in pages' redirects.
//

import Foundation
import Testing
@testable import AsterFIN

struct TrackerTests {
    private var secrets: TrackerSecrets {
        var secrets = TrackerSecrets()
        secrets.aniList = .init(token: "abc.def.ghi", name: "Phillip", expires: Date(timeIntervalSince1970: 1_900_000_000))
        secrets.myAnimeList = .init(tokens: .init(access: "a1", refresh: "r1", expires: Date(timeIntervalSince1970: 1_800_000_000)), name: "phil")
        secrets.updated = Date(timeIntervalSince1970: 1_790_000_000)
        return secrets
    }

    @Test func scrambledForOneUser() throws {
        let blob = try #require(TrackerVault.seal(secrets, user: "5F2C-AB10"))
        #expect(blob.hasPrefix("aster1:"))
        #expect(!blob.contains("abc.def.ghi"))
        // The user's id however it's written: case and dashes don't count.
        #expect(TrackerVault.open(blob, user: "5f2cab10") == secrets)
        #expect(TrackerVault.open(blob, user: "someone-else") == nil)
        #expect(TrackerVault.open("not a blob", user: "5f2cab10") == nil)
        // Sealed twice, two different blobs (a fresh nonce each time).
        #expect(TrackerVault.seal(secrets, user: "5f2cab10") != blob)
    }

    @Test func aniListsRedirectGivesTheToken() throws {
        let url = try #require(URL(string: "aster://anilist-auth#access_token=eyJ0eXAi.abc&token_type=Bearer&expires_in=31536000"))
        let found = try #require(AniList.token(fromRedirect: url))
        #expect(found.token == "eyJ0eXAi.abc")
        #expect(abs((found.expires?.timeIntervalSinceNow ?? 0) - 31_536_000) < 60)
        #expect(AniList.token(fromRedirect: try #require(URL(string: "aster://anilist-auth?error=access_denied"))) == nil)
    }

    @Test func myAnimeListsRedirectGivesTheCode() throws {
        let url = try #require(URL(string: "aster://mal-auth?code=def502&state=S1"))
        #expect(MyAnimeList.code(fromRedirect: url, state: "S1") == "def502")
        // Another sign-in's answer isn't taken.
        #expect(MyAnimeList.code(fromRedirect: url, state: "S2") == nil)
    }

    /// An episode goes by its show's ids with its season and number; a film
    /// by its own; an anime episode to Simkl by its season's MyAnimeList id.
    @Test func historyBodies() throws {
        var show = BaseItem(id: "s")
        show.type = ItemKind.series.rawValue
        show.providerIds = ["Tvdb": "81189", "Tmdb": "1396", "Imdb": "tt0903747"]
        var episode = BaseItem(id: "e")
        episode.type = ItemKind.episode.rawValue
        episode.parentIndexNumber = 2
        episode.indexNumber = 5
        let watched = try #require(WatchedTitle(item: episode, show: show))
        let body = watched.historyBody(idTypes: ["tmdb", "imdb", "tvdb"])
        let shows = try #require(body["shows"] as? [[String: Any]])
        let ids = try #require(shows.first?["ids"] as? [String: Any])
        #expect(ids["tvdb"] as? Int == 81189)
        #expect(ids["imdb"] as? String == "tt0903747")
        let seasons = try #require(shows.first?["seasons"] as? [[String: Any]])
        #expect(seasons.first?["number"] as? Int == 2)
        #expect((seasons.first?["episodes"] as? [[String: Any]])?.first?["number"] as? Int == 5)

        var film = BaseItem(id: "f")
        film.type = ItemKind.movie.rawValue
        film.providerIds = ["Tmdb": "603"]
        let movies = try #require(WatchedTitle(item: film, show: nil)?.historyBody(idTypes: ["tmdb"])["movies"] as? [[String: Any]])
        #expect((movies.first?["ids"] as? [String: Any])?["tmdb"] as? Int == 603)

        let anime = try #require(WatchedTitle(item: episode, show: show, anime: AnimeEntry(aniList: 1, myAnimeList: 37779)))
        let simkl = try #require(anime.historyBody(idTypes: ["mal"], simklAnime: true)["shows"] as? [[String: Any]])
        #expect((simkl.first?["ids"] as? [String: Any])?["mal"] as? Int == 37779)
        #expect((simkl.first?["episodes"] as? [[String: Any]])?.first?["number"] as? Int == 5)
        #expect(simkl.first?["seasons"] == nil)
        // No ids at all: nothing to send.
        #expect(WatchedTitle(item: episode, show: BaseItem(id: "x")) == nil)
    }

    @Test func formsAreEncoded() {
        let body = MyAnimeList.formBody(["status": "watching", "num_watched_episodes": "5", "redirect_uri": "aster://mal-auth"])
        #expect(body == "num_watched_episodes=5&redirect_uri=aster%3A%2F%2Fmal-auth&status=watching")
    }
}
