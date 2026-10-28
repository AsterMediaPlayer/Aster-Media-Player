//
//  ServerAddressTests.swift
//  AsterFINTests
//
//  Plain http:// is warned about only when it crosses the internet; home
//  network names and addresses, and https, aren't.
//

import Foundation
import Testing
@testable import AsterFIN

struct ServerAddressTests {
    private func warns(_ address: String) -> Bool {
        ServerAddress.isUnencryptedRemote(URL(string: address)!)
    }

    @Test func remotePlainHTTPIsWarnedAbout() {
        #expect(warns("http://myhost.ddns.net:8096"))
        #expect(warns("http://jellyfin.example.com"))
        #expect(warns("http://73.12.40.8:8096"))
        #expect(warns("http://172.32.0.5:8096"))
    }

    @Test func homeNetworkAndHTTPSAreNot() {
        #expect(!warns("https://myhost.ddns.net"))
        #expect(!warns("http://192.168.1.240:8096"))
        #expect(!warns("http://10.0.0.4:8096"))
        #expect(!warns("http://172.20.1.2:8096"))
        #expect(!warns("http://100.101.102.103:8096"))
        #expect(!warns("http://nas.local:8096"))
        #expect(!warns("http://jellyfin:8096"))
        #expect(!warns("http://localhost:8096"))
        #expect(!warns("http://[fd12::1]:8096"))
    }
}
