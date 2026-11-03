//
//  SignInFlowTests.swift
//  AsterFINTests
//
//  The first steps of signing in, against the review demo server (openly
//  licensed content only): every way the address gets typed reaches it, a
//  mistyped one fails in seconds with words that say why, and its users
//  are listed. Signing in itself needs the demo password, which stays out
//  of the repo.
//

import Foundation
import Testing
@testable import AsterFIN

@Suite(.serialized)
struct SignInFlowTests {
    private static let demo = "testfin.berrymancloud.us"

    @Test func addressesAreReadAsTyped() {
        #expect(ServerConnectView.normalize(Self.demo)?.absoluteString == "https://testfin.berrymancloud.us")
        #expect(ServerConnectView.normalize("https://\(Self.demo)/")?.absoluteString == "https://testfin.berrymancloud.us")
        #expect(ServerConnectView.normalize("  http://\(Self.demo)  ")?.absoluteString == "http://testfin.berrymancloud.us")
        #expect(ServerConnectView.normalize("192.168.1.10:8096")?.absoluteString == "https://192.168.1.10:8096")
        #expect(ServerConnectView.normalize("   ") == nil)
    }

    /// The demo server answers however its address is typed.
    @Test(arguments: ["testfin.berrymancloud.us", "https://testfin.berrymancloud.us/", "http://testfin.berrymancloud.us"])
    func theDemoServerIsFound(_ typed: String) async throws {
        let url = try #require(ServerConnectView.normalize(typed))
        let info = try await JellyfinClient(baseURL: url).publicSystemInfo()
        #expect(info.serverName == "Aster Demo")
    }

    /// A mistyped name fails at once, rather than spinning: before, the
    /// sign-in connection waited for a network that was already there.
    @Test func aMistypedAddressFailsQuickly() async throws {
        let url = try #require(ServerConnectView.normalize("testfin.berrymancloud.uss"))
        let started = Date()
        do {
            _ = try await JellyfinClient(baseURL: url).publicSystemInfo()
            Issue.record("A server that doesn't exist answered")
        } catch {
            #expect(Date().timeIntervalSince(started) < 15)
            #expect(ServerConnectView.unreachableMessage(error) == "No server has that name. Check the address for typos.")
        }
    }

    @Test func failuresAreSaidPlainly() {
        #expect(ServerConnectView.unreachableMessage(URLError(.notConnectedToInternet)) == "This device isn't connected to a network.")
        #expect(ServerConnectView.unreachableMessage(URLError(.timedOut)).hasPrefix("Nothing answered"))
        #expect(ServerConnectView.unreachableMessage(URLError(.serverCertificateUntrusted)).contains("http://"))
    }

    /// The demo user is listed to pick, as reviewers are told.
    @Test func theDemoUserIsListed() async throws {
        let url = try #require(ServerConnectView.normalize(Self.demo))
        let users = try await JellyfinClient(baseURL: url).publicUsers()
        #expect(users.contains { $0.name == "demo" })
    }
}
