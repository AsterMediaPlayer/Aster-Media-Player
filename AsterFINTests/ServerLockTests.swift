//
//  ServerLockTests.swift
//  AsterFINTests
//
//  A change that lets others past a server's lock asks for its password or
//  PIN first; one that tightens it doesn't.
//

import Foundation
import Testing
@testable import AsterFIN

struct ServerLockTests {
    private func server(asks: Bool = false, lockAfter: Int? = nil) throws -> SavedServer {
        let stored = StoredSession(serverURL: try #require(URL(string: "http://192.168.1.240:8096")), serverName: "Server",
                                   userId: "u", userName: "peppy", accessToken: "t", serverKind: .jellyfin)
        return SavedServer(session: stored, asksPasswordToSwitch: asks, lockAfterMinutes: lockAfter)
    }

    @Test func turningOffTheSwitchPasswordAsksForIt() throws {
        #expect(try server(asks: true).loosens(asksToSwitch: false))
        #expect(!(try server(asks: false).loosens(asksToSwitch: true)))
        #expect(!(try server(asks: true).loosens(asksToSwitch: true)))
    }

    @Test func aLongerOrNoLockAsksForIt() throws {
        let locked = try server(lockAfter: 15)
        #expect(locked.loosens(lockAfter: nil))
        #expect(locked.loosens(lockAfter: 60))
        #expect(!locked.loosens(lockAfter: 5))
        #expect(!locked.loosens(lockAfter: 15))
        // Nothing to loosen on a server that never locks.
        #expect(!(try server().loosens(lockAfter: 5)))
    }
}
