//
//  PlexSessionTests.swift
//  AsterFINTests
//
//  A Plex sign-in is kept with its plex.tv side and known by the server's
//  own id; Jellyfin and Emby sign-ins are kept as before.
//

import Foundation
import Testing
@testable import AsterFIN

struct PlexSessionTests {
    private let link = PlexLink(
        accountToken: "account",
        machineId: "4d09e81d",
        connections: [
            PlexConnectionInfo(uri: URL(string: "https://192-168-1-240.abc.plex.direct:32400")!, local: true, relay: false),
        ])

    @Test func aPlexSignInRoundTrips() throws {
        let stored = StoredSession(serverURL: URL(string: "https://192-168-1-240.abc.plex.direct:32400")!, serverName: "Test Server",
                                   userId: "home-user", userName: "peppy", accessToken: "server", serverKind: .plex, plex: link)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(stored))
        #expect(decoded == stored)
        #expect(decoded.kind == .plex)
        #expect(MediaServerFactory.client(for: decoded).kind == .plex)
    }

    /// The address used to reach a Plex server can change; its id can't.
    @Test func aPlexServerIsKnownByItsId() {
        let stored = StoredSession(serverURL: URL(string: "https://10-10-14-1.abc.plex.direct:32400")!, serverName: "Test Server",
                                   userId: "home-user", userName: "peppy", accessToken: "server", serverKind: .plex, plex: link)
        #expect(SavedServer(session: stored).id == "plex:4d09e81d|home-user")
    }

    /// Locking asks for a Plex Home PIN, so only a profile with one can be locked.
    @Test func aPlexProfileLocksWithItsPin() throws {
        var withPin = link
        withPin.homeUserUUID = "a1"
        withPin.homeUserHasPin = true
        let locked = SavedServer(session: StoredSession(serverURL: URL(string: "https://s.plex.direct:32400")!, serverName: "Test Server",
                                                        userId: "a1", userName: "peppy", accessToken: "t", serverKind: .plex, plex: withPin))
        #expect(locked.canBeLocked)
        #expect(locked.credentialName == "PIN")

        // Signed in before this was kept: nothing to lock with until signed in again.
        let older = try JSONDecoder().decode(PlexLink.self, from: Data(#"{"accountToken":"a","machineId":"m","connections":[]}"#.utf8))
        #expect(older.homeUserUUID == nil)
        let unlocked = SavedServer(session: StoredSession(serverURL: URL(string: "https://s.plex.direct:32400")!, serverName: "Test Server",
                                                          userId: "u", userName: "peppy", accessToken: "t", serverKind: .plex, plex: older))
        #expect(!unlocked.canBeLocked)

        let jellyfin = SavedServer(session: StoredSession(serverURL: URL(string: "http://192.168.1.240:8096")!, serverName: "Server",
                                                          userId: "u", userName: "peppy", accessToken: "t", serverKind: .jellyfin))
        #expect(jellyfin.canBeLocked)
        #expect(jellyfin.credentialName == "password")
    }

    @Test func jellyfinAndEmbySignInsAreUnchanged() throws {
        let old = #"{"serverURL":"http://192.168.1.240:8096","userId":"u","userName":"peppy","accessToken":"t","serverKind":"emby"}"#
        let stored = try JSONDecoder().decode(StoredSession.self, from: Data(old.utf8))
        #expect(stored.plex == nil)
        #expect(stored.kind == .emby)
        #expect(SavedServer(session: stored).id == "http://192.168.1.240:8096|u")
        #expect(MediaServerFactory.client(for: stored) is JellyfinClient)
    }
}
