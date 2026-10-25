//
//  PlexClient.swift
//  AsterFIN
//
//  A Plex Media Server, through the same `MediaServer` calls as Jellyfin:
//  Plex's answers are turned into the app's `BaseItem`s. Every request
//  carries the server's token and this device's Plex identity as headers;
//  addresses handed to players carry them in the query instead.
//

import Foundation

nonisolated enum PlexError: LocalizedError, Sendable {
    case notBuilt
    case http(Int)
    case noServers
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .notBuilt: "This isn't available on Plex yet."
        case .http(let code): "The Plex server answered with an error (\(code))."
        case .noServers: "This Plex account has no servers."
        case .unreachable(let name): "\(name) isn't answering. If you're away from home, turn on Remote Access in the server's settings."
        }
    }
}

/// This device as Plex knows it.
nonisolated enum PlexDevice {
    static let product = "Aster"
    /// Stable per install, as Plex asks: the same id Jellyfin sees.
    static var clientIdentifier: String { JellyfinDevice.deviceId }

    /// The headers plex.tv and servers want on every request.
    static func headers(token: String?) -> [String: String] {
        var headers = [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": JellyfinDevice.version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Device-Name": JellyfinDevice.deviceName,
            "X-Plex-Platform": platform,
        ]
        if let token { headers["X-Plex-Token"] = token }
        return headers
    }

    static var platform: String {
        #if os(tvOS)
        "tvOS"
        #elseif os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }
}

nonisolated final class PlexClient: MediaServer {
    let baseURL: URL
    let accessToken: String
    /// The Plex Home user (or account) signed in.
    let userId: String?
    let link: PlexLink
    let kind: ServerKind = .plex
    private let session: URLSession

    init(baseURL: URL, accessToken: String, userId: String?, link: PlexLink) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.userId = userId
        self.link = link
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    /// Browsing, playing, resume and watched; the rest comes later.
    var capabilities: ServerCapabilities { [] }

    // MARK: Requests

    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = path.hasPrefix("/") ? path : "/" + path
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        components.queryItems = items.isEmpty ? nil : items.sorted { $0.name < $1.name }
        return components.url ?? baseURL
    }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in PlexDevice.headers(token: accessToken) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func data(from url: URL, fresh: Bool) async throws -> Data {
        var request = request(url)
        if fresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlexError.http(http.statusCode)
        }
        return data
    }

    // MARK: Pictures

    /// `ref.tag` is the picture's path on the server (a `thumb` or `art`),
    /// resized by the server's photo transcoder.
    func imageURL(_ ref: ImageRef) -> URL {
        url("/photo/:/transcode", query: [
            "url": ref.tag,
            "width": ref.maxWidth.map(String.init) ?? ref.maxHeight.map { String($0 * 2) },
            "height": ref.maxHeight.map(String.init) ?? ref.maxWidth.map { String($0 * 2) },
            "minSize": "1",
            "upscale": "1",
            "quality": String(ref.quality),
            "X-Plex-Token": accessToken,
        ])
    }

    // MARK: Browsing (P4)

    func libraries() async throws -> [BaseItem] { throw PlexError.notBuilt }
    func item(_ id: String) async throws -> BaseItem { throw PlexError.notBuilt }
    func items(_ query: ItemQuery) async throws -> ItemsResult { throw PlexError.notBuilt }
    func latest(parentId: String?, limit: Int, kinds: [ItemKind]) async throws -> [BaseItem] { throw PlexError.notBuilt }
    func resume(limit: Int, parentId: String?) async throws -> [BaseItem] { throw PlexError.notBuilt }
    func nextUp(limit: Int, seriesId: String?, parentId: String?) async throws -> [BaseItem] { throw PlexError.notBuilt }
    func seasons(seriesId: String) async throws -> [BaseItem] { throw PlexError.notBuilt }
    func episodes(seriesId: String, seasonId: String?) async throws -> [BaseItem] { throw PlexError.notBuilt }
    func similar(to id: String, limit: Int) async throws -> [BaseItem] { throw PlexError.notBuilt }
    func specialFeatures(of id: String) async throws -> [BaseItem] { throw PlexError.notBuilt }
    func search(_ term: String, limit: Int) async throws -> [BaseItem] { throw PlexError.notBuilt }
    func setFavorite(_ id: String, _ favorite: Bool) async throws { throw PlexError.notBuilt }
    func setPlayed(_ id: String, _ played: Bool) async throws { throw PlexError.notBuilt }

    /// Plex has no per-device sign-in to end on the server.
    func logout() async {}
}

/// The client for a saved sign-in, whichever server it's for.
nonisolated enum MediaServerFactory {
    static func client(for stored: StoredSession) -> any MediaServer {
        if stored.kind == .plex, let link = stored.plex {
            return PlexClient(baseURL: stored.serverURL, accessToken: stored.accessToken, userId: stored.userId, link: link)
        }
        return JellyfinClient(baseURL: stored.serverURL, accessToken: stored.accessToken, userId: stored.userId, kind: stored.kind)
    }
}
