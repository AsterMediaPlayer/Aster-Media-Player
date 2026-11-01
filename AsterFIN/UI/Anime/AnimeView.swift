//
//  AnimeView.swift
//  AsterFIN
//
//  The Anime tab: everything in the libraries Shoko matched (see
//  `AppSession.animeLibraries`), which Movies and TV Shows leave out.
//

import SwiftUI

@Observable
final class AnimeModel {
    private(set) var continueWatching: [BaseItem] = []
    private(set) var nextUp: [BaseItem] = []
    private(set) var recentlyAdded: [BaseItem] = []
    /// Each music video library the tab shows (the OP/ED plugin's openings
    /// and endings, AMVs), with its newest videos.
    private(set) var musicVideoShelves: [MusicVideoShelf] = []
    /// The hero's titles: anime only, picked as Home picks its own.
    private(set) var featured: [BaseItem] = []
    private(set) var isLoading = false
    /// Whether a load has finished, so the page knows the hero isn't coming.
    private(set) var hasLoaded = false

    struct MusicVideoShelf: Identifiable {
        let library: BaseItem
        let items: [BaseItem]
        var id: String { library.id }
    }

    func load(client: any MediaServer, libraries: [BaseItem], musicVideoLibraries: [BaseItem] = []) async {
        isLoading = featured.isEmpty && !libraries.isEmpty
        let ids = libraries.map(\.id)
        let showIds = libraries.filter { $0.collectionType == "tvshows" }.map(\.id)

        async let resume = Self.merged(ids) { try await client.resume(limit: 20, parentId: $0) }
        async let next = Self.merged(showIds) { try await client.nextUp(limit: 20, seriesId: nil, parentId: $0) }
        async let latest = Self.recentlyAdded(client: client, libraries: libraries)
        // Music videos (the OP/ED plugin's, and AMV libraries) are Jellyfin's.
        let jellyfin = client as? JellyfinClient
        async let musicVideos = withTaskGroup(of: (Int, MusicVideoShelf).self) { group in
            for (position, library) in musicVideoLibraries.enumerated() {
                guard let client = jellyfin else { break }
                group.addTask { (position, MusicVideoShelf(library: library, items: await client.latestMusicVideos(inLibrary: library.id))) }
            }
            var shelves: [(Int, MusicVideoShelf)] = []
            for await shelf in group { shelves.append(shelf) }
            return shelves.sorted { $0.0 < $1.0 }.map(\.1)
        }

        // Newest first across libraries; ISO 8601 dates sort as text.
        let resumed = await resume
        continueWatching = Array(resumed.sorted { ($0.userData?.lastPlayedDate ?? "") > ($1.userData?.lastPlayedDate ?? "") }.prefix(20))
        nextUp = Array(await next.filter { episode in !resumed.contains { $0.id == episode.id } }.prefix(20))
        recentlyAdded = await latest
        musicVideoShelves = await musicVideos

        var picks: [BaseItem] = []
        for item in continueWatching.prefix(3) + nextUp.prefix(3) + recentlyAdded.prefix(5) where !picks.contains(where: { $0.id == item.id }) {
            picks.append(item)
        }
        featured = Array(picks.prefix(8))
        hasLoaded = true
        isLoading = false
    }

    /// The newest series and films across the anime libraries. Home's
    /// Recently Added Anime shelf uses this too.
    static func recentlyAdded(client: any MediaServer, libraries: [BaseItem], limit: Int = 20) async -> [BaseItem] {
        let all = await merged(libraries.map(\.id)) { try await client.latest(parentId: $0, limit: limit) }
        let newest = all.sorted { ($0.dateCreated ?? "") > ($1.dateCreated ?? "") }

        // Jellyfin reports a season when new episodes land in it. Show its
        // series instead, as the library rows below do, and each show once.
        let seriesIds = Set(newest.filter { $0.kind == .season }.compactMap(\.seriesId))
        var series: [String: BaseItem] = [:]
        if !seriesIds.isEmpty, let found = try? await client.items(ItemQuery(ids: Array(seriesIds))) {
            series = Dictionary(found.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var shown: [BaseItem] = []
        for item in newest {
            let entry = item.kind == .season ? (item.seriesId.flatMap { series[$0] } ?? item) : item
            if !shown.contains(where: { $0.id == entry.id }) { shown.append(entry) }
        }
        return Array(shown.prefix(limit))
    }

    /// Runs `fetch` for each library side by side and joins the results in
    /// library order, skipping any that fail.
    private static func merged(_ libraryIds: [String], fetch: @escaping @Sendable (String) async throws -> [BaseItem]) async -> [BaseItem] {
        await withTaskGroup(of: (Int, [BaseItem]).self) { group in
            for (position, id) in libraryIds.enumerated() {
                group.addTask { (position, (try? await fetch(id)) ?? []) }
            }
            var chunks: [(Int, [BaseItem])] = []
            for await chunk in group { chunks.append(chunk) }
            return chunks.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }
}

struct AnimeView: View {
    @Environment(AppSession.self) private var session
    /// Room on the right for the floating Now Playing panel.
    @Environment(\.themeMiniInset) private var themeMiniInset
    @State private var model = AnimeModel()
    /// Where focus goes on pressing down from the hero: the first library.
    @FocusState private var focusedTile: String?
    /// Whether the hero has focus, so a press down lands on the first library.
    @State private var heroFocused = false
    #if os(macOS)
    @Environment(\.openItem) private var openItem
    @Environment(KeyboardNavigation.self) private var keyboard
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// Whether the keyboard is paging the hero or moving through the rows.
    @State private var keyboardOnHero = true
    @State private var heroPage = 0
    @State private var atTop = true
    #endif

    private static let librariesRowID = "anime-libraries"

    var body: some View {
        // Full-bleed like Home: the hero runs to the edges and the rows
        // keep their own margins.
        ScrollView(.vertical) {
            // A plain VStack, as on Home: the rows sit below a full-screen
            // hero, and focus can only move to a card that exists.
            VStack(alignment: .leading, spacing: 20) {
                if !model.featured.isEmpty {
                    HeroCarousel(items: model.featured, moveDown: {
                        #if os(macOS)
                        enterRows()
                        #else
                        focusedTile = session.animeLibraries.first?.id
                        #endif
                    }, focusChanged: { focused in
                        if focused { focusedTile = nil }
                        heroFocused = focused
                    }, keyboardPage: heroKeyboardPage, pageChanged: { page in
                        #if os(macOS)
                        heroPage = page
                        #endif
                    })
                } else if !model.hasLoaded {
                    // Only the spinner until the hero is ready. The Libraries
                    // row used to show first, and the Apple TV gave it focus;
                    // when the hero then appeared above, the row and its focus
                    // were pushed down the page.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 200)
                } else {
                    Text("Anime")
                        .font(.largeTitle.weight(.bold))
                        .padding(.horizontal, Lockup.screenPadding)
                        .padding(.top, Lockup.pageTopPadding + 40)
                }

                if model.hasLoaded || !model.featured.isEmpty {
                    // The rows make way for the floating Now Playing panel;
                    // the hero stays full width under it. (A Group pads
                    // each row in place, so the rows stay where focus
                    // expects them, below the hero.)
                    Group {
                    // Each opens the whole library as a sortable grid.
                    Shelf(title: "Libraries", items: session.animeLibraries + session.animeMusicVideoLibraries) { library in
                        LibraryTile(library: library, focus: $focusedTile)
                    }
                    .id(Self.librariesRowID)
                    .heroLanding($focusedTile, on: session.animeLibraries.first?.id, fromHero: heroFocused)
                    Shelf(title: "Continue Watching", items: model.continueWatching) { item in
                        LandscapeLockup(item: item)
                    }
                    Shelf(title: "Next Up", items: model.nextUp) { item in
                        LandscapeLockup(item: item)
                    }
                    Shelf(title: "Recently Added", items: model.recentlyAdded) { item in
                        LandscapeLockup(item: item)
                    }
                    // Openings & endings (the OP/ED plugin's library) and AMVs.
                    ForEach(model.musicVideoShelves) { shelf in
                        Shelf(title: shelf.library.displayTitle, items: shelf.items) { item in
                            LandscapeLockup(item: item, showSeriesTitle: false)
                        }
                    }
                    // Starting this season and next, to request from Seerr
                    // (when it's set up): last at the foot of the page.
                    SeerrDiscoverShelf(title: "Upcoming Anime") { account in
                        try await SeerrClient.upcomingAnime(account: account)
                    }
                    }
                    .padding(.trailing, themeMiniInset)
                    .animation(.smooth(duration: 0.4), value: themeMiniInset)
                }
            }
            .padding(.bottom, Lockup.pageBottomPadding)
        }
        .scrollClipDisabled()
        .ignoresSafeArea()
        #if os(macOS)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < 40
        } action: { _, top in
            atTop = top
            // Back at the top, however it got there: the hero again.
            if top { keyboardOnHero = true }
        }
        .onAppear {
            keyboardOnHero = atTop
            keyboard.register(.anime) { key in handleKey(key) }
        }
        .onDisappear { keyboard.unregister(.anime) }
        #endif
        .task(id: (session.animeLibraries + session.animeMusicVideoLibraries).map(\.id)) { await reload() }
        .onChange(of: session.userDataRevision) { _, _ in
            Task { await reload() }
        }
    }

    /// The hero page the Mac keyboard asks for; nil elsewhere.
    private var heroKeyboardPage: Int? {
        #if os(macOS)
        heroPage
        #else
        nil
        #endif
    }

    #if os(macOS)
    /// At the top the arrows page the hero, Return opens it, and down goes
    /// on to the rows. There the nearest card that way is chosen, as on
    /// other pages, and up from the top row goes back to the hero. Left on
    /// the first page or card, and up from the hero, are the sidebar's.
    private func handleKey(_ key: KeyboardNavigation.Key) -> KeyPress.Result {
        if key == .exit { return .ignored }
        guard keyboardOnHero, !model.featured.isEmpty else {
            let result = KeyboardTargets.shared.handle(key, on: .anime)
            if result == .ignored, key == .up, !model.featured.isEmpty {
                keyboardOnHero = true
                KeyboardTargets.shared.clearSelection()
                withAnimation(.easeInOut(duration: 0.4)) {
                    scrollPosition.scrollTo(edge: .top)
                }
                return .handled
            }
            return result
        }
        switch key {
        case .select:
            guard model.featured.indices.contains(heroPage) else { return .ignored }
            // The page opened takes the keys (its cards, Esc), not the hero.
            keyboardOnHero = false
            openItem?(model.featured[heroPage])
        case .down:
            enterRows()
        case .left, .right:
            let step = key == .left ? -1 : 1
            if step < 0, heroPage == 0 { return .ignored }
            heroPage = min(max(heroPage + step, 0), model.featured.count - 1)
        case .up, .exit:
            return .ignored
        }
        return .handled
    }

    /// Down from the hero: brings the Libraries row up, then chooses the
    /// first card showing (the first library) once it's on screen.
    private func enterRows() {
        keyboardOnHero = false
        KeyboardTargets.shared.clearSelection()
        withAnimation(.easeInOut(duration: 0.3)) {
            scrollPosition.scrollTo(id: Self.librariesRowID, anchor: .center)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            _ = KeyboardTargets.shared.handle(.down, on: .anime)
        }
    }
    #endif

    private func reload() async {
        guard let client = session.client else { return }
        await model.load(client: client, libraries: session.animeLibraries, musicVideoLibraries: session.animeMusicVideoLibraries)
    }
}
