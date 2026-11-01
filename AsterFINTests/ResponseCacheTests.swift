//
//  ResponseCacheTests.swift
//  AsterFINTests
//
//  What a page last showed, kept per server and user: it comes back as it
//  went in, never for another user, and not after clearing.
//

import Foundation
import Testing
@testable import AsterFIN

@Suite(.serialized)
struct ResponseCacheTests {
    private let server = URL(string: "http://cache-test.invalid:8096")!

    private func items() throws -> [BaseItem] {
        try JSONDecoder().decode([BaseItem].self, from: Data(#"[{"Id": "a1", "Name": "Beastars", "Type": "Series", "ProductionYear": 2019, "UserData": {"Played": false, "PlaybackPositionTicks": 0}}, {"Id": "b2", "Name": "Dune", "Type": "Movie"}]"#.utf8))
    }

    @Test func keptAsItWent() async throws {
        let rows = try items()
        ResponseCache.save(rows, "test-row", server: server, user: "u1")
        var back: [BaseItem]?
        for _ in 0..<50 where back == nil {
            try await Task.sleep(for: .milliseconds(20))
            back = await ResponseCache.load([BaseItem].self, "test-row", server: server, user: "u1")?.value
        }
        #expect(back == rows)
        #expect(back?.first?.displayTitle == "Beastars")
        // Never for anyone else.
        #expect(await ResponseCache.load([BaseItem].self, "test-row", server: server, user: "u2") == nil)
    }

    @Test func clearedOnSigningOut() async throws {
        ResponseCache.save(try items(), "test-clear", server: server, user: "u1")
        try await Task.sleep(for: .milliseconds(200))
        ResponseCache.clear()
        #expect(await ResponseCache.load([BaseItem].self, "test-clear", server: server, user: "u1") == nil)
    }

    @Test func filesNameNoOne() {
        let file = ResponseCache.file("home", server: server, user: "u1").lastPathComponent
        #expect(!file.contains("u1") && !file.contains("cache-test"))
        #expect(file != ResponseCache.file("home", server: server, user: "u2").lastPathComponent)
    }
}
