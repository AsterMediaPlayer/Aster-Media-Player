//
//  SeerrDiscover.swift
//  AsterFIN
//
//  What the Discover tab asks Seerr for: its Discover rows (in the order
//  and with the titles its admin set), the films and shows to browse with
//  filters, and the requests, with an admin's Approve and Decline.
//

import Foundation

/// A title in a row or grid. Films and shows share TMDB ids, so a row that
/// holds both (Trending) tells them apart by kind as well.
nonisolated struct SeerrCard: Identifiable, Hashable, Sendable {
    var title: SeerrTitle
    var id: String { "\(title.mediaType ?? "tv")-\(title.id)" }
}

/// A page of anything Seerr pages.
nonisolated struct SeerrPage<Item: Decodable & Sendable>: Decodable, Sendable {
    var page: Int?
    var totalPages: Int?
    var totalResults: Int?
    var results: [Item]
}

/// One of Seerr's Discover rows, as its admin arranged them.
nonisolated struct SeerrSlider: Decodable, Sendable, Hashable, Identifiable {
    var id: Int?
    var type: Int
    var title: String?
    var data: String?
    var enabled: Bool?

    var stableID: String { "\(type)|\(id ?? 0)|\(data ?? "")" }
}

/// The signed-in Seerr user: who, and whether they may manage requests.
nonisolated struct SeerrUser: Decodable, Sendable {
    var id: Int
    var displayName: String?
    var permissions: Int?

    /// Seerr's ADMIN (2) or MANAGE_REQUESTS (16) permission.
    var managesRequests: Bool { ((permissions ?? 0) & (2 | 16)) != 0 }
}

/// A request, as Seerr lists them.
nonisolated struct SeerrRequest: Decodable, Sendable, Identifiable, Hashable {
    var id: Int
    /// 1 pending approval, 2 approved, 3 declined, 4 failed, 5 completed.
    var status: Int
    var type: String?
    var createdAt: String?
    var is4k: Bool?
    var media: Media
    var seasons: [Season]?
    var requestedBy: Person?
    var modifiedBy: Person?

    struct Media: Decodable, Sendable, Hashable {
        var tmdbId: Int
        var mediaType: String?
        var status: SeerrStatus?
    }

    struct Season: Decodable, Sendable, Hashable {
        var seasonNumber: Int
    }

    struct Person: Decodable, Sendable, Hashable {
        var id: Int
        var displayName: String?
    }

    var isPending: Bool { status == 1 }

    /// Where the request stands, as Seerr's own list says it.
    var stateLabel: String {
        switch status {
        case 1: "Pending Approval"
        case 3: "Declined"
        case 4: "Failed"
        default:
            switch media.status {
            case .available: "Available"
            case .partiallyAvailable: "Partly Available"
            case .processing: "Processing"
            default: status == 5 ? "Completed" : "Approved"
            }
        }
    }

    /// "2026-11-01T12:31:29.000Z" as a date.
    var created: Date? {
        guard let createdAt else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }
}

/// A genre with pictures from its titles, for Discover's genre rows.
nonisolated struct SeerrGenre: Decodable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var backdrops: [String]?
}

/// A film studio or TV network, for Discover's rows of them.
nonisolated struct SeerrCompany: Decodable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var logoPath: String?
}

/// A streaming service, to filter by what's on it.
nonisolated struct SeerrProvider: Decodable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var logoPath: String?
    var displayPriority: Int?
}

/// How the Movies and Series grids are narrowed and sorted, as Seerr's own
/// Discover filters write it.
nonisolated struct SeerrFilter: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case movie, tv }

    enum Sort: String, CaseIterable, Hashable, Sendable, Identifiable {
        case popular, rating, newest, oldest, title
        var id: Self { self }

        var label: String {
            switch self {
            case .popular: "Most Popular"
            case .rating: "Highest Rated"
            case .newest: "Newest"
            case .oldest: "Oldest"
            case .title: "Title"
            }
        }

        func value(for kind: Kind) -> String {
            let date = kind == .movie ? "primary_release_date" : "first_air_date"
            switch self {
            case .popular: return "popularity.desc"
            case .rating: return "vote_average.desc"
            case .newest: return "\(date).desc"
            case .oldest: return "\(date).asc"
            case .title: return kind == .movie ? "title.asc" : "original_name.asc"
            }
        }
    }

    var kind: Kind
    var sort: Sort = .popular
    var genres: Set<Int> = []
    var fromYear: Int?
    var toYear: Int?
    /// Out of ten.
    var minimumRating: Double?
    /// Minutes.
    var minimumRuntime: Int?
    var maximumRuntime: Int?
    /// ISO 639-1, as TMDB's original language.
    var language: String?
    /// A studio (films) or network (shows).
    var company: SeerrCompany?
    var providers: Set<Int> = []
    var region = Locale.current.region?.identifier ?? "US"
    /// Keyword ids, comma-separated, from a custom row.
    var keywords: String?

    init(kind: Kind) { self.kind = kind }

    /// How many filters are set, for the Filters button.
    var activeCount: Int {
        [!genres.isEmpty, fromYear != nil || toYear != nil, minimumRating != nil,
         minimumRuntime != nil || maximumRuntime != nil, language != nil, company != nil,
         !providers.isEmpty, keywords != nil].filter { $0 }.count
    }

    /// The `/discover/movies` or `/discover/tv` query for `page`.
    func path(page: Int) -> String {
        var items = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "sortBy", value: sort.value(for: kind))]
        if !genres.isEmpty { items.append(.init(name: "genre", value: genres.sorted().map(String.init).joined(separator: ","))) }
        let dateGte = kind == .movie ? "primaryReleaseDateGte" : "firstAirDateGte"
        let dateLte = kind == .movie ? "primaryReleaseDateLte" : "firstAirDateLte"
        if let fromYear { items.append(.init(name: dateGte, value: "\(fromYear)-01-01")) }
        if let toYear { items.append(.init(name: dateLte, value: "\(toYear)-12-31")) }
        if let minimumRating {
            items.append(.init(name: "voteAverageGte", value: String(format: "%g", minimumRating)))
            // Without a floor of votes, a film three people rated tops the list.
            items.append(.init(name: "voteCountGte", value: "50"))
        }
        if let minimumRuntime { items.append(.init(name: "withRuntimeGte", value: String(minimumRuntime))) }
        if let maximumRuntime { items.append(.init(name: "withRuntimeLte", value: String(maximumRuntime))) }
        if let language { items.append(.init(name: "language", value: language)) }
        if let company { items.append(.init(name: kind == .movie ? "studio" : "network", value: String(company.id))) }
        if !providers.isEmpty {
            items.append(.init(name: "watchProviders", value: providers.sorted().map(String.init).joined(separator: "|")))
            items.append(.init(name: "watchRegion", value: region))
        }
        if let keywords { items.append(.init(name: "keywords", value: keywords)) }
        var components = URLComponents()
        components.queryItems = items
        // Seerr turns away a bare "," (it wants "%2C", which TMDB reads as
        // "and": every genre chosen); "|" ("or", for services) it takes.
        let query = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: ",", with: "%2C")
            .replacingOccurrences(of: "%7C", with: "|")
        return "/discover/\(kind == .movie ? "movies" : "tv")?\(query)"
    }
}

/// A grid to open: a filter, with what to call it.
nonisolated struct SeerrBrowse: Hashable, Sendable {
    var title: String
    var filter: SeerrFilter
}

/// The requests list's choices, as Seerr's own.
nonisolated enum SeerrRequestFilter: String, CaseIterable, Identifiable, Sendable {
    case all, pending, approved, processing, available, declined = "unavailable"
    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All"
        case .pending: "Pending"
        case .approved: "Approved"
        case .processing: "Processing"
        case .available: "Available"
        case .declined: "Declined"
        }
    }
}

nonisolated extension SeerrClient {
    // MARK: Discover rows

    /// The Discover rows, enabled ones only, in the admin's order.
    static func sliders(account: SeerrAccount) async throws -> [SeerrSlider] {
        try await get([SeerrSlider].self, account, "/settings/discover").filter { $0.enabled != false }
    }

    static func me(account: SeerrAccount) async throws -> SeerrUser {
        try await get(SeerrUser.self, account, "/auth/me")
    }

    /// A row's name: the admin's, else Seerr's own for a built-in row.
    static func sliderTitle(_ slider: SeerrSlider) -> String {
        if let title = slider.title, !title.isEmpty { return title }
        return switch slider.type {
        case 1: "Recently Added"
        case 2: "Recent Requests"
        case 3: "Watchlist"
        case 4: "Trending"
        case 5: "Popular Movies"
        case 6: "Movie Genres"
        case 7: "Upcoming Movies"
        case 8: "Studios"
        case 9: "Popular Series"
        case 10: "Series Genres"
        case 11: "Upcoming Series"
        case 12: "Networks"
        case inTheatersType: "In Theaters"
        default: "More to Discover"
        }
    }

    /// The titles in a row of titles; nil for a row of genres or companies.
    static func titlesPath(for slider: SeerrSlider) -> (path: String, kind: SeerrFilter.Kind?)? {
        // A list of ids ("28,12") needs its commas encoded for Seerr.
        let data = (slider.data ?? "").replacingOccurrences(of: ",", with: "%2C")
        switch slider.type {
        case 3: return ("/discover/watchlist?page=1", nil)
        case 4: return ("/discover/trending?page=1", nil)
        case 5: return ("/discover/movies?page=1", .movie)
        case 7: return ("/discover/movies/upcoming?page=1", .movie)
        case 9: return ("/discover/tv?page=1", .tv)
        case 11: return ("/discover/tv/upcoming?page=1", .tv)
        case 13: return ("/discover/movies?page=1&keywords=\(data)", .movie)
        case 14: return ("/discover/movies?page=1&genre=\(data)", .movie)
        case 15: return ("/discover/tv?page=1&keywords=\(data)", .tv)
        case 16: return ("/discover/tv?page=1&genre=\(data)", .tv)
        case 17:
            let term = (slider.data ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return ("/search?query=\(term)&page=1", nil)
        case 18: return ("/discover/movies/studio/\(data)?page=1", .movie)
        case 19: return ("/discover/tv/network/\(data)?page=1", .tv)
        case 20, 21:
            // "US,8|337": the region, then the services.
            let parts = (slider.data ?? "").split(separator: ",", maxSplits: 1).map(String.init)
            let region = parts.count == 2 ? parts[0] : "US"
            let services = parts.last ?? ""
            return slider.type == 20
                ? ("/discover/movies?page=1&watchRegion=\(region)&watchProviders=\(services)", .movie)
                : ("/discover/tv?page=1&watchRegion=\(region)&watchProviders=\(services)", .tv)
        default: return nil
        }
    }

    /// A page of titles from any of Discover's lists, people left out, each
    /// knowing whether it's a film or a show.
    static func titles(_ path: String, kind: SeerrFilter.Kind?, account: SeerrAccount) async throws -> SeerrPage<SeerrTitle> {
        var page = try await get(SeerrPage<SeerrTitle>.self, account, path)
        page.results = page.results.compactMap { title in
            var title = title
            if let kind { title.mediaType = kind.rawValue }
            return title.mediaType == "movie" || title.mediaType == "tv" ? title : nil
        }
        return page
    }

    /// Discover's own row, not one of Seerr's: films in cinemas now.
    static let inTheatersType = 1000

    /// Films in cinemas now, as near as Seerr's filters come (it passes on
    /// no theatrical-release filter): out in the last six weeks with some
    /// votes, most popular first, less those already on the region's big
    /// streaming services.
    static func inTheaters(account: SeerrAccount, region: String = Locale.current.region?.identifier ?? "US", now: Date = Date()) async throws -> [SeerrTitle] {
        let window = theatricalWindow(from: now)
        let recent = "/discover/movies?sortBy=popularity.desc&primaryReleaseDateGte=\(window.from)&primaryReleaseDateLte=\(window.to)&voteCountGte=20"
        // The services most people have there, by TMDB's own ranking.
        let services = try await providers(.movie, region: region, account: account).prefix(12).map { String($0.id) }
        async let shown = pages(recent, upTo: 3, account: account)
        var streaming = Set<Int>()
        if !services.isEmpty {
            let path = recent + "&watchRegion=\(region)&watchProviders=\(services.joined(separator: "|"))"
            streaming = Set(try await pages(path, upTo: 5, account: account).map(\.id))
        }
        return try await shown.filter { !streaming.contains($0.id) }
    }

    /// "2026-09-20" to "2026-11-01": the last six weeks.
    static func theatricalWindow(from now: Date) -> (from: String, to: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(byAdding: .day, value: -42, to: now) ?? now
        let format = DateFormatter()
        format.calendar = calendar
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return (format.string(from: start), format.string(from: now))
    }

    /// Films from up to `count` pages of a list, in order.
    private static func pages(_ path: String, upTo count: Int, account: SeerrAccount) async throws -> [SeerrTitle] {
        var found: [SeerrTitle] = []
        for page in 1 ... count {
            let reply = try await titles(path + "&page=\(page)", kind: .movie, account: account)
            found += reply.results
            if page >= (reply.totalPages ?? 1) { break }
        }
        return found
    }

    /// What arrived on the server lately, newest first, as titles.
    static func recentlyAdded(account: SeerrAccount) async throws -> [SeerrTitle] {
        struct Media: Decodable, Sendable { var tmdbId: Int; var mediaType: String }
        let media = try await get(SeerrPage<Media>.self, account, "/media?filter=allavailable&take=20&skip=0&sort=mediaAdded").results
        return await titles(for: media.map { ($0.tmdbId, $0.mediaType) }, account: account)
    }

    /// Each (TMDB id, kind) as a title, asked side by side, in order;
    /// those that fail are left out.
    static func titles(for ids: [(Int, String)], account: SeerrAccount) async -> [SeerrTitle] {
        await withTaskGroup(of: (Int, SeerrTitle?).self) { group in
            for (position, (id, kind)) in ids.enumerated() {
                group.addTask {
                    let path = kind == "movie" ? "/movie/\(id)" : "/tv/\(id)"
                    var title = try? await get(SeerrTitle.self, account, path)
                    title?.mediaType = kind
                    return (position, title)
                }
            }
            var found: [(Int, SeerrTitle?)] = []
            for await title in group { found.append(title) }
            return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }

    static func genres(_ kind: SeerrFilter.Kind, account: SeerrAccount) async throws -> [SeerrGenre] {
        try await get([SeerrGenre].self, account, "/discover/genreslider/\(kind.rawValue)")
    }

    /// Seerr's own studios and networks, as its Discover page shows them.
    static let studioIds = [2, 127928, 34, 174, 33, 4, 3, 521, 420, 9993, 41077]
    static let networkIds = [213, 2739, 1024, 2552, 453, 49, 4353, 2, 19, 6, 16, 56, 1112, 4330]

    /// Studios (`movie`) or networks (`tv`), with their logos.
    static func companies(_ kind: SeerrFilter.Kind, account: SeerrAccount) async -> [SeerrCompany] {
        let ids = kind == .movie ? studioIds : networkIds
        let route = kind == .movie ? "studio" : "network"
        return await withTaskGroup(of: (Int, SeerrCompany?).self) { group in
            for (position, id) in ids.enumerated() {
                group.addTask { (position, try? await get(SeerrCompany.self, account, "/\(route)/\(id)")) }
            }
            var found: [(Int, SeerrCompany?)] = []
            for await company in group { found.append(company) }
            return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }

    static func providers(_ kind: SeerrFilter.Kind, region: String, account: SeerrAccount) async throws -> [SeerrProvider] {
        let route = kind == .movie ? "movies" : "tv"
        return try await get([SeerrProvider].self, account, "/watchproviders/\(route)?watchRegion=\(region)")
            .sorted { ($0.displayPriority ?? 999) < ($1.displayPriority ?? 999) }
    }

    /// A company's logo, white on the dark page.
    static func logoURL(_ path: String?) -> URL? {
        path.flatMap { URL(string: "https://image.tmdb.org/t/p/w500_filter(duotone,ffffff,bababa)\($0)") }
    }

    // MARK: Requests

    /// A page of requests: everyone's for someone who manages them, else
    /// the viewer's own (Seerr shows only those anyway).
    static func requests(_ filter: SeerrRequestFilter, mine: Bool, userId: Int, page: Int, account: SeerrAccount) async throws -> SeerrPage<SeerrRequest> {
        struct Reply: Decodable, Sendable {
            struct Info: Decodable, Sendable { var pages: Int?; var page: Int?; var results: Int? }
            var pageInfo: Info
            var results: [SeerrRequest]
        }
        let take = 20
        var path = "/request?take=\(take)&skip=\((page - 1) * take)&filter=\(filter.rawValue)&sort=added"
        if mine { path += "&requestedBy=\(userId)" }
        let reply = try await get(Reply.self, account, path)
        return SeerrPage(page: reply.pageInfo.page, totalPages: reply.pageInfo.pages, totalResults: reply.pageInfo.results, results: reply.results)
    }

    static func approve(_ request: SeerrRequest, account: SeerrAccount) async throws {
        try await act("/request/\(request.id)/approve", method: "POST", account: account)
    }

    static func decline(_ request: SeerrRequest, account: SeerrAccount) async throws {
        try await act("/request/\(request.id)/decline", method: "POST", account: account)
    }

    /// Withdraws a request not yet approved.
    static func cancel(_ request: SeerrRequest, account: SeerrAccount) async throws {
        try await act("/request/\(request.id)", method: "DELETE", account: account)
    }

    private static func act(_ path: String, method: String, account: SeerrAccount) async throws {
        let (data, response) = try await send(account.url, path, method: method, cookie: account.cookie)
        if response.statusCode == 401 { throw SeerrError.signedOut }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { var message: String? }
            throw SeerrError.refused((try? JSONDecoder().decode(Failure.self, from: data))?.message)
        }
    }
}

// MARK: - Requested films on the way

/// A film the viewer asked for and got approved, not out yet: when it
/// arrives and how (on digital or disc, else in cinemas).
nonisolated struct SeerrComingFilm: Sendable, Hashable, Identifiable {
    var title: SeerrTitle
    var date: Date
    /// "Digital Release", "On Disc", "In Theaters".
    var how: String
    var id: Int { title.id }
}

/// TMDB's release dates for a film, by country and kind.
nonisolated struct SeerrReleases: Decodable, Sendable {
    struct Country: Decodable, Sendable {
        var iso_3166_1: String
        var release_dates: [Release]
    }
    struct Release: Decodable, Sendable {
        /// 1 premiere, 2 limited, 3 theatrical, 4 digital, 5 physical, 6 TV.
        var type: Int
        var release_date: String
    }
    var results: [Country]?

    /// When it can be watched at home and how: the first digital or disc
    /// release still ahead; nil once one's past (it's out). With none
    /// known, its cinema release if that's ahead.
    func arrival(region: String, now: Date = Date()) -> (date: Date, how: String)? {
        let countries = results ?? []
        let releases = (countries.first { $0.iso_3166_1 == region } ?? countries.first { $0.iso_3166_1 == "US" })?.release_dates ?? []
        let dated = releases.compactMap { release -> (Int, Date)? in
            Self.date(release.release_date).map { (release.type, $0) }
        }
        let home = dated.filter { $0.0 == 4 || $0.0 == 5 }
        if home.contains(where: { $0.1 <= now }) { return nil }
        if let next = home.filter({ $0.1 > now }).min(by: { $0.1 < $1.1 }) {
            return (next.1, next.0 == 4 ? "Digital Release" : "On Disc")
        }
        if let cinema = dated.filter({ (1...3).contains($0.0) && $0.1 > now }).min(by: { $0.1 < $1.1 }) {
            return (cinema.1, "In Theaters")
        }
        return nil
    }

    static func date(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

nonisolated extension SeerrClient {
    /// The viewer's approved film requests not out yet, soonest first.
    static func comingFilms(account: SeerrAccount, region: String = Locale.current.region?.identifier ?? "US", now: Date = Date()) async throws -> [SeerrComingFilm] {
        struct Dated: Decodable, Sendable {
            var title: SeerrTitle
            var releases: SeerrReleases?
            enum Keys: String, CodingKey { case releases }
            init(from decoder: any Decoder) throws {
                title = try SeerrTitle(from: decoder)
                releases = try decoder.container(keyedBy: Keys.self).decodeIfPresent(SeerrReleases.self, forKey: .releases)
            }
        }
        let requests = try await requests(.approved, mine: true, userId: account.userId, page: 1, account: account).results
            .filter { $0.type == "movie" && $0.media.status != .available }
        let films = await withTaskGroup(of: SeerrComingFilm?.self) { group in
            for request in requests {
                group.addTask {
                    guard var dated = try? await get(Dated.self, account, "/movie/\(request.media.tmdbId)"),
                          let arrival = dated.releases?.arrival(region: region, now: now) else { return nil }
                    dated.title.mediaType = "movie"
                    return SeerrComingFilm(title: dated.title, date: arrival.date, how: arrival.how)
                }
            }
            var found: [SeerrComingFilm] = []
            for await film in group { if let film { found.append(film) } }
            return found
        }
        return films.sorted { $0.date < $1.date }
    }
}
