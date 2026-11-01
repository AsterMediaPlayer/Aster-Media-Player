//
//  SeerrClient.swift
//  AsterFIN
//
//  Seerr (the joined Overseerr and Jellyseerr): asking the viewer's own
//  request server for films and shows their media server hasn't got.
//  Signed in to the way Seerr's own site does (a Jellyfin or Emby user and
//  password, the Plex account's token, or a Seerr account), which leaves a
//  session cookie; that cookie is all that's kept, synced to the viewer's
//  other devices like the tracking accounts. Nothing here shows until a
//  Seerr address is given in Settings.
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

/// Signed in to Seerr: its address, the session, and who.
nonisolated struct SeerrAccount: Codable, Sendable, Equatable {
    var url: URL
    var cookie: String
    var name: String
    var userId: Int
}

nonisolated enum SeerrError: LocalizedError, Equatable {
    case signedOut
    case refused(String?)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .signedOut: "The Seerr sign-in has run out. Sign in again in Settings."
        case .refused(let message): message ?? "Seerr turned that down."
        case .http(let code): "Seerr answered \(code)."
        }
    }
}

nonisolated enum SeerrClient {
    /// How a Seerr server lets people sign in.
    struct Sign: Decodable, Sendable {
        /// 1 Plex, 2 Jellyfin, 3 Emby, 4 none.
        var mediaServerType: Int?
        var localLogin: Bool?
        var mediaServerLogin: Bool?
        var applicationTitle: String?

        var signsInWithPlex: Bool { mediaServerType == 1 && mediaServerLogin != false }
        var signsInWithJellyfinOrEmby: Bool { (mediaServerType == 2 || mediaServerType == 3) && mediaServerLogin != false }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // The cookie's kept and sent by hand, so it can sync.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// "192.168.1.240:5055" or "https://requests.example.com/" as an address.
    static func address(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard let url = URL(string: trimmed), url.host() != nil else { return nil }
        return url
    }

    static func send(_ base: URL, _ path: String, method: String = "GET", body: [String: Any]? = nil, cookie: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: base.absoluteString + "/api/v1" + path) else { throw SeerrError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SeerrError.http(0) }
        return (data, http)
    }

    static func get<T: Decodable>(_ type: T.Type, _ account: SeerrAccount, _ path: String) async throws -> T {
        let (data, response) = try await send(account.url, path, cookie: account.cookie)
        if response.statusCode == 401 || response.statusCode == 403 { throw SeerrError.signedOut }
        guard response.statusCode == 200 else { throw SeerrError.http(response.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Signing in

    static func signInOptions(_ base: URL) async throws -> Sign {
        let (data, response) = try await send(base, "/settings/public")
        guard response.statusCode == 200 else { throw SeerrError.http(response.statusCode) }
        return try JSONDecoder().decode(Sign.self, from: data)
    }

    /// With the media server's user and password (Jellyfin, Emby).
    static func signIn(_ base: URL, username: String, password: String) async throws -> SeerrAccount {
        try await signIn(base, "/auth/jellyfin", ["username": username, "password": password])
    }

    /// With the Plex account's own token, nothing to type.
    static func signIn(_ base: URL, plexToken: String) async throws -> SeerrAccount {
        try await signIn(base, "/auth/plex", ["authToken": plexToken])
    }

    /// With a Seerr account of its own (an email address and password).
    static func signIn(_ base: URL, email: String, password: String) async throws -> SeerrAccount {
        try await signIn(base, "/auth/local", ["email": email, "password": password])
    }

    private static func signIn(_ base: URL, _ path: String, _ body: [String: Any]) async throws -> SeerrAccount {
        let (data, response) = try await send(base, path, method: "POST", body: body)
        guard response.statusCode == 200 else {
            struct Failure: Decodable { var message: String? }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.message
            throw response.statusCode == 401 || response.statusCode == 403
                ? SeerrError.refused(message ?? "That user name or password wasn't right.")
                : SeerrError.refused(message)
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { all, pair in
            if let key = pair.key as? String, let value = pair.value as? String { all[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: base)
        guard let cookie = cookies.first(where: { $0.name == "connect.sid" }) ?? cookies.first else { throw SeerrError.http(response.statusCode) }
        struct User: Decodable { var id: Int; var displayName: String?; var username: String?; var jellyfinUsername: String?; var plexUsername: String?; var email: String? }
        let user = try JSONDecoder().decode(User.self, from: data)
        let name = user.displayName ?? user.jellyfinUsername ?? user.plexUsername ?? user.username ?? user.email ?? "Seerr"
        return SeerrAccount(url: base, cookie: "\(cookie.name)=\(cookie.value)", name: name, userId: user.id)
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
    static func request(_ title: SeerrTitle, seasons: [Int] = [], account: SeerrAccount) async throws {
        var body: [String: Any] = ["mediaType": title.isMovie ? "movie" : "tv", "mediaId": title.id]
        if !title.isMovie { body["seasons"] = seasons }
        let (data, response) = try await send(account.url, "/request", method: "POST", body: body, cookie: account.cookie)
        if response.statusCode == 401 { throw SeerrError.signedOut }
        guard response.statusCode == 201 || response.statusCode == 200 else {
            struct Failure: Decodable { var message: String? }
            throw SeerrError.refused((try? JSONDecoder().decode(Failure.self, from: data))?.message)
        }
    }
}
