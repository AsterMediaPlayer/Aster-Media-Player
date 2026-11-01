//
//  SonosClient.swift
//  AsterFIN
//
//  Talks to a Sonos speaker over its local control interface (UPnP SOAP on
//  port 1400), as Sonos's own apps did before their cloud API: reads the
//  household's rooms and groups, fills a group's queue with stream
//  addresses, and plays, pauses, seeks and reads back where it is. The
//  speaker fetches each song from the media server itself, so it plays on
//  with the phone locked or gone.
//

import Foundation

/// One Sonos player (a room, or one speaker of a pair).
nonisolated struct SonosSpeaker: Sendable, Hashable, Identifiable {
    /// Its "RINCON_…" id.
    var id: String
    var name: String
    var host: String
    var port: Int = 1400

    var baseURL: URL? { URL(string: "http://\(host):\(port)") }
}

/// Rooms playing together, led by a coordinator, which takes every command.
nonisolated struct SonosGroup: Sendable, Hashable, Identifiable {
    var id: String
    var coordinator: SonosSpeaker
    /// The rooms in it, the coordinator first.
    var members: [SonosSpeaker]

    /// "Living Room", or "Living Room + Kitchen".
    var name: String {
        let others = members.filter { $0.id != coordinator.id }.map(\.name)
        return ([coordinator.name] + others).joined(separator: " + ")
    }
}

/// A song or a book's part, for a Sonos queue.
nonisolated struct SonosTrack: Sendable, Hashable {
    var itemId: String
    var url: URL
    var mime: String
    var title: String
    var artist: String?
    var album: String?
    var artURL: URL?
}

/// Where a group's playback is.
nonisolated struct SonosPosition: Sendable, Equatable {
    /// 1 for the queue's first track.
    var track: Int
    var duration: TimeInterval
    var elapsed: TimeInterval
    var uri: String
}

nonisolated enum SonosTransportState: String, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMedia = "NO_MEDIA_PRESENT"
}

nonisolated enum SonosPlayMode: String, Sendable {
    case normal = "NORMAL"
    case repeatAll = "REPEAT_ALL"
    case repeatOne = "REPEAT_ONE"
}

nonisolated enum SonosError: LocalizedError, Equatable {
    case unreachable
    /// The speaker refused the command, with UPnP's code for why.
    case fault(Int)
    case badReply

    var errorDescription: String? {
        switch self {
        case .unreachable: "The Sonos speaker didn't answer."
        case .fault(let code): "The Sonos speaker refused that (\(code))."
        case .badReply: "The Sonos speaker's reply couldn't be read."
        }
    }
}

nonisolated struct SonosClient: Sendable {
    let speaker: SonosSpeaker

    private enum Service: String {
        case avTransport = "AVTransport"
        case groupRendering = "GroupRenderingControl"
        case topology = "ZoneGroupTopology"

        var path: String {
            switch self {
            case .avTransport: "/MediaRenderer/AVTransport/Control"
            case .groupRendering: "/MediaRenderer/GroupRenderingControl/Control"
            case .topology: "/ZoneGroupTopology/Control"
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    /// What a queue is played from, on this coordinator.
    var queueURI: String { "x-rincon-queue:\(speaker.id)#0" }

    // MARK: Rooms

    /// Every group in the household this speaker belongs to.
    func zoneGroups() async throws -> [SonosGroup] {
        let reply = try await call(.topology, "GetZoneGroupState", [])
        guard let state = reply["ZoneGroupState"] else { throw SonosError.badReply }
        return Self.groups(fromZoneGroupState: state)
    }

    // MARK: The queue

    func clearQueue() async throws {
        _ = try await call(.avTransport, "RemoveAllTracksFromQueue", [("InstanceID", "0")])
    }

    /// Adds `tracks` to the end of the queue, sixteen to a request (as many
    /// as a speaker takes at once).
    func enqueue(_ tracks: [SonosTrack]) async throws {
        for start in stride(from: 0, to: tracks.count, by: 16) {
            let chunk = tracks[start ..< min(start + 16, tracks.count)]
            _ = try await call(.avTransport, "AddMultipleURIsToQueue", [
                ("InstanceID", "0"),
                ("UpdateID", "0"),
                ("NumberOfURIs", String(chunk.count)),
                ("EnqueuedURIs", chunk.map(\.url.absoluteString).joined(separator: " ")),
                ("EnqueuedURIsMetaData", chunk.map(Self.didl).joined(separator: " ")),
                ("ContainerURI", ""),
                ("ContainerMetaData", ""),
                ("DesiredFirstTrackNumberEnqueued", "0"),
                ("EnqueueAsNext", "0"),
            ])
        }
    }

    /// Makes the queue what the group plays (after a radio station, say).
    func playFromQueue() async throws {
        _ = try await call(.avTransport, "SetAVTransportURI", [
            ("InstanceID", "0"), ("CurrentURI", queueURI), ("CurrentURIMetaData", ""),
        ])
    }

    // MARK: Transport

    func play() async throws {
        _ = try await call(.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
    }

    func pause() async throws {
        _ = try await call(.avTransport, "Pause", [("InstanceID", "0")])
    }

    func stop() async throws {
        _ = try await call(.avTransport, "Stop", [("InstanceID", "0")])
    }

    func next() async throws {
        _ = try await call(.avTransport, "Next", [("InstanceID", "0")])
    }

    func previous() async throws {
        _ = try await call(.avTransport, "Previous", [("InstanceID", "0")])
    }

    /// To the queue's `track`th entry, 1 for the first.
    func seek(track: Int) async throws {
        _ = try await call(.avTransport, "Seek", [("InstanceID", "0"), ("Unit", "TRACK_NR"), ("Target", String(track))])
    }

    /// Within the track playing.
    func seek(to seconds: TimeInterval) async throws {
        _ = try await call(.avTransport, "Seek", [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", Self.clock(seconds))])
    }

    /// Plays the queue's `track`th entry from `seconds` in. A speaker seeks
    /// within a track only once it's playing it: a seek sent straight after
    /// choosing the track failed, and the track (a whole audiobook) began
    /// from the start. So it plays, waits until the speaker says so, seeks,
    /// and checks where it landed, trying again for a while; then pauses
    /// when it isn't to play on.
    func start(track: Int, at seconds: TimeInterval, playing: Bool) async throws {
        try await seek(track: track)
        try await play()
        if seconds > 1 {
            var landed = false
            for attempt in 0 ..< 15 where !landed {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 300 : 700))
                guard (try? await transportState()) == .playing else { continue }
                do {
                    try await seek(to: seconds)
                } catch {
                    #if DEBUG
                    print("DEBUG sonos: seek to \(Self.clock(seconds)) refused (try \(attempt + 1)): \(error)")
                    #endif
                    continue
                }
                if let position = try? await position(), abs(position.elapsed - seconds) < 20 {
                    landed = true
                }
            }
            #if DEBUG
            print("DEBUG sonos: track \(track) \(landed ? "at" : "never reached") \(Self.clock(seconds))")
            #endif
        }
        if !playing { try await pause() }
    }

    func setPlayMode(_ mode: SonosPlayMode) async throws {
        _ = try await call(.avTransport, "SetPlayMode", [("InstanceID", "0"), ("NewPlayMode", mode.rawValue)])
    }

    func position() async throws -> SonosPosition {
        let reply = try await call(.avTransport, "GetPositionInfo", [("InstanceID", "0")])
        return SonosPosition(
            track: Int(reply["Track"] ?? "") ?? 0,
            duration: Self.seconds(reply["TrackDuration"]),
            elapsed: Self.seconds(reply["RelTime"]),
            uri: reply["TrackURI"] ?? ""
        )
    }

    func transportState() async throws -> SonosTransportState {
        let reply = try await call(.avTransport, "GetTransportInfo", [("InstanceID", "0")])
        return reply["CurrentTransportState"].flatMap(SonosTransportState.init(rawValue:)) ?? .stopped
    }

    // MARK: Volume

    /// The group's volume, 0 to 100.
    func groupVolume() async throws -> Int {
        let reply = try await call(.groupRendering, "GetGroupVolume", [("InstanceID", "0")])
        return Int(reply["CurrentVolume"] ?? "") ?? 0
    }

    func setGroupVolume(_ volume: Int) async throws {
        _ = try await call(.groupRendering, "SetGroupVolume", [("InstanceID", "0"), ("DesiredVolume", String(min(max(volume, 0), 100)))])
    }

    // MARK: SOAP

    private func call(_ service: Service, _ action: String, _ arguments: [(String, String)]) async throws -> [String: String] {
        guard let base = speaker.baseURL else { throw SonosError.unreachable }
        let urn = "urn:schemas-upnp-org:service:\(service.rawValue):1"
        var request = URLRequest(url: base.appending(path: service.path))
        request.httpMethod = "POST"
        request.setValue(#"text/xml; charset="utf-8""#, forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(Self.envelope(action: action, urn: urn, arguments: arguments).utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw SonosError.unreachable
        }
        let values = Self.leaves(of: data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SonosError.fault(Int(values["errorCode"] ?? "") ?? ((response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        return values
    }

    static func envelope(action: String, urn: String, arguments: [(String, String)]) -> String {
        let body = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return #"<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#
            + "<u:\(action) xmlns:u=\"\(urn)\">\(body)</u:\(action)></s:Body></s:Envelope>"
    }

    /// A track's title and pictures as Sonos shows them (in its own app too).
    static func didl(_ track: SonosTrack) -> String {
        var item = "<dc:title>\(escape(track.title))</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        if let artist = track.artist { item += "<dc:creator>\(escape(artist))</dc:creator>" }
        if let album = track.album { item += "<upnp:album>\(escape(album))</upnp:album>" }
        if let art = track.artURL { item += "<upnp:albumArtURI>\(escape(art.absoluteString))</upnp:albumArtURI>" }
        item += "<res protocolInfo=\"http-get:*:\(track.mime):*\">\(escape(track.url.absoluteString))</res>"
        return #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">"#
            + "<item id=\"aster-\(escape(track.itemId))\" parentID=\"-1\" restricted=\"true\">\(item)</item></DIDL-Lite>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// "1:03:25" as seconds; anything else (NOT_IMPLEMENTED) as zero.
    static func seconds(_ clock: String?) -> TimeInterval {
        guard let parts = clock?.split(separator: ":").map({ Double($0) }), parts.count == 3,
              let hours = parts[0], let minutes = parts[1], let seconds = parts[2] else { return 0 }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }

    // MARK: Reading replies

    /// Every element holding only text, by name (without its prefix): what
    /// a SOAP reply's values are. Escaped XML inside one (a zone group
    /// state) comes back as text, to be read in turn.
    static func leaves(of data: Data) -> [String: String] {
        let reader = LeafReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.values
    }

    /// The groups in a `ZoneGroupState`: the rooms people pick, leaving out
    /// the hidden halves of pairs, surrounds and subs, and bridges.
    static func groups(fromZoneGroupState state: String) -> [SonosGroup] {
        let reader = ZoneGroupReader()
        let parser = XMLParser(data: Data(state.utf8))
        parser.delegate = reader
        parser.parse()
        return reader.groups.compactMap { group in
            let members = group.members.filter { !$0.hidden }.map(\.speaker)
            guard let coordinator = members.first(where: { $0.id == group.coordinatorId }) else { return nil }
            let ordered = [coordinator] + members.filter { $0.id != coordinator.id }
            return SonosGroup(id: group.id, coordinator: coordinator, members: ordered)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

nonisolated private final class LeafReader: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var text = ""
    private var hasChildren = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        hasChildren = false
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if !hasChildren {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            values[local] = text
        }
        // The element enclosing this one has a child.
        hasChildren = true
        text = ""
    }
}

nonisolated private final class ZoneGroupReader: NSObject, XMLParserDelegate {
    struct Member { var speaker: SonosSpeaker; var hidden: Bool }
    struct Group { var id: String; var coordinatorId: String; var members: [Member] }

    var groups: [Group] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "ZoneGroup":
            groups.append(Group(id: attributes["ID"] ?? UUID().uuidString, coordinatorId: attributes["Coordinator"] ?? "", members: []))
        case "ZoneGroupMember":
            guard !groups.isEmpty, let id = attributes["UUID"],
                  let location = attributes["Location"].flatMap(URL.init(string:)), let host = location.host() else { return }
            let speaker = SonosSpeaker(id: id, name: attributes["ZoneName"] ?? "Sonos", host: host, port: location.port ?? 1400)
            let hidden = attributes["Invisible"] == "1" || attributes["IsZoneBridge"] == "1"
            groups[groups.count - 1].members.append(Member(speaker: speaker, hidden: hidden))
        default:
            break
        }
    }
}

// MARK: - Stream addresses

nonisolated extension JellyfinClient {
    /// Formats a Sonos plays from the file as it is; anything else is
    /// converted to MP3 at 320 kbps.
    private static let sonosFormats: [String: String] = [
        "mp3": "audio/mpeg", "flac": "audio/flac", "m4a": "audio/mp4", "m4b": "audio/mp4",
        "aac": "audio/aac", "wav": "audio/wav", "aiff": "audio/aiff",
    ]

    /// A song or book part as a Sonos fetches it: from this server, with the
    /// sign-in in the address (a speaker can't send headers).
    func sonosTrack(for item: BaseItem, title: String? = nil, artist: String? = nil, album: String? = nil, art: URL? = nil) -> SonosTrack {
        let container = item.container?.lowercased().split(separator: ",").first.map(String.init)
        let url: URL
        let mime: String
        if let container, let known = Self.sonosFormats[container] {
            // The extension tells the speaker what's coming; m4b is m4a.
            url = tokenURL("/Audio/\(item.id)/stream.\(container == "m4b" ? "m4a" : container)", query: ["static": "true"])
            mime = known
        } else {
            url = tokenURL("/Audio/\(item.id)/stream.mp3", query: ["audioCodec": "mp3", "audioBitRate": "320000", "static": "false"])
            mime = "audio/mpeg"
        }
        return SonosTrack(itemId: item.id, url: url, mime: mime, title: title ?? item.displayTitle,
                          artist: artist ?? item.artistText, album: album ?? item.album, artURL: art)
    }

    /// The item a Sonos queue's track address is for.
    static func sonosItemId(in uri: String) -> String? {
        guard let range = uri.range(of: "/Audio/") else { return nil }
        let rest = uri[range.upperBound...]
        let id = rest.prefix { $0 != "/" && $0 != "?" }
        return id.isEmpty ? nil : String(id)
    }
}
