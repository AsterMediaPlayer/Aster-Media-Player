//
//  ServerKindTests.swift
//  AsterFINTests
//
//  Jellyfin and Emby told apart by their public info, sessions saved before
//  Emby still read as Jellyfin, and Emby's chapter marks as skip segments.
//

import Foundation
import Testing
@testable import AsterFIN

struct ServerKindTests {
    private func info(_ json: String) throws -> PublicSystemInfo {
        try JSONDecoder().decode(PublicSystemInfo.self, from: Data(json.utf8))
    }

    /// The two servers' actual replies (Jellyfin 12.1, Emby 4.11).
    @Test func eachServerIsKnownByItsPublicInfo() throws {
        let jellyfin = try info(#"{"LocalAddress":"192.168.1.240","ServerName":"Server","Version":"12.1.0","ProductName":"Jellyfin Server","Id":"c76e"}"#)
        let emby = try info(#"{"LocalAddresses":[],"RemoteAddresses":[],"ServerName":"Server","Version":"4.11.0.3","Id":"8282"}"#)
        #expect(jellyfin.kind == .jellyfin)
        #expect(emby.kind == .emby)
        #expect(emby.version == "4.11.0.3")
    }

    @Test func aSessionSavedBeforeEmbyIsJellyfin() throws {
        let old = #"{"serverURL":"http://192.168.1.240:8096","userId":"u","userName":"peppy","accessToken":"t"}"#
        let session = try JSONDecoder().decode(StoredSession.self, from: Data(old.utf8))
        #expect(session.kind == .jellyfin)

        let emby = StoredSession(serverURL: URL(string: "http://192.168.1.240:8098")!, serverName: nil, userId: "u", userName: "peppy", accessToken: "t", serverKind: .emby)
        let roundTrip = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(emby))
        #expect(roundTrip.kind == .emby)
    }

    @Test func embysChapterMarksBecomeIntroAndCredits() {
        let chapters = [
            ChapterInfo(startPositionTicks: 0, name: "Chapter 1", markerType: "Chapter"),
            ChapterInfo(startPositionTicks: 900_000_000, name: "Intro", markerType: "IntroStart"),
            ChapterInfo(startPositionTicks: 1_800_000_000, name: "Intro End", markerType: "IntroEnd"),
            ChapterInfo(startPositionTicks: 12_000_000_000, name: "Credits", markerType: "CreditsStart"),
        ]
        let segments = JellyfinClient.segments(fromChapters: chapters, itemId: "739", runTimeTicks: 14_000_000_000)
        #expect(segments.map(\.type) == ["Intro", "Outro"])
        #expect(segments.first?.startTicks == 900_000_000)
        #expect(segments.first?.endTicks == 1_800_000_000)
        #expect(segments.last?.endTicks == 14_000_000_000)
    }

    @Test func plainChaptersGiveNothingToSkip() {
        let chapters = [
            ChapterInfo(startPositionTicks: 0, name: "Chapter 1", markerType: "Chapter"),
            ChapterInfo(startPositionTicks: 6_000_000_000, name: "Chapter 2", markerType: "Chapter"),
        ]
        #expect(JellyfinClient.segments(fromChapters: chapters, itemId: "739", runTimeTicks: 14_000_000_000).isEmpty)
    }
}
