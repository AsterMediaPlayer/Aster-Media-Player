//
//  SonosClientTests.swift
//  AsterFINTests
//
//  What can be checked of Sonos without a speaker: the household's rooms
//  read from a zone group state, a SOAP reply's values, times both ways,
//  a queue entry's metadata, and the address a speaker fetches a song from.
//

import Foundation
import Testing
@testable import AsterFIN

struct SonosClientTests {
    /// A pair, a room on its own with a hidden sub, and a bridge, as a
    /// speaker on current firmware writes them.
    private let state = """
    <ZoneGroupState><ZoneGroups>\
    <ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:12">\
    <ZoneGroupMember UUID="RINCON_A" Location="http://192.168.1.50:1400/xml/device_description.xml" ZoneName="Living Room"/>\
    <ZoneGroupMember UUID="RINCON_SUB" Location="http://192.168.1.53:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="1"/>\
    <ZoneGroupMember UUID="RINCON_B" Location="http://192.168.1.51:1400/xml/device_description.xml" ZoneName="Kitchen"/>\
    </ZoneGroup>\
    <ZoneGroup Coordinator="RINCON_C" ID="RINCON_C:3">\
    <ZoneGroupMember UUID="RINCON_C" Location="http://192.168.1.52:1400/xml/device_description.xml" ZoneName="Bedroom"><Satellite UUID="RINCON_S" Location="http://192.168.1.54:1400/x.xml" ZoneName="Bedroom" Invisible="1"/></ZoneGroupMember>\
    </ZoneGroup>\
    <ZoneGroup Coordinator="RINCON_BR" ID="RINCON_BR:1">\
    <ZoneGroupMember UUID="RINCON_BR" Location="http://192.168.1.55:1400/xml/device_description.xml" ZoneName="BOOST" IsZoneBridge="1"/>\
    </ZoneGroup>\
    </ZoneGroups><VanishedDevices/></ZoneGroupState>
    """

    @Test func roomsAndGroupsAreRead() {
        let groups = SonosClient.groups(fromZoneGroupState: state)
        #expect(groups.map(\.name) == ["Bedroom", "Living Room + Kitchen"])
        let living = groups[1]
        #expect(living.coordinator.id == "RINCON_A")
        #expect(living.coordinator.host == "192.168.1.50")
        #expect(living.coordinator.port == 1400)
        // The hidden sub isn't a room.
        #expect(living.members.map(\.id) == ["RINCON_A", "RINCON_B"])
        #expect(SonosClient(speaker: living.coordinator).queueURI == "x-rincon-queue:RINCON_A#0")
    }

    /// The zone group state comes escaped inside the reply, read as text.
    @Test func aReplysValuesAreRead() throws {
        let escaped = SonosClient.escape(state)
        let reply = #"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>"#
            + #"<u:GetZoneGroupStateResponse xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"><ZoneGroupState>"#
            + escaped + "</ZoneGroupState></u:GetZoneGroupStateResponse></s:Body></s:Envelope>"
        let values = SonosClient.leaves(of: Data(reply.utf8))
        let inner = try #require(values["ZoneGroupState"])
        #expect(SonosClient.groups(fromZoneGroupState: inner).count == 2)

        let position = #"<s:Envelope xmlns:s="x"><s:Body><u:GetPositionInfoResponse xmlns:u="y"><Track>3</Track><TrackDuration>0:04:05</TrackDuration><TrackURI>http://h/Audio/abc/stream.flac?static=true</TrackURI><RelTime>1:02:03</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>"#
        let read = SonosClient.leaves(of: Data(position.utf8))
        #expect(read["Track"] == "3")
        #expect(SonosClient.seconds(read["TrackDuration"]) == 245)
        #expect(SonosClient.seconds(read["RelTime"]) == 3723)
        #expect(JellyfinClient.sonosItemId(in: read["TrackURI"] ?? "") == "abc")

        let fault = #"<s:Envelope xmlns:s="x"><s:Body><s:Fault><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>701</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"#
        #expect(SonosClient.leaves(of: Data(fault.utf8))["errorCode"] == "701")
    }

    @Test func timesBothWays() {
        #expect(SonosClient.clock(3723.9) == "1:02:03")
        #expect(SonosClient.clock(0) == "0:00:00")
        #expect(SonosClient.seconds("NOT_IMPLEMENTED") == 0)
        #expect(SonosClient.seconds(nil) == 0)
    }

    /// The title and address are escaped once in the metadata, and the
    /// metadata again as a SOAP argument.
    @Test func aQueueEntrysMetadata() throws {
        let track = SonosTrack(itemId: "abc", url: try #require(URL(string: "http://h:8096/Audio/abc/stream.mp3?a=1&api_key=t")),
                               mime: "audio/mpeg", title: "Rock & Roll <Live>", artist: "A", album: nil, artURL: nil)
        let didl = SonosClient.didl(track)
        #expect(didl.contains("<dc:title>Rock &amp; Roll &lt;Live&gt;</dc:title>"))
        #expect(didl.contains("stream.mp3?a=1&amp;api_key=t</res>"))
        #expect(didl.contains(#"protocolInfo="http-get:*:audio/mpeg:*""#))
        let envelope = SonosClient.envelope(action: "AddMultipleURIsToQueue", urn: "urn:x", arguments: [("EnqueuedURIsMetaData", didl)])
        #expect(envelope.contains("&lt;dc:title&gt;Rock &amp;amp; Roll"))
    }

    /// A file a Sonos plays goes as it is; anything else becomes MP3.
    @Test func streamAddresses() throws {
        let client = JellyfinClient(baseURL: try #require(URL(string: "http://192.168.1.10:8096")), accessToken: "token", userId: "u")
        var flac = BaseItem(id: "f1")
        flac.container = "flac"
        let direct = client.sonosTrack(for: flac)
        #expect(direct.url.path() == "/Audio/f1/stream.flac")
        #expect(direct.url.query()?.contains("static=true") == true)
        #expect(direct.url.query()?.contains("api_key=token") == true)
        #expect(direct.mime == "audio/flac")

        var book = BaseItem(id: "b1")
        book.container = "m4b"
        #expect(client.sonosTrack(for: book).url.path() == "/Audio/b1/stream.m4a")

        // As servers write the MP4 family: an audiobook goes as the file.
        var family = BaseItem(id: "m1")
        family.container = "mov,mp4,m4a,3gp,3g2,mj2"
        #expect(client.sonosTrack(for: family).url.path() == "/Audio/m1/stream.m4a")
        #expect(client.sonosTrack(for: family).url.query()?.contains("static=true") == true)

        var opus = BaseItem(id: "o1")
        opus.container = "ogg"
        let converted = client.sonosTrack(for: opus)
        #expect(converted.url.path() == "/Audio/o1/stream.mp3")
        #expect(converted.url.query()?.contains("audioCodec=mp3") == true)
        #expect(converted.mime == "audio/mpeg")
        #expect(client.sonosTrack(for: BaseItem(id: "n1")).url.path() == "/Audio/n1/stream.mp3")
    }
}
