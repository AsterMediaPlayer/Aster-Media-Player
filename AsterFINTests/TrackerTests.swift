//
//  TrackerTests.swift
//  AsterFINTests
//
//  The tracking accounts' scrambling (a copy for one server user opens
//  only for that user), and reading the sign-in pages' redirects.
//

import Foundation
import Testing
@testable import AsterFIN

struct TrackerTests {
    private var secrets: TrackerSecrets {
        var secrets = TrackerSecrets()
        secrets.aniList = .init(token: "abc.def.ghi", name: "Phillip", expires: Date(timeIntervalSince1970: 1_900_000_000))
        secrets.myAnimeList = .init(tokens: .init(access: "a1", refresh: "r1", expires: Date(timeIntervalSince1970: 1_800_000_000)), name: "phil")
        secrets.updated = Date(timeIntervalSince1970: 1_790_000_000)
        return secrets
    }

    @Test func scrambledForOneUser() throws {
        let blob = try #require(TrackerVault.seal(secrets, user: "5F2C-AB10"))
        #expect(blob.hasPrefix("aster1:"))
        #expect(!blob.contains("abc.def.ghi"))
        // The user's id however it's written: case and dashes don't count.
        #expect(TrackerVault.open(blob, user: "5f2cab10") == secrets)
        #expect(TrackerVault.open(blob, user: "someone-else") == nil)
        #expect(TrackerVault.open("not a blob", user: "5f2cab10") == nil)
        // Sealed twice, two different blobs (a fresh nonce each time).
        #expect(TrackerVault.seal(secrets, user: "5f2cab10") != blob)
    }

    @Test func aniListsRedirectGivesTheToken() throws {
        let url = try #require(URL(string: "aster://anilist-auth#access_token=eyJ0eXAi.abc&token_type=Bearer&expires_in=31536000"))
        let found = try #require(AniList.token(fromRedirect: url))
        #expect(found.token == "eyJ0eXAi.abc")
        #expect(abs((found.expires?.timeIntervalSinceNow ?? 0) - 31_536_000) < 60)
        #expect(AniList.token(fromRedirect: try #require(URL(string: "aster://anilist-auth?error=access_denied"))) == nil)
    }

    @Test func myAnimeListsRedirectGivesTheCode() throws {
        let url = try #require(URL(string: "aster://mal-auth?code=def502&state=S1"))
        #expect(MyAnimeList.code(fromRedirect: url, state: "S1") == "def502")
        // Another sign-in's answer isn't taken.
        #expect(MyAnimeList.code(fromRedirect: url, state: "S2") == nil)
    }

    @Test func formsAreEncoded() {
        let body = MyAnimeList.formBody(["status": "watching", "num_watched_episodes": "5", "redirect_uri": "aster://mal-auth"])
        #expect(body == "num_watched_episodes=5&redirect_uri=aster%3A%2F%2Fmal-auth&status=watching")
    }
}
