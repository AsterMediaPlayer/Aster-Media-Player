//
//  RedactTests.swift
//  AsterFINTests
//
//  A debug report's lines with what signs in, where the server is and who's
//  using it taken out: the same cases as the Android app's, so a report
//  reads alike from every platform. All values here are made up.
//

import Foundation
import Testing
@testable import AsterFIN

struct RedactTests {
    private func clean(_ text: String, _ names: String...) -> String { Redact.text(text, names: names) }

    @Test func tokensInAddressesAndHeaders() {
        #expect(clean("GET https://media.example.org:8920/Videos/1/stream?api_key=0123456789abcdef0123456789abcdef&Static=true")
                == "GET https://<server>/Videos/1/stream?api_key=<hidden>&Static=true")
        #expect(clean("X-Emby-Token: abcdef0123456789") == "X-Emby-Token: <hidden>")
        #expect(clean("…?X-Plex-Token=AbC-dEf_123&x=1") == "…?X-Plex-Token=<hidden>&x=1")
        #expect(clean(#"{"AccessToken":"feedfacefeedface","User":1}"#) == #"{"AccessToken":"<hidden>","User":1}"#)
        #expect(clean(#"MediaBrowser Client="Aster", DeviceId="abc123", Token="secret-value""#) == #"MediaBrowser Client="Aster", DeviceId="<hidden>", Token="<hidden>""#)
        #expect(clean("Authorization: Bearer abcdefghijklmnop") == "Authorization: Bearer <hidden>")
        #expect(clean(#"{"Username":"x","Pw":"hunter22"}"#) == #"{"Username":"x","Pw":"<hidden>"}"#)
    }

    @Test func addressesAndHosts() {
        #expect(clean("http://192.0.2.10:8096/emby/System/Info") == "http://<server>/emby/System/Info")
        #expect(clean("connecting to 198-51-100-7.0123456789abcdef0123456789abcdef.plex.direct") == "connecting to <server>")
        #expect(clean("from 203.0.113.5 and 2001:db8:0:0:0:0:0:1") == "from <ip> and <ip>")
        #expect(clean("mail someone@example.com") == "mail <email>")
    }

    @Test func libraryPathsKeepOnlyTheirKind() {
        #expect(clean(#""Path":"/mnt/Anime/Some Show (2023)/Season 1/S01E01.mkv""#) == #""Path":"<path>.mkv""#)
        #expect(clean(#"opened D:\Books\An Author\A Book.m4b"#) == "opened <path>.m4b")
        #expect(clean(#""Path":"/Volumes/Media/Films/A Film (2020).mp4""#) == #""Path":"<path>.mp4""#)
    }

    @Test func theUsersNameGoesWhereverItIs() {
        #expect(clean("Signed in as Jordan on jordan's server", "Jordan") == "Signed in as <name> on <name>'s server")
        // Only as a whole word: a longer word that holds it stays.
        #expect(clean("Jordanian food", "Jordan") == "Jordanian food")
    }

    /// A server called "Server" is no clue to whose it is, and a placeholder put in already isn't touched.
    @Test func genericNamesAndPlaceholdersStay() {
        #expect(clean("GET http://192.0.2.1:8096/Items: the server's settings", "Server") == "GET http://<server>/Items: the server's settings")
    }

    @Test func theAccountsIdGoesWithAndWithoutDashes() {
        let id = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        #expect(clean("/Users/\(id)/Views?userId=\(id.replacingOccurrences(of: "-", with: ""))", id) == "/Users/<name>/Views?userId=<name>")
    }

    @Test func whatsUsefulStays() {
        let line = "Playback failed: decoding failed, video hevc 3840x2160 10-bit, audio truehd 7.1, direct play, item 4a1f"
        #expect(clean(line) == line)
        #expect(clean("Error at 00:12:31.4").contains("00:12:31.4"))
        #expect(!clean("version 0.10.4 on Fire OS 8.1.0.3").contains("<ip>"))
    }

    /// What a report holds of the app's own settings leaves out anything naming a place, a person or a sign-in.
    @Test func settingsLeaveOutWhatIdentifies() {
        let found = DebugReport.settings(from: [
            "AsterFIN.serverURL": "https://home.example.org",
            "AsterFIN.deviceId": "abc",
            "AsterFIN.animeMusicVideoLibraries": "My Private Videos",
            "AsterFIN.autoplayNext": true,
            "AsterFIN.maxBitrate": 40_000_000,
            "Other.thing": "x",
        ])
        #expect(found == ["autoplayNext": "true", "maxBitrate": "40000000"])
    }
}
