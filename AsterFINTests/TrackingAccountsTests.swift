//
//  TrackingAccountsTests.swift
//  AsterFINTests
//
//  The plugin's linked accounts: the page of accounts is read, the services
//  the server serves are told apart, and what the app kept itself for them
//  is moved out once.
//

import Foundation
import Testing
@testable import AsterFIN

@MainActor
struct TrackingAccountsTests {
    @Test func accountsAreRead() throws {
        let json = #"""
        {"Simkl":{"Available":true,"Linked":true,"Name":"peppy","Scrobble":true},
         "AniList":{"Available":true,"Linked":false},
         "LastFm":{"Available":false},
         "Waiting":2,
         "Log":[{"At":"2026-11-04T12:00:00Z","Service":"simkl","Title":"Blue Box","Result":"sent"}]}
        """#
        let accounts = try TrackingFeatures.decoder.decode(TrackedAccounts.self, from: Data(json.utf8))
        #expect(accounts.account(.simkl)?.isLinked == true)
        #expect(accounts.account(.simkl)?.name == "peppy")
        #expect(accounts.account(.anilist)?.isLinked == false)
        #expect(accounts.account(.lastfm)?.available == false)
        #expect(accounts.account(.hardcover) == nil)
        #expect(accounts.waiting == 2)
        #expect(accounts.log?.first?.title == "Blue Box")
        #expect(accounts.log?.first?.date != nil)
    }

    @Test func eachServiceHasItsFlowAndGroup() {
        #expect(TrackedService.simkl.flow == .code)
        #expect(TrackedService.lastfm.flow == .approve)
        #expect(TrackedService.anilist.flow == .paste)
        #expect(TrackedService.listenbrainz.group == "Music")
        #expect(TrackedService.lastfm.verb == "listen to")
    }

    @Test func linkIsRead() throws {
        let json = #"{"Url":"https://simkl.com/pin","Code":"AB12C","CompleteUrl":"https://simkl.com/pin/AB12C","Interval":5,"ExpiresIn":900}"#
        let link = try TrackingFeatures.decoder.decode(TrackedLink.self, from: Data(json.utf8))
        #expect(link.code == "AB12C")
        #expect(link.interval == 5)
        #expect(link.paste == nil)
    }
}
