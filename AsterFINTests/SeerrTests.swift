//
//  SeerrTests.swift
//  AsterFINTests
//
//  Seerr's replies as its 3.5 server gives them (trimmed from a real one):
//  how sign-in is offered, a search, a show's seasons and where each stands,
//  and what an address typed in Settings becomes.
//

import Foundation
import Testing
@testable import AsterFIN

struct SeerrTests {
    @Test func signInIsOffered() throws {
        let sign = try JSONDecoder().decode(SeerrClient.Sign.self, from: Data(#"{"mediaServerType": 2, "localLogin": true, "mediaServerLogin": true, "applicationTitle": "Seerr"}"#.utf8))
        #expect(sign.signsInWithJellyfinOrEmby)
        #expect(!sign.signsInWithPlex)
    }

    @Test func searchResultsAreRead() throws {
        struct Page: Decodable { var results: [SeerrTitle] }
        let page = try JSONDecoder().decode(Page.self, from: Data(#"{"page": 1, "results": [{"id": 438631, "mediaType": "movie", "title": "Dune", "releaseDate": "2021-09-15", "posterPath": "/v1tRXZ4JtD2Iv6fjkPvT4GiwslV.jpg", "overview": "Paul Atreides, a brilliant and gifted young man born into a great destiny beyond his understanding, must travel to the most dangerous planet in the universe to ensure the future of his family and his people. As malevolent forces explode into conflict over the planet's exclusive supply of the most precious resource in existence - a commodity capable of unlocking humanity's greatest potential - only those who can conquer their fear will survive."}, {"id": 90228, "mediaType": "tv", "name": "Dune: Prophecy", "firstAirDate": "2024-11-17", "posterPath": "/oWVohNsxkxA3u92EzRo8fTuXIS0.jpg", "overview": "Ten thousand years before the ascension of Paul Atreides, sisters Valya and Tula Harkonnen establish the fabled sect and female order that would become known as the Bene Gesserit to control the future of humankind."}]}"#.utf8))
        let dune = try #require(page.results.first)
        #expect(dune.id == 438631)
        #expect(dune.isMovie)
        #expect(dune.year == "2021")
        #expect(dune.posterURL?.absoluteString.hasPrefix("https://image.tmdb.org/t/p/w342/") == true)
        #expect(dune.status == .unknown)
        #expect(dune.status.canRequest)
        let owned = try JSONDecoder().decode(SeerrTitle.self, from: Data(#"{"id": 3034, "mediaType": "movie", "title": "Frankenstein", "mediaInfo": {"status": 5, "jellyfinMediaId": "9f36790b"}}"#.utf8))
        #expect(owned.status == .available)
        #expect(!owned.status.canRequest)
    }

    @Test func aShowsSeasons() throws {
        let fresh = try JSONDecoder().decode(SeerrShow.self, from: Data(#"{"seasons": [{"seasonNumber": 0, "episodeCount": 300, "name": "Specials"}, {"seasonNumber": 1, "episodeCount": 10, "name": "Season 1"}, {"seasonNumber": 2, "episodeCount": 10, "name": "Season 2"}], "mediaInfo": null}"#.utf8)).seasonStatus()
        #expect(fresh.allSatisfy { $0.status == .unknown })
        #expect(!fresh.contains { $0.number == 0 })
        let partly = try JSONDecoder().decode(SeerrShow.self, from: Data(#"{"seasons": [{"seasonNumber": 0, "episodeCount": 3}, {"seasonNumber": 1, "episodeCount": 12}, {"seasonNumber": 2, "episodeCount": 12}, {"seasonNumber": 3, "episodeCount": 12}], "mediaInfo": {"status": 4, "seasons": [{"seasonNumber": 1, "status": 5}, {"seasonNumber": 2, "status": 2}]}}"#.utf8)).seasonStatus()
        // The specials left out; season 1 there, 2 asked for, 3 open.
        #expect(partly.map(\.number) == [1, 2, 3])
        #expect(partly.map(\.status) == [.available, .pending, .unknown])
        #expect(partly[0].episodes == 12)
    }

    @Test func addressesAreRead() {
        #expect(SeerrClient.address("192.168.1.240:5055")?.absoluteString == "http://192.168.1.240:5055")
        #expect(SeerrClient.address(" https://requests.example.com/ ")?.absoluteString == "https://requests.example.com")
        #expect(SeerrClient.address("") == nil)
    }
}
