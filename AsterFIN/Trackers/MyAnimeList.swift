//
//  MyAnimeList.swift
//  AsterFIN
//
//  MyAnimeList (myanimelist.net): signing in with OAuth 2 and PKCE (plain,
//  the only kind it takes; no client secret for an "other" app), tokens
//  refreshed as they run out, and an episode's progress written to the
//  viewer's list through its v2 API.
//

import Foundation

nonisolated enum MyAnimeList {
    static let redirect = "aster://mal-auth"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// A sign-in's address and the verifier its code is traded with.
    static func signIn() -> (url: URL, verifier: String, state: String)? {
        guard !TrackerKeys.myAnimeListClientId.isEmpty else { return nil }
        // 43 to 128 unreserved characters; with "plain" it's also the challenge.
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = String((0 ..< 96).map { _ in alphabet.randomElement()! })
        let state = UUID().uuidString
        var components = URLComponents(string: "https://myanimelist.net/v1/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: TrackerKeys.myAnimeListClientId),
            URLQueryItem(name: "code_challenge", value: verifier),
            URLQueryItem(name: "code_challenge_method", value: "plain"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { return nil }
        return (url, verifier, state)
    }

    /// The code in a sign-in's redirect, when its state is the one sent.
    static func code(fromRedirect url: URL, state: String) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { return nil }
        return items.first { $0.name == "code" }?.value
    }

    struct Tokens: Codable, Sendable, Equatable {
        var access: String
        var refresh: String
        var expires: Date
    }

    static func tokens(code: String, verifier: String) async throws -> Tokens {
        try await tokenRequest([
            "client_id": TrackerKeys.myAnimeListClientId, "grant_type": "authorization_code",
            "code": code, "code_verifier": verifier, "redirect_uri": redirect,
        ])
    }

    static func refreshed(_ tokens: Tokens) async throws -> Tokens {
        try await tokenRequest(["client_id": TrackerKeys.myAnimeListClientId, "grant_type": "refresh_token", "refresh_token": tokens.refresh])
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://myanimelist.net/v1/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody(form).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { throw TrackerError.signedOut }
        guard status == 200 else { throw TrackerError.http(status) }
        struct Reply: Decodable { var access_token: String; var refresh_token: String; var expires_in: Double }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Tokens(access: reply.access_token, refresh: reply.refresh_token, expires: Date().addingTimeInterval(reply.expires_in))
    }

    static func formBody(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    private static func api(_ path: String, method: String = "GET", form: [String: String]? = nil, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.myanimelist.net/v2\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(formBody(form).utf8)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw TrackerError.signedOut }
        guard status == 200 else { throw TrackerError.http(status) }
        return data
    }

    static func userName(token: String) async throws -> String {
        struct Reply: Decodable { var name: String }
        return try JSONDecoder().decode(Reply.self, from: try await api("/users/@me", token: token)).name
    }

    /// Episode `number` of anime `id` watched: watched count set to it
    /// (never lowered) and the entry Watching, or Completed at the last.
    static func watched(animeId id: Int, episode number: Int, token: String) async throws -> TrackerUpdate {
        struct Reply: Decodable {
            struct Status: Decodable { var status: String?; var num_episodes_watched: Int?; var is_rewatching: Bool? }
            var num_episodes: Int?
            var my_list_status: Status?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: try await api("/anime/\(id)?fields=num_episodes,my_list_status", token: token))
        let watched = reply.my_list_status?.num_episodes_watched ?? 0
        let status = reply.my_list_status?.status
        guard number > watched || status == nil || status == "plan_to_watch" else { return .unchanged }
        let newWatched = max(number, watched)
        let total = reply.num_episodes.flatMap { $0 > 0 ? $0 : nil }
        let done = total.map { newWatched >= $0 } ?? false
        var form = ["num_watched_episodes": String(newWatched), "status": done ? "completed" : "watching"]
        if reply.my_list_status?.is_rewatching == true, !done {
            form["status"] = "completed"
            form["is_rewatching"] = "true"
        }
        _ = try await api("/anime/\(id)/my_list_status", method: "PATCH", form: form, token: token)
        return done ? .completed(newWatched) : .progress(newWatched)
    }
}
