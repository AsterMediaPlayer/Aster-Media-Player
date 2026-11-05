//
//  SeerrClient.swift
//  AsterFIN
//
//  Seerr (the joined Overseerr and Jellyseerr): asking for films and shows
//  the media server hasn't got. Reached through the Aster Discovery and
//  Tracking plugin on the Jellyfin server, as the signed-in person, so
//  Seerr's own permissions and quotas apply and no app signs in to Seerr
//  (see AsterTracking.swift). Nothing here shows without the plugin.
//

import Foundation

/// Where a title stands with Seerr (its MediaStatus).
nonisolated enum SeerrStatus: Int, Codable, Sendable {
    case unknown = 1, pending, processing, partiallyAvailable, available, blacklisted, deleted

    /// What its badge says; nil for a title nobody's asked for.
    var label: String? {
        switch self {
        case .unknown, .deleted: nil
        case .pending: "Requested"
        case .processing: "Processing"
        case .partiallyAvailable: "Partly Available"
        case .available: "Available"
        case .blacklisted: "Not Available"
        }
    }

    /// Whether there's anything left to ask for.
    var canRequest: Bool { self == .unknown || self == .deleted || self == .partiallyAvailable }
}

/// A film or show as Seerr lists it (from TMDB).
nonisolated struct SeerrTitle: Decodable, Sendable, Hashable, Identifiable {
    var id: Int
    /// "movie" or "tv"; Discover's rows of one kind may leave it out.
    var mediaType: String?
    var title: String?
    var name: String?
    var releaseDate: String?
    var firstAirDate: String?
    var posterPath: String?
    var backdropPath: String?
    var overview: String?
    var mediaInfo: MediaInfo?

    struct MediaInfo: Decodable, Sendable, Hashable {
        var status: SeerrStatus?
        /// The 4K copy's, kept apart by Seerr.
        var status4k: SeerrStatus?
        var seasons: [SeasonStatus]?
        var jellyfinMediaId: String?
        var ratingKey: String?
    }

    struct SeasonStatus: Decodable, Sendable, Hashable {
        var seasonNumber: Int
        var status: SeerrStatus?
    }

    var isMovie: Bool { mediaType == "movie" }
    var displayTitle: String { title ?? name ?? "" }
    var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
    var status: SeerrStatus { mediaInfo?.status ?? .unknown }

    var posterURL: URL? {
        posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") }
    }
}

/// A show's seasons, and where each stands.
nonisolated struct SeerrShow: Decodable, Sendable {
    var seasons: [Season]
    var mediaInfo: SeerrTitle.MediaInfo?

    struct Season: Decodable, Sendable, Hashable {
        var seasonNumber: Int
        var episodeCount: Int?
        var name: String?
    }

    /// The seasons (not the specials) and their status, requests included.
    func seasonStatus() -> [(number: Int, episodes: Int?, status: SeerrStatus)] {
        let known = Dictionary((mediaInfo?.seasons ?? []).map { ($0.seasonNumber, $0.status ?? .unknown) }, uniquingKeysWith: { a, _ in a })
        return seasons.filter { $0.seasonNumber > 0 }.map { ($0.seasonNumber, $0.episodeCount, known[$0.seasonNumber] ?? .unknown) }
    }
}

/// Seerr as the signed-in person reaches it: through the server's plugin,
/// at its address, with the Jellyfin authorization header (no Seerr
/// sign-in, no cookie), and who that person is in Seerr.
nonisolated struct SeerrAccount: Sendable, Equatable {
    var url: URL
    var authorization: String
    var name: String
    var userId: Int

    init(base: URL, authorization: String, name: String, userId: Int) {
        url = base
        self.authorization = authorization
        self.name = name
        self.userId = userId
    }
}

nonisolated enum SeerrError: LocalizedError, Equatable {
    /// The server turned the Jellyfin sign-in down (401).
    case signedOut
    case refused(String?)
    case http(Int)
    /// The server's admin has switched requests off (503).
    case off
    /// The server couldn't reach Seerr (502): never "sign in".
    case unreachable
    /// A title the admin keeps out of Discover (404).
    case notOnServer(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Your sign-in to the server has run out."
        case .refused(let message): message ?? "Seerr turned that down."
        case .http(let code): "Seerr answered \(code)."
        case .off: "Requests are turned off on this server."
        case .unreachable: "Requests aren't available right now."
        case .notOnServer(let message): message
        }
    }
}

nonisolated enum SeerrClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// A call on Seerr's API through the server's plugin: its own paths,
    /// with the Jellyfin authorization header and no Seerr cookie.
    static func send(_ base: URL, _ path: String, method: String = "GET", body: [String: Any]? = nil, authorization: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: base.absoluteString + "/api/v1" + path) else { throw SeerrError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue(authorization, forHTTPHeaderField: "X-Emby-Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SeerrError.http(0) }
        return (data, http)
    }

    /// What a failing answer through the plugin means: 401 the server's own
    /// sign-in, 502 Seerr out of reach, 503 requests off, 404 a title kept
    /// out of Discover, with the plugin's own words.
    static func failure(_ status: Int, _ data: Data) -> SeerrError {
        struct Body: Decodable { var message: String? }
        let message = (try? JSONDecoder().decode(Body.self, from: data))?.message
        switch status {
        case 401: return .signedOut
        case 404 where message?.localizedCaseInsensitiveContains("Not available on this server") == true:
            return .notOnServer(message ?? "Not available on this server.")
        case 502: return .unreachable
        case 503: return .off
        default: return status == 400 || status == 403 || status == 409 ? .refused(message) : .http(status)
        }
    }

    static func get<T: Decodable>(_ type: T.Type, _ account: SeerrAccount, _ path: String) async throws -> T {
        let (data, response) = try await send(account.url, path, authorization: account.authorization)
        guard response.statusCode == 200 else { throw failure(response.statusCode, data) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Finding and asking

    static func search(_ query: String, account: SeerrAccount) async throws -> [SeerrTitle] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let term = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        struct Page: Decodable { var results: [SeerrTitle] }
        let page = try await get(Page.self, account, "/search?query=\(term)&page=1")
        return page.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }

    /// Anime starting or airing around now: Japanese animation first airing
    /// from the first of last month to six months on, newest first, as
    /// Seerr's own Discover filters write it.
    static func upcomingAnime(account: SeerrAccount, now: Date = Date()) async throws -> [SeerrTitle] {
        let window = upcomingWindow(from: now)
        var items = [
            URLQueryItem(name: "language", value: "server|ja"),
            URLQueryItem(name: "sortBy", value: "first_air_date.desc"),
            URLQueryItem(name: "firstAirDateGte", value: window.from),
            URLQueryItem(name: "firstAirDateLte", value: window.to),
            URLQueryItem(name: "genre", value: "16"),
        ]
        struct Page: Decodable { var results: [SeerrTitle]; var totalPages: Int? }
        var found: [SeerrTitle] = []
        // Two pages at most: forty titles is plenty for a row.
        for page in 1 ... 2 {
            items.removeAll { $0.name == "page" }
            items.append(URLQueryItem(name: "page", value: String(page)))
            var components = URLComponents()
            components.queryItems = items
            let query = components.percentEncodedQuery?.replacingOccurrences(of: "|", with: "%7C") ?? ""
            let reply = try await get(Page.self, account, "/discover/tv?\(query)")
            found += reply.results.map { title in
                var title = title
                title.mediaType = "tv"
                return title
            }
            if page >= (reply.totalPages ?? 1) { break }
        }
        return found
    }

    /// "2026-10-01" to "2027-04-01": the first of last month, and six months on.
    static func upcomingWindow(from now: Date) -> (from: String, to: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let start = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        let end = calendar.date(byAdding: .month, value: 6, to: start) ?? start
        let format = DateFormatter()
        format.calendar = calendar
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return (format.string(from: start), format.string(from: end))
    }

    static func show(_ id: Int, account: SeerrAccount) async throws -> SeerrShow {
        try await get(SeerrShow.self, account, "/tv/\(id)")
    }

    /// Asks for a film, or for these seasons of a show.
    /// `options` (an admin's): which Sonarr or Radarr, folder and quality.
    static func request(_ title: SeerrTitle, seasons: [Int] = [], options: SeerrRequestOptions? = nil, account: SeerrAccount) async throws {
        var body: [String: Any] = ["mediaType": title.isMovie ? "movie" : "tv", "mediaId": title.id]
        if !title.isMovie { body["seasons"] = seasons }
        options?.add(to: &body)
        let (data, response) = try await send(account.url, "/request", method: "POST", body: body, authorization: account.authorization)
        guard response.statusCode == 201 || response.statusCode == 200 else { throw failure(response.statusCode, data) }
    }
}
