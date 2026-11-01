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

    struct Named: Decodable, Sendable, Hashable { var name: String }
    struct Credits: Decodable, Sendable { var cast: [Person]? }
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
                if let overview = details?.overview ?? title.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.body)
                        .lineLimit(5)
                        .frame(maxWidth: Metrics.overviewWidth, alignment: .leading)
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

    // MARK: Asking

    private func load() async {
        guard let account = accounts.secrets.seerr, let found = try? await SeerrClient.details(title, account: account) else { return }
        details = found
        if let known = found.mediaInfo?.status { status = known }
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
    private let size: CGFloat = 160
    #else
    private let size: CGFloat = 96
    #endif

    var body: some View {
        VStack(spacing: 8) {
            RemoteImage(url: person.photoURL, systemImage: "person.fill")
                .frame(width: size, height: size)
                .clipShape(Circle())
            Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
            if let character = person.character, !character.isEmpty {
                Text(character).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: size + 24)
        .accessibilityElement(children: .combine)
    }
}
