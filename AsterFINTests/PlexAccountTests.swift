//
//  PlexAccountTests.swift
//  AsterFINTests
//
//  plex.tv's replies (shapes from a real account, tokens and addresses
//  replaced): link codes, servers with their addresses ranked, and Home
//  users.
//

import Foundation
import Testing
@testable import AsterFIN

struct PlexAccountTests {
    private let resources = #"""
    [
      {"name":"Living Room","product":"Plex for Apple TV","provides":"client,player","clientIdentifier":"atv","connections":[]},
      {"name":"Friend's Server","product":"Plex Media Server","productVersion":"1.25.4.5487","provides":"server","clientIdentifier":"friend",
       "accessToken":"shared-token","owned":false,"home":false,
       "connections":[
         {"protocol":"https","address":"173.230.133.75","port":8443,"uri":"https://173-230-133-75.f.plex.direct:8443","local":false,"relay":true,"IPv6":false},
         {"protocol":"https","address":"66.78.154.177","port":13041,"uri":"https://66-78-154-177.f.plex.direct:13041","local":false,"relay":false,"IPv6":false},
         {"protocol":"https","address":"192.168.40.240","port":32400,"uri":"https://192-168-40-240.f.plex.direct:32400","local":true,"relay":false,"IPv6":false}
       ]},
      {"name":"Test Server","product":"Plex Media Server","productVersion":"1.43.5.11029","provides":"server","clientIdentifier":"4d09e81d",
       "accessToken":"own-token","owned":true,"home":false,
       "connections":[
         {"protocol":"https","address":"192.168.1.240","port":32400,"uri":"https://192-168-1-240.o.plex.direct:32400","local":true,"relay":false,"IPv6":false},
         {"protocol":"https","address":"172.18.0.1","port":32400,"uri":"https://172-18-0-1.o.plex.direct:32400","local":true,"relay":false,"IPv6":false}
       ]}
    ]
    """#

    @Test func onlyServersAreListedOwnFirst() throws {
        let all = try JSONDecoder().decode([PlexResource].self, from: Data(resources.utf8))
        let servers = all.filter(\.isServer).sorted { ($0.owned ?? false) && !($1.owned ?? false) }
        #expect(servers.map(\.name) == ["Test Server", "Friend's Server"])
        #expect(servers[0].accessToken == "own-token")
        #expect(servers[1].accessToken == "shared-token")
    }

    @Test func addressesRankHomeThenInternetThenRelay() throws {
        let friend = try JSONDecoder().decode([PlexResource].self, from: Data(resources.utf8))[1]
        #expect(friend.rankedConnections.map(\.uri.absoluteString) == [
            "https://192-168-40-240.f.plex.direct:32400",
            // The same home address, plainly, in case the secure name's lookup fails.
            "http://192.168.40.240:32400",
            "https://66-78-154-177.f.plex.direct:13041",
            "https://173-230-133-75.f.plex.direct:8443",
        ])
    }

    @Test func homeUsersAndTheirPins() throws {
        let json = #"""
        {"id":1,"name":"Home","guestUserID":2,"guestEnabled":false,"users":[
          {"id":10,"uuid":"a1","title":"peppy6582","username":"peppy6582","thumb":"https://plex.tv/users/a1/avatar","admin":true,"guest":false,"restricted":false,"protected":true,"hasPassword":true,"pin":"x"},
          {"id":11,"uuid":"b2","title":"Lana","username":"","thumb":"https://plex.tv/users/b2/avatar","admin":false,"guest":false,"restricted":true,"protected":false,"hasPassword":false}
        ]}
        """#
        nonisolated struct Home: Decodable { var users: [PlexHomeUser] }
        let users = try JSONDecoder().decode(Home.self, from: Data(json.utf8)).users
        #expect(users.map(\.title) == ["peppy6582", "Lana"])
        #expect(users[0].protected == true)
        #expect(users[1].restricted == true)
    }

    @Test func aLinkCodeBeforeAndAfter() throws {
        let waiting = try JSONDecoder().decode(PlexPin.self, from: Data(#"{"id":123,"code":"ABCD","clientIdentifier":"c","authToken":null,"expiresIn":1800}"#.utf8))
        #expect(waiting.code == "ABCD")
        #expect(waiting.authToken == nil)
        let linked = try JSONDecoder().decode(PlexPin.self, from: Data(#"{"id":123,"code":"ABCD","authToken":"tok","expiresIn":1700}"#.utf8))
        #expect(linked.authToken == "tok")
    }

    @Test func picturesGoThroughThePhotoTranscoder() {
        let link = PlexLink(accountToken: "a", machineId: "m", connections: [])
        let client = PlexClient(baseURL: URL(string: "https://192-168-1-240.o.plex.direct:32400")!, accessToken: "own", userId: "u", link: link)
        let url = client.imageURL(itemId: "6139", kind: .primary, tag: "/library/metadata/6139/thumb/1792890348", maxWidth: 500)
        #expect(url.absoluteString == "https://192-168-1-240.o.plex.direct:32400/photo/:/transcode?X-Plex-Token=own&height=1500&minSize=0&quality=90&upscale=1&url=/library/metadata/6139/thumb/1792890348&width=500")
        // A logo keeps its transparency.
        let logo = client.imageURL(itemId: "6137", kind: .logo, tag: "/library/metadata/6137/clearLogo/1", maxWidth: 900)
        #expect(logo.query()?.contains("format=png") == true)
    }
}
