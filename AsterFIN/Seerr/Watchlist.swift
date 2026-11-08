//
//  Watchlist.swift
//  AsterFIN
//
//  Add to Watchlist (plugin 0.9.8, docs/aster-tracking-clients.md §6): any
//  film or show, from the library, Discover or Seerr, goes on the person's
//  linked watchlist through the server, with or without Seerr. Only Simkl's
//  Plan to Watch for now; the button shows only when the server's plugin
//  offers it and the person has Simkl linked.
//

import SwiftUI

/// A film or show, as the watchlist routes name it: every id known, in the
/// routes' lowercase names.
nonisolated struct WatchlistTitle: Sendable, Equatable {
    /// "movie" or "tv".
    var mediaType: String
    var anime: Bool?
    var ids: [String: String]
    var title: String?
    var year: Int?

    var isUsable: Bool { !ids.isEmpty }

    /// Jellyfin's ProviderIds as the routes name them; anything else, and
    /// empty values, left out.
    static func ids(from providerIds: [String: String]?) -> [String: String] {
        var ids: [String: String] = [:]
        for (key, value) in providerIds ?? [:] where !value.isEmpty {
            switch key.lowercased() {
            case "tmdb": ids["tmdb"] = value
            case "imdb": ids["imdb"] = value
            case "tvdb": ids["tvdb"] = value
            case "anidb": ids["anidb"] = value
            case "anilist": ids["anilist"] = value
            case "myanimelist", "mal": ids["mal"] = value
            default: break
            }
        }
        return ids
    }

    /// A library film or show; nil for anything else (seasons, episodes).
    init?(item: BaseItem) {
        switch item.kind {
        case .movie: mediaType = "movie"
        case .series: mediaType = "tv"
        default: return nil
        }
        anime = item.isAnime
        ids = Self.ids(from: item.providerIds)
        title = item.name
        year = item.productionYear
    }

    /// A title from the server's Discover page, whose ids are already named
    /// as the routes want (less the season's).
    init(item: TrackedItem) {
        mediaType = item.isMovie ? "movie" : "tv"
        anime = item.anime
        ids = (item.ids ?? [:]).compactMapValues { $0.value.isEmpty ? nil : $0.value }.filter { $0.key != "tmdbSeason" }
        title = item.title
        year = item.year
    }

    /// A title from Seerr: its TMDB id, and the IMDb and TVDB ids its
    /// details carry.
    init(seerr title: SeerrTitle, details: SeerrDetails?, anime: Bool) {
        mediaType = title.isMovie ? "movie" : "tv"
        self.anime = anime
        var ids = ["tmdb": String(title.id)]
        if let imdb = details?.externalIds?.imdbId ?? details?.imdbId, !imdb.isEmpty { ids["imdb"] = imdb }
        if let tvdb = details?.externalIds?.tvdbId { ids["tvdb"] = String(tvdb) }
        self.ids = ids
        self.title = title.displayTitle
        year = (title.releaseDate ?? title.firstAirDate).flatMap { Int($0.prefix(4)) }
    }

    var body: [String: Any] {
        var body: [String: Any] = ["MediaType": mediaType, "Ids": ids]
        if let anime { body["Anime"] = anime }
        if let title { body["Title"] = title }
        if let year { body["Year"] = year }
        return body
    }
}

nonisolated struct WatchlistState: Decodable, Sendable, Equatable {
    struct Service: Decodable, Sendable, Equatable {
        var service: String
        var linked: Bool?
        /// Whether the service can hold the title (AniList and MyAnimeList
        /// only anime); missing from a plugin before 0.9.9, which had only Simkl.
        var fits: Bool?
        /// Nil when not linked, or when it couldn't be told.
        var on: Bool?

        var name: String {
            switch service.lowercased() {
            case "anilist": "AniList"
            case "myanimelist": "MyAnimeList"
            case "simkl": "Simkl"
            default: service
            }
        }
    }
    var services: [Service]?
}

nonisolated enum WatchlistError: LocalizedError, Equatable {
    /// 400 or 404: nothing to offer for this title.
    case unsupported
    /// Anything else, in the server's words when it gave them.
    case failed(status: Int, service: String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .unsupported: nil
        case .failed(let status, let service, let detail):
            if let detail, !detail.isEmpty { detail }
            else {
                switch status {
                case 409: "Link \(service) first, in Settings › Tracking."
                case 410: "\(service) needs linking again."
                case 422: "\(service) doesn't know this title."
                case 502: "\(service) couldn't be reached. Try again."
                default: "The server answered \(status)."
                }
            }
        }
    }
}

nonisolated enum WatchlistAPI {
    static func state(of title: WatchlistTitle, client: JellyfinClient) async throws -> WatchlistState {
        var components = URLComponents(url: client.baseURL.appending(path: "AsterTracking/Watchlist"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mediaType", value: title.mediaType)]
            + title.ids.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw WatchlistError.unsupported }
        var request = client.authorizedRequest(url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw error(for: status, service: "the watchlist", data: data) }
        return try TrackingFeatures.decoder.decode(WatchlistState.self, from: data)
    }

    /// Adds or takes off; answers where it stands now. The DELETE carries
    /// the same body (URLSession sends it as given).
    static func set(_ on: Bool, service: WatchlistState.Service, title: WatchlistTitle, client: JellyfinClient) async throws -> Bool? {
        var request = client.authorizedRequest(client.baseURL.appending(path: "AsterTracking/Watchlist/\(service.service)"), method: on ? "POST" : "DELETE")
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: title.body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw error(for: status, service: service.name, data: data) }
        return try TrackingFeatures.decoder.decode(WatchlistState.Service.self, from: data).on
    }

    /// The plugin's problems carry their reason in `detail` ("It's on your
    /// AniList as Watching already.").
    static func error(for status: Int, service: String, data: Data) -> WatchlistError {
        if status == 400 || status == 404 { return .unsupported }
        struct Problem: Decodable { var detail: String? }
        let detail = (try? JSONDecoder().decode(Problem.self, from: data))?.detail
        return .failed(status: status, service: service, detail: detail)
    }
}

/// "Add to Watchlist" / "On Watchlist": shown only for the services the
/// server's plugin can add to, that the person has linked, and that can hold
/// the title (Simkl for anything; AniList and MyAnimeList for anime). Asked
/// after the page's own content, so it never holds the page up. With one
/// such service it's a toggle; with more, a menu with each.
struct WatchlistButton: View {
    let title: WatchlistTitle?
    /// A round icon (beside Favorite on a library page), or a labelled
    /// button (on Seerr's page and the Discover page).
    var iconOnly = false
    var focus: FocusState<String?>.Binding? = nil

    @Environment(AppSession.self) private var session
    /// The services offered for this title, with where it stands on each.
    @State private var services: [WatchlistState.Service] = []
    @State private var working = false
    @State private var problem: String?

    private var isOn: Bool { services.contains { $0.on == true } }
    private var label: String { isOn ? "On Watchlist" : "Add to Watchlist" }
    private var symbol: String { isOn ? "bookmark.fill" : "bookmark" }

    var body: some View {
        // A stack, not a Group: a Group hands its modifiers to what it holds,
        // and while hidden it holds nothing, so the check never ran.
        ZStack {
            if services.count == 1, let only = services.first {
                Group {
                    if iconOnly {
                        IconButton(systemImage: symbol, accessibilityLabel: label, focus: focus, focusID: "watchlist") {
                            toggle(only)
                        }
                    } else {
                        ActionButton(title: label, systemImage: symbol, focus: focus, focusID: "watchlist") {
                            toggle(only)
                        }
                    }
                }
                .disabled(working)
                .overlay(alignment: .bottomLeading) { problemLine }
            } else if services.count > 1 {
                Menu {
                    ForEach(services, id: \.service) { service in
                        Button {
                            toggle(service)
                        } label: {
                            Label(service.on == true ? "On \(service.name)" : "Add to \(service.name)",
                                  systemImage: service.on == true ? "checkmark" : "plus")
                        }
                    }
                } label: {
                    if iconOnly {
                        Image(systemName: symbol)
                            .font(Lockup.iconButtonFont)
                            .frame(width: Lockup.iconButtonSize, height: Lockup.iconButtonSize)
                    } else {
                        Label(label, systemImage: symbol)
                    }
                }
                .actionButtonStyle()
                .accessibilityLabel(label)
                .optionallyFocused(focus, equals: "watchlist")
                .disabled(working)
                .overlay(alignment: .bottomLeading) { problemLine }
            }
        }
        .task(id: title) { await load() }
    }

    @ViewBuilder
    private var problemLine: some View {
        // Under the button, without moving the row.
        if let problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize()
                .offset(y: 28)
        }
    }

    private func load() async {
        services = []
        problem = nil
        guard let title else { return }
        guard title.isUsable else {
            DebugLog.note("watchlist", "Hidden for \(title.title ?? "?"): no ids")
            return
        }
        let offered = Set((AsterTracking.shared.features?.watchlist ?? []).map { $0.lowercased() })
        guard !offered.isEmpty, let client = session.jellyfin else {
            DebugLog.note("watchlist", "Hidden: the server's plugin offers no watchlist")
            return
        }
        let state: WatchlistState
        do {
            state = try await WatchlistAPI.state(of: title, client: client)
        } catch {
            DebugLog.note("watchlist", "Hidden for \(title.title ?? "?"): state failed, \(error)")
            return
        }
        let usable = (state.services ?? []).filter { offered.contains($0.service.lowercased()) && $0.linked == true && $0.fits != false }
        if usable.isEmpty {
            DebugLog.note("watchlist", "Hidden for \(title.title ?? "?"): no linked service fits it (\(state))")
        }
        services = usable.map { service in
            var known = service
            known.on = service.on ?? false
            return known
        }
    }

    private func toggle(_ service: WatchlistState.Service) {
        guard let title, let client = session.jellyfin, !working else { return }
        let wanted = service.on != true
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                let now = try await WatchlistAPI.set(wanted, service: service, title: title, client: client) ?? wanted
                if let index = services.firstIndex(where: { $0.service == service.service }) {
                    services[index].on = now
                }
            } catch let error as WatchlistError {
                if error == .unsupported {
                    services.removeAll { $0.service == service.service }
                } else {
                    problem = error.localizedDescription
                }
            } catch {
                problem = "\(service.name) couldn't be reached. Try again."
            }
        }
    }
}
