//
//  AsterTrackingTests.swift
//  AsterFINTests
//
//  The Aster Discovery and Tracking plugin's replies as the contract gives
//  them (docs/aster-tracking-clients.md, trimmed): what the server offers,
//  the Discover page's rows and items, how the rows mix with Seerr's, and
//  what the plugin's failures mean.
//

import Foundation
import Testing
@testable import AsterFIN

struct AsterTrackingTests {
    @Test func featuresArePascalCase() throws {
        let features = try TrackingFeatures.decoder.decode(TrackingFeatures.self, from: Data(#"{"Seerr": {"Enabled": true, "Proxy": "/AsterTracking/Seerr/api/v1"}, "Services": ["simkl", "anilist", "myanimelist"]}"#.utf8))
        #expect(features.seerr?.enabled == true)
        #expect(features.seerr?.proxy == "/AsterTracking/Seerr/api/v1")
        #expect(features.services == ["simkl", "anilist", "myanimelist"])
    }

    private static let home = #"""
    {"Rows": [
      {"Id": "recommended", "Kind": "recommended", "Title": "Recommended for You", "Items": [
        {"Title": "Frieren: Beyond Journey's End", "Year": 2023, "MediaType": "tv", "Anime": true,
         "Poster": "https://image.tmdb.org/t/p/w342/x.jpg", "Progress": "Episode 4 of 12",
         "Ids": {"tmdb": "209867", "anilist": 154587, "tmdbSeason": "1"},
         "InLibrary": {"ItemId": "abc", "Name": "Frieren", "Type": "Series"}, "Genres": ["Adventure"], "Adult": false},
        {"Title": "A Server Film", "Year": 2020, "MediaType": "movie", "Poster": "/Items/9f/Images/Primary?maxHeight=450",
         "Ids": {"tmdb": "55"}}
      ]},
      {"Id": "watchlist", "Kind": "watchlist", "Title": "Your Watchlists", "Items": [{"Title": "W", "MediaType": "tv", "Ids": {"tmdb": "7"}}]},
      {"Id": "trending", "Kind": "trending", "Title": "Trending", "Items": [{"Title": "T", "MediaType": "tv", "Ids": {"tmdb": "8"}}]},
      {"Id": "season", "Kind": "season", "Title": "This Season's Anime", "Items": [{"Title": "S", "MediaType": "tv", "Ids": {"tmdb": "9"}}]},
      {"Id": "empty", "Kind": "because", "Title": "Because You Watched X", "Items": []}
    ], "Built": "2026-11-04T12:00:00Z"}
    """#

    @Test func theDiscoverPageIsRead() throws {
        let page = try TrackingFeatures.decoder.decode(TrackedHome.self, from: Data(Self.home.utf8))
        #expect(page.rows.map(\.kind) == ["recommended", "watchlist", "trending", "season", "because"])
        let frieren = try #require(page.rows.first?.items.first)
        #expect(frieren.tmdbId == 209867)
        #expect(frieren.ids?["anilist"]?.value == "154587")
        #expect(frieren.inLibrary?.itemId == "abc")
        #expect(frieren.subtitle == "Episode 4 of 12")
        #expect(frieren.seerrTitle?.id == 209867)
        #expect(frieren.seerrTitle?.isMovie == false)
    }

    /// A poster is a web address, or a path on the server; only http and
    /// https are complete addresses.
    @Test func postersAreWebAddressesOrServerPaths() throws {
        let page = try TrackingFeatures.decoder.decode(TrackedHome.self, from: Data(Self.home.utf8))
        let server = URL(string: "https://media.example.org/")
        let items = try #require(page.rows.first?.items)
        #expect(items[0].posterURL(server: server)?.absoluteString == "https://image.tmdb.org/t/p/w342/x.jpg")
        #expect(items[1].posterURL(server: server)?.absoluteString == "https://media.example.org/Items/9f/Images/Primary?maxHeight=450")
        #expect(items[1].subtitle == "2020 · Film")
    }

    /// The server's rows first; Seerr's after (less its Watchlist when the
    /// server has one); the server's Trending and Season in Seerr's Trending's
    /// place, then In Theaters.
    @Test func rowsMixAsTheContractSays() throws {
        let rows = try TrackingFeatures.decoder.decode(TrackedHome.self, from: Data(Self.home.utf8)).rows
        let sliders = [SeerrSlider(type: 1), SeerrSlider(type: 3), SeerrSlider(type: 4), SeerrSlider(type: 5)]
        let mixed = TrackedDiscover.order(rows: rows, sliders: sliders, theaters: true).map(\.id)
        #expect(mixed == ["tracked-recommended", "tracked-watchlist", "slider-1|0|", "tracked-trending", "tracked-season", "theaters", "slider-5|0|"])
        // Without Seerr: the server's rows alone, empty ones left out.
        #expect(TrackedDiscover.order(rows: rows, sliders: nil, theaters: false).map(\.id) == ["tracked-recommended", "tracked-watchlist", "tracked-trending", "tracked-season"])
        // The server has no Trending: Seerr's stays, and In Theaters follows it.
        let none = rows.filter { $0.kind != "trending" && $0.kind != "season" }
        #expect(TrackedDiscover.order(rows: none, sliders: sliders, theaters: true).map(\.id).contains("slider-4|0|"))
        // No Trending among Seerr's: the server's go last.
        let noTrending = TrackedDiscover.order(rows: rows, sliders: [SeerrSlider(type: 1)], theaters: true).map(\.id)
        #expect(noTrending.suffix(2) == ["tracked-trending", "tracked-season"])
        // Seerr's Watchlist stays when the server has none of its own.
        let withoutWatchlist = rows.filter { $0.kind != "watchlist" }
        #expect(TrackedDiscover.order(rows: withoutWatchlist, sliders: sliders, theaters: false).map(\.id).contains("slider-3|0|"))
    }

    @Test func theServersFailuresAreSaidPlainly() {
        let notThere = Data(#"{"message":"Not available on this server."}"#.utf8)
        #expect(SeerrClient.failure(404, notThere) == .notOnServer("Not available on this server."))
        #expect(SeerrClient.failure(502, Data()) == .unreachable)
        #expect(SeerrClient.failure(503, Data()) == .off)
        #expect(SeerrClient.failure(401, Data()) == .signedOut)
        #expect(SeerrClient.failure(404, Data()) == .http(404))
        #expect(SeerrError.unreachable.errorDescription == "Requests aren't available right now.")
    }
}
