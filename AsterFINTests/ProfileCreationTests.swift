//
//  ProfileCreationTests.swift
//  AsterFINTests
//
//  Adding a profile: the form's checks match the plugin's own rules, the
//  server's lists become the form's choices, and the draft goes to the
//  server as the plugin takes it.
//

import Foundation
import Testing
@testable import AsterFIN

struct ProfileCreationTests {
    private let client = BonfireClient(jellyfin: JellyfinClient(baseURL: URL(string: "https://media.example")!, accessToken: "t", userId: "u"))

    @Test func theFormChecksWhatTheServerWould() {
        var draft = ProfileDraft()
        #expect(draft.validationMessage(confirmPin: "") == "Enter a name for the profile.")
        draft.name = String(repeating: "a", count: 33)
        #expect(draft.validationMessage(confirmPin: "")?.contains("at most 32") == true)
        draft.name = "Kids <3"
        #expect(draft.validationMessage(confirmPin: "")?.contains("letters, numbers") == true)
        draft.name = "  Kids' Room  "
        #expect(draft.validationMessage(confirmPin: "") == nil)
        #expect(draft.trimmedName == "Kids' Room")
        #expect(draft.initial == "K")

        draft.pin = "123"
        #expect(draft.validationMessage(confirmPin: "123") == "A PIN is 4 to 8 digits.")
        draft.pin = "12a4"
        #expect(draft.validationMessage(confirmPin: "12a4") == "A PIN is 4 to 8 digits.")
        draft.pin = "123456789"
        #expect(draft.validationMessage(confirmPin: "123456789") == "A PIN is 4 to 8 digits.")
        draft.pin = "2468"
        #expect(draft.validationMessage(confirmPin: "2469") == "The PINs don't match.")
        #expect(draft.validationMessage(confirmPin: "2468") == nil)
    }

    @Test func theServersListsBecomeChoices() throws {
        let avatars = try Bonfire.decoder.decode(BonfireAvatarLibrary.self, from: Data("""
        {"AllowCustomUploads":true,"StarterAvatarsEnabled":true,"Avatars":[
          {"Id":"lib-1","DisplayName":"Our Dog","Url":"/plugins/profiles/avatars/lib-1","ThumbUrl":"/plugins/profiles/avatars/lib-1?size=thumb","IsStarter":false},
          {"Id":"starter-fox","DisplayName":"Fox","Url":"/plugins/profiles/avatars/starter-fox","IsStarter":true}]}
        """.utf8))
        let libraries = try Bonfire.decoder.decode([BonfireLibrary].self, from: Data(#"[{"Id":"f1","Name":"Films","CollectionType":"movies"},{"id":"k1","name":"Kids","collectionType":"tvshows"}]"#.utf8))
        let ratings = try Bonfire.decoder.decode(BonfireRatings.self, from: Data(#"{"Country":"GB","Ratings":[{"Score":12,"Labels":["12","12A"]},{"Score":0,"Labels":["U"]}]}"#.utf8))

        let options = ProfileCreationOptions(avatars: avatars, libraries: libraries, ratings: ratings, client: client)
        #expect(options.avatars.map(\.name) == ["Our Dog", "Fox"])
        #expect(options.avatars[1].url.path().hasSuffix("/plugins/profiles/avatars/starter-fox"))
        #expect(options.libraries.map(\.id) == ["f1", "k1"])
        // Youngest first, labels joined.
        #expect(options.ratings.map(\.label) == ["U", "12 / 12A"])
        #expect(options.ratings.map(\.score) == [0, 12])
        #expect(options.ratingCountry == "GB")

        // A list the server couldn't give is just empty.
        let bare = ProfileCreationOptions(avatars: nil, libraries: nil, ratings: nil, client: client)
        #expect(bare.avatars.isEmpty && bare.libraries.isEmpty && bare.ratings.isEmpty)
    }

    @Test func theDraftGoesAsThePluginTakesIt() throws {
        var draft = ProfileDraft()
        draft.name = " Kids "
        draft.pin = "2468"
        draft.bypassPinOnLocalNetwork = true
        draft.avatarId = "starter-fox"
        draft.colorHex = "#FF6B35"
        draft.ratingScore = 12
        draft.libraryIds = ["k1", "f1"]
        draft.masterPin = "1234"
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BonfireCreateRequest(draft))) as? [String: Any]
        let body = try #require(json)
        #expect(body["profileName"] as? String == "Kids")
        #expect(body["pin"] as? String == "2468")
        #expect(body["bypassPinOnLocalNetwork"] as? Bool == true)
        #expect(body["avatarLibraryId"] as? String == "starter-fox")
        #expect(body["avatarColor"] as? String == "#FF6B35")
        #expect(body["maxParentalRating"] as? String == "12")
        #expect(body["enabledFolders"] as? [String] == ["f1", "k1"])
        #expect(body["masterPin"] as? String == "1234")

        // No PIN: none sent, and nothing about skipping it; every library:
        // the key left out, which the plugin reads as all, now and later.
        var open = ProfileDraft()
        open.name = "Guest"
        let openBody = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(BonfireCreateRequest(open))) as? [String: Any])
        #expect(openBody["pin"] == nil)
        #expect(openBody["bypassPinOnLocalNetwork"] == nil)
        #expect(openBody["enabledFolders"] == nil)
        #expect(openBody["maxParentalRating"] == nil)
        #expect(openBody["masterPin"] == nil)
        #expect(openBody["avatarLibraryId"] == nil)
        #expect(openBody["avatarColor"] as? String == Bonfire.defaultAvatarColor)
    }

    @Test func aCreatedProfileDecodesEitherSpelling() throws {
        let made = try Bonfire.decoder.decode(BonfireCreatedProfile.self, from: Data(#"{"ProfileUserId":"11111111-2222-3333-4444-555555555555","ProfileName":"Kids"}"#.utf8))
        #expect(HouseholdProfile.plainId(made.profileUserId) == "11111111222233334444555555555555")
        #expect(made.profileName == "Kids")
    }
}
