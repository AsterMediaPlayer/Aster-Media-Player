//
//  TraktSimkl.swift
//  AsterFIN
//
//  Trakt (trakt.tv) and Simkl (simkl.com): signed in to with a code shown
//  here and entered on the service's site on any phone or computer, so a TV
//  signs in too; and everything watched (films and every show, anime
//  included) added to the viewer's history there. Titles go by the ids the
//  server has: TMDB, IMDb and TVDB, with a show's season and episode
//  numbers; Simkl also takes anime's MyAnimeList and AniDB ids.
//

import Foundation

/// A code sign-in under way: the code to enter and where.
nonisolated struct DeviceCode: Sendable, Equatable {
    var userCode: String
    var verificationURL: URL
    /// What the app asks with while it waits (Trakt's device code; Simkl's
    /// user code).
    var pollCode: String
    var interval: TimeInterval
    var expires: Date
}

/// What a watched title is, for the two services' histories.
nonisolated struct WatchedTitle: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case movie
        case episode(season: Int, number: Int)
    }

    var kind: Kind
    /// The film's or show's own ids, as the services name them: "tmdb",
    /// "imdb", "tvdb", and for anime on Simkl the season's "mal".
    var ids: [String: String]

    /// A film or episode as its server describes it: `show` is an episode's
    /// series (whose ids count).
    init?(item: BaseItem, show: BaseItem?, anime: AnimeEntry? = nil) {
        let source = item.kind == .movie ? item : show
        var ids: [String: String] = [:]
        for (service, provider) in [("tmdb", "Tmdb"), ("imdb", "Imdb"), ("tvdb", "Tvdb")] {
            if let id = source?.providerId(provider), !id.isEmpty { ids[service] = id }
        }
        // The season's own entry, as Simkl lists anime (each season apart).
        if let mal = anime?.myAnimeList { ids["mal"] = String(mal) }
        guard !ids.isEmpty else { return nil }
        self.ids = ids
        switch item.kind {
        case .movie:
            kind = .movie
        case .episode:
            guard let season = item.parentIndexNumber, let number = item.indexNumber else { return nil }
            kind = .episode(season: season, number: number)
        default:
            return nil
        }
    }

    /// The history body both services take: `movies`, or `shows` with the
    /// season and episode. `anime` sends a show among Simkl's anime, by
    /// episode number alone (its anime have no seasons).
    func historyBody(idTypes: Set<String>, simklAnime: Bool = false) -> [String: Any] {
        let kept = ids.filter { idTypes.contains($0.key) }.mapValues { value -> Any in Int(value) ?? value }
        let watchedAt = ISO8601DateFormatter().string(from: Date())
        switch kind {
        case .movie:
            return ["movies": [["ids": kept, "watched_at": watchedAt]]]
        case .episode(let season, let number):
            if simklAnime {
                return ["shows": [["ids": kept, "episodes": [["number": number, "watched_at": watchedAt]]]]]
            }
            return ["shows": [["ids": kept, "seasons": [["number": season, "episodes": [["number": number, "watched_at": watchedAt]]]]]]]
        }
    }
}

private let trackerSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    return URLSession(configuration: configuration)
}()

nonisolated enum Trakt {
    struct Tokens: Codable, Sendable, Equatable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, token: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://api.trakt.tv\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TrackerKeys.traktClientId, forHTTPHeaderField: "trakt-api-key")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await trackerSession.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func startSignIn() async throws -> DeviceCode {
        let (data, status) = try await request("/oauth/device/code", method: "POST", body: ["client_id": TrackerKeys.traktClientId])
        guard status == 200 else { throw TrackerError.http(status) }
        struct Reply: Decodable { var device_code: String; var user_code: String; var verification_url: String; var expires_in: Double; var interval: Double }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let url = URL(string: reply.verification_url) else { throw TrackerError.badReply }
        return DeviceCode(userCode: reply.user_code, verificationURL: url, pollCode: reply.device_code,
                          interval: reply.interval, expires: Date().addingTimeInterval(reply.expires_in))
    }

    /// The tokens once the code's been entered; nil while it hasn't.
    static func poll(_ code: DeviceCode) async throws -> Tokens? {
        let (data, status) = try await request("/oauth/device/token", method: "POST", body: [
            "code": code.pollCode, "client_id": TrackerKeys.traktClientId, "client_secret": TrackerKeys.traktClientSecret,
        ])
        switch status {
        case 200: return try tokens(data)
        case 400, 429: return nil
        default: throw TrackerError.http(status)
        }
    }

    static func refreshed(_ tokens: Tokens) async throws -> Tokens {
        let (data, status) = try await request("/oauth/token", method: "POST", body: [
            "refresh_token": tokens.refresh, "client_id": TrackerKeys.traktClientId, "client_secret": TrackerKeys.traktClientSecret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token",
        ])
        if status == 400 || status == 401 { throw TrackerError.signedOut }
        guard status == 200 else { throw TrackerError.http(status) }
        return try self.tokens(data)
    }

    private static func tokens(_ data: Data) throws -> Tokens {
        struct Reply: Decodable { var access_token: String; var refresh_token: String; var expires_in: Double; var created_at: Double }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Tokens(access: reply.access_token, refresh: reply.refresh_token, expires: Date(timeIntervalSince1970: reply.created_at + reply.expires_in))
    }

    static func userName(token: String) async throws -> String {
        let (data, status) = try await request("/users/settings", token: token)
        if status == 401 { throw TrackerError.signedOut }
        guard status == 200 else { throw TrackerError.http(status) }
        struct Reply: Decodable { struct User: Decodable { var username: String; var name: String? }; var user: User }
        let user = try JSONDecoder().decode(Reply.self, from: data).user
        return user.username
    }

    /// Adds a watched film or episode to the viewer's history.
    static func watched(_ title: WatchedTitle, token: String) async throws -> TrackerUpdate {
        let (data, status) = try await request("/sync/history", method: "POST", body: title.historyBody(idTypes: ["tmdb", "imdb", "tvdb"]), token: token)
        if status == 401 { throw TrackerError.signedOut }
        guard status == 201 || status == 200 else { throw TrackerError.http(status) }
        struct Reply: Decodable { struct Added: Decodable { var movies: Int?; var episodes: Int? }; var added: Added }
        let added = (try? JSONDecoder().decode(Reply.self, from: data))?.added
        return (added?.movies ?? 0) + (added?.episodes ?? 0) > 0 ? .watched : .unchanged
    }
}

nonisolated enum Simkl {
    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, token: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://api.simkl.com\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TrackerKeys.simklClientId, forHTTPHeaderField: "simkl-api-key")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await trackerSession.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func startSignIn() async throws -> DeviceCode {
        let (data, status) = try await request("/oauth/pin?client_id=\(TrackerKeys.simklClientId)&redirect=aster%3A%2F%2Fsimkl-auth")
        guard status == 200 else { throw TrackerError.http(status) }
        struct Reply: Decodable { var user_code: String; var verification_url: String; var expires_in: Double; var interval: Double? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let url = URL(string: reply.verification_url) else { throw TrackerError.badReply }
        return DeviceCode(userCode: reply.user_code, verificationURL: url, pollCode: reply.user_code,
                          interval: reply.interval ?? 5, expires: Date().addingTimeInterval(reply.expires_in))
    }

    /// The token once the code's been entered; nil while it hasn't. Simkl's
    /// don't run out.
    static func poll(_ code: DeviceCode) async throws -> String? {
        let (data, status) = try await request("/oauth/pin/\(code.pollCode)?client_id=\(TrackerKeys.simklClientId)")
        guard status == 200 else { throw TrackerError.http(status) }
        struct Reply: Decodable { var result: String?; var access_token: String? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return reply.result == "OK" ? reply.access_token : nil
    }

    static func userName(token: String) async throws -> String {
        let (data, status) = try await request("/users/settings", method: "POST", token: token)
        if status == 401 { throw TrackerError.signedOut }
        guard status == 200 else { throw TrackerError.http(status) }
        struct Reply: Decodable { struct User: Decodable { var name: String }; var user: User }
        return try JSONDecoder().decode(Reply.self, from: data).user.name
    }

    /// Adds a watched film or episode to the viewer's history; an anime
    /// episode by its season's MyAnimeList id, as Simkl lists anime.
    static func watched(_ title: WatchedTitle, token: String) async throws -> TrackerUpdate {
        let anime = title.ids["mal"] != nil
        let body = title.historyBody(idTypes: anime ? ["mal"] : ["tmdb", "imdb", "tvdb"], simklAnime: anime)
        let (data, status) = try await request("/sync/history", method: "POST", body: body, token: token)
        if status == 401 { throw TrackerError.signedOut }
        guard status == 201 || status == 200 else { throw TrackerError.http(status) }
        struct Reply: Decodable { struct Added: Decodable { var movies: Int?; var shows: Int?; var episodes: Int? }; var added: Added? }
        let added = (try? JSONDecoder().decode(Reply.self, from: data))?.added
        return (added?.movies ?? 0) + (added?.shows ?? 0) + (added?.episodes ?? 0) > 0 ? .watched : .unchanged
    }
}
