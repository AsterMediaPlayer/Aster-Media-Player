//
//  SeerrTitlePage.swift
//  AsterFIN
//
//  A title the server hasn't got, as Aster's own title pages show one: the
//  art full bleed behind the page, the name large over it, what it is, and
//  Request where Play would be; a show's seasons to pick, and its cast.
//  A new show often has no backdrop yet: then its poster, blurred and
//  enlarged, fills the screen, and the poster itself stands beside the name.
//  From Seerr (TMDB's details); pushed like a library title's page.
//

import SwiftUI

/// A film's or show's full details from Seerr.
nonisolated struct SeerrDetails: Decodable, Sendable {
    var title: String?
    var name: String?
    var tagline: String?
    var overview: String?
    var backdropPath: String?
    var posterPath: String?
    var releaseDate: String?
    var firstAirDate: String?
    var status: String?
    var runtime: Int?
    var numberOfSeasons: Int?
    var genres: [Named]?
    var networks: [Named]?
    var credits: Credits?
    var seasons: [SeerrShow.Season]?
    var mediaInfo: SeerrTitle.MediaInfo?
    var originalTitle: String?
    var originalName: String?
    var originalLanguage: String?
    var numberOfEpisodes: Int?
    var voteAverage: Double?
    var productionCompanies: [Named]?
    var createdBy: [Named]?
    var keywords: [Named]?
    var relatedVideos: [Video]?

    struct Named: Decodable, Sendable, Hashable { var name: String }
    struct Credits: Decodable, Sendable { var cast: [Person]?; var crew: [Crew]? }
    struct Crew: Decodable, Sendable, Hashable { var name: String; var job: String? }
    struct Video: Decodable, Sendable, Hashable { var type: String?; var site: String?; var url: String?; var key: String?; var name: String? }

    /// Its own title, in its own language, when that's not the one shown.
    var original: String? { originalName ?? originalTitle }

    /// The first trailer, else teaser: new anime often have only a teaser.
    private var trailer: Video? {
        let videos = relatedVideos ?? []
        return videos.first { $0.type == "Trailer" } ?? videos.first { $0.type == "Teaser" }
    }

    /// The trailer, to watch on its site.
    var trailerURL: URL? { trailer?.url.flatMap(URL.init(string:)) }

    /// The trailer in the YouTube app, which is how an Apple TV can play it.
    var trailerAppURL: URL? {
        guard let trailer, trailer.site == nil || trailer.site == "YouTube" else { return nil }
        let id = trailer.key ?? trailer.url.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "v" }?.value }
        return id.flatMap { URL(string: "youtube://watch/\($0)") }
    }

    /// A film's directors, else a show's creators.
    var makers: [String] {
        let directors = (credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name)
        return Array(NSOrderedSet(array: directors.isEmpty ? (createdBy ?? []).map(\.name) : directors)) as? [String] ?? directors
    }

    /// Japanese animation: AniList may know it when TMDB has little.
    var isAnime: Bool {
        originalLanguage == "ja" && (genres ?? []).contains { $0.name == "Animation" }
    }
    struct Person: Decodable, Sendable, Hashable, Identifiable {
        var id: Int
        var name: String
        var character: String?
        var profilePath: String?

        var photoURL: URL? { profilePath.flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") } }
    }

    var show: SeerrShow { SeerrShow(seasons: seasons ?? [], mediaInfo: mediaInfo) }

    /// When it first came out, or comes out.
    var date: Date? {
        guard let text = releaseDate ?? firstAirDate, !text.isEmpty else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format.date(from: text)
    }
}

nonisolated extension SeerrClient {
    static func details(_ title: SeerrTitle, account: SeerrAccount) async throws -> SeerrDetails {
        try await get(SeerrDetails.self, account, title.isMovie ? "/movie/\(title.id)" : "/tv/\(title.id)")
    }

    /// TMDB's picture at a size for the screen: the whole width on a TV.
    static func image(_ path: String?, width: String) -> URL? {
        path.flatMap { URL(string: "https://image.tmdb.org/t/p/\(width)\($0)") }
    }
}

struct SeerrTitlePage: View {
    let title: SeerrTitle

    private let accounts = TrackerAccounts.shared
    @State private var details: SeerrDetails?
    @Environment(\.openURL) private var openURL
    /// The trailer couldn't open: the YouTube app isn't installed.
    @State private var noYouTube = false
    /// AniList's description and studios, for anime TMDB knows little of.
    @State private var aniList: (description: String?, studios: [String])?
    @State private var status: SeerrStatus
    @State private var seasons: [(number: Int, episodes: Int?, status: SeerrStatus)] = []
    @State private var chosen: Set<Int> = []
    @State private var working = false
    @State private var problem: String?

    init(title: SeerrTitle) {
        self.title = title
        _status = State(initialValue: title.status)
    }

    private enum Metrics {
        #if os(tvOS)
        static let titleSize: CGFloat = 76
        static let posterWidth: CGFloat = 300
        static let overviewWidth: CGFloat = 1100
        static let headerHeight: CGFloat = 900
        static let backdropSize = "original"
        #else
        static let titleSize: CGFloat = 40
        static let posterWidth: CGFloat = 150
        static let overviewWidth: CGFloat = 640
        static let headerHeight: CGFloat = 520
        static let backdropSize = "w1280"
        #endif
    }

    private var backdropURL: URL? { SeerrClient.image(details?.backdropPath ?? title.backdropPath, width: Metrics.backdropSize) }
    private var posterURL: URL? { SeerrClient.image(details?.posterPath ?? title.posterPath, width: "w500") }
    /// No backdrop: the poster stands in, blurred, and beside the name.
    private var postersOnly: Bool { backdropURL == nil }
    /// Seasons nobody's asked for yet.
    private var open: [Int] { seasons.filter { $0.status == .unknown || $0.status == .deleted }.map(\.number) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    header
                        .frame(maxWidth: .infinity, minHeight: Metrics.headerHeight, alignment: .bottomLeading)
                    if !title.isMovie, !seasons.isEmpty {
                        seasonChips
                    }
                    if let details {
                        detailsSection(details)
                    }
                    if let cast = details?.credits?.cast, !cast.isEmpty {
                        Shelf(title: "Cast", items: Array(cast.prefix(20)), spacing: Lockup.personSpacing) { person in
                            CastPortrait(person: person)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        }
        .ignoresSafeArea()
        .task { await load() }
        .alert("YouTube Needed", isPresented: $noYouTube) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The trailer plays in the YouTube app. Install it from the App Store, then try again.")
        }
    }

    // MARK: Pieces

    private var backdrop: some View {
        ZStack {
            if postersOnly {
                RemoteImage(url: posterURL) { Color(white: 0.08) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 60)
                    .scaleEffect(1.3)
                    .clipped()
                    .opacity(0.85)
            } else {
                RemoteImage(url: backdropURL) { Color(white: 0.08) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.55), .black.opacity(0.97)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .leading, endPoint: .center)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 32) {
            if postersOnly {
                RemoteImage(url: posterURL, systemImage: title.isMovie ? "film" : "tv")
                    .frame(width: Metrics.posterWidth, height: Metrics.posterWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(details?.title ?? details?.name ?? title.displayTitle)
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                if let tagline = details?.tagline, !tagline.isEmpty {
                    Text(tagline).font(.title3.italic()).foregroundStyle(.secondary)
                }
                Text(metadata.joined(separator: "  ·  "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let premiere = premiereLine {
                    Label(premiere, systemImage: "calendar")
                        .font(.callout.weight(.semibold))
                }
                if let overview = summary {
                    Text(overview)
                        .font(.body)
                        .lineLimit(5)
                        .frame(maxWidth: Metrics.overviewWidth, alignment: .leading)
                } else if details != nil {
                    Text("No description yet.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                actions
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.top, 120)
    }

    /// TMDB's overview, else AniList's description.
    private var summary: String? {
        for text in [details?.overview, title.overview, aniList?.description] {
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// "2027  ·  Animation, Comedy  ·  1 Season  ·  In Production".
    private var metadata: [String] {
        var parts: [String] = []
        if let year = title.year { parts.append(year) }
        if let genres = details?.genres, !genres.isEmpty { parts.append(genres.prefix(3).map(\.name).joined(separator: ", ")) }
        if let network = details?.networks?.first?.name { parts.append(network) }
        if title.isMovie, let runtime = details?.runtime, runtime > 0 {
            parts.append(runtime >= 60 ? "\(runtime / 60) hr \(runtime % 60) min" : "\(runtime) min")
        }
        if let count = details?.numberOfSeasons, count > 0 { parts.append(count == 1 ? "1 Season" : "\(count) Seasons") }
        if let state = details?.status, !state.isEmpty, state != "Released" { parts.append(state) }
        return parts
    }

    /// "Premieres 10 January 2027", for what isn't out yet.
    private var premiereLine: String? {
        guard let date = details?.date, date > Date() else { return nil }
        return "\(title.isMovie ? "Releases" : "Premieres") \(date.formatted(date: .long, time: .omitted))"
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 16) {
            if status.canRequest, title.isMovie || !open.isEmpty || seasons.isEmpty {
                ActionButton(title: requestTitle, systemImage: "plus", prominent: true) {
                    Task { await request() }
                }
                .disabled(working || (!title.isMovie && !seasons.isEmpty && chosen.isEmpty))
            } else if let label = status.label {
                Label(label, systemImage: status == .available ? "checkmark.circle.fill" : "clock")
                    .font(.headline)
                    .padding(.vertical, 10)
            }
            #if os(tvOS)
            // The TV has no browser: the trailer opens in the YouTube app.
            if let trailer = details?.trailerAppURL {
                ActionButton(title: "Trailer", systemImage: "play.rectangle") {
                    openURL(trailer) { opened in
                        if !opened { noYouTube = true }
                    }
                }
            }
            #else
            if let trailer = details?.trailerURL {
                Link(destination: trailer) {
                    Label("Trailer", systemImage: "play.rectangle")
                }
                .actionButtonStyle()
            }
            #endif
            if working { ProgressView() }
        }
        .padding(.top, 8)
    }

    private var requestTitle: String {
        if title.isMovie { return "Request" }
        if chosen.count == open.count { return "Request All Seasons" }
        return chosen.count == 1 ? "Request 1 Season" : "Request \(chosen.count) Seasons"
    }

    /// Each season as a chip: the open ones to pick, the rest saying why not.
    private var seasonChips: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seasons")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, Lockup.screenPadding)
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(seasons, id: \.number) { season in
                        let free = open.contains(season.number)
                        Button {
                            if chosen.contains(season.number) { chosen.remove(season.number) } else { chosen.insert(season.number) }
                        } label: {
                            VStack(spacing: 2) {
                                Text("Season \(season.number)").font(.callout.weight(.semibold))
                                Text(free ? season.episodes.map { "\($0) episodes" } ?? " " : season.status.label ?? "")
                                    .font(.caption2)
                                    .opacity(0.75)
                            }
                            .padding(.horizontal, 6)
                        }
                        .chipStyle(selected: free && chosen.contains(season.number))
                        .disabled(!free)
                        .opacity(free ? 1 : 0.55)
                        .accessibilityAddTraits(chosen.contains(season.number) ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Lockup.screenPadding)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
    }

    /// What the library's Details tab shows of a title, as far as it's known.
    private func detailsSection(_ details: SeerrDetails) -> some View {
        var facts: [(String, String)] = []
        if let original = details.original, original != (details.title ?? details.name) { facts.append(("Original Title", original)) }
        if let date = details.date {
            facts.append((title.isMovie ? "Release" : "Premiere", date.formatted(date: .long, time: .omitted)))
        }
        if let state = details.status, !state.isEmpty { facts.append(("Status", state)) }
        if let networks = details.networks, !networks.isEmpty { facts.append((networks.count == 1 ? "Network" : "Networks", Self.shortList(networks.map(\.name)))) }
        let studios = (details.productionCompanies ?? []).map(\.name)
        let shownStudios = studios.isEmpty ? (aniList?.studios ?? []) : studios
        if !shownStudios.isEmpty { facts.append(("Studio", shownStudios.prefix(3).joined(separator: ", "))) }
        if !details.makers.isEmpty { facts.append((title.isMovie ? "Director" : "Created by", details.makers.prefix(3).joined(separator: ", "))) }
        if let episodes = details.numberOfEpisodes, episodes > 0 { facts.append(("Episodes", String(episodes))) }
        if let genres = details.genres, !genres.isEmpty { facts.append(("Genres", genres.map(\.name).joined(separator: ", "))) }
        if let keywords = details.keywords, !keywords.isEmpty { facts.append(("Keywords", keywords.prefix(8).map(\.name).joined(separator: ", "))) }
        let score = TitleScore(.tmdb, details.voteAverage, outOf: 10)
        return VStack(alignment: .leading, spacing: 16) {
            Text("Details")
                .font(.title3.weight(.semibold))
            if let score {
                TitleScoreRow(scores: [score])
                    .font(.callout)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.factWidth), spacing: 28, alignment: .topLeading)], alignment: .leading, spacing: 18) {
                ForEach(facts, id: \.0) { fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fact.0.uppercased())
                            .font(.caption.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        Text(fact.1)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, Lockup.screenPadding)
        #if os(tvOS)
        // Reachable by the remote, so the page scrolls down to it.
        .focusable()
        #endif
    }

    /// The first three, and how many more: a show on every local station
    /// in Japan lists dozens.
    static func shortList(_ names: [String], keeping kept: Int = 3) -> String {
        guard names.count > kept + 1 else { return names.joined(separator: ", ") }
        return names.prefix(kept).joined(separator: ", ") + " and \(names.count - kept) more"
    }

    #if os(tvOS)
    private static let factWidth: CGFloat = 360
    #else
    private static let factWidth: CGFloat = 200
    #endif

    // MARK: Asking

    private func load() async {
        guard let account = accounts.secrets.seerr, let found = try? await SeerrClient.details(title, account: account) else { return }
        details = found
        if let known = found.mediaInfo?.status { status = known }
        // New anime often have nothing yet on TMDB: AniList may.
        if found.isAnime, (found.overview ?? "").isEmpty || (found.productionCompanies ?? []).isEmpty {
            aniList = await AniList.describe(native: found.original, english: found.name ?? found.title ?? title.displayTitle)
        }
        if !title.isMovie {
            seasons = found.show.seasonStatus()
            chosen = Set(open)
        }
    }

    private func request() async {
        guard let account = accounts.secrets.seerr else { return }
        working = true
        defer { working = false }
        do {
            try await SeerrClient.request(title, seasons: chosen.sorted(), account: account)
            status = .pending
            seasons = seasons.map { season in
                chosen.contains(season.number) ? (season.number, season.episodes, .pending) : season
            }
            chosen = []
            problem = nil
        } catch SeerrError.signedOut {
            accounts.seerrSignedOut()
            problem = SeerrError.signedOut.localizedDescription
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A cast member: their photo in a circle, their name and part.
private struct CastPortrait: View {
    let person: SeerrDetails.Person
    #if os(tvOS)
    /// Focusable so the remote can reach the row, and the page scrolls to it.
    @FocusState private var focused: Bool
    #endif

    #if os(tvOS)
    private let size: CGFloat = 160
    #else
    private let size: CGFloat = 96
    #endif

    var body: some View {
        VStack(spacing: 8) {
            RemoteImage(url: person.photoURL, systemImage: "person.fill")
                .frame(width: size, height: size)
                .clipShape(Circle())
                #if os(tvOS)
                .overlay(Circle().stroke(.white, lineWidth: focused ? 4 : 0))
                .scaleEffect(focused ? 1.12 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 16, y: 8)
                .animation(.easeOut(duration: 0.15), value: focused)
                #endif
            Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
            if let character = person.character, !character.isEmpty {
                Text(character).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: size + 24)
        .accessibilityElement(children: .combine)
        #if os(tvOS)
        .focusable()
        .focused($focused)
        #endif
    }
}
