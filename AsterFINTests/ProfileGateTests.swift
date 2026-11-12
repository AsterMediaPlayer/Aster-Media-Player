//
//  ProfileGateTests.swift
//  AsterFINTests
//
//  Whether "Who's watching?" comes up as the app opens, decided from what
//  the saved sign-in knows; and the household kept with a sign-in, read
//  back by this version, older ones, and the widgets.
//

import Foundation
import Testing
@testable import AsterFIN

struct ProfileGateTests {
    private let server = URL(string: "https://media.example")!
    private let household = StoredHousehold(masterUserId: "8e3cdfa579a84bb9bd9a0e96b7dc974a", isMaster: false,
                                            avatarInitial: "K", avatarColor: "#FF6B35", profileImage: "fox")

    private var plain: StoredSession {
        StoredSession(serverURL: server, serverName: "Media", userId: "u1", userName: "bard", accessToken: "t", serverKind: .jellyfin)
    }

    private var inHousehold: StoredSession {
        var stored = plain
        stored.household = household
        return stored
    }

    private var plexHome: StoredSession {
        StoredSession(serverURL: server, serverName: "Plex", userId: "u2", userName: "kid", accessToken: "t", serverKind: .plex,
                      plex: PlexLink(accountToken: "a", machineId: "m", connections: [], homeUserUUID: "u2", homeUserHasPin: false, homeToken: "home"))
    }

    @Test func anOrdinarySignInIsNeverAsked() {
        for mode in ProfileGateMode.allCases {
            for cached in [nil, true, false] {
                #expect(!ProfileGate.shouldAsk(stored: plain, mode: mode, cachedAskOnStartup: cached))
            }
        }
    }

    @Test func aHouseholdFollowsTheSettingHere() {
        #expect(ProfileGate.shouldAsk(stored: inHousehold, mode: .always, cachedAskOnStartup: nil))
        #expect(!ProfileGate.shouldAsk(stored: inHousehold, mode: .never, cachedAskOnStartup: true))
        // As the server is set: only once its preference has been read, and says so.
        #expect(ProfileGate.shouldAsk(stored: inHousehold, mode: .server, cachedAskOnStartup: true))
        #expect(!ProfileGate.shouldAsk(stored: inHousehold, mode: .server, cachedAskOnStartup: false))
        #expect(!ProfileGate.shouldAsk(stored: inHousehold, mode: .server, cachedAskOnStartup: nil))
    }

    /// A Plex Home has no setting of its own: only Every Time asks.
    @Test func aPlexHomeAsksOnlyEveryTime() {
        #expect(ProfileGate.shouldAsk(stored: plexHome, mode: .always, cachedAskOnStartup: nil))
        #expect(!ProfileGate.shouldAsk(stored: plexHome, mode: .server, cachedAskOnStartup: true))
        #expect(!ProfileGate.shouldAsk(stored: plexHome, mode: .never, cachedAskOnStartup: nil))
        // Signed in before the Home's token was kept: nothing to switch with.
        var older = plexHome
        older.plex?.homeToken = nil
        #expect(!ProfileGate.shouldAsk(stored: older, mode: .always, cachedAskOnStartup: nil))
    }

    @Test func theHouseholdRoundTripsAndOlderSignInsStillRead() throws {
        let decoded = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(inHousehold))
        #expect(decoded == inHousehold)
        #expect(decoded.householdKey == "https://media.example|8e3cdfa579a84bb9bd9a0e96b7dc974a")

        // Saved before households were kept.
        let older = try JSONDecoder().decode(StoredSession.self, from: Data(#"{"serverURL":"https://media.example","userId":"u1","userName":"bard","accessToken":"t"}"#.utf8))
        #expect(older.household == nil)
        #expect(older.householdKey == nil)

        // The widgets and Top Shelf read only what they know of the session.
        nonisolated struct WidgetShaped: Decodable { var serverURL: URL; var userId: String; var accessToken: String; var serverKind: ServerKind? }
        let seen = try JSONDecoder().decode(WidgetShaped.self, from: JSONEncoder().encode(inHousehold))
        #expect(seen.userId == "u1" && seen.serverKind == .jellyfin)
    }

    /// A profile's password on the server is its PIN; the main account keeps its password.
    @Test func aProfileAsksForItsPin() {
        #expect(SavedServer(session: inHousehold).credentialName == "PIN")
        #expect(SavedServer(session: inHousehold).isHouseholdProfile)
        var master = inHousehold
        master.household?.isMaster = true
        #expect(SavedServer(session: master).credentialName == "password")
        #expect(SavedServer(session: plain).credentialName == "password")
    }

    /// Only a profile with a PIN can be locked; with a lock set it asks on
    /// opening too. The main account and an ordinary sign-in lock with their
    /// password, after time away only.
    @Test func aProfileLocksWithItsPinAndOnOpening() throws {
        var withPin = inHousehold
        withPin.household?.hasPin = true
        var locked = SavedServer(session: withPin)
        #expect(locked.canBeLocked)
        #expect(!locked.locksOnOpening)
        locked.lockAfterMinutes = 1
        #expect(locked.locksOnOpening)

        // No PIN: nothing to ask for.
        var noPin = inHousehold
        noPin.household?.hasPin = false
        let open = SavedServer(session: noPin, lockAfterMinutes: 5)
        #expect(!open.canBeLocked)
        #expect(!open.locksOnOpening)
        // Saved before the PIN was kept: not locked until the household is read again.
        #expect(!SavedServer(session: inHousehold, lockAfterMinutes: 5).canBeLocked)

        var master = withPin
        master.household?.isMaster = true
        let main = SavedServer(session: master, lockAfterMinutes: 5)
        #expect(main.canBeLocked && !main.locksOnOpening)
        #expect(SavedServer(session: plain, lockAfterMinutes: 5).canBeLocked)
        #expect(!SavedServer(session: plain, lockAfterMinutes: 5).locksOnOpening)

        // The flag survives a round trip, and an older household reads as unknown.
        let decoded = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(withPin))
        #expect(decoded.household?.hasPin == true)
        let older = try JSONDecoder().decode(StoredHousehold.self, from: Data(#"{"masterUserId":"m","isMaster":false}"#.utf8))
        #expect(older.hasPin == nil)
        #expect(SavedServer.lockChoices.first == 1)
    }

    @MainActor @Test func theHouseholdsPreferenceIsKeptPerHousehold() {
        let defaults = UserDefaults(suiteName: "ProfileGateTests-\(UUID().uuidString)")!
        let key = inHousehold.householdKey!
        #expect(ProfileGateCache.askOnStartup(for: key, defaults: defaults) == nil)
        ProfileGateCache.set(true, for: key, defaults: defaults)
        #expect(ProfileGateCache.askOnStartup(for: key, defaults: defaults) == true)
        #expect(ProfileGateCache.askOnStartup(for: "https://other.example|m", defaults: defaults) == nil)
        ProfileGateCache.set(false, for: key, defaults: defaults)
        #expect(ProfileGateCache.askOnStartup(for: key, defaults: defaults) == false)
    }
}
