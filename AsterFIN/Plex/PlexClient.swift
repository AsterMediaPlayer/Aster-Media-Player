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
    case pinNeeded
    case wrongPin
    case noServers
    case unreachable(String)
    /// Playback failed while the server was already converting others.
    case transcoderBusy(String)
    /// Playback failed on a connection through Plex's relay.
    case relayLimited(String)

    var errorDescription: String? {
        switch self {
        case .notBuilt: "This isn't available on Plex yet."
        case .pinNeeded: "Enter the PIN."
        case .wrongPin: "That PIN isn't right."
        case .http(401), .http(403): "Plex no longer accepts this sign-in. Sign in with Plex again from the server's page in Settings."
        case .http(404): "That's no longer on the Plex server."
        case .http(503): "The Plex server is busy or still starting up. Try again in a moment."
        case .http(let code): "The Plex server answered with an error (\(code))."
        case .noServers: "This Plex account has no servers."
        case .unreachable(let name): "\(name) isn't answering. Check that it's on; away from home, it also needs Remote Access turned on (in Plex's settings for the server, under Remote Access)."
        case .transcoderBusy(let name): "\(name) is already converting another video, and it converts a limited number at once. Stop the other one, or raise the limit in the server's Transcoder settings."
        case .relayLimited(let name): "\(name) is reached through Plex's relay, which allows only low-quality streams. Turn on Remote Access in the server's settings, or lower Maximum Streaming Quality in Aster's settings."
        }
    }

    /// Errors that mean nothing answered at the server's address.
    static func meansUnreachable(_ error: URLError) -> Bool {
        [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed].contains(error.code)
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

    /// The platform the transcoder is told. Plex picks a conversion profile
    /// by it and has none for a Mac app, answering a bare 400 to every
    /// conversion asked for as "macOS"; the Apple TV's profile (HLS, H.264
    /// and HEVC, AAC and Dolby) fits what the Mac plays, so the Mac
    /// converts as one. The header outranks the query parameter, so both
    /// say it (see `PlexClient.request`).
    static var transcodePlatform: String {
        #if os(macOS)
        "tvOS"
        #else
        platform
        #endif
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
    /// The server's name, for messages.
    let serverName: String
    let session: URLSession

    init(baseURL: URL, accessToken: String, userId: String?, link: PlexLink, serverName: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.userId = userId
        self.link = link
        self.serverName = serverName.flatMap { $0.isEmpty ? nil : $0 } ?? "The Plex server"
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: RedirectGuard.shared, delegateQueue: nil)
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
        // The transcoder goes by the header's platform over the query's.
        if url.path().hasPrefix("/video/:/transcode/") {
            request.setValue(PlexDevice.transcodePlatform, forHTTPHeaderField: "X-Plex-Platform")
        }
        return request
    }

    /// Sends `request`: an error status becomes `PlexError.http`, and
    /// nothing answering becomes `PlexError.unreachable`, whose message
    /// says why that usually happens.
    @discardableResult
    func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where PlexError.meansUnreachable(error) {
            throw PlexError.unreachable(serverName)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlexError.http(http.statusCode)
        }
        return data
    }

    func data(from url: URL, fresh: Bool) async throws -> Data {
        var request = request(url)
        if fresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        return try await perform(request)
    }

    /// Whether this session reaches the server through Plex's relay.
    var isRelayed: Bool {
        link.connections.contains { $0.relay && $0.uri.host() == baseURL.host() && $0.uri.port == baseURL.port }
    }

    /// Why playback that gave up probably failed, when Plex can say: the
    /// server gone, its transcoder already busy with others, or the relay's
    /// low limit. Nil when none of those. The transcoder only matters
    /// when `wasConverting`.
    func playbackTrouble(wasConverting: Bool, playSessionId: String?) async -> PlexError? {
        do {
            let sessions = try await container("/transcode/sessions").transcodeSession ?? []
            if wasConverting, sessions.contains(where: { $0.key != playSessionId }) { return .transcoderBusy(serverName) }
        } catch let error as PlexError {
            if case .unreachable = error { return error }
        } catch {}
        return isRelayed ? .relayLimited(serverName) : nil
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
        let data: Data
        do {
            data = try await perform(request)
        } catch {
            #if DEBUG
            print("DEBUG plex: \(path) -> \(error)")
            #endif
            throw error
        }
        do {
            let container = try JSONDecoder().decode(PlexReply.self, from: data).mediaContainer
            #if DEBUG
            print("DEBUG plex: \(path) -> \(container.metadata?.count ?? 0) titles")
            #endif
            return container
        } catch {
            #if DEBUG
            print("DEBUG plex: \(path) couldn't be read: \(error)")
            #endif
            throw error
        }
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
            wanted = sections.filter { types.isEmpty || $0.type.map(types.contains) == true }
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

    /// The show's episodes with their chapters (and their pictures). Plex's
    /// lists carry no chapters, only an episode's own metadata does, so the
    /// episodes are asked for again by id, a batch to a request; should that
    /// bring none either, the first few of each season are asked for one by
    /// one (openings repeat from one episode to the next, so a sample does).
    func episodesWithChapters(seriesId: String) async throws -> [BaseItem] {
        let listed = try await titles("/library/metadata/\(seriesId)/allLeaves")
        let ids = listed.map(\.id)
        var byId: [String: BaseItem] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 40).map({ Array(ids[$0 ..< min($0 + 40, ids.count)]) }) {
            let batch = (try? await titles("/library/metadata/\(chunk.joined(separator: ","))", query: ["includeChapters": "1"])) ?? []
            for episode in batch { byId[episode.id] = episode }
        }
        if byId.values.contains(where: { !($0.chapters ?? []).isEmpty }) {
            return listed.map { byId[$0.id] ?? $0 }
        }
        let sample = Set(Dictionary(grouping: listed.filter { ($0.parentIndexNumber ?? 0) > 0 }, by: { $0.parentIndexNumber ?? 0 })
            .values.flatMap { $0.prefix(3) }.map(\.id))
        let fetched = await withTaskGroup(of: BaseItem?.self) { group in
            for id in sample {
                group.addTask { try? await self.item(id) }
            }
            var found: [String: BaseItem] = [:]
            for await episode in group {
                if let episode { found[episode.id] = episode }
            }
            return found
        }
        return listed.map { fetched[$0.id] ?? $0 }
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
        try await perform(request(url))
    }

    /// Plex has no per-device sign-in to end on the server.
    func logout() async {}

    // MARK: Anime

    /// Libraries matched by an anime agent (Shoko, HAMA or AniDB), and
    /// without one (Plex's own agent), those where at least half of a few
    /// sampled titles carry an anime genre or an AniDB, AniList or
    /// MyAnimeList id, or that are named for anime.
    func animeLibraries(among libraries: [BaseItem]) async -> [BaseItem] {
        guard let sections = try? await sections() else { return [] }
        let byAgent = Set(sections.filter { section in
            let agent = (section.agent ?? "").lowercased()
            return ["shoko", "hama", "anidb"].contains { agent.contains($0) }
        }.map(\.key))
        let candidates = libraries.filter { library in
            !byAgent.contains(library.id) && sections.contains { $0.key == library.id }
        }
        let sampled = await withTaskGroup(of: (String, Bool).self) { group in
            for library in candidates {
                group.addTask {
                    let sample = (try? await self.titles("/library/sections/\(library.id)/all", query: ["includeGuids": "1"], size: 5)) ?? []
                    let anime = sample.filter { $0.isAnime(on: .plex) }.count
                    return (library.id, !sample.isEmpty && (anime * 2 >= sample.count || library.isNamedForAnime))
                }
            }
            var found: Set<String> = []
            for await (id, isAnime) in group where isAnime { found.insert(id) }
            return found
        }
        return libraries.filter { byAgent.contains($0.id) || sampled.contains($0.id) }
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
            return PlexClient(baseURL: stored.serverURL, accessToken: stored.accessToken, userId: stored.userId, link: link, serverName: stored.serverName)
        }
        return JellyfinClient(baseURL: stored.serverURL, accessToken: stored.accessToken, userId: stored.userId, kind: stored.kind)
    }
}
