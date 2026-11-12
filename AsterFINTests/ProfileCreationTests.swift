//
//  ProfileCreationTests.swift
//  AsterFINTests
//
//  Adding and changing a profile: the form's checks match the plugin's
//  own rules, the server's lists become the form's choices, a draft goes
//  to the server as the plugin takes it (a change keeping what isn't
//  changed), and the Mac's arrow keys stay on the tiles and buttons.
//

import Foundation
import Testing
@testable import AsterFIN

struct ProfileCreationTests {
    private let client = BonfireClient(jellyfin: JellyfinClient(baseURL: URL(string: "https://media.example")!, accessToken: "t", userId: "u"))

    private func body(_ draft: ProfileDraft) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(BonfireProfileRequest(draft))) as? [String: Any])
    }

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
        // Taking the PIN away: whatever's in the field doesn't matter.
        draft.removePin = true
        draft.pin = "1"
        #expect(draft.validationMessage(confirmPin: "") == nil)
    }

    @Test func theServersListsBecomeChoices() throws {
        let avatars = try Bonfire.decoder.decode(BonfireAvatarLibrary.self, from: Data("""
        {"AllowCustomUploads":true,"StarterAvatarsEnabled":true,"Avatars":[
          {"Id":"lib-1","DisplayName":"Our Dog","Url":"/plugins/profiles/avatars/lib-1","ThumbUrl":"/plugins/profiles/avatars/lib-1?size=thumb","IsStarter":false},
          {"Id":"starter-fox","DisplayName":"Fox","Url":"/plugins/profiles/avatars/starter-fox","IsStarter":true}]}
        """.utf8))
        let libraries = try Bonfire.decoder.decode([BonfireLibrary].self, from: Data(#"[{"Id":"F1A2","Name":"Films","CollectionType":"movies"},{"id":"k1","name":"Kids","collectionType":"tvshows"}]"#.utf8))
        let ratings = try Bonfire.decoder.decode(BonfireRatings.self, from: Data(#"{"Country":"GB","Ratings":[{"Score":12,"Labels":["12","12A"]},{"Score":0,"Labels":["U"]}]}"#.utf8))

        let options = ProfileCreationOptions(avatars: avatars, libraries: libraries, ratings: ratings, client: client)
        #expect(options.avatars.map(\.name) == ["Our Dog", "Fox"])
        #expect(options.avatars[1].url.path().hasSuffix("/plugins/profiles/avatars/starter-fox"))
        // Libraries by plain id, as the profile's own list is read.
        #expect(options.libraries.map(\.id) == ["f1a2", "k1"])
        // Youngest first, labels joined.
        #expect(options.ratings.map(\.label) == ["U", "12 / 12A"])
        #expect(options.ratings.map(\.score) == [0, 12])
        #expect(options.ratingCountry == "GB")

        // A list the server couldn't give is just empty.
        let bare = ProfileCreationOptions(avatars: nil, libraries: nil, ratings: nil, client: client)
        #expect(bare.avatars.isEmpty && bare.libraries.isEmpty && bare.ratings.isEmpty)
    }

    @Test func aNewProfileGoesAsThePluginTakesIt() throws {
        var draft = ProfileDraft()
        draft.name = " Kids "
        draft.pin = "2468"
        draft.bypassPinOnLocalNetwork = true
        draft.avatarId = "starter-fox"
        draft.colorHex = "#FF6B35"
        draft.ratingScore = 12
        draft.libraryIds = ["k1", "f1"]
        draft.masterPin = "1234"
        let body = try body(draft)
        #expect(body["profileId"] == nil)
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
        let openBody = try self.body(open)
        #expect(openBody["pin"] == nil)
        #expect(openBody["bypassPinOnLocalNetwork"] == nil)
        #expect(openBody["enabledFolders"] == nil)
        #expect(openBody["maxParentalRating"] == nil)
        #expect(openBody["masterPin"] == nil)
        #expect(openBody["avatarLibraryId"] == nil)
        #expect(openBody["avatarColor"] as? String == Bonfire.defaultAvatarColor)
    }

    /// A change says which profile, keeps the PIN and picture unless told
    /// otherwise (an empty PIN takes it away), and sends the rating and
    /// libraries as they are, since the plugin would clear them if left out.
    @Test func aChangeKeepsWhatIsntChanged() throws {
        var draft = ProfileDraft()
        draft.profileId = "11111111-2222-3333-4444-555555555555"
        draft.name = "Kids"
        draft.colorHex = "#FF6B35"
        draft.ratingScore = 12
        draft.libraryIds = ["k1"]
        draft.bypassPinOnLocalNetwork = true
        let kept = try body(draft)
        #expect(kept["profileId"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(kept["pin"] == nil)
        #expect(kept["avatarLibraryId"] == nil)
        #expect(kept["maxParentalRating"] as? String == "12")
        #expect(kept["enabledFolders"] as? [String] == ["k1"])
        #expect(kept["bypassPinOnLocalNetwork"] as? Bool == true)

        draft.pin = "9876"
        #expect(try body(draft)["pin"] as? String == "9876")

        draft.removePin = true
        let removed = try body(draft)
        #expect(removed["pin"] as? String == "")
        #expect(removed["bypassPinOnLocalNetwork"] == nil)

        draft.removePin = false
        draft.pin = ""
        draft.avatarId = "starter-cat"
        draft.ratingScore = nil
        draft.libraryIds = nil
        let widened = try body(draft)
        #expect(widened["avatarLibraryId"] as? String == "starter-cat")
        #expect(widened["maxParentalRating"] == nil)
        #expect(widened["enabledFolders"] == nil)
    }

    @Test func aProfileIsFilledInAsItIs() throws {
        let records = try Bonfire.decoder.decode([BonfireProfileRecord].self, from: Data("""
        [{"ProfileUserId":"11111111-2222-3333-4444-555555555555","ProfileName":"Kids","AvatarColor":"#FF6B35","HasPin":true,"RequiresPin":true,
          "IsMaster":false,"EnabledFolders":["F1A2-0000","k1"],"AllLibraries":false,"BypassPinOnLocalNetwork":true,"MasterUserId":"8E3CDFA5-79A8-4BB9-BD9A-0E96B7DC974A"},
         {"ProfileUserId":"22222222-2222-3333-4444-555555555555","ProfileName":"Guest","IsMaster":false,"EnabledFolders":[],"AllLibraries":true,"MasterUserId":"8E3CDFA5-79A8-4BB9-BD9A-0E96B7DC974A"}]
        """.utf8))
        let kids = HouseholdProfile(bonfire: records[0], client: client, currentUserId: "x")
        #expect(kids.enabledFolders == ["f1a20000", "k1"])
        #expect(kids.allLibraries == false)
        #expect(kids.bypassPinOnLocalNetwork == true)
        let guest = HouseholdProfile(bonfire: records[1], client: client, currentUserId: "x")
        #expect(guest.allLibraries == true)
    }

    @Test func aCreatedProfileDecodesEitherSpelling() throws {
        let made = try Bonfire.decoder.decode(BonfireCreatedProfile.self, from: Data(#"{"ProfileUserId":"11111111-2222-3333-4444-555555555555","ProfileName":"Kids"}"#.utf8))
        #expect(HouseholdProfile.plainId(made.profileUserId) == "11111111222233334444555555555555")
        #expect(made.profileName == "Kids")
    }

    /// Three tiles (two people and Add Profile) over two buttons.
    @Test func theArrowKeysStayOnTheTilesAndButtons() {
        var keys = PickerKeyboard()
        let stops = [3, 2]
        // Each move outside the macro: it holds the keys immutably.
        var moved = keys.move(.left, stops: stops)
        #expect(!moved)
        moved = keys.move(.right, stops: stops)
        #expect(moved && keys.column == 1)
        moved = keys.move(.right, stops: stops)
        #expect(moved && keys.column == 2)
        moved = keys.move(.right, stops: stops)
        #expect(!moved)
        // Down from the third tile lands on the last button there is.
        moved = keys.move(.down, stops: stops)
        #expect(moved && keys.row == 1 && keys.column == 1)
        moved = keys.move(.down, stops: stops)
        #expect(!moved)
        moved = keys.move(.up, stops: stops)
        #expect(moved && keys.row == 0 && keys.column == 1)
        // No buttons at all: down goes nowhere.
        moved = keys.move(.down, stops: [3, 0])
        #expect(!moved)
        // A profile removed from under the selection: back onto the row.
        keys = PickerKeyboard(row: 0, column: 2)
        keys.clamp(to: [1, 2])
        #expect(keys.column == 0)
        keys.clamp(to: [0, 2])
        #expect(keys.row == 1 && keys.column == 0)
    }
}
