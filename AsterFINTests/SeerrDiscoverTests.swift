//
//  SeerrDiscoverTests.swift
//  AsterFINTests
//
//  The Discover tab's asks of Seerr: filters written as its own Discover
//  page writes them, each kind of row's list, and requests as Seerr 3.5
//  lists them (trimmed from a real one).
//

import Foundation
import Testing
@testable import AsterFIN

struct SeerrDiscoverTests {
    @Test func anUnfilteredGrid() {
        let path = SeerrFilter(kind: .movie).path(page: 1)
        #expect(path == "/discover/movies?page=1&sortBy=popularity.desc")
    }

    @Test func everyFilterAsSeerrWritesIt() {
        var filter = SeerrFilter(kind: .tv)
        filter.sort = .newest
        filter.genres = [16, 10759]
        filter.fromYear = 2020
        filter.toYear = 2029
        filter.minimumRating = 7
        filter.minimumRuntime = 30
        filter.maximumRuntime = 60
        filter.language = "ja"
        filter.company = SeerrCompany(id: 213, name: "Netflix")
        filter.providers = [8, 337]
        filter.region = "US"
        let path = filter.path(page: 2)
        #expect(path.hasPrefix("/discover/tv?page=2&sortBy=first_air_date.desc"))
        #expect(path.contains("genre=16%2C10759"))
        #expect(path.contains("firstAirDateGte=2020-01-01&firstAirDateLte=2029-12-31"))
        #expect(path.contains("voteAverageGte=7&voteCountGte=50"))
        #expect(path.contains("withRuntimeGte=30&withRuntimeLte=60"))
        #expect(path.contains("language=ja"))
        #expect(path.contains("network=213"))
        #expect(path.contains("watchProviders=8|337&watchRegion=US"))
        #expect(filter.activeCount == 7)
        // Films go by studio and release date instead.
        var film = SeerrFilter(kind: .movie)
        film.company = SeerrCompany(id: 3, name: "Pixar")
        film.fromYear = 1990
        #expect(film.path(page: 1).contains("studio=3"))
        #expect(film.path(page: 1).contains("primaryReleaseDateGte=1990-01-01"))
    }

    @Test func animeIsAnimationFromJapan() {
        var filter = SeerrFilter(kind: .tv)
        filter.genres = [10759]
        filter.isAnime = true
        #expect(filter.genres == [16, 10759])
        #expect(filter.language == "ja")
        #expect(filter.path(page: 1).contains("genre=16%2C10759"))
        #expect(filter.path(page: 1).contains("language=ja"))
        filter.isAnime = false
        #expect(filter.genres == [10759])
        #expect(filter.language == nil)
        // Japanese alone, or Animation alone, isn't anime.
        filter.language = "ja"
        #expect(!filter.isAnime)
    }

    @Test func eachRowsList() {
        func path(_ type: Int, _ data: String? = nil) -> String? {
            SeerrClient.titlesPath(for: SeerrSlider(type: type, data: data))?.path
        }
        #expect(path(4) == "/discover/trending?page=1")
        #expect(path(7) == "/discover/movies/upcoming?page=1")
        #expect(path(11) == "/discover/tv/upcoming?page=1")
        #expect(path(14, "28") == "/discover/movies?page=1&genre=28")
        #expect(path(13, "210024,6075") == "/discover/movies?page=1&keywords=210024%2C6075")
        #expect(path(19, "213") == "/discover/tv/network/213?page=1")
        #expect(path(21, "US,8|337") == "/discover/tv?page=1&watchRegion=US&watchProviders=8|337")
        // Genres and companies are rows of their own kind, not titles.
        #expect(path(6) == nil)
        #expect(path(12) == nil)
        #expect(SeerrClient.sliderTitle(SeerrSlider(type: 9)) == "Popular Series")
        #expect(SeerrClient.sliderTitle(SeerrSlider(type: 13, title: "Cyberpunk")) == "Cyberpunk")
    }

    /// In Theaters looks back six weeks from today.
    @Test func inTheatersWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)))
        #expect(SeerrClient.theatricalWindow(from: today) == ("2026-09-20", "2026-11-01"))
        #expect(SeerrClient.sliderTitle(SeerrSlider(type: SeerrClient.inTheatersType)) == "In Theaters")
        #expect(SeerrClient.titlesPath(for: SeerrSlider(type: SeerrClient.inTheatersType)) == nil)
    }

    /// A requested film arrives on its first home release still ahead;
    /// once one's past it's out, and with only a cinema date, that.
    @Test func whenARequestedFilmArrives() throws {
        func releases(_ json: String) throws -> SeerrReleases {
            try JSONDecoder().decode(SeerrReleases.self, from: Data(json.utf8))
        }
        let now = try #require(SeerrReleases.date("2026-11-01T12:00:00.000Z"))
        let streetFighter = try releases(#"{"results": [{"iso_3166_1": "US", "release_dates": [{"type": 3, "release_date": "2026-10-16T00:00:00.000Z"}, {"type": 4, "release_date": "2026-12-01T00:00:00.000Z"}]}]}"#)
        let arrival = try #require(streetFighter.arrival(region: "US", now: now))
        #expect(arrival.how == "Digital Release")
        #expect(arrival.date == SeerrReleases.date("2026-12-01T00:00:00.000Z"))
        // Out on digital already: not upcoming, whatever the disc's date.
        let coyote = try releases(#"{"results": [{"iso_3166_1": "US", "release_dates": [{"type": 4, "release_date": "2026-09-29T00:00:00.000Z"}, {"type": 5, "release_date": "2026-12-01T00:00:00.000Z"}]}]}"#)
        #expect(coyote.arrival(region: "US", now: now) == nil)
        // Only a cinema date, ahead; and another region falls back to the US.
        let cinema = try releases(#"{"results": [{"iso_3166_1": "US", "release_dates": [{"type": 3, "release_date": "2027-03-05T00:00:00.000Z"}]}]}"#)
        #expect(cinema.arrival(region: "GB", now: now)?.how == "In Theaters")
    }

    /// A request starts on Seerr's defaults for the server, the anime ones
    /// for an anime show; an empty anime folder falls back to the usual.
    @Test func whereARequestGoesByDefault() throws {
        let sonarr = try JSONDecoder().decode(SeerrService.self, from: Data(#"{"id": 0, "name": "Sonarr", "is4k": false, "isDefault": true, "activeProfileId": 4, "activeDirectory": "/data/tv", "activeLanguageProfileId": 1, "activeAnimeProfileId": 7, "activeAnimeDirectory": "/data/anime", "activeAnimeLanguageProfileId": 2}"#.utf8))
        let show = SeerrRequestOptions(server: sonarr, anime: false)
        #expect(show.rootFolder == "/data/tv")
        #expect(show.profileId == 4)
        let anime = SeerrRequestOptions(server: sonarr, anime: true)
        #expect(anime.rootFolder == "/data/anime")
        #expect(anime.profileId == 7)
        #expect(anime.languageProfileId == 2)
        let plain = try JSONDecoder().decode(SeerrService.self, from: Data(#"{"id": 1, "name": "Sonarr 2", "activeProfileId": 4, "activeDirectory": "/tv", "activeAnimeDirectory": ""}"#.utf8))
        #expect(SeerrRequestOptions(server: plain, anime: true).rootFolder == "/tv")
        var body: [String: Any] = [:]
        anime.add(to: &body)
        #expect(body["serverId"] as? Int == 0)
        #expect(body["rootFolder"] as? String == "/data/anime")
    }

    @Test func aServersChoicesAreRead() throws {
        let choices = try JSONDecoder().decode(SeerrServiceChoices.self, from: Data(#"{"server": {"id": 0, "name": "Sonarr"}, "profiles": [{"id": 4, "name": "HD-1080p"}], "rootFolders": [{"id": 1, "freeSpace": 2100000000000, "path": "/data/anime", "totalSpace": 4000000000000}], "languageProfiles": null, "tags": []}"#.utf8))
        #expect(choices.profiles?.first?.name == "HD-1080p")
        #expect(choices.rootFolders?.first?.path == "/data/anime")
        #expect(choices.languageProfiles == nil)
    }

    @Test func requestsAreRead() throws {
        struct Reply: Decodable { var results: [SeerrRequest] }
        let reply = try JSONDecoder().decode(Reply.self, from: Data(#"{"pageInfo": {"pages": 2, "pageSize": 3, "results": 6, "page": 1}, "results": [{"id": 12, "status": 1, "createdAt": "2026-11-01T12:31:29.000Z", "type": "tv", "is4k": false, "media": {"id": 261, "mediaType": "tv", "tmdbId": 35106, "status": 2}, "seasons": [{"id": 19, "seasonNumber": 1, "status": 1}], "requestedBy": {"id": 1, "displayName": "peppy", "permissions": 2}}, {"id": 9, "status": 2, "type": "movie", "media": {"tmdbId": 693134, "mediaType": "movie", "status": 5}}]}"#.utf8))
        let pending = try #require(reply.results.first)
        #expect(pending.isPending)
        #expect(pending.stateLabel == "Pending Approval")
        #expect(pending.seasons?.map(\.seasonNumber) == [1])
        #expect(pending.requestedBy?.displayName == "peppy")
        #expect(pending.created != nil)
        #expect(reply.results[1].stateLabel == "Available")
    }

    @Test func whoManagesRequests() throws {
        let admin = try JSONDecoder().decode(SeerrUser.self, from: Data(#"{"id": 1, "displayName": "peppy", "permissions": 2}"#.utf8))
        let manager = try JSONDecoder().decode(SeerrUser.self, from: Data(#"{"id": 3, "permissions": 48}"#.utf8))
        let requester = try JSONDecoder().decode(SeerrUser.self, from: Data(#"{"id": 4, "permissions": 32}"#.utf8))
        #expect(admin.managesRequests)
        #expect(manager.managesRequests)
        #expect(!requester.managesRequests)
    }

    /// Trending mixes films and shows, which may share a TMDB id.
    @Test func cardsTellFilmsFromShows() throws {
        let film = try JSONDecoder().decode(SeerrTitle.self, from: Data(#"{"id": 100, "mediaType": "movie", "title": "A"}"#.utf8))
        let show = try JSONDecoder().decode(SeerrTitle.self, from: Data(#"{"id": 100, "mediaType": "tv", "name": "B"}"#.utf8))
        #expect(SeerrCard(title: film).id != SeerrCard(title: show).id)
    }
}
