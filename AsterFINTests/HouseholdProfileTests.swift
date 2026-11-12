//
//  HouseholdProfileTests.swift
//  AsterFINTests
//
//  Bonfire's household list, as the picker reads it: either spelling of
//  the keys, ids matched either way Jellyfin writes them, pictures found
//  wherever they are, and the way to each profile (saved sign-in, a
//  switch, or its PIN first).
//

import Foundation
import Testing
@testable import AsterFIN

struct HouseholdProfileTests {
    private static let master = "8E3CDFA5-79A8-4BB9-BD9A-0E96B7DC974A"
    private static let kids = "11111111-2222-3333-4444-555555555555"
    private static let neighbour = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    /// The plugin's own pages get camelCase; Jellyfin's serializer gives
    /// PascalCase. The third entry is a linked household's, in PascalCase.
    private static let listJSON = """
    [
      {"profileUserId":"\(master)","profileName":"Bard","avatarInitial":"B","avatarColor":"#00A4DC",
       "requiresPin":true,"hasPin":true,"isMaster":true,"isBonfire":false,"profileImage":null,"masterUserId":"\(master)"},
      {"profileUserId":"\(kids)","profileName":"Kids","avatarInitial":"K","avatarColor":"#FF6B35",
       "requiresPin":false,"hasPin":false,"isMaster":false,"profileImage":"fox","masterUserId":"\(master)"},
      {"ProfileUserId":"\(neighbour)","ProfileName":"Neighbour","RequiresPin":true,"HasPin":true,"IsMaster":true,
       "IsBonfire":true,"ProfileImage":"https://example.com/pic.jpg","MasterUserId":"\(neighbour)"}
    ]
    """

    private let client = BonfireClient(jellyfin: JellyfinClient(baseURL: URL(string: "https://media.example")!, accessToken: "t", userId: "u"))

    private func records() throws -> [BonfireProfileRecord] {
        try Bonfire.decoder.decode([BonfireProfileRecord].self, from: Data(Self.listJSON.utf8))
    }

    @Test func theListDecodesEitherSpelling() throws {
        let records = try records()
        #expect(records.count == 3)
        #expect(records[0].profileName == "Bard")
        #expect(records[0].requiresPin == true)
        #expect(records[2].profileName == "Neighbour")
        #expect(records[2].isBonfire == true)
        #expect(records[2].profileImage == "https://example.com/pic.jpg")
    }

    /// The sign-in keeps the id without dashes; the plugin sends it with.
    @Test func theCurrentProfileIsFoundEitherWayTheIdIsWritten() throws {
        let profiles = try records().map { HouseholdProfile(bonfire: $0, client: client, currentUserId: "8e3cdfa579a84bb9bd9a0e96b7dc974a") }
        #expect(profiles.map(\.isCurrent) == [true, false, false])
        #expect(profiles[0].id == "8e3cdfa579a84bb9bd9a0e96b7dc974a")
        #expect(profiles[0].rawId == Self.master)
        #expect(profiles[1].masterUserId == "8e3cdfa579a84bb9bd9a0e96b7dc974a")
        #expect(profiles[1].storedHousehold.masterUserId == "8e3cdfa579a84bb9bd9a0e96b7dc974a")
        #expect(profiles[1].storedHousehold.isMaster == false)
        #expect(profiles[0].storedHousehold.isMaster)
    }

    @Test func picturesComeFromWhereverTheyAre() throws {
        let profiles = try records().map { HouseholdProfile(bonfire: $0, client: client, currentUserId: "x") }
        // None: the initial on the colour.
        #expect(profiles[0].imageURL == nil)
        #expect(profiles[0].initial == "B")
        #expect(profiles[0].colorHex == "#00A4DC")
        // Stored on the server: the plugin's image route, small.
        let kids = try #require(profiles[1].imageURL)
        #expect(kids.path().hasSuffix("/plugins/profiles/image/\(Self.kids)"))
        #expect(kids.query()?.contains("size=thumb") == true)
        // Elsewhere: straight from there.
        #expect(profiles[2].imageURL == URL(string: "https://example.com/pic.jpg"))
        #expect(profiles[2].isOtherHousehold)
        // No initial sent: the name's first letter.
        #expect(profiles[2].initial == "N")
        #expect(profiles[2].colorHex == Bonfire.defaultAvatarColor)
    }

    @Test func aSwitchResultDecodesEitherSpelling() throws {
        let camel = try Bonfire.decoder.decode(BonfireSwitchResult.self, from: Data(#"{"activeProfileToken":"abc","jellyfinUserId":"\#(Self.kids)","libraryArtwork":[]}"#.utf8))
        #expect(camel.activeProfileToken == "abc")
        let pascal = try Bonfire.decoder.decode(BonfireSwitchResult.self, from: Data(#"{"ActiveProfileToken":"abc","JellyfinUserId":"\#(Self.kids)"}"#.utf8))
        #expect(pascal.jellyfinUserId == Self.kids)
    }

    /// A saved sign-in is reused only where no PIN is asked: a profile with
    /// one goes through the server every time.
    @Test func theWayToAProfileNeverSkipsItsPin() throws {
        let profiles = try records().map { HouseholdProfile(bonfire: $0, client: client, currentUserId: "8e3cdfa579a84bb9bd9a0e96b7dc974a") }
        let saved = StoredSession(serverURL: URL(string: "https://media.example")!, serverName: "Media", userId: profiles[1].id,
                                  userName: "Kids", accessToken: "kids-token", serverKind: .jellyfin)
        #expect(ProfileSwitchPlan.make(for: profiles[0], stored: nil) == .alreadyCurrent)
        #expect(ProfileSwitchPlan.make(for: profiles[1], stored: saved) == .reuseStored(saved))
        #expect(ProfileSwitchPlan.make(for: profiles[1], stored: nil) == .switchNow)
        #expect(ProfileSwitchPlan.make(for: profiles[2], stored: saved) == .needsPin)
        var current = profiles[0]
        current.isCurrent = false
        #expect(ProfileSwitchPlan.make(for: current, stored: saved) == .needsPin)
    }

    @Test func aPlexHomeUserBecomesAProfile() {
        let link = PlexLink(accountToken: "a", machineId: "m1", connections: [], homeUserUUID: "u2", homeUserHasPin: false, homeToken: "home")
        let locked = HouseholdProfile(plex: PlexHomeUser(id: 1, uuid: "u1", title: "Peppy", thumb: "https://plex.tv/users/1/avatar", admin: true, protected: true),
                                      link: link, currentUserId: "u2")
        #expect(locked.requiresPin && locked.hasPin && locked.isMaster && !locked.isCurrent)
        #expect(locked.imageURL == URL(string: "https://plex.tv/users/1/avatar"))
        let open = HouseholdProfile(plex: PlexHomeUser(id: 2, uuid: "u2", title: "kid"), link: link, currentUserId: "u2")
        #expect(!open.requiresPin && open.isCurrent && open.imageURL == nil && open.initial == "K")
    }
}
