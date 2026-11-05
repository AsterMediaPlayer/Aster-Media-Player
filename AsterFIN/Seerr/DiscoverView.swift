//
//  DiscoverView.swift
//  AsterFIN
//
//  The Discover tab: the library's Upcoming episodes, and with a Seerr
//  sign-in its own Discover page, the films and shows to browse with
//  filters, and the requests (with Approve and Decline for whoever
//  manages them).
//

import SwiftUI

struct DiscoverView: View {
    enum Section: String, CaseIterable, Identifiable {
        case discover = "Discover", upcoming = "Upcoming", movies = "Movies", series = "Series", requests = "Requests"
        var id: Self { self }
    }

    @Environment(AppSession.self) private var session
    @State private var section: Section?
    @State private var movieFilter = SeerrFilter(kind: .movie)
    @State private var seriesFilter = SeerrFilter(kind: .tv)

    private var tracking: AsterTracking { AsterTracking.shared }

    /// What there is. Discover's rows come from the server's plugin and
    /// Seerr's own; Movies, Series and Requests are Seerr's, through the
    /// plugin; Upcoming is the library's episodes and the films asked for.
    private var sections: [Section] {
        let seerr = tracking.seerr != nil
        return Section.allCases.filter { section in
            switch section {
            case .discover: tracking.isPresent || seerr
            case .upcoming: session.hasUpcoming || seerr
            case .movies, .series, .requests: seerr
            }
        }
    }

    private var shown: Section? {
        section.flatMap { sections.contains($0) ? $0 : nil } ?? sections.first
    }

    var body: some View {
        // The sections sit over the page (over Upcoming's full-screen
        // picture, as the TV app's own tabs do), so each page keeps its look.
        ZStack(alignment: .top) {
            switch shown {
            case .upcoming:
                UpcomingAgenda(topInset: pickerRoom)
            case let page?:
                seerrPage(page)
            case nil:
                MessageView(systemImage: "safari", title: "Nothing to discover yet",
                            detail: "Upcoming episodes show here, and with the Aster Discovery and Tracking plugin on your Jellyfin server, recommendations and films and shows to request.")
            }
            if sections.count > 1 {
                sectionPicker
            }
        }
        #if !os(tvOS)
        // The title sits in the bar beside the back arrow, not above the
        // page in a tall large-title bar of its own.
        .navigationTitle("Discover")
        .toolbarTitleDisplayMode(.inline)
        #endif
    }

    private var sectionPicker: some View {
        Picker("Section", selection: Binding(get: { shown ?? .discover }, set: { section = $0 })) {
            ForEach(sections) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: Self.pickerWidth)
        // A little backing, so the pills read over the page's pictures.
        .padding(Self.pickerBacking)
        .background(Color.black.opacity(0.35), in: Capsule())
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.top, Self.pickerTop)
    }

    /// Room above a page for the sections.
    private var pickerRoom: CGFloat { sections.count > 1 ? Self.pickerHeight : 0 }

    private func seerrPage(_ section: Section) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                switch section {
                case .movies:
                    DiscoverGrid(filter: $movieFilter)
                case .series:
                    DiscoverGrid(filter: $seriesFilter)
                case .requests:
                    SeerrRequestsList()
                default:
                    DiscoverRows()
                }
            }
            .padding(.top, pickerRoom + Lockup.pageTopPadding)
            .padding(.bottom, Lockup.pageBottomPadding)
        }
        .scrollClipDisabled()
    }

    #if os(tvOS)
    private static let pickerWidth: CGFloat = 1100
    private static let pickerHeight: CGFloat = 90
    private static let pickerBacking: CGFloat = 8
    private static let pickerTop: CGFloat = Lockup.pageTopPadding
    #else
    private static let pickerWidth: CGFloat = 560
    private static let pickerHeight: CGFloat = 52
    private static let pickerBacking: CGFloat = 4
    private static let pickerTop: CGFloat = 4
    #endif
}

/// The Seerr account (through the server's plugin), or nothing.
@MainActor
private func seerrAccount() -> SeerrAccount? {
    AsterTracking.shared.seerr
}

@MainActor
private func noteSeerrFailure(_ error: Error, _ what: String) {
    if case SeerrError.signedOut = error { AsterTracking.shared.noteRefused() }
    DebugLog.note("seerr", "\(what) failed: \((error as? SeerrError)?.errorDescription ?? error.localizedDescription)")
    #if DEBUG
    print("DEBUG seerr: \(what) failed: \(error)")
    #endif
}

// MARK: - Discover rows

/// The Discover page: what the server's plugin built for this person
/// (continue, recommended, because you watched, on your server, watchlists,
/// trending, this season) and Seerr's own rows in its admin's order, mixed as
/// the Aster contract says. Seerr's rows don't wait for the server's page:
/// if it isn't back within a second and a half they show alone, and it
/// fills in when it comes.
private struct DiscoverRows: View {
    @Environment(AppSession.self) private var session
    @State private var tracked: [TrackedRow] = []
    @State private var sliders: [SeerrSlider]?
    @State private var loaded = false
    @State private var problem: String?

    private var entries: [DiscoverEntry] {
        TrackedDiscover.order(rows: tracked, sliders: sliders, theaters: AsterTracking.shared.seerr != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 120)
            }
            if loaded, entries.isEmpty {
                Text(problem ?? "Nothing to suggest yet. Watch something and link your accounts in the plugin's dashboard, and Discover learns what you like.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.vertical, 60)
            } else if loaded, let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Lockup.screenPadding)
            }
            ForEach(entries) { entry in
                switch entry {
                case .tracked(let row):
                    TrackedShelf(row: row)
                case .slider(let slider):
                    SliderRow(slider: slider)
                case .inTheaters:
                    SliderRow(slider: SeerrSlider(type: SeerrClient.inTheatersType))
                }
            }
        }
        // Again once the plugin's answered: the server's features come a
        // moment after launch, and a first look found none.
        .task(id: "\(AsterTracking.shared.seerr?.authorization ?? "")|\(AsterTracking.shared.isPresent)") { await load() }
    }

    private func load() async {
        guard let jellyfin = session.jellyfin else {
            loaded = true
            return
        }
        let homeTask = Task { () -> TrackedHome? in
            do { return try await TrackedDiscover.home(client: jellyfin) }
            catch {
                DebugLog.note("discover", "The server's page failed: \(error.localizedDescription)")
                return nil
            }
        }
        var found: [SeerrSlider]?
        problem = nil
        if let account = seerrAccount() {
            do {
                found = try await SeerrClient.sliders(account: account)
                DebugLog.note("discover", "\(found?.count ?? 0) Seerr rows")
            } catch {
                noteSeerrFailure(error, "Discover rows")
                problem = (error as? SeerrError)?.errorDescription ?? "Seerr's rows couldn't be read."
            }
        }
        // The server's page, if it's quick; else Seerr's rows alone first.
        let quick = await Self.within(1.5, homeTask)
        sliders = found
        if let quick {
            tracked = quick?.rows ?? []
            loaded = true
        } else {
            loaded = found != nil
            let late = await homeTask.value
            tracked = late?.rows ?? []
            loaded = true
        }
    }

    /// The task's answer if it comes within `seconds`: nil if it doesn't.
    /// (An answer of no page at all is `.some(nil)`.)
    private static func within(_ seconds: Double, _ task: Task<TrackedHome?, Never>) async -> TrackedHome?? {
        await withTaskGroup(of: TrackedHome??.self) { group in
            group.addTask { .some(await task.value) }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .none
            }
            let first = await group.next() ?? .none
            group.cancelAll()
            return first
        }
    }
}

// MARK: - The server's own rows

/// One of the server's rows, as Seerr cards: each opens its page by its
/// TMDB id, or the library's item when requests are off.
private struct TrackedShelf: View {
    let row: TrackedRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Shelf(title: row.title, items: row.items.filter { $0.tmdbId != nil || $0.inLibrary != nil }) { item in
                TrackedLockup(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A title from the server's page, like a library title: its picture, its
/// name, and how far along it is (or its year and kind), with "On Server"
/// when it's there to play.
struct TrackedLockup: View {
    let item: TrackedItem

    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: item) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(url: item.posterURL(server: session.serverURL), systemImage: item.isMovie ? "film" : "tv")
                        .frame(width: Lockup.posterWidth, height: Lockup.posterHeight)
                    if item.inLibrary != nil {
                        Text("On Server")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(8)
                    }
                }
                .frame(width: Lockup.posterWidth, height: Lockup.posterHeight)
            }
            .cardButtonStyle()
            .accessibilityLabel([item.title, item.subtitle, item.inLibrary != nil ? "On your server" : nil].compactMap { $0 }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: Lockup.posterWidth, alignment: .leading)
        }
    }
}

/// Where a server title opens: Seerr's page by its TMDB id, with the Request
/// button; or, with requests off, its place in the library.
struct TrackedItemPage: View {
    let item: TrackedItem

    var body: some View {
        if AsterTracking.shared.seerr != nil, let title = item.seerrTitle {
            SeerrTitlePage(title: title)
        } else if let library = item.inLibrary {
            ItemDetailView(item: BaseItem(id: library.itemId, name: library.name ?? item.title,
                                          type: library.type ?? (item.isMovie ? ItemKind.movie.rawValue : ItemKind.series.rawValue)))
        } else {
            MessageView(systemImage: "questionmark.circle", title: item.title, detail: "This title can't be opened here.")
        }
    }
}

/// One Discover row: titles, genres, or studios and networks.
private struct SliderRow: View {
    let slider: SeerrSlider

    @State private var cards: [SeerrCard] = []
    @State private var genres: [SeerrGenre] = []
    @State private var companies: [SeerrCompany] = []

    private var title: String { SeerrClient.sliderTitle(slider) }
    /// Movie genres and studios are films'; the others shows'.
    private var kind: SeerrFilter.Kind { slider.type == 6 || slider.type == 8 ? .movie : .tv }

    var body: some View {
        // A stack, not a Group: a Group hands its modifiers to what it holds,
        // and an empty row holds nothing, so its load never ran.
        VStack(alignment: .leading, spacing: 0) {
            switch slider.type {
            case 6, 10:
                Shelf(title: title, items: genres) { genre in
                    GenreTile(genre: genre, kind: kind)
                }
            case 8, 12:
                Shelf(title: title, items: companies) { company in
                    CompanyTile(company: company, kind: kind)
                }
            case 4:
                // Trending leads, art first.
                Shelf(title: title, items: cards) { card in
                    SeerrBackdropLockup(title: card.title)
                }
            default:
                Shelf(title: title, items: cards) { card in
                    SeerrTitleLockup(title: card.title)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
    }

    private func load() async {
        guard cards.isEmpty, genres.isEmpty, companies.isEmpty, let account = seerrAccount() else { return }
        do {
            switch slider.type {
            case SeerrClient.inTheatersType:
                cards = try await SeerrClient.inTheaters(account: account).map(SeerrCard.init)
            case 1:
                cards = try await SeerrClient.recentlyAdded(account: account).map(SeerrCard.init)
            case 2:
                let requests = try await SeerrClient.requests(.all, mine: false, userId: account.userId, page: 1, account: account).results
                var seen = Set<String>()
                let ids = requests.map { ($0.media.tmdbId, $0.media.mediaType ?? $0.type ?? "movie") }
                    .filter { seen.insert("\($0.1)-\($0.0)").inserted }
                cards = await SeerrClient.titles(for: ids, account: account).map(SeerrCard.init)
            case 6, 10:
                genres = try await SeerrClient.genres(kind, account: account)
            case 8, 12:
                companies = await SeerrClient.companies(kind, account: account)
            default:
                guard let source = SeerrClient.titlesPath(for: slider) else { return }
                cards = try await SeerrClient.titles(source.path, kind: source.kind, account: account).results.map(SeerrCard.init)
            }
        } catch {
            noteSeerrFailure(error, title)
        }
    }
}

/// A title as a wide picture with its name on it, for Trending.
struct SeerrBackdropLockup: View {
    let title: SeerrTitle

    var body: some View {
        NavigationLink(value: title) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: SeerrClient.image(title.backdropPath, width: "w780") ?? title.posterURL,
                            systemImage: title.isMovie ? "film" : "tv")
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text([title.year, title.isMovie ? "Film" : "Series", title.status.label].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(Self.inset)
            }
            .frame(width: Self.width, height: Self.width * 9 / 16)
        }
        .cardButtonStyle()
        .accessibilityLabel([title.displayTitle, title.year, title.status.label].compactMap { $0 }.joined(separator: ", "))
    }

    #if os(tvOS)
    static let width: CGFloat = 640
    private static let inset: CGFloat = 24
    #else
    static let width: CGFloat = 300
    private static let inset: CGFloat = 12
    #endif
}

/// A genre: one of its titles' pictures under its name; opens its grid.
private struct GenreTile: View {
    let genre: SeerrGenre
    let kind: SeerrFilter.Kind

    var body: some View {
        NavigationLink(value: browse) {
            ZStack {
                RemoteImage(url: SeerrClient.image(genre.backdrops?.first, width: "w780")) { Color(white: 0.15) }
                Color.black.opacity(0.45)
                Text(genre.name)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
            .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
        }
        .cardButtonStyle()
        .accessibilityLabel(genre.name)
    }

    private var browse: SeerrBrowse {
        var filter = SeerrFilter(kind: kind)
        filter.genres = [genre.id]
        return SeerrBrowse(title: "\(genre.name) \(kind == .movie ? "Movies" : "Series")", filter: filter)
    }
}

/// A studio or network by its logo; opens its grid.
private struct CompanyTile: View {
    let company: SeerrCompany
    let kind: SeerrFilter.Kind

    var body: some View {
        NavigationLink(value: browse) {
            ZStack {
                Color(white: 0.16)
                if let logo = SeerrClient.logoURL(company.logoPath) {
                    RemoteImage(url: logo, contentMode: .fit) { Text(company.name).font(.headline) }
                        .padding(Self.inset)
                } else {
                    Text(company.name).font(.headline).multilineTextAlignment(.center)
                }
            }
            .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
        }
        .cardButtonStyle()
        .accessibilityLabel(company.name)
    }

    private var browse: SeerrBrowse {
        var filter = SeerrFilter(kind: kind)
        filter.company = company
        return SeerrBrowse(title: company.name, filter: filter)
    }

    #if os(tvOS)
    private static let inset: CGFloat = 40
    #else
    private static let inset: CGFloat = 18
    #endif
}

// MARK: - Browse

/// A pushed grid: a genre's, a studio's or network's, with its filters.
struct SeerrBrowsePage: View {
    let browse: SeerrBrowse
    @State private var filter: SeerrFilter

    init(browse: SeerrBrowse) {
        self.browse = browse
        _filter = State(initialValue: browse.filter)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                Text(browse.title)
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.top, Lockup.pageTopPadding)
                DiscoverGrid(filter: $filter)
            }
            .padding(.bottom, Lockup.pageBottomPadding)
        }
        .scrollClipDisabled()
    }
}

/// Films or shows from Seerr, filtered and sorted, a page at a time as
/// the grid scrolls. Sits inside its page's scroll view.
private struct DiscoverGrid: View {
    @Binding var filter: SeerrFilter

    @State private var cards: [SeerrCard] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SeerrFilterBar(filter: $filter)
            if cards.isEmpty, !loading {
                Text(failed ? "Seerr didn't answer." : "Nothing matches these filters.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.vertical, 60)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Lockup.posterWidth), spacing: Lockup.shelfSpacing, alignment: .top)],
                      alignment: .leading, spacing: Lockup.shelfSpacing) {
                ForEach(cards) { card in
                    SeerrTitleLockup(title: card.title)
                        .onAppear {
                            // Near the end: the next page.
                            if card.id == cards[max(0, cards.count - 6)].id { Task { await loadMore() } }
                        }
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        }
        .task(id: filter) {
            cards = []
            page = 0
            totalPages = 1
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !loading, page < totalPages, let account = seerrAccount() else { return }
        loading = true
        defer { loading = false }
        let asked = filter
        do {
            let reply = try await SeerrClient.titles(asked.path(page: page + 1), kind: asked.kind, account: account)
            guard asked == filter else { return }
            var seen = Set(cards.map(\.id))
            cards += reply.results.map(SeerrCard.init).filter { seen.insert($0.id).inserted }
            page = reply.page ?? page + 1
            totalPages = min(reply.totalPages ?? 1, 500)
            failed = false
        } catch {
            noteSeerrFailure(error, "browse")
            failed = cards.isEmpty
        }
    }
}

// MARK: - Filters

/// Sort, and each filter as a button that says what it's set to.
private struct SeerrFilterBar: View {
    @Binding var filter: SeerrFilter

    @State private var picking: Picking?
    @State private var genres: [SeerrGenre] = []
    @State private var companies: [SeerrCompany] = []
    @State private var providers: [SeerrProvider] = []

    enum Picking: String, Identifiable {
        case genres, company, providers
        var id: Self { self }
    }

    private var isMovie: Bool { filter.kind == .movie }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                // Anime: Animation from Japan, in one press.
                Button {
                    filter.isAnime.toggle()
                } label: {
                    Label("Anime", systemImage: filter.isAnime ? "checkmark" : "sparkles")
                }
                .chipStyle(selected: filter.isAnime)
                .accessibilityValue(filter.isAnime ? "On" : "Off")

                Menu {
                    Picker("Sort", selection: $filter.sort) {
                        ForEach(SeerrFilter.Sort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label(filter.sort.label, systemImage: "arrow.up.arrow.down")
                }
                .chipStyle(selected: false)

                Button { picking = .genres } label: {
                    Text(genreLabel)
                }
                .chipStyle(selected: !filter.genres.isEmpty)

                Menu {
                    Picker("Released", selection: yearChoice) {
                        ForEach(YearChoice.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Text(yearChoice.wrappedValue == .any ? "Any Year" : yearChoice.wrappedValue.label)
                }
                .chipStyle(selected: filter.fromYear != nil || filter.toYear != nil)

                Menu {
                    Picker("Rating", selection: $filter.minimumRating) {
                        Text("Any Rating").tag(Double?.none)
                        ForEach([6.0, 7.0, 8.0], id: \.self) { Text("\(Int($0))+ Stars").tag(Double?.some($0)) }
                    }
                } label: {
                    Text(filter.minimumRating.map { "\(Int($0))+ Stars" } ?? "Any Rating")
                }
                .chipStyle(selected: filter.minimumRating != nil)

                Menu {
                    Picker("Runtime", selection: runtimeChoice) {
                        ForEach(RuntimeChoice.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Text(runtimeChoice.wrappedValue == .any ? "Any Length" : runtimeChoice.wrappedValue.label)
                }
                .chipStyle(selected: filter.minimumRuntime != nil || filter.maximumRuntime != nil)

                Menu {
                    Picker("Language", selection: $filter.language) {
                        Text("Any Language").tag(String?.none)
                        ForEach(Self.languages, id: \.code) { Text($0.name).tag(String?.some($0.code)) }
                    }
                } label: {
                    Text(Self.languages.first { $0.code == filter.language }?.name ?? "Any Language")
                }
                .chipStyle(selected: filter.language != nil)

                Button { picking = .company } label: {
                    Text(filter.company?.name ?? (isMovie ? "Any Studio" : "Any Network"))
                }
                .chipStyle(selected: filter.company != nil)

                Button { picking = .providers } label: {
                    Text(providerLabel)
                }
                .chipStyle(selected: !filter.providers.isEmpty)

                if filter.activeCount > 0 {
                    Button("Clear", systemImage: "xmark") {
                        let kind = filter.kind
                        filter = SeerrFilter(kind: kind)
                    }
                    .chipStyle(selected: false)
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .sheet(item: $picking) { picking in
            NavigationStack {
                pickList(picking)
            }
            #if os(macOS)
            // A Mac sheet takes its content's size, and a list has none of
            // its own: it opened as a sliver, looking empty.
            .frame(minWidth: 420, idealWidth: 460, minHeight: 480, idealHeight: 560)
            #endif
        }
        .task(id: filter.kind) { await loadChoices() }
    }

    @ViewBuilder
    private func pickList(_ picking: Picking) -> some View {
        switch picking {
        case .genres:
            List(genres) { genre in
                Toggle(genre.name, isOn: Binding(
                    get: { filter.genres.contains(genre.id) },
                    set: { on in if on { filter.genres.insert(genre.id) } else { filter.genres.remove(genre.id) } }))
            }
            .navigationTitle("Genres")
            .toolbar { done }
        case .company:
            List {
                Button(isMovie ? "Any Studio" : "Any Network") {
                    filter.company = nil
                    self.picking = nil
                }
                ForEach(companies) { company in
                    Button {
                        filter.company = company
                        self.picking = nil
                    } label: {
                        HStack {
                            Text(company.name)
                            Spacer()
                            if filter.company?.id == company.id { Image(systemName: "checkmark") }
                        }
                        // The row's own colour, which turns dark on a focused
                        // TV row; a button's tint stayed white on white.
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(isMovie ? "Studio" : "Network")
            .toolbar { done }
        case .providers:
            List(providers) { provider in
                Toggle(provider.name, isOn: Binding(
                    get: { filter.providers.contains(provider.id) },
                    set: { on in if on { filter.providers.insert(provider.id) } else { filter.providers.remove(provider.id) } }))
            }
            .navigationTitle("Streaming On")
            .toolbar { done }
        }
    }

    private var done: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { picking = nil }
        }
    }

    private func loadChoices() async {
        guard let account = seerrAccount() else { return }
        genres = (try? await SeerrClient.genres(filter.kind, account: account)) ?? []
        companies = await SeerrClient.companies(filter.kind, account: account)
        // The services people have, not all three hundred.
        providers = Array(((try? await SeerrClient.providers(filter.kind, region: filter.region, account: account)) ?? []).prefix(40))
    }

    private var genreLabel: String {
        let chosen = genres.filter { filter.genres.contains($0.id) }.map(\.name)
        switch chosen.count {
        case 0: return filter.genres.isEmpty ? "Any Genre" : "\(filter.genres.count) Genres"
        case 1: return chosen[0]
        default: return "\(chosen.count) Genres"
        }
    }

    private var providerLabel: String {
        let chosen = providers.filter { filter.providers.contains($0.id) }.map(\.name)
        switch chosen.count {
        case 0: return filter.providers.isEmpty ? "Any Service" : "\(filter.providers.count) Services"
        case 1: return chosen[0]
        default: return "\(chosen.count) Services"
        }
    }

    // MARK: Choices

    enum YearChoice: String, CaseIterable, Identifiable {
        case any, upcoming, thisYear, twenties, tens, noughties, nineties, eighties, older
        var id: Self { self }

        var label: String {
            switch self {
            case .any: "Any Year"
            case .upcoming: "Not Out Yet"
            case .thisYear: "This Year"
            case .twenties: "2020s"
            case .tens: "2010s"
            case .noughties: "2000s"
            case .nineties: "1990s"
            case .eighties: "1980s"
            case .older: "Before 1980"
            }
        }

        var range: (Int?, Int?) {
            let year = Calendar.current.component(.year, from: Date())
            return switch self {
            case .any: (nil, nil)
            case .upcoming: (year + 1, nil)
            case .thisYear: (year, year)
            case .twenties: (2020, 2029)
            case .tens: (2010, 2019)
            case .noughties: (2000, 2009)
            case .nineties: (1990, 1999)
            case .eighties: (1980, 1989)
            case .older: (nil, 1979)
            }
        }
    }

    private var yearChoice: Binding<YearChoice> {
        Binding(get: {
            YearChoice.allCases.first { $0.range == (filter.fromYear, filter.toYear) } ?? .any
        }, set: { choice in
            (filter.fromYear, filter.toYear) = choice.range
        })
    }

    enum RuntimeChoice: String, CaseIterable, Identifiable {
        case any, short, hour, ninety, long, epic
        var id: Self { self }

        var label: String {
            switch self {
            case .any: "Any Length"
            case .short: "Under 30 min"
            case .hour: "30–60 min"
            case .ninety: "Under 1½ hours"
            case .long: "1½–2 hours"
            case .epic: "Over 2 hours"
            }
        }

        var range: (Int?, Int?) {
            switch self {
            case .any: (nil, nil)
            case .short: (nil, 30)
            case .hour: (30, 60)
            case .ninety: (nil, 90)
            case .long: (90, 120)
            case .epic: (120, nil)
            }
        }
    }

    private var runtimeChoice: Binding<RuntimeChoice> {
        Binding(get: {
            RuntimeChoice.allCases.first { $0.range == (filter.minimumRuntime, filter.maximumRuntime) } ?? .any
        }, set: { choice in
            (filter.minimumRuntime, filter.maximumRuntime) = choice.range
        })
    }

    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("fr", "French"),
        ("es", "Spanish"), ("de", "German"), ("it", "Italian"), ("hi", "Hindi"), ("pt", "Portuguese"),
        ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"), ("th", "Thai"), ("tr", "Turkish"),
    ]
}

// MARK: - Requests

/// Requests and where each stands: everyone's, for whoever manages them
/// (with Approve and Decline), else the viewer's own (with Cancel while
/// it waits).
private struct SeerrRequestsList: View {
    @State private var filter: SeerrRequestFilter = .all
    @State private var mine = false
    @State private var user: SeerrUser?
    @State private var requests: [SeerrRequest] = []
    @State private var titles: [String: SeerrTitle] = [:]
    @State private var loading = false
    @State private var working: Int?
    @State private var problem: String?
    @State private var confirming: Confirm?
    /// The pending request whose destination an admin is changing.
    @State private var editing: SeerrRequest?

    struct Confirm: Identifiable {
        let request: SeerrRequest
        let decline: Bool
        var id: String { "\(request.id)-\(decline)" }
    }

    private var manages: Bool { user?.managesRequests ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                Picker("Show", selection: $filter) {
                    ForEach(SeerrRequestFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: Self.filterWidth)
                if manages {
                    Picker("Whose", selection: $mine) {
                        Text("Everyone's").tag(false)
                        Text("Mine").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: Self.whoseWidth)
                }
            }
            .padding(.horizontal, Lockup.screenPadding)

            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Lockup.screenPadding)
            }
            if requests.isEmpty, !loading {
                Text("No requests here.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.vertical, 40)
            }
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(requests) { request in
                    row(request)
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        }
        .task(id: "\(filter.rawValue)|\(mine)") { await load() }
        .sheet(item: $editing) { request in
            SeerrDestinationSheet(
                kind: request.type == "movie" ? .movie : .tv,
                current: request.serverId.map { SeerrRequestOptions(serverId: $0, profileId: request.profileId, rootFolder: request.rootFolder, languageProfileId: request.languageProfileId, is4k: request.is4k ?? false) },
                // A 4K request stays one; a usual one stays usual.
                fourK: request.is4k ?? false,
                confirmTitle: "Save"
            ) { options in
                guard let options, let account = seerrAccount() else { return }
                try await SeerrClient.update(request, options: options, account: account)
                await load()
            }
        }
        .confirmationDialog(confirming.map { $0.decline ? "Decline this request?" : "Cancel this request?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { confirm in
            Button(confirm.decline ? "Decline" : "Cancel Request", role: .destructive) {
                Task { await act(confirm.request, confirm.decline ? .decline : .cancel) }
            }
            Button("Keep It", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(_ request: SeerrRequest) -> some View {
        let title = titles[key(request)]
        HStack(alignment: .center, spacing: 28) {
            if let title {
                NavigationLink(value: title) {
                    RemoteImage(url: title.posterURL, systemImage: request.type == "movie" ? "film" : "tv")
                        .frame(width: Self.posterWidth, height: Self.posterWidth * 1.5)
                }
                .cardButtonStyle()
            } else {
                ArtworkPlaceholder(systemImage: request.type == "movie" ? "film" : "tv")
                    .frame(width: Self.posterWidth, height: Self.posterWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title?.displayTitle ?? "…")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(detailLine(request, title: title))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(request.stateLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(stateColor(request))
                if let who = request.requestedBy?.displayName {
                    Text([who, request.created?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 20)
            if working == request.id {
                ProgressView()
            } else if request.isPending {
                HStack(spacing: 16) {
                    if manages {
                        ActionButton(title: "Approve", systemImage: "checkmark", prominent: true) {
                            Task { await act(request, .approve) }
                        }
                        ActionButton(title: "Edit", systemImage: "slider.horizontal.3") {
                            editing = request
                        }
                        ActionButton(title: "Decline", systemImage: "xmark") {
                            confirming = Confirm(request: request, decline: true)
                        }
                    }
                    if request.requestedBy?.id == seerrAccount()?.userId {
                        ActionButton(title: "Cancel", systemImage: "trash") {
                            confirming = Confirm(request: request, decline: false)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func key(_ request: SeerrRequest) -> String {
        "\(request.media.mediaType ?? request.type ?? "movie")-\(request.media.tmdbId)"
    }

    private func detailLine(_ request: SeerrRequest, title: SeerrTitle?) -> String {
        var parts = [title?.year, request.type == "movie" ? "Film" : "Series"].compactMap { $0 }
        if let seasons = request.seasons, !seasons.isEmpty {
            let numbers = seasons.map(\.seasonNumber).sorted()
            parts.append(numbers.count == 1 ? "Season \(numbers[0])" : "Seasons \(numbers.map(String.init).joined(separator: ", "))")
        }
        if request.is4k == true { parts.append("4K") }
        return parts.joined(separator: " · ")
    }

    private func stateColor(_ request: SeerrRequest) -> Color {
        switch request.status {
        case 1: .orange
        case 3, 4: .red
        default: request.media.status == .available ? .green : .blue
        }
    }

    private func load() async {
        guard let account = seerrAccount() else { return }
        loading = true
        defer { loading = false }
        do {
            if user == nil { user = try await SeerrClient.me(account: account) }
            let page = try await SeerrClient.requests(filter, mine: mine || !manages, userId: account.userId, page: 1, account: account)
            requests = page.results
            problem = nil
            let missing = page.results.filter { titles[key($0)] == nil }
                .map { ($0.media.tmdbId, $0.media.mediaType ?? $0.type ?? "movie") }
            for title in await SeerrClient.titles(for: missing, account: account) {
                titles["\(title.mediaType ?? "tv")-\(title.id)"] = title
            }
        } catch {
            noteSeerrFailure(error, "requests")
            problem = error.localizedDescription
        }
    }

    enum Action { case approve, decline, cancel }

    private func act(_ request: SeerrRequest, _ action: Action) async {
        guard let account = seerrAccount() else { return }
        working = request.id
        defer { working = nil }
        do {
            switch action {
            case .approve: try await SeerrClient.approve(request, account: account)
            case .decline: try await SeerrClient.decline(request, account: account)
            case .cancel: try await SeerrClient.cancel(request, account: account)
            }
            await load()
        } catch {
            noteSeerrFailure(error, "request \(action)")
            problem = error.localizedDescription
        }
    }

    #if os(tvOS)
    private static let posterWidth: CGFloat = 120
    private static let filterWidth: CGFloat = 1000
    private static let whoseWidth: CGFloat = 400
    #else
    private static let posterWidth: CGFloat = 60
    private static let filterWidth: CGFloat = 560
    private static let whoseWidth: CGFloat = 220
    #endif
}
