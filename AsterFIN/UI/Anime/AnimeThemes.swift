//
//  AnimeThemes.swift
//  AsterFIN
//
//  The song card's details from AnimeThemes (animethemes.moe) when the
//  server has no OP/ED plugin to give them: on Plex, on Emby, and on
//  Jellyfin without the plugin. A show is found by its AniDB id when the
//  server knows it (Jellyfin with Shoko), else by its name and the year
//  the episode aired, since AnimeThemes lists each season apart and by its
//  Japanese name. Each show is asked about once per launch.
//

import Foundation
import Synchronization

/// One opening or ending, as AnimeThemes knows it.
nonisolated struct KnownTheme: Sendable, Hashable {
    var isOpening: Bool
    var sequence: Int
    var songTitle: String?
    var artists: [String]
    /// The episodes it plays in, as AnimeThemes writes them: "1-6, 8-".
    var episodes: String?

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

nonisolated enum AnimeThemesLookup {
    private static let base = URL(string: "https://api.animethemes.moe")!
    private static let include = "animethemes.song.performances.artist,animethemes.animethemeentries"
    /// What each show turned out to have, nothing included.
    private static let found = Mutex<[String: [KnownTheme]]>([:])

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// The themes of the show `episode` is from: by `aniDBId`, else by
    /// `seriesName` and the year the episode aired.
    static func themes(aniDBId: String?, seriesName: String, year: Int?) async -> [KnownTheme] {
        let key = aniDBId.map { "anidb:\($0)" } ?? "name:\(seriesName.lowercased())|\(year ?? 0)"
        if let cached = found.withLock({ $0[key] }) { return cached }
        let themes: [KnownTheme]
        if let aniDBId {
            themes = await byAniDB(aniDBId)
        } else {
            themes = await byName(seriesName, year: year)
        }
        found.withLock { $0[key] = themes }
        return themes
    }

    private static func byAniDB(_ id: String) async -> [KnownTheme] {
        let reply: AnimeList? = await get("/anime", [
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
    private static func byName(_ name: String, year: Int?) async -> [KnownTheme] {
        let search: SearchReply? = await get("/search", ["q": name, "fields[search]": "anime"])
        let candidates = search?.search.anime ?? []
        let pick: Anime?
        if let year {
            pick = candidates.first { $0.year == year } ?? candidates.first { $0.year == year - 1 }
        } else {
            pick = candidates.first
        }
        guard let pick else { return [] }
        let reply: AnimeReply? = await get("/anime/\(pick.slug)", ["include": include])
        return reply.map { themes($0.anime) } ?? []
    }

    static func themes(_ anime: Anime) -> [KnownTheme] {
        (anime.animethemes ?? []).compactMap { theme in
            guard theme.type == "OP" || theme.type == "ED" else { return nil }
            let artists = (theme.song?.performances ?? []).compactMap { $0.artist?.name }
            let episodes = (theme.animethemeentries ?? []).compactMap(\.episodes).first
            return KnownTheme(isOpening: theme.type == "OP", sequence: theme.sequence ?? 1,
                              songTitle: theme.song?.title, artists: artists, episodes: episodes)
        }
    }

    private static func get<T: Decodable>(_ path: String, _ query: [String: String]) async -> T? {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: AnimeThemes' JSON

    struct AnimeList: Decodable, Sendable { var anime: [Anime] }
    struct AnimeReply: Decodable, Sendable { var anime: Anime }
    struct SearchReply: Decodable, Sendable {
        var search: Results
        struct Results: Decodable, Sendable { var anime: [Anime] }
    }

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
}
