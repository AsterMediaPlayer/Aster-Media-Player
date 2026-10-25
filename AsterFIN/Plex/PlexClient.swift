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
import Synchronization

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
    /// resized by the server's photo transcoder to fit inside the size asked
    /// for (the free side is left three times as long, so it never decides).
    /// Logos come as PNG, keeping their transparency.
    func imageURL(_ ref: ImageRef) -> URL {
        url("/photo/:/transcode", query: [
            "url": ref.tag,
            "width": ref.maxWidth.map(String.init) ?? ref.maxHeight.map { String($0 * 3) },
            "height": ref.maxHeight.map(String.init) ?? ref.maxWidth.map { String($0 * 3) },
            "minSize": "0",
            "upscale": "1",
            "quality": String(ref.quality),
            "format": ref.kind == .logo ? "png" : nil,
            "X-Plex-Token": accessToken,
        ])
    }

    // MARK: Asking

    /// One page of a list, by Plex's paging headers (as query parameters
    /// they're ignored).
    private func container(_ path: String, query: [String: String?] = [:], start: Int? = nil, size: Int? = nil) async throws -> PlexContainer {
        var request = request(url(path, query: query))
        if let start { request.setValue(String(start), forHTTPHeaderField: "X-Plex-Container-Start") }
        if let size { request.setValue(String(size), forHTTPHeaderField: "X-Plex-Container-Size") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlexError.http(http.statusCode)
        }
        return try JSONDecoder().decode(PlexReply.self, from: data).mediaContainer
    }

    private func titles(_ path: String, query: [String: String?] = [:], start: Int? = nil, size: Int? = nil) async throws -> [BaseItem] {
        (try await container(path, query: query, start: start, size: size).metadata ?? []).map(PlexMapper.item)
    }

    /// The server's movie and TV libraries, asked once.
    private let sectionCache = Mutex<[PlexDirectory]?>(nil)

    private func sections() async throws -> [PlexDirectory] {
        if let cached = sectionCache.withLock({ $0 }) { return cached }
        let all = try await container("/library/sections").directory ?? []
        // Music and photos come later on Plex.
        let shown = all.filter { $0.type == "movie" || $0.type == "show" }
        sectionCache.withLock { $0 = shown }
        return shown
    }

    /// Plex's number for a kind of title, in a section's listing.
    private static func typeNumber(_ kind: ItemKind) -> String? {
        switch kind {
        case .movie: "1"
        case .series: "2"
        case .season: "3"
        case .episode: "4"
        case .boxSet: "18"
        default: nil
        }
    }

    private static func sortParameter(_ sort: ItemSort?, descending: Bool?) -> String? {
        guard let sort else { return nil }
        let field = switch sort {
        case .name: "titleSort"
        case .dateAdded: "addedAt"
        case .releaseDate: "originallyAvailableAt"
        case .rating: "audienceRating"
        }
        return descending == true ? field + ":desc" : field
    }

    // MARK: Browsing

    func libraries() async throws -> [BaseItem] {
        try await sections().map(PlexMapper.library)
    }

    func item(_ id: String) async throws -> BaseItem {
        guard let metadata = try await container("/library/metadata/\(id)", query: [
            "includeGuids": "1", "includeMarkers": "1", "includeChapters": "1",
        ]).metadata?.first else { throw PlexError.http(404) }
        return PlexMapper.item(metadata)
    }

    func items(_ query: ItemQuery) async throws -> ItemsResult {
        // Plex keeps no favourites.
        if query.filters.contains(.favorite) { return ItemsResult(items: [], totalRecordCount: 0) }
        if !query.ids.isEmpty {
            let found = try await titles("/library/metadata/\(query.ids.joined(separator: ","))")
            return ItemsResult(items: found, totalRecordCount: found.count)
        }
        let sections = try await sections()
        var parameters: [String: String?] = ["sort": Self.sortParameter(query.sort, descending: query.descending)]
        if let kind = query.kinds.first { parameters["type"] = Self.typeNumber(kind) }
        if let personId = query.personId { parameters["actor"] = personId }

        // A collection's or folder's own titles.
        if let parentId = query.parentId, !sections.contains(where: { $0.key == parentId }) {
            let found = try await titles("/library/metadata/\(parentId)/children")
            return ItemsResult(items: found, totalRecordCount: found.count)
        }

        // One library, or every library holding these kinds, one after
        // another: a page that runs past the end of one carries on into
        // the next.
        let wanted: [PlexDirectory]
        if let parentId = query.parentId {
            wanted = sections.filter { $0.key == parentId }
        } else {
            let types = Set(query.kinds.compactMap { kind -> String? in
                switch kind {
                case .movie: "movie"
                case .series, .season, .episode: "show"
                default: nil
                }
            })
            wanted = sections.filter { types.isEmpty || types.contains($0.type) }
        }
        var start = query.startIndex ?? 0
        var remaining = query.limit ?? Int.max
        var found: [BaseItem] = []
        var total = 0
        for section in wanted {
            let path = "/library/sections/\(section.key)/all"
            let size = try await container(path, query: parameters, start: 0, size: 0).totalSize ?? 0
            total += size
            guard remaining > 0, start < size else {
                start = max(0, start - size)
                continue
            }
            let page = try await titles(path, query: parameters, start: start, size: min(remaining, size - start))
            found += page
            remaining -= page.count
            start = 0
        }
        return ItemsResult(items: found, totalRecordCount: total)
    }

    /// Newest first: films by when they were added, shows by their newest
    /// episode (as Jellyfin's Recently Added groups episodes by show).
    func latest(parentId: String?, limit: Int, kinds: [ItemKind]) async throws -> [BaseItem] {
        let sections = try await sections()
        let wanted = parentId.map { id in sections.filter { $0.key == id } }
            ?? sections.filter { section in
                kinds.isEmpty || kinds.contains { kind in (kind == .movie) == (section.type == "movie") }
            }
        var found: [BaseItem] = []
        for section in wanted {
            let isShows = section.type == "show"
            found += try await titles("/library/sections/\(section.key)/all", query: [
                "type": isShows ? "2" : "1",
                "sort": isShows ? "episode.addedAt:desc" : "addedAt:desc",
            ], start: 0, size: limit)
        }
        return Array(found.prefix(limit))
    }

    /// What's partway through, everywhere or in one library.
    func resume(limit: Int, parentId: String?) async throws -> [BaseItem] {
        let hubs = try await container("/hubs/continueWatching", query: ["count": String(parentId == nil ? limit : limit * 4)]).hub ?? []
        let section = parentId.flatMap(Int.init)
        let metadata = hubs.flatMap { $0.metadata ?? [] }.filter { section == nil || $0.librarySectionID == section }
        let items = metadata.map(PlexMapper.item)
        return Array(items.filter { ($0.userData?.playbackPositionTicks ?? 0) > 0 }.prefix(limit))
    }

    /// The next episode to watch: of one show, or across them all (Plex's
    /// On Deck, less what's partway through, which Continue Watching has).
    func nextUp(limit: Int, seriesId: String?, parentId: String?) async throws -> [BaseItem] {
        if let seriesId {
            let episodes = try await titles("/library/metadata/\(seriesId)/allLeaves")
            let next = episodes.first { ($0.userData?.playbackPositionTicks ?? 0) > 0 }
                ?? episodes.first { $0.userData?.played != true }
            return next.map { [$0] } ?? []
        }
        let deck = try await titles(parentId.map { "/library/sections/\($0)/onDeck" } ?? "/library/onDeck", start: 0, size: limit * 2)
        return Array(deck.filter { $0.kind == .episode && ($0.userData?.playbackPositionTicks ?? 0) == 0 }.prefix(limit))
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        try await titles("/library/metadata/\(seriesId)/children").filter { $0.kind == .season }
    }

    func episodes(seriesId: String, seasonId: String?) async throws -> [BaseItem] {
        if let seasonId {
            return try await titles("/library/metadata/\(seasonId)/children")
        }
        return try await titles("/library/metadata/\(seriesId)/allLeaves")
    }

    func similar(to id: String, limit: Int) async throws -> [BaseItem] {
        try await titles("/library/metadata/\(id)/similar", query: ["count": String(limit)])
    }

    func specialFeatures(of id: String) async throws -> [BaseItem] {
        try await titles("/library/metadata/\(id)/extras")
    }

    /// Films, shows and episodes, in that order.
    func search(_ term: String, limit: Int) async throws -> [BaseItem] {
        let hubs = try await container("/hubs/search", query: ["query": term, "limit": String(limit)]).hub ?? []
        let order = ["movie", "show", "episode"]
        return hubs
            .filter { order.contains($0.type ?? "") }
            .sorted { (order.firstIndex(of: $0.type ?? "") ?? 9) < (order.firstIndex(of: $1.type ?? "") ?? 9) }
            .flatMap { ($0.metadata ?? []).map(PlexMapper.item) }
    }

    /// Plex keeps no favourites (its watchlist is plex.tv's, for later).
    func setFavorite(_ id: String, _ favorite: Bool) async throws {
        throw PlexError.notBuilt
    }

    func setPlayed(_ id: String, _ played: Bool) async throws {
        let url = url(played ? "/:/scrobble" : "/:/unscrobble", query: ["key": id, "identifier": "com.plexapp.plugins.library"])
        let (_, response) = try await session.data(for: request(url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlexError.http(http.statusCode)
        }
    }

    /// Plex has no per-device sign-in to end on the server.
    func logout() async {}

    // MARK: Anime

    /// Libraries matched by an anime agent: Shoko, HAMA or AniDB.
    func animeLibraries(among libraries: [BaseItem]) async -> [BaseItem] {
        guard let sections = try? await sections() else { return [] }
        let anime = Set(sections.filter { section in
            let agent = (section.agent ?? "").lowercased()
            return ["shoko", "hama", "anidb"].contains { agent.contains($0) }
        }.map(\.key))
        return libraries.filter { anime.contains($0.id) }
    }

    func itemIds(inLibraries libraryIds: [String], types: String) async -> Set<String> {
        var typeNumbers: [String] = []
        if types.contains("Series") { typeNumbers.append("2") }
        if types.contains("Movie") { typeNumbers.append("1") }
        return await withTaskGroup(of: [String].self) { group in
            for libraryId in libraryIds {
                for type in typeNumbers {
                    group.addTask {
                        let found = try? await self.container("/library/sections/\(libraryId)/all", query: ["type": type])
                        return found?.metadata?.map(\.ratingKey) ?? []
                    }
                }
            }
            var ids = Set<String>()
            for await chunk in group { ids.formUnion(chunk) }
            return ids
        }
    }
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
