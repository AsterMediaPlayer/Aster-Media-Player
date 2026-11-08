//
//  TrackingAccounts.swift
//  AsterFIN
//
//  Each person's tracking accounts, linked through the server's Aster
//  Discovery and Tracking plugin (docs/aster-tracking-clients.md §3): Simkl,
//  AniList, MyAnimeList, Last.fm, ListenBrainz and Hardcover, linked once for
//  every app. The server sends what's watched and listened to; the apps
//  only link, unlink, and switch sending on or off.
//

import Foundation

nonisolated enum TrackedService: String, CaseIterable, Identifiable, Sendable {
    case simkl, anilist, myanimelist, lastfm, listenbrainz, hardcover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simkl: "Simkl"
        case .anilist: "AniList"
        case .myanimelist: "MyAnimeList"
        case .lastfm: "Last.fm"
        case .listenbrainz: "ListenBrainz"
        case .hardcover: "Hardcover"
        }
    }

    /// How linking goes: a code to enter on the service's site (Simkl,
    /// Hardcover), approving Aster there (Last.fm), or a code or token pasted
    /// back (AniList, MyAnimeList, ListenBrainz).
    enum Flow { case code, approve, paste }

    var flow: Flow {
        switch self {
        case .simkl, .hardcover: .code
        case .lastfm: .approve
        case .anilist, .myanimelist, .listenbrainz: .paste
        }
    }

    /// What it keeps track of.
    var group: String {
        switch self {
        case .simkl: "Films and Shows"
        case .anilist, .myanimelist: "Anime"
        case .lastfm, .listenbrainz: "Music"
        case .hardcover: "Audiobooks"
        }
    }

    /// "watch" or "listen to", for the switch's words.
    var verb: String {
        switch self {
        case .lastfm, .listenbrainz, .hardcover: "listen to"
        default: "watch"
        }
    }
}

nonisolated struct TrackedAccount: Decodable, Sendable, Equatable {
    var available: Bool?
    var linked: Bool?
    var name: String?
    var linkedAt: String?
    /// When the link runs out and needs doing again (AniList's year).
    var expires: String?
    var scrobble: Bool?

    var isLinked: Bool { linked == true }
}

nonisolated struct SendLogEntry: Decodable, Sendable, Identifiable, Equatable {
    var at: String?
    var service: String?
    var title: String?
    var result: String?

    var id: String { "\(at ?? "")|\(service ?? "")|\(title ?? "")" }
    var date: Date? { at.flatMap(TrackingAPI.date) }
}

nonisolated struct TrackedAccounts: Decodable, Sendable, Equatable {
    var simkl: TrackedAccount?
    var aniList: TrackedAccount?
    var myAnimeList: TrackedAccount?
    var lastFm: TrackedAccount?
    var listenBrainz: TrackedAccount?
    var hardcover: TrackedAccount?
    /// Sends waiting to be tried again.
    var waiting: Int?
    /// The last sends, newest first.
    var log: [SendLogEntry]?

    func account(_ service: TrackedService) -> TrackedAccount? {
        switch service {
        case .simkl: simkl
        case .anilist: aniList
        case .myanimelist: myAnimeList
        case .lastfm: lastFm
        case .listenbrainz: listenBrainz
        case .hardcover: hardcover
        }
    }
}

/// What starting to link gives: where to go, and what to enter there.
nonisolated struct TrackedLink: Decodable, Sendable, Equatable {
    var url: String
    var code: String?
    /// The address with the code in it, for a QR code.
    var completeUrl: String?
    var paste: Bool?
    /// Seconds between checks.
    var interval: Int?
    var expiresIn: Int?
}

nonisolated enum TrackedLinkResult: Equatable, Sendable {
    case linked
    /// Not entered or approved yet.
    case waiting
    /// The code ran out or was refused: start again.
    case expired
    case failed(String)
}

nonisolated enum TrackingError: LocalizedError {
    case noApp(String)
    case unreachable(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noApp(let name): "This server has no app to link \(name) with yet. Its admin can add one in the plugin's settings."
        case .unreachable(let name): "\(name) couldn't be reached. Try again in a moment."
        case .http(let code): "The server answered \(code)."
        }
    }
}

nonisolated enum TrackingAPI {
    private static func request(_ client: JellyfinClient, _ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = client.authorizedRequest(client.baseURL.appending(path: path), method: method)
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// What's linked, and the last sends.
    static func accounts(client: JellyfinClient) async throws -> TrackedAccounts {
        let (data, status) = try await send(request(client, "AsterTracking/Accounts"))
        guard status == 200 else { throw TrackingError.http(status) }
        return try TrackingFeatures.decoder.decode(TrackedAccounts.self, from: data)
    }

    static func startLink(_ service: TrackedService, client: JellyfinClient) async throws -> TrackedLink {
        let (data, status) = try await send(request(client, "AsterTracking/Accounts/\(service.rawValue)/Link", method: "POST"))
        switch status {
        case 200: return try TrackingFeatures.decoder.decode(TrackedLink.self, from: data)
        case 409: throw TrackingError.noApp(service.title)
        case 502: throw TrackingError.unreachable(service.title)
        default: throw TrackingError.http(status)
        }
    }

    /// Asks whether a code's been entered or approved (code and approve
    /// flows), or hands over what was pasted.
    static func complete(_ service: TrackedService, pasted: String? = nil, client: JellyfinClient) async throws -> TrackedLinkResult {
        let body: [String: Any]? = pasted.map { ["Code": $0] }
        let (_, status) = try await send(request(client, "AsterTracking/Accounts/\(service.rawValue)/Link/Complete", method: "POST", body: body ?? [:]))
        switch status {
        case 200: return .linked
        case 202: return .waiting
        case 400: return .failed("Paste the code the sign-in page showed.")
        case 409: return .failed(TrackingError.noApp(service.title).localizedDescription)
        case 410: return .expired
        case 502: return .failed(TrackingError.unreachable(service.title).localizedDescription)
        default: return .failed(TrackingError.http(status).localizedDescription)
        }
    }

    static func setScrobble(_ service: TrackedService, _ on: Bool, client: JellyfinClient) async throws {
        let (_, status) = try await send(request(client, "AsterTracking/Accounts/\(service.rawValue)/Settings", method: "PUT", body: ["Scrobble": on]))
        guard (200..<300).contains(status) else { throw TrackingError.http(status) }
    }

    static func unlink(_ service: TrackedService, client: JellyfinClient) async throws {
        let (_, status) = try await send(request(client, "AsterTracking/Accounts/\(service.rawValue)", method: "DELETE"))
        guard (200..<300).contains(status) else { throw TrackingError.http(status) }
    }

    /// An ISO 8601 date, with or without fractions of a second.
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
