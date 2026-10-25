//
//  PlexMapperTests.swift
//  AsterFINTests
//
//  Plex's titles become the app's: replies trimmed from a real Plex Media
//  Server 1.43 (an anime episode, a film, a show and its season).
//

import Foundation
import Testing
@testable import AsterFIN

struct PlexMapperTests {
    private func metadata(_ json: String) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexReply.self, from: Data(json.utf8)).mediaContainer.metadata![0]
    }

    private let episode = #"""
    {"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"6139","key":"/library/metadata/6139","parentRatingKey":"6138","grandparentRatingKey":"6137",
     "guid":"tv.plex.agents.custom.shoko://episode/e2255","type":"episode","title":"As of Today, I'm a Bad Girl!","grandparentTitle":"Bad Girl","parentTitle":"Season 1",
     "summary":"Yuu Yuutani is a model first year student.","index":1,"parentIndex":1,"year":2025,"viewOffset":62000,
     "thumb":"/library/metadata/6139/thumb/1792890348","art":"/library/metadata/6137/art/1792894637","parentThumb":"/library/metadata/6138/thumb/1792886180",
     "grandparentThumb":"/library/metadata/6137/thumb/1792894637","grandparentArt":"/library/metadata/6137/art/1792894637",
     "duration":1422428,"originallyAvailableAt":"2025-07-06","addedAt":1788704596,
     "Media":[{"id":8696,"duration":1422428,"bitrate":9007,"width":1920,"height":1080,"audioCodec":"opus","videoCodec":"hevc","videoResolution":"1080","container":"mkv",
       "Part":[{"id":8696,"key":"/library/parts/8696/1788704596/file.mkv","duration":1422428,"container":"mkv","Stream":[
         {"id":71904,"streamType":1,"default":true,"codec":"hevc","index":0,"width":1920,"height":1080,"displayTitle":"1080p"},
         {"id":71905,"streamType":2,"default":true,"codec":"opus","index":1,"channels":2,"languageCode":"eng","displayTitle":"English (OPUS Stereo)"},
         {"id":71907,"streamType":3,"codec":"ass","index":3,"forced":true,"languageCode":"eng","displayTitle":"English Forced"}]}]}],
     "Image":[{"alt":"x","type":"coverPoster","url":"/library/metadata/6137/thumb/1792894637"},{"alt":"x","type":"clearLogo","url":"/library/metadata/6137/clearLogo/1792894637"}],
     "Guid":[{"id":"tmdb://5439847"},{"id":"tvdb://10566016"}],
     "Chapter":[{"id":982,"tag":"Prologue","index":1,"startTimeOffset":1002,"endTimeOffset":135990},{"id":30356,"tag":"Opening","index":2,"startTimeOffset":135990,"endTimeOffset":226000}]}]}}
    """#

    @Test func anAnimeEpisode() throws {
        let item = PlexMapper.item(try metadata(episode))
        #expect(item.id == "6139")
        #expect(item.kind == .episode)
        #expect(item.seriesId == "6137")
        #expect(item.seriesName == "Bad Girl")
        #expect(item.seasonId == "6138")
        #expect(item.indexNumber == 1)
        #expect(item.parentIndexNumber == 1)
        #expect(item.runTimeTicks == 14_224_280_000)
        #expect(item.userData?.playbackPositionTicks == 620_000_000)
        #expect(item.userData?.played == false)
        // Its own still, then its show's poster, backdrop and logo.
        #expect(item.imageTags?["Primary"] == "/library/metadata/6139/thumb/1792890348")
        #expect(item.imageTags?["Logo"] == nil)
        #expect(item.seriesPrimaryImageTag == "/library/metadata/6137/thumb/1792894637")
        #expect(item.parentBackdropItemId == "6137")
        #expect(item.parentBackdropImageTags == ["/library/metadata/6137/art/1792894637"])
        #expect(item.parentLogoImageTag == "/library/metadata/6137/clearLogo/1792894637")
        #expect(item.providerIds == ["Tmdb": "5439847", "Tvdb": "10566016", "Shoko": "e2255"])
        #expect(item.premiereDate == "2025-07-06T00:00:00Z")
        #expect(item.chapters?.map(\.name) == ["Prologue", "Opening"])
        #expect(item.chapters?[1].startPositionTicks == 1_359_900_000)
        #expect(item.mediaStreams?.map(\.type) == ["Video", "Audio", "Subtitle"])
        #expect(item.mediaStreams?[2].isForced == true)
        #expect(item.container == "mkv")
    }

    @Test func aFilmWithItsCast() throws {
        let item = PlexMapper.item(try metadata(#"""
        {"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"769","type":"movie","title":"The 'Burbs","titleSort":"Burbs","year":1989,"duration":6082560,
         "thumb":"/library/metadata/769/thumb/1792876534","art":"/library/metadata/769/art/1792876534","contentRating":"PG","rating":5.7,"audienceRating":7.1,
         "studio":"Imagine Entertainment","tagline":"Paranoia Begins At Home","addedAt":1791657480,"originallyAvailableAt":"1989-02-17","viewCount":2,
         "Genre":[{"id":1,"tag":"Comedy"}],"Role":[{"id":798,"tag":"Tom Hanks","role":"Ray Peterson","thumb":"https://metadata-static.plex.tv/people/a.jpg"}],
         "Director":[{"id":900,"tag":"Joe Dante"}]}]}}
        """#))
        #expect(item.kind == .movie)
        #expect(item.sortName == "Burbs")
        #expect(item.officialRating == "PG")
        #expect(item.communityRating == 7.1)
        #expect(item.genres == ["Comedy"])
        #expect(item.studios?.first?.name == "Imagine Entertainment")
        #expect(item.taglines == ["Paranoia Begins At Home"])
        #expect(item.userData?.played == true)
        #expect(item.backdropImageTags == ["/library/metadata/769/art/1792876534"])
        #expect(item.cast.map(\.name) == ["Tom Hanks"])
        #expect(item.cast.first?.id == "798")
        #expect(item.people?.last?.type == "Director")
    }

    @Test func aShowAndItsSeasonCountWhatsLeft() throws {
        let show = PlexMapper.item(try metadata(#"""
        {"MediaContainer":{"Metadata":[{"ratingKey":"1188","type":"show","title":"No Reservations","leafCount":134,"viewedLeafCount":134,"childCount":8,
         "thumb":"/library/metadata/1188/thumb/1","art":"/library/metadata/1188/art/1"}]}}
        """#))
        #expect(show.kind == .series)
        #expect(show.childCount == 8)
        #expect(show.userData?.played == true)
        #expect(show.userData?.unplayedItemCount == 0)

        let season = PlexMapper.item(try metadata(#"""
        {"MediaContainer":{"Metadata":[{"ratingKey":"1189","type":"season","title":"Season 1","index":1,"parentRatingKey":"1188","parentTitle":"No Reservations",
         "parentThumb":"/library/metadata/1188/thumb/1","leafCount":13,"viewedLeafCount":4,"thumb":"/library/metadata/1189/thumb/1"}]}}
        """#))
        #expect(season.kind == .season)
        #expect(season.seriesId == "1188")
        #expect(season.userData?.unplayedItemCount == 9)
        #expect(season.userData?.played == false)
        #expect(season.seriesPrimaryImageTag == "/library/metadata/1188/thumb/1")
    }

    @Test func sectionsBecomeLibraries() throws {
        let json = #"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies","agent":"tv.plex.agents.movie"},{"key":"4","type":"show","title":"Anime","agent":"tv.plex.agents.custom.shoko"}]}}"#
        let libraries = try JSONDecoder().decode(PlexReply.self, from: Data(json.utf8)).mediaContainer.directory!.map(PlexMapper.library)
        #expect(libraries.map(\.collectionType) == ["movies", "tvshows"])
        #expect(libraries.map(\.kind) == [.collectionFolder, .collectionFolder])
    }

    /// The shared picture choice finds the right Plex paths.
    @Test func lockupsFindThePlexPictures() throws {
        let link = PlexLink(accountToken: "a", machineId: "m", connections: [])
        let client = PlexClient(baseURL: URL(string: "https://s.plex.direct:32400")!, accessToken: "t", userId: "u", link: link)
        let item = PlexMapper.item(try metadata(episode))
        #expect(client.landscapeURL(for: item)?.query?.contains("url=/library/metadata/6139/thumb/1792890348") == true)
        #expect(client.backdropURL(for: item)?.query?.contains("url=/library/metadata/6137/art/1792894637") == true)
        #expect(client.logoURL(for: item)?.query?.contains("url=/library/metadata/6137/clearLogo/1792894637") == true)
    }
}
