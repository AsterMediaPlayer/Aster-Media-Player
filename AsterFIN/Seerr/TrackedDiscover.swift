//
//  TrackedDiscover.swift
//  AsterFIN
//
//  The server's Discover page (GET /AsterTracking/Discover/Home): each
//  person's rows, built from their own plays and linked accounts, sent ready
//  to show, in one shape. The app doesn't rank anything: it shows the rows
//  in the order given, mixed with Seerr's own rows as the contract says.
//

import Foundation

/// A string that may arrive as a number.
nonisolated struct FlexibleString: Codable, Hashable, Sendable {
    var value: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else if let number = try? container.decode(Int.self) { value = String(number) }
        else if let number = try? container.decode(Double.self) { value = String(Int(number)) }
        else { value = "" }
    }
}

nonisolated struct TrackedItem: Codable, Hashable, Sendable, Identifiable {
    struct InLibrary: Codable, Hashable, Sendable {
        var itemId: String
        var name: String?
        var type: String?
    }

    var title: String
    var year: Int?
    /// "movie" or "tv", the way Seerr and TMDB split titles.
    var mediaType: String?
    var anime: Bool?
    /// A full web address, or a path on the Jellyfin server.
    var poster: String?
    var overview: String?
    /// "Episode 4 of 12".
    var progress: String?
    var ids: [String: FlexibleString]?
    var inLibrary: InLibrary?
    var genres: [String]?
    var adult: Bool?

    var tmdbId: Int? { ids?["tmdb"].flatMap { Int($0.value) } }
    var isMovie: Bool { mediaType == "movie" }

    var id: String {
        if let tmdb = ids?["tmdb"]?.value, !tmdb.isEmpty { return "tmdb-\(mediaType ?? "tv")-\(tmdb)" }
        if let library = inLibrary { return "library-\(library.itemId)" }
        return "\(title)-\(year ?? 0)"
    }

    /// "Episode 4 of 12", else "2023 · Series".
    var subtitle: String {
        if let progress, !progress.isEmpty { return progress }
        return [year.map(String.init), isMovie ? "Film" : "Series"].compactMap { $0 }.joined(separator: " · ")
    }

    /// The picture's address: as given when it's a web address (http or
    /// https only), else a path on the server.
    func posterURL(server: URL?) -> URL? {
        guard let poster, !poster.isEmpty else { return nil }
        if let url = URL(string: poster), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return url }
        guard let server, poster.hasPrefix("/") else { return nil }
        var base = server.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + poster)
    }

    /// The title as Seerr knows it, by its TMDB id, for its page.
    var seerrTitle: SeerrTitle? {
        guard let tmdbId else { return nil }
        var json: [String: Any] = ["id": tmdbId, "mediaType": isMovie ? "movie" : "tv"]
        json[isMovie ? "title" : "name"] = title
        if let overview { json["overview"] = overview }
        if let year { json[isMovie ? "releaseDate" : "firstAirDate"] = "\(year)-01-01" }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(SeerrTitle.self, from: data)
    }
}

nonisolated struct TrackedRow: Codable, Hashable, Sendable, Identifiable {
    var id: String
    /// continue, recommended, because, library, watchlist, trending, season.
    var kind: String
    var title: String
    var subtitle: String?
    var items: [TrackedItem]
}

nonisolated struct TrackedHome: Decodable, Sendable {
    var rows: [TrackedRow]
    var built: String?
}

/// One row of Discover, whichever it comes from.
enum DiscoverEntry: Identifiable, Hashable {
    case tracked(TrackedRow)
    case slider(SeerrSlider)
    case inTheaters

    var id: String {
        switch self {
        case .tracked(let row): "tracked-\(row.id)"
        case .slider(let slider): "slider-\(slider.stableID)"
        case .inTheaters: "theaters"
        }
    }
}

nonisolated enum TrackedDiscover {
    /// The server's page for this person, or nil on a server without the
    /// plugin. `fresh` builds it again now (pull to refresh). Decoded off the
    /// main actor: the whole page is a lot of JSON.
    @concurrent
    static func home(client: JellyfinClient, fresh: Bool = false) async throws -> TrackedHome? {
        var components = URLComponents(url: client.baseURL.appending(path: "AsterTracking/Discover/Home"), resolvingAgainstBaseURL: false)
        if fresh { components?.queryItems = [URLQueryItem(name: "fresh", value: "true")] }
        guard let url = components?.url else { return nil }
        var request = client.authorizedRequest(url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try TrackingFeatures.decoder.decode(TrackedHome.self, from: data)
        case 404: return nil
        case let status: throw SeerrError.http(status)
        }
    }

    /// The page in the contract's order, as the Linux app does it. The
    /// server's own rows `continue`, `recommended`, `because`, `library` and
    /// `watchlist` come first; then Seerr's sliders in their admin's order,
    /// less its Watchlist (type 3, Plex's only) when the server has its own;
    /// and the server's `trending` and `season` in the place of Seerr's
    /// Trending (type 4), followed by In Theaters. Seerr's Trending stays
    /// when the server has none. With no Seerr, only the server's rows, in
    /// the order given.
    static func order(rows: [TrackedRow], sliders: [SeerrSlider]?, theaters: Bool) -> [DiscoverEntry] {
        let rows = rows.filter { !$0.items.isEmpty }
        guard let sliders else { return rows.map(DiscoverEntry.tracked) }
        let leading: Set<String> = ["continue", "recommended", "because", "library", "watchlist"]
        let kept: Set<String> = leading.union(["trending", "season"])
        var out = rows.filter { leading.contains($0.kind) }.map(DiscoverEntry.tracked)
        // Rows of a kind the app doesn't know yet, as the server gave them.
        out += rows.filter { !kept.contains($0.kind) }.map(DiscoverEntry.tracked)
        let hasWatchlist = rows.contains { $0.kind == "watchlist" }
        let hasTrending = rows.contains { $0.kind == "trending" }
        let trending = rows.filter { $0.kind == "trending" || $0.kind == "season" }.map(DiscoverEntry.tracked)
        for slider in sliders {
            if slider.type == 3, hasWatchlist { continue }
            if slider.type == 4 {
                if hasTrending { out += trending } else { out.append(.slider(slider)) }
                if theaters { out.append(.inTheaters) }
                continue
            }
            out.append(.slider(slider))
        }
        // No Trending among Seerr's rows: the server's go last.
        if !sliders.contains(where: { $0.type == 4 }) { out += trending }
        return out
    }
}
