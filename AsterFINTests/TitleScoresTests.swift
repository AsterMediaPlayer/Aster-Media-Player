//
//  TitleScoresTests.swift
//  AsterFINTests
//
//  A title's scores: Plex's as its title pages give them (from the real
//  reply for The 'Burbs), Jellyfin's two, MDBList's, how each is written,
//  and MDBList's taking the server's place.
//

import Foundation
import Testing
@testable import AsterFIN

struct TitleScoresTests {
    @Test func plexScoresAreAttributed() throws {
        let ratings = [
            PlexRating(image: "imdb://image.rating", type: "audience", value: 6.8),
            PlexRating(image: "rottentomatoes://image.rating.rotten", type: "critic", value: 5.7),
            PlexRating(image: "rottentomatoes://image.rating.upright", type: "audience", value: 7.1),
            PlexRating(image: "themoviedb://image.rating", type: "audience", value: 6.8),
        ]
        let scores = try #require(PlexMapper.scores(ratings))
        #expect(scores.map(\.source) == [.tomatometer, .popcorn, .imdb, .tmdb])
        #expect(scores.map(\.text) == ["57%", "71%", "6.8", "68%"])
        #expect(!scores[0].isFresh)
        #expect(PlexMapper.scores([]) == nil)
    }

    @Test func jellyfinsTwoScores() {
        var item = BaseItem(id: "1")
        item.criticRating = 92
        item.communityRating = 7.84
        #expect(item.serverScores.map(\.source) == [.tomatometer, .community])
        #expect(item.serverScores.map(\.text) == ["92%", "7.8"])
        #expect(item.serverScores[0].isFresh)
        // Zero is "not rated yet", not a score.
        item.criticRating = 0
        #expect(item.serverScores.map(\.source) == [.community])
    }

    @Test func mdbListsReplyIsRead() {
        let json = #"""
        {"title":"The Matrix","ratings":[
          {"source":"imdb","value":8.7,"score":87,"votes":2000000},
          {"source":"metacritic","value":73,"score":73},
          {"source":"trakt","value":85,"score":85},
          {"source":"tomatoes","value":83,"score":83},
          {"source":"popcorn","value":85,"score":85},
          {"source":"tmdb","value":82,"score":82},
          {"source":"letterboxd","value":4.2,"score":84},
          {"source":"rogerebert","value":null,"score":null}]}
        """#
        let scores = TitleScore.ordered(MDBList.parse(Data(json.utf8)))
        #expect(scores.map(\.source) == [.tomatometer, .popcorn, .imdb, .tmdb, .metacritic, .letterboxd])
        #expect(scores.map(\.text) == ["83%", "85%", "8.7", "82%", "73", "4.2"])
    }

    @Test func mdbListIsAskedByTheBestId() {
        var film = BaseItem(id: "1")
        film.type = ItemKind.movie.rawValue
        film.providerIds = ["Imdb": "tt0133093", "Tmdb": "603"]
        #expect(MDBList.lookup(for: film)! == ("tmdb", "movie", "603"))
        var show = BaseItem(id: "2")
        show.type = ItemKind.series.rawValue
        show.providerIds = ["Tvdb": "81189"]
        #expect(MDBList.lookup(for: show)! == ("tvdb", "show", "81189"))
        var episode = BaseItem(id: "3")
        episode.type = ItemKind.episode.rawValue
        episode.providerIds = ["Tmdb": "1"]
        #expect(MDBList.lookup(for: episode) == nil)
    }

    /// MDBList's scores take their sites' place; the server's own
    /// unattributed one goes once there are real ones.
    @Test func mdbListsScoresReplaceTheServers() throws {
        let own = [try #require(TitleScore(.tomatometer, 90, outOf: 100)), try #require(TitleScore(.community, 7, outOf: 10))]
        let added = [try #require(TitleScore(.tomatometer, 83, outOf: 100)), try #require(TitleScore(.imdb, 8.7, outOf: 10))]
        let merged = TitleScore.merged(own, added)
        #expect(merged.map(\.source) == [.tomatometer, .imdb])
        #expect(merged[0].text == "83%")
        #expect(TitleScore.merged(own, []).map(\.source) == [.tomatometer, .community])
    }
}
