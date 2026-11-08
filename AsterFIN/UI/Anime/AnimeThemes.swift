//
//  AnimeThemes.swift
//  AsterFIN
//
//  The song card's details from AnimeThemes (animethemes.moe) when the
//  server has no OP/ED plugin to give them: on Plex, on Emby, and on
//  Jellyfin without the plugin. A show is found by its AniDB id when the
//  server knows it (Jellyfin with Shoko), else by its name and the year
//  the season began, since AnimeThemes lists each season apart and by its
//  Japanese name. What a name found is kept between runs (see
//  `SongThemeCache`), and asked for fifty names to a request in the
//  background, so a show's page finds it kept.
//

import Foundation
import Synchronization

/// One opening or ending, as AnimeThemes knows it.
nonisolated struct KnownTheme: Codable, Sendable, Hashable {
    var isOpening: Bool
    var sequence: Int
    var songTitle: String?
    var artists: [String]
    /// The episodes it plays in, as AnimeThemes writes them: "1-6, 8-".
    var episodes: String?

    /// How many episodes it plays in; unknown, as good as all of them, so a
    /// theme listed for a few episodes comes before one for the whole show.
    var episodeCount: Int {
        guard let episodes, !episodes.trimmingCharacters(in: .whitespaces).isEmpty else { return .max }
        var total = 0
        for range in Self.ranges(episodes) {
            // "8-": every episode from the eighth on.
            if range.upperBound == .max { return .max }
            total += range.count
        }
        return total
    }

    /// Whether it plays in episode `number`; any episode when unknown.
    func plays(inEpisode number: Int?) -> Bool {
        guard let number, let episodes, !episodes.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return Self.ranges(episodes).contains { $0.contains(number) }
    }

    /// "1-6, 8-" as 1...6 and 8...; "7" as 7...7.
    static func ranges(_ text: String) -> [ClosedRange<Int>] {
        text.split(separator: ",").compactMap { part in
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = bounds.first, let low = Int(first) else { return nil }
            if bounds.count == 1 { return low...low }
            let high = Int(bounds[1]) ?? Int.max
            return high >= low ? low...high : nil
        }
    }
}

/// A show AnimeThemes names and the themes it has. One name finds a show's
/// seasons, each its own: told apart by their AniDB id, which a season on a
/// server with the Shoko or AniDB provider carries, else by the year they
/// began.
nonisolated struct ShowCandidate: Codable, Sendable, Hashable {
    var slug: String
    var year: Int?
    var themes: [KnownTheme]
    var aniDBIds: [Int] = []
}

/// How a `prefetch` went: the names it asked about, and whether it got to
/// the end (a request failing ends it early).
nonisolated struct Warmed: Sendable, Equatable {
    var asked: Int
    var complete: Bool
}

nonisolated enum AnimeThemesLookup {
    private static let base = URL(string: "https://api.animethemes.moe")!
    private static let graphQL = URL(string: "https://graphql.animethemes.moe")!
    private static let include = "animethemes.song.performances.artist,animethemes.animethemeentries"
    /// Shows to a request: AnimeThemes asks for lookups in batches of 50 where they can be.
    static let batch = 50
    /// What each show turned out to have, nothing included: each is asked
    /// about once per launch.
    private static let found = Mutex<[String: [KnownTheme]]>([:])
    /// What each name found this launch (every season of the show, with its
    /// themes), by `nameKey`.
    private static let shows = Mutex<[String: [ShowCandidate]]>([:])

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // AnimeThemes often takes 5 to 15 seconds to answer.
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// What a server's findings are kept under: its address.
    static func serverKey(_ client: any MediaServer) -> String {
        client.baseURL.absoluteString
    }

    /// What a show's themes are remembered under: its AniDB id, else its
    /// name and the year its season began.
    static func key(aniDBId: String?, seriesName: String, year: Int?) -> String {
        aniDBId.map { "anidb:\($0)" } ?? "name:\(seriesName.lowercased())|\(year ?? 0)"
    }

    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Forgets what this launch has found, for a refresh to ask again.
    static func reset() {
        shows.withLock { $0 = [:] }
        found.withLock { $0 = [:] }
    }

    /// The themes of the show `episode` is from: by `aniDBId`, else by
    /// `seriesName` and the year the season began. `server` is whose kept
    /// findings to use (see `serverKey`); nil for none.
    static func themes(aniDBId: String?, seriesName: String, year: Int?, server: String? = nil) async -> [KnownTheme] {
        await lookup(aniDBId: aniDBId, seriesName: seriesName, year: year, server: server) ?? []
    }

    /// `themes`, or nil when the lookup failed (offline, an error), which
    /// isn't the same as a show with none.
    static func lookup(aniDBId: String?, seriesName: String, year: Int?, server: String? = nil) async -> [KnownTheme]? {
        let key = key(aniDBId: aniDBId, seriesName: seriesName, year: year)
        if let cached = found.withLock({ $0[key] }) { return cached }
        let themes: [KnownTheme]
        do {
            if let aniDBId {
                // A season's AniDB id is found among the shows its name found
                // (kept, or got ready in the background) before it's asked by id.
                if let kept = await keptByAniDB(seriesName, aniDBId, server: server) {
                    themes = kept
                } else {
                    themes = try await byAniDB(aniDBId)
                }
            } else {
                themes = try await byName(seriesName, year: year, server: server)
            }
        } catch {
            // Not kept: a lookup that didn't get through is tried again next time.
            return nil
        }
        found.withLock { $0[key] = themes }
        return themes
    }

    /// The themes of the season with this AniDB id among what `name` already
    /// found; nil when nothing is kept for the name or it isn't there.
    private static func keptByAniDB(_ name: String, _ aniDBId: String, server: String?) async -> [KnownTheme]? {
        guard let id = Int(aniDBId.trimmingCharacters(in: .whitespaces)) else { return nil }
        let key = nameKey(name)
        var candidates = shows.withLock { $0[key] }
        if candidates == nil, let server, let kept = await SongThemeCache.shared.shows(server: server, name: name) {
            shows.withLock { $0[key] = kept }
            candidates = kept
        }
        return candidates?.first { $0.aniDBIds.contains(id) }?.themes
    }

    private static func byAniDB(_ id: String) async throws -> [KnownTheme] {
        let reply: AnimeList? = try await get("/anime", [
            "filter[has]": "resources",
            "filter[site]": "AniDB",
            "filter[external_id]": id,
            "include": include,
        ])
        return reply?.anime.first.map(themes) ?? []
    }

    /// The show that began in `year` (or the year before: a season running
    /// over New Year began in the earlier one) among those the name finds;
    /// with no year, the first found. AnimeThemes names shows in Japanese,
    /// so the year, not the name, tells its seasons apart.
    private static func byName(_ name: String, year: Int?, server: String?) async throws -> [KnownTheme] {
        let candidates = try await candidatesFor(name, server: server)
        let pick: ShowCandidate?
        if let year {
            pick = candidates.first { $0.year == year } ?? candidates.first { $0.year == year - 1 }
        } else {
            pick = candidates.first
        }
        return pick?.themes ?? []
    }

    // MARK: By name, in batches

    /// One name, from this launch, then what's kept, then AnimeThemes
    /// (alone, as a batch of one). Throws when AnimeThemes couldn't be asked.
    private static func candidatesFor(_ name: String, server: String?) async throws -> [ShowCandidate] {
        let key = nameKey(name)
        if let known = shows.withLock({ $0[key] }) { return known }
        if let server, let kept = await SongThemeCache.shared.shows(server: server, name: name) {
            shows.withLock { $0[key] = kept }
            return kept
        }
        guard let answers = try await fetch([name]), let candidates = answers.first ?? nil else {
            throw URLError(.badServerResponse)
        }
        shows.withLock { $0[key] = candidates }
        if let server { await SongThemeCache.shared.putShows(server: server, [name: candidates]) }
        return candidates
    }

    /// Gets ready the names that no lookup has found yet, `batch` of them to
    /// a request and a pause between requests, for a library's shows to be
    /// found before their pages are opened. What's kept for `server` isn't
    /// asked again. A request that fails ends it: the next run goes on from
    /// there.
    static func prefetch(names: [String], server: String?, pause: Duration = .seconds(4)) async -> Warmed {
        var toAsk: [String] = []
        var seen: Set<String> = []
        for name in names {
            let key = nameKey(name)
            guard !key.isEmpty, seen.insert(key).inserted, shows.withLock({ $0[key] }) == nil else { continue }
            if let server, let kept = await SongThemeCache.shared.shows(server: server, name: name) {
                shows.withLock { $0[key] = kept }
            } else {
                toAsk.append(name)
            }
        }
        var asked = 0
        let chunks = stride(from: 0, to: toAsk.count, by: batch).map { Array(toAsk[$0 ..< min($0 + batch, toAsk.count)]) }
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { try? await Task.sleep(for: pause) }
            guard !Task.isCancelled, let answers = try? await fetch(chunk) else { return Warmed(asked: asked, complete: false) }
            var got: [String: [ShowCandidate]] = [:]
            for (name, candidates) in zip(chunk, answers) {
                if let candidates { got[name] = candidates }
            }
            if let server { await SongThemeCache.shared.putShows(server: server, got) }
            shows.withLock { known in
                for (name, candidates) in got { known[nameKey(name)] = candidates }
            }
            asked += chunk.count
        }
        return Warmed(asked: asked, complete: true)
    }

    private static let selection = "anime{slug year resources{nodes{site externalId}} animethemes{type sequence song{title{romaji} performances{artist{name{main}}}} animethemeentries{episodes}}}"

    /// The query for `count` names, each its own `search` (`s0`, `s1`...) in
    /// the one request; the names go as variables.
    static func query(count: Int) -> String {
        let variables = (0..<count).map { "$n\($0):String!" }.joined(separator: ",")
        let searches = (0..<count).map { "s\($0):search(search:$n\($0),first:5){\(selection)}" }.joined(separator: " ")
        return "query(\(variables)){\(searches)}"
    }

    /// What each of `count` names found, in order: nil for one the reply left out.
    static func parse(_ data: [String: GraphSearch?], count: Int) -> [[ShowCandidate]?] {
        (0..<count).map { index in
            guard let search = data["s\(index)"], let search, let anime = search.anime else { return nil }
            return anime.map(candidate)
        }
    }

    private static func candidate(_ show: GraphAnime) -> ShowCandidate {
        let ids = (show.resources?.nodes ?? []).compactMap { node -> Int? in
            node.site == "ANIDB" ? node.externalId?.value : nil
        }
        let themes = (show.animethemes ?? []).compactMap { theme -> KnownTheme? in
            guard theme.type == "OP" || theme.type == "ED" else { return nil }
            let artists = (theme.song?.performances ?? []).compactMap { $0.artist?.name?.main }.filter { !$0.isEmpty }
            let title = theme.song?.title?.romaji.flatMap { $0.isEmpty ? nil : $0 }
            let episodes = (theme.animethemeentries ?? []).compactMap(\.episodes).first { !$0.isEmpty }
            return KnownTheme(isOpening: theme.type == "OP", sequence: theme.sequence ?? 1, songTitle: title, artists: artists, episodes: episodes)
        }
        return ShowCandidate(slug: show.slug, year: show.year, themes: themes, aniDBIds: ids)
    }

    /// What each name found; nil when the query was refused (a reply that is
    /// only errors). Throws when AnimeThemes couldn't be asked.
    private static func fetch(_ names: [String]) async throws -> [[ShowCandidate]?]? {
        var variables: [String: String] = [:]
        for (index, name) in names.enumerated() { variables["n\(index)"] = name }
        var request = URLRequest(url: graphQL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphRequest(query: query(count: names.count), variables: variables))
        // A batch of fifty takes about ten seconds; the usual thirty is cut close.
        request.timeoutInterval = 90
        let reply: GraphReply? = try await execute(request)
        guard let data = reply?.data else { return nil }
        return parse(data, count: names.count)
    }

    // MARK: Asking

    static func themes(_ anime: Anime) -> [KnownTheme] {
        (anime.animethemes ?? []).compactMap { theme in
            guard theme.type == "OP" || theme.type == "ED" else { return nil }
            let artists = (theme.song?.performances ?? []).compactMap { $0.artist?.name }
            let episodes = (theme.animethemeentries ?? []).compactMap(\.episodes).first
            return KnownTheme(isOpening: theme.type == "OP", sequence: theme.sequence ?? 1,
                              songTitle: theme.song?.title, artists: artists, episodes: episodes)
        }
    }

    private static func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T? {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await execute(request)
    }

    /// The reply, or nil when AnimeThemes has nothing there (a 404, or a
    /// reply that isn't what was asked). Throws when it couldn't be asked:
    /// a timeout, a dropped connection or a server error, each tried once more.
    private static func execute<T: Decodable>(_ request: URLRequest) async throws -> T? {
        for attempt in 1...2 {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status >= 500 || status == 429 { throw URLError(.badServerResponse) }
                guard status == 200 else { return nil }
                return try? JSONDecoder().decode(T.self, from: data)
            } catch {
                if attempt == 2 || Task.isCancelled { throw error }
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        return nil
    }

    // MARK: AnimeThemes' JSON

    struct AnimeList: Decodable, Sendable { var anime: [Anime] }
    struct AnimeReply: Decodable, Sendable { var anime: Anime }

    struct Anime: Decodable, Sendable {
        var name: String
        var slug: String
        var year: Int?
        var animethemes: [Theme]?
    }

    struct Theme: Decodable, Sendable {
        var type: String
        var sequence: Int?
        var song: Song?
        var animethemeentries: [Entry]?
    }

    struct Song: Decodable, Sendable {
        var title: String?
        var performances: [Performance]?
    }

    struct Performance: Decodable, Sendable {
        var artist: Artist?
        struct Artist: Decodable, Sendable { var name: String }
    }

    struct Entry: Decodable, Sendable {
        var episodes: String?
    }

    // MARK: AnimeThemes' GraphQL

    struct GraphRequest: Encodable, Sendable {
        var query: String
        var variables: [String: String]
    }

    struct GraphReply: Decodable, Sendable {
        var data: [String: GraphSearch?]?
    }

    struct GraphSearch: Decodable, Sendable {
        var anime: [GraphAnime]?
    }

    struct GraphAnime: Decodable, Sendable {
        var slug: String
        var year: Int?
        var resources: GraphResources?
        var animethemes: [GraphTheme]?
    }

    struct GraphResources: Decodable, Sendable {
        var nodes: [GraphResource]?
    }

    struct GraphResource: Decodable, Sendable {
        var site: String?
        var externalId: LenientInt?
    }

    struct GraphTheme: Decodable, Sendable {
        var type: String?
        var sequence: Int?
        var song: GraphSong?
        var animethemeentries: [Entry]?
    }

    struct GraphSong: Decodable, Sendable {
        var title: GraphTitle?
        var performances: [GraphPerformance]?
    }

    struct GraphTitle: Decodable, Sendable { var romaji: String? }
    struct GraphPerformance: Decodable, Sendable { var artist: GraphArtist? }
    struct GraphArtist: Decodable, Sendable { var name: GraphName? }
    struct GraphName: Decodable, Sendable { var main: String? }

    /// A number AnimeThemes may write as a number or as text.
    struct LenientInt: Decodable, Sendable {
        var value: Int

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                value = number
            } else if let text = try? container.decode(String.self), let number = Int(text) {
                value = number
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number")
            }
        }
    }
}
