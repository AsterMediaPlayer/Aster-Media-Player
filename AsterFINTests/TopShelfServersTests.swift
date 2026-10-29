//
//  TopShelfServersTests.swift
//  AsterFINTests
//
//  The servers kept off the Top Shelf. The extension rebuilds the server id
//  itself (TopShelfSession.serverID), so its format is pinned here.
//

import Foundation
import Testing
@testable import AsterFIN

struct TopShelfServersTests {
    @Test func theExtensionsIdMatchesTheSavedServers() throws {
        let url = try #require(URL(string: "https://demo.example.com"))
        #expect(SavedServer.id(url, "user1") == url.absoluteString + "|" + "user1")
    }

    @Test func turnsOffAndBackOn() {
        let id = "https://shelf-test.example.com|\(UUID().uuidString)"
        #expect(TopShelfServers.isShown(id))
        TopShelfServers.setShown(false, for: id)
        #expect(!TopShelfServers.isShown(id))
        TopShelfServers.setShown(true, for: id)
        #expect(TopShelfServers.isShown(id))
    }
}
