//
//  PortFixesTests.swift
//  AsterFINTests
//
//  Fixes found while porting to Windows and Android: the sign-in never
//  follows a redirect to another site, and Emby's chapter marks give the
//  opening and ending.
//

import Foundation
import Testing
@testable import AsterFIN

struct PortFixesTests {
    private func request(_ address: String) throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: address)))
        for header in RedirectGuard.credentialHeaders { request.setValue("token", forHTTPHeaderField: header) }
        return request
    }

    @Test func aRedirectWithinTheServerKeepsTheSignIn() throws {
        let original = try #require(URL(string: "https://media.example.com:8920/Items"))
        let kept = RedirectGuard.guarded(try request("https://MEDIA.example.com:8920/Videos/1"), from: original)
        #expect(RedirectGuard.credentialHeaders.allSatisfy { kept.value(forHTTPHeaderField: $0) == "token" })
        // The default port written out is the same address.
        let plain = try #require(URL(string: "https://media.example.com/Items"))
        #expect(RedirectGuard.guarded(try request("https://media.example.com:443/x"), from: plain).value(forHTTPHeaderField: "X-Emby-Authorization") == "token")
    }

    @Test func aRedirectElsewhereLosesTheSignIn() throws {
        let original = try #require(URL(string: "http://192.168.1.10:8096/Users/AuthenticateByName"))
        for target in ["http://evil.example.com:8096/x", "http://192.168.1.10:9000/x", "https://192.168.1.10:8096/x"] {
            let sent = RedirectGuard.guarded(try request(target), from: original)
            #expect(RedirectGuard.credentialHeaders.allSatisfy { sent.value(forHTTPHeaderField: $0) == nil }, "\(target)")
        }
    }

    private func chapter(_ seconds: Int64, _ name: String?, _ marker: String? = nil) -> ChapterInfo {
        ChapterInfo(startPositionTicks: seconds * 10_000_000, name: name, imageTag: nil, markerType: marker)
    }

    @Test func embysMarksGiveTheOpeningAndEnding() {
        // Emby: an ordinary chapter at the same moment as IntroStart.
        let chapters = [chapter(0, "Chapter 1", "Chapter"), chapter(90, "Intro", "IntroStart"), chapter(90, "Chapter 2", "Chapter"),
                        chapter(180, "Intro End", "IntroEnd"), chapter(1300, "Credits", "CreditsStart")]
        let found = OpeningsEndings.candidates(in: chapters, runTimeTicks: 1420 * 10_000_000)
        #expect(found.map(\.kind) == [.opening, .ending])
        #expect(found.map { ($0.end - $0.start) / 10_000_000 } == [90, 120])
    }

    @Test func aNamedChapterRunsToTheNextLaterOne() {
        let chapters = [chapter(0, "Prologue"), chapter(60, "Opening"), chapter(60, "Part A"), chapter(150, "Part B")]
        let found = OpeningsEndings.candidates(in: chapters, runTimeTicks: 1400 * 10_000_000)
        #expect(found.count == 1)
        #expect(found.first.map { ($0.end - $0.start) / 10_000_000 } == 90)
    }
}
