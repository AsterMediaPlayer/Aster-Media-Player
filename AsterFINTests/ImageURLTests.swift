//
//  ImageURLTests.swift
//  AsterFINTests
//
//  The picture chosen for each lockup and backdrop, and its address on
//  Jellyfin, pinned so moving the choosing out of the Jellyfin client (for
//  Plex to share) can't change a picture.
//

import Foundation
import Testing
@testable import AsterFIN

struct ImageURLTests {
    private let client = JellyfinClient(baseURL: URL(string: "http://jf.test")!, accessToken: "t", userId: "u")

    private func item(_ json: String) throws -> BaseItem {
        try JSONDecoder().decode(BaseItem.self, from: Data(json.utf8))
    }

    private let episode = #"{"Id":"ep","Type":"Episode","SeriesId":"show","ImageTags":{"Primary":"p1"},"ParentBackdropItemId":"show","ParentBackdropImageTags":["b1"],"ParentThumbItemId":"show","ParentThumbImageTag":"t1","SeriesPrimaryImageTag":"sp","SeriesThumbImageTag":"st","ParentLogoItemId":"show","ParentLogoImageTag":"l1"}"#
    private let movie = #"{"Id":"mov","Type":"Movie","ImageTags":{"Primary":"p2","Thumb":"t2","Logo":"l2"},"BackdropImageTags":["b2"]}"#
    private let season = #"{"Id":"sea","Type":"Season","SeriesId":"show","SeriesPrimaryImageTag":"sp","ParentBackdropItemId":"show","ParentBackdropImageTags":["b3"]}"#
    private let song = #"{"Id":"song","Type":"Audio","AlbumId":"alb","AlbumPrimaryImageTag":"ap"}"#

    @Test func episodeTakesItsOwnStillForLandscape() throws {
        let episode = try item(episode)
        #expect(client.landscapeURL(for: episode)?.absoluteString == "http://jf.test/Items/ep/Images/Primary?maxWidth=800&quality=90&tag=p1")
        #expect(client.posterURL(for: episode)?.absoluteString == "http://jf.test/Items/ep/Images/Primary?maxWidth=500&quality=90&tag=p1")
        #expect(client.backdropURL(for: episode)?.absoluteString == "http://jf.test/Items/show/Images/Backdrop/0?maxWidth=1920&quality=90&tag=b1")
        #expect(client.logoURL(for: episode)?.absoluteString == "http://jf.test/Items/show/Images/Logo?maxWidth=800&quality=90&tag=l1")
    }

    @Test func movieUsesItsOwnPictures() throws {
        let movie = try item(movie)
        #expect(client.landscapeURL(for: movie, width: 600)?.absoluteString == "http://jf.test/Items/mov/Images/Thumb?maxWidth=600&quality=90&tag=t2")
        #expect(client.posterURL(for: movie, width: 300, quality: 70)?.absoluteString == "http://jf.test/Items/mov/Images/Primary?maxWidth=300&quality=70&tag=p2")
        #expect(client.backdropURL(for: movie)?.absoluteString == "http://jf.test/Items/mov/Images/Backdrop/0?maxWidth=1920&quality=90&tag=b2")
        #expect(client.logoURL(for: movie)?.absoluteString == "http://jf.test/Items/mov/Images/Logo?maxWidth=800&quality=90&tag=l2")
    }

    @Test func seasonFallsBackToItsShow() throws {
        let season = try item(season)
        #expect(client.posterURL(for: season)?.absoluteString == "http://jf.test/Items/show/Images/Primary?maxWidth=500&quality=90&tag=sp")
        #expect(client.landscapeURL(for: season)?.absoluteString == "http://jf.test/Items/show/Images/Backdrop/0?maxWidth=800&quality=90&tag=b3")
        #expect(client.logoURL(for: season) == nil)
    }

    @Test func songFallsBackToItsAlbum() throws {
        let song = try item(song)
        #expect(client.posterURL(for: song)?.absoluteString == "http://jf.test/Items/alb/Images/Primary?maxWidth=500&quality=90&tag=ap")
        #expect(client.landscapeURL(for: song) == nil)
        #expect(client.backdropURL(for: song) == nil)
    }

    @Test func personPhoto() throws {
        let person = try JSONDecoder().decode(PersonInfo.self, from: Data(#"{"Id":"per","Name":"A","PrimaryImageTag":"pp"}"#.utf8))
        #expect(client.personImageURL(person)?.absoluteString == "http://jf.test/Items/per/Images/Primary?maxWidth=300&quality=90&tag=pp")
    }
}
