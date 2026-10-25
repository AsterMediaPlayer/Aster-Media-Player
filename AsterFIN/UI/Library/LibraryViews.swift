//
//  LibraryViews.swift
//  AsterFIN
//
//  Library browsing: all libraries, a library's contents, and the Movies and
//  TV Shows grids.
//

import SwiftUI

// MARK: - Library tab

struct LibraryView: View {
    @Environment(AppSession.self) private var session
    @State private var libraries: [BaseItem] = []
    @State private var favorites: [BaseItem] = []
    @State private var videoPlaylists: [BaseItem] = []
    @State private var errorMessage: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Lockup.sectionSpacing) {
                Text("Library")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.top, Lockup.pageTopPadding)

                if !libraries.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: Lockup.shelfSpacing) {
                            ForEach(libraries) { library in
                                LibraryTile(library: library)
                            }
                        }
                        .padding(.horizontal, Lockup.screenPadding)
                        .padding(.vertical, Lockup.shelfVerticalPadding)
                    }
                    .scrollClipDisabled()
                    .tvFocusSection()
                }

                Shelf(title: "Favorites", items: favorites) { item in
                    if item.kind == .episode {
                        LandscapeLockup(item: item)
                    } else {
                        PosterLockup(item: item)
                    }
                }

                Shelf(title: "Playlists", items: videoPlaylists) { playlist in
                    LandscapeLockup(item: playlist)
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).padding(.horizontal, Lockup.screenPadding)
                }
            }
            .padding(.bottom, Lockup.pageBottomPadding)
        }
        .scrollClipDisabled()
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            libraries = try await client.libraries().filter { $0.collectionType != "playlists" }
            favorites = try await client.items(ItemQuery(
                kinds: [.movie, .series, .episode], recursive: true, sort: .name, filters: [.favorite], limit: 40
            )).items
            videoPlaylists = (try? await session.jellyfin?.playlists(mediaType: "Video")) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - A library's contents

enum LibrarySort: String, CaseIterable, Identifiable {
    case name = "Name"
    case dateAdded = "Recently Added"
    case releaseDate = "Release Date"
    case rating = "Rating"

    var id: String { rawValue }

    var itemSort: ItemSort {
        switch self {
        case .name: .name
        case .dateAdded: .dateAdded
        case .releaseDate: .releaseDate
        case .rating: .rating
        }
    }

    /// A–Z goes up; the rest, newest or best first.
    var descending: Bool { self != .name }

    /// Jellyfin's own sort parameters, for music's grids, which still ask
    /// in Jellyfin's terms.
    var query: (sortBy: String, order: String) {
        let parameters = ItemQuery(sort: itemSort, descending: descending).jellyfinParameters
        return ((parameters["sortBy"] ?? nil) ?? "", (parameters["sortOrder"] ?? nil) ?? "")
    }
}

@Observable
final class GridModel {
    private(set) var items: [BaseItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var totalCount = 0
    private var loadedWith: AnyHashable?
    /// How far into the server's results loading has got, counting items
    /// left out by `excluding`, so pages carry on from the right place.
    private var fetched = 0
    /// Bumped on every reset, so a page still loading from before it is
    /// dropped instead of landing in the new results.
    private var generation = 0

    /// Loads the next page of `query`. Items whose ids are in `excluding`
    /// are skipped, e.g. anime, which has its own tab.
    func load(client: any MediaServer, query: ItemQuery, excluding: Set<String> = [], reset: Bool = false) async {
        await load(key: [AnyHashable(query), AnyHashable(excluding.count)], excluding: excluding, reset: reset) { start, size in
            try await client.items(query.page(from: start, size: size))
        }
    }

    /// The same, for a query in Jellyfin's own parameters (music's grids).
    func load(client: JellyfinClient, query: [String: String?], excluding: Set<String> = [], reset: Bool = false) async {
        // Sorted: a dictionary's order can differ between two equal ones, and
        // a key that changed with it reset the grid (and its scrolling) as
        // each new page was asked for.
        let key = query
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value ?? "")" }
            .joined(separator: "&") + "|\(excluding.count)"
        await load(key: key, excluding: excluding, reset: reset) { start, size in
            var merged = query
            merged["startIndex"] = String(start)
            merged["limit"] = String(size)
            return try await client.items(merged)
        }
    }

    /// Loads the next page from `page` (given where to start and how many),
    /// starting afresh when `key` (what's being listed) changes.
    private func load(key: AnyHashable, excluding: Set<String>, reset: Bool,
                      page: @escaping @Sendable (Int, Int) async throws -> ItemsResult) async {
        if reset || loadedWith != key {
            items = []
            fetched = 0
            totalCount = 0
            loadedWith = key
            generation += 1
            // Any load in flight belongs to the old results; let this one run.
            isLoading = false
        }
        guard !isLoading else { return }
        let started = generation
        isLoading = true
        errorMessage = nil
        let start = fetched
        do {
            // The request runs on its own, not in the caller's task: the
            // loading row that asks for a page leaves the screen (and its
            // task is cancelled) on a fast scroll, or as a reset empties the
            // grid, and the page must still arrive.
            let request = Task { try await page(start, 100) }
            let result = try await request.value
            guard started == generation else { return }
            fetched += result.items.count
            let kept = result.items.filter { new in !excluding.contains(new.id) && !items.contains { $0.id == new.id } }
            items.append(contentsOf: kept)
            totalCount = result.totalRecordCount ?? fetched
        } catch {
            guard started == generation else { return }
            // A cancelled request isn't a failure to report.
            if !Self.isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    var hasMore: Bool { fetched < totalCount }
}

/// Everything inside one library or collection, as a grid with sort options.
struct LibraryGridView: View {
    let parent: BaseItem

    @Environment(AppSession.self) private var session
    /// Room on the right for the floating Now Playing panel.
    @Environment(\.themeMiniInset) private var themeMiniInset
    @State private var model = GridModel()
    @State private var sort: LibrarySort = .name

    private var landscape: Bool {
        parent.collectionType == "homevideos" || parent.collectionType == "musicvideos"
    }

    private var query: ItemQuery {
        var query = ItemQuery(parentId: parent.id, sort: sort.itemSort, descending: sort.descending)
        let kind: ItemKind? = switch parent.collectionType {
        case "movies": .movie
        case "tvshows": .series
        case "boxsets": .boxSet
        // Every video, not the folders (one per show or artist) they're in.
        case "musicvideos": .musicVideo
        default: nil
        }
        if let kind {
            query.kinds = [kind]
            query.recursive = true
        }
        return query
    }

    /// By name, the library comes in letter sections with an index; it's
    /// loaded whole for that (libraries are small next to the work saved).
    @State private var sections: [IndexSection] = []

    private var indexed: Bool { sort == .name && !sections.isEmpty }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(parent.displayTitle)
                .font(.largeTitle.weight(.bold))
            Spacer()
            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.top, Lockup.pageTopPadding)
    }

    #if os(tvOS)
    @State private var proxy = TVGridProxy()

    /// The grid is a collection view, with the title, sort and letters as
    /// its header; the focus engine does all the moving between titles.
    var body: some View {
        Group {
            if model.items.isEmpty, model.errorMessage != nil || !model.isLoading {
                VStack(alignment: .leading, spacing: 0) {
                    tvHeader
                    if let error = model.errorMessage {
                        MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                            .frame(height: Lockup.emptyStateHeight)
                    } else {
                        MessageView(systemImage: "tray", title: "Nothing here yet")
                            .frame(height: Lockup.emptyStateHeight)
                    }
                    Spacer()
                }
            } else {
                TVCollectionGrid(
                    sections: indexed ? sections : [IndexSection(key: "all", items: model.items)],
                    landscape: landscape,
                    showsLetters: indexed,
                    proxy: proxy,
                    focusesFirstItemInitially: true,
                    onNearBottom: model.hasMore && sort != .name ? { Task { await load() } } : nil,
                    header: AnyView(tvHeader)
                )
            }
        }
        .task(id: sort) { await reloadIfNeeded(for: sort.rawValue) }
        .onChange(of: model.items.count) { _, _ in updateSections() }
    }

    private var tvHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
                .modifier(MiniPlayerRoom())
            if indexed {
                LibraryIndexBar(keys: sections.map(\.key)) { key in proxy.scrollTo(section: key) }
            }
        }
    }
    #else
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    titleRow

                    if model.items.isEmpty, let error = model.errorMessage {
                        MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                            .frame(height: Lockup.emptyStateHeight)
                    } else if model.items.isEmpty, !model.isLoading {
                        MessageView(systemImage: "tray", title: "Nothing here yet")
                            .frame(height: Lockup.emptyStateHeight)
                    } else if indexed {
                        SectionedItemGrid(sections: sections, landscape: landscape)
                    } else {
                        ItemGrid(items: model.items, landscape: landscape)
                        if model.hasMore, sort != .name {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(Lockup.pageBottomPadding)
                                .task { await load() }
                        }
                    }
                }
                .padding(.bottom, Lockup.pageBottomPadding)
                // The grid makes way for the floating Now Playing panel, and
                // on a touch screen or the Mac for the index strip.
                .padding(.trailing, themeMiniInset + (indexed ? LibraryIndexBar.stripRoom : 0))
                .animation(.smooth(duration: 0.4), value: themeMiniInset)
            }
            .scrollClipDisabled()
            .overlay(alignment: .trailing) {
                if indexed {
                    LibraryIndexBar(keys: sections.map(\.key)) { key in jump(to: key, reader) }
                        .padding(.trailing, themeMiniInset + 4)
                }
            }
        }
        .task(id: sort) { await reloadIfNeeded(for: sort.rawValue) }
        .onChange(of: model.items.count) { _, _ in updateSections() }
    }

    /// Brings a letter's section up.
    private func jump(to key: String, _ reader: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) {
            reader.scrollTo(LibraryIndexBar.anchor(key), anchor: .top)
        }
    }
    #endif

    /// The sort the grid was last loaded for. Coming back to the grid (from
    /// a title's page, or its player) leaves it as it was, so focus stays on
    /// the title that was picked rather than the grid emptying and refilling
    /// and focus jumping to the top.
    @State private var loadedKey: String?

    private func reloadIfNeeded(for key: String) async {
        guard loadedKey != key || model.items.isEmpty else { return }
        await reload()
        guard !Task.isCancelled else { return }
        loadedKey = key
    }

    /// Everything when sorted by name (for the sections), else page by page.
    private func reload() async {
        sections = []
        await load(reset: true)
        if sort == .name {
            while model.hasMore, !Task.isCancelled {
                let before = model.items.count
                await load()
                if model.items.count == before, model.errorMessage != nil { break }
            }
        }
        updateSections()
    }

    private func updateSections() {
        sections = sort == .name && !model.hasMore ? LibraryIndex.sections(model.items) : []
    }

    private func load(reset: Bool = false) async {
        guard let client = session.client else { return }
        await model.load(client: client, query: query, reset: reset)
    }
}

/// All movies or all series across every library.
struct TypeGridView: View {
    let kind: ItemKind

    @Environment(AppSession.self) private var session
    @State private var model = GridModel()
    @State private var recent: [BaseItem] = []
    @State private var sort: LibrarySort = .name
    /// The hero's titles: what's in progress, then (for shows) what's up
    /// next, then what's new, as Home picks its own. Anime is left out.
    @State private var featured: [BaseItem] = []
    /// Whether the hero's load has finished, so the page knows it isn't coming.
    @State private var heroLoaded = false
    #if !os(tvOS)
    /// Where focus goes on pressing down from the hero: the first new title.
    @FocusState private var focusedLockup: String?
    /// Whether the hero has focus, so a press down lands on the first new title.
    @State private var heroFocused = false
    #endif
    /// By name, every title in letter sections with an index.
    @State private var sections: [IndexSection] = []

    private var title: String { kind == .movie ? "Movies" : "TV Shows" }

    private var indexed: Bool { sort == .name && !sections.isEmpty }

    private var query: ItemQuery {
        ItemQuery(kinds: [kind], recursive: true, sort: sort.itemSort, descending: sort.descending)
    }

    #if os(tvOS)
    @State private var proxy = TVGridProxy()

    /// The grid is a collection view, with the hero, title and sort, Recently
    /// Added and the letters as its header, so the page is one scroll and the
    /// focus engine does all the moving between titles.
    var body: some View {
        Group {
            if !heroLoaded {
                // Only the spinner until the hero is ready: a row shown first
                // takes focus, and the hero arriving above pushes it down.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty, let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 0) {
                    tvHeader
                    MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                        .frame(height: Lockup.emptyStateHeight)
                    Spacer()
                }
            } else {
                TVCollectionGrid(
                    sections: indexed ? sections : [IndexSection(key: "all", items: model.items)],
                    showsLetters: indexed,
                    proxy: proxy,
                    // With a hero, the hero keeps initial focus.
                    focusesFirstItemInitially: featured.isEmpty,
                    onNearBottom: model.hasMore && sort != .name ? { Task { await load() } } : nil,
                    header: AnyView(tvHeader)
                )
            }
        }
        // Full-bleed under the hero, as on Home; the rows keep their margins.
        .ignoresSafeArea(edges: featured.isEmpty ? [] : .all)
        // Reloads once anime detection finishes, so its titles drop out.
        .task(id: "\(sort.rawValue)|\(session.animeItemIds.count)") { await reloadIfNeeded(for: "\(sort.rawValue)|\(session.animeItemIds.count)") }
        .onChange(of: model.items.count) { _, _ in updateSections() }
        .task(id: session.animeItemIds.count) { await loadHero() }
        .onChange(of: session.userDataRevision) { _, _ in
            Task { await loadHero() }
        }
    }

    private var tvHeader: some View {
        TypeGridHeader(
            title: title,
            featured: featured,
            recent: recent,
            sort: $sort,
            letters: indexed ? sections.map(\.key) : [],
            jump: { key in proxy.scrollTo(section: key) }
        )
    }
    #else
    private static let allTitlesID = "all-titles"

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                // A plain VStack, as on Home: focus can only move from the hero to
                // a card that exists. The grid below stays lazy.
                VStack(alignment: .leading, spacing: 0) {
                    if !featured.isEmpty {
                        HeroCarousel(items: featured, moveDown: {
                            focusedLockup = recent.first?.id
                        }, focusChanged: { focused in
                            if focused { focusedLockup = nil }
                            heroFocused = focused
                        })
                    }
                    if heroLoaded {
                        page(reader)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 200)
                    }
                }
                .padding(.bottom, Lockup.pageBottomPadding)
            }
            .scrollClipDisabled()
            .overlay(alignment: .trailing) {
                if indexed {
                    LibraryIndexBar(keys: sections.map(\.key)) { key in jump(to: key, reader) }
                        .padding(.trailing, 4)
                }
            }
        }
        // Full-bleed under the hero, as on Home; the rows keep their margins.
        .ignoresSafeArea(edges: featured.isEmpty ? [] : .all)
        // Reloads once anime detection finishes, so its titles drop out.
        .task(id: "\(sort.rawValue)|\(session.animeItemIds.count)") { await reloadIfNeeded(for: "\(sort.rawValue)|\(session.animeItemIds.count)") }
        .onChange(of: model.items.count) { _, _ in updateSections() }
        .task(id: session.animeItemIds.count) { await loadHero() }
        .onChange(of: session.userDataRevision) { _, _ in
            Task { await loadHero() }
        }
    }

    @ViewBuilder
    private func page(_ reader: ScrollViewProxy) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Spacer()
            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.top, featured.isEmpty ? Lockup.pageTopPadding : 20)

        Shelf(title: "Recently Added", items: recent) { item in
            LandscapeLockup(item: item, focus: $focusedLockup)
        }
        .heroLanding($focusedLockup, on: recent.first?.id, fromHero: heroFocused)

        if model.items.isEmpty, let error = model.errorMessage {
            MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                .frame(height: Lockup.emptyStateHeight)
        } else {
            Text("All \(title)")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, Lockup.screenPadding)
                .padding(.top, 20)
                .id(Self.allTitlesID)
            if indexed {
                SectionedItemGrid(sections: sections)
                    .padding(.trailing, LibraryIndexBar.stripRoom)
            } else {
                ItemGrid(items: model.items, focus: $focusedLockup)
                if model.hasMore, sort != .name {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(Lockup.pageBottomPadding)
                        .task { await load() }
                }
            }
        }
    }

    /// Brings a letter's section up.
    private func jump(to key: String, _ reader: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) {
            reader.scrollTo(LibraryIndexBar.anchor(key), anchor: .top)
        }
    }
    #endif

    private func load(reset: Bool = false) async {
        guard let client = session.client else { return }
        await model.load(client: client, query: query, excluding: session.animeItemIds, reset: reset)
    }

    /// Everything when sorted by name (for the sections), else page by page.
    /// What the grid was last loaded for (sort, and anime detection): coming
    /// back to it leaves it as it was, so focus stays on the title picked.
    @State private var loadedKey: String?

    private func reloadIfNeeded(for key: String) async {
        guard loadedKey != key || model.items.isEmpty else { return }
        await reload()
        if !Task.isCancelled { loadedKey = key }
    }

    private func reload() async {
        sections = []
        await load(reset: true)
        if sort == .name {
            while model.hasMore, !Task.isCancelled {
                let before = model.items.count
                await load()
                if model.items.count == before, model.errorMessage != nil { break }
            }
        }
        updateSections()
    }

    private func updateSections() {
        sections = sort == .name && !model.hasMore ? LibraryIndex.sections(model.items) : []
    }

    /// Recently Added, and from it and what's in progress, the hero.
    private func loadHero() async {
        guard let client = session.client else { return }
        let anime = session.animeItemIds
        // Ask for extra, as anime ones are taken out.
        async let latest = client.latest(parentId: nil, limit: 40, kinds: [kind])
        async let resumed = client.resume(limit: 30)
        let isShows = kind == .series
        async let next: [BaseItem] = isShows ? ((try? await client.nextUp(limit: 20)) ?? []) : []
        let newest = Array(((try? await latest) ?? []).filter { !anime.contains($0.id) }.prefix(20))

        var picks: [BaseItem] = []
        let inProgress: [BaseItem]
        let upNext: [BaseItem]
        if kind == .movie {
            inProgress = ((try? await resumed) ?? []).filter { $0.kind == .movie && !anime.contains($0.id) }
            upNext = []
        } else {
            inProgress = ((try? await resumed) ?? []).filter { $0.kind == .episode && !anime.contains($0.seriesId ?? "") }
            upNext = (await next).filter { episode in
                !anime.contains(episode.seriesId ?? "") && !inProgress.contains { $0.id == episode.id }
            }
        }
        for item in inProgress.prefix(kind == .movie ? 4 : 3) + upNext.prefix(3) + newest.prefix(5) where !picks.contains(where: { $0.id == item.id }) {
            picks.append(item)
        }
        recent = newest
        featured = Array(picks.prefix(8))
        heroLoaded = true
    }
}

#if os(tvOS)
/// The Movies or TV Shows page above its grid: the hero, the title and
/// sort, Recently Added and the letters. One SwiftUI root inside the grid's
/// header, so the hero's press down can hand focus to the shelf's first
/// card. Down from the shelf reaches the letters and the grid's first row
/// by itself: they're real views directly below.
private struct TypeGridHeader: View {
    let title: String
    let featured: [BaseItem]
    let recent: [BaseItem]
    @Binding var sort: LibrarySort
    let letters: [String]
    let jump: (String) -> Void

    /// Where focus goes on pressing down from the hero: the first new title.
    @FocusState private var focusedLockup: String?
    /// Whether the hero has focus, so a press down lands on the first new title.
    @State private var heroFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !featured.isEmpty {
                HeroCarousel(items: featured, moveDown: {
                    focusedLockup = recent.first?.id
                }, focusChanged: { focused in
                    if focused { focusedLockup = nil }
                    heroFocused = focused
                })
            }
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.top, featured.isEmpty ? Lockup.pageTopPadding : 20)
            .modifier(MiniPlayerRoom())

            Shelf(title: "Recently Added", items: recent) { item in
                LandscapeLockup(item: item, focus: $focusedLockup)
            }
            .heroLanding($focusedLockup, on: recent.first?.id, fromHero: heroFocused)

            Text("All \(title)")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, Lockup.screenPadding)
                .padding(.top, 20)
            if !letters.isEmpty {
                LibraryIndexBar(keys: letters, jump: jump)
            }
        }
    }
}
#endif

// MARK: - People

struct PersonView: View {
    let person: PersonInfo

    #if os(tvOS)
    private static let photoSize: CGFloat = 260
    #else
    private static let photoSize: CGFloat = 110
    #endif

    @Environment(AppSession.self) private var session
    @State private var items: [BaseItem] = []
    @State private var details: BaseItem?

    var body: some View {
        Group {
            #if os(tvOS)
            TVCollectionGrid(sections: [IndexSection(key: "all", items: items)], header: AnyView(header))
            #else
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Lockup.sectionSpacing) {
                    header
                    ItemGrid(items: items)
                }
                .padding(.bottom, Lockup.pageBottomPadding)
            }
            .scrollClipDisabled()
            #endif
        }
        .task {
            guard let client = session.client else { return }
            details = try? await client.item(person.id)
            items = (try? await client.items(ItemQuery(
                kinds: [.movie, .series], recursive: true, sort: .releaseDate, descending: true, personId: person.id
            )).items) ?? []
        }
    }

    /// The photo, name and biography, and the Filmography heading.
    private var header: some View {
        VStack(alignment: .leading, spacing: Lockup.sectionSpacing) {
            HStack(alignment: .top, spacing: Lockup.sectionSpacing) {
                RemoteImage(url: session.client?.personImageURL(person, width: 500), systemImage: "person.fill")
                    .frame(width: Self.photoSize, height: Self.photoSize)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 12) {
                    Text(person.name ?? "")
                        .font(.largeTitle.weight(.bold))
                    if let overview = details?.overview {
                        Text(overview)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.top, Lockup.pageTopPadding)

            Text("Filmography")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, Lockup.screenPadding)
        }
    }
}
