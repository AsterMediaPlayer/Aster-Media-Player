//
//  HomeView.swift
//  AsterFIN
//
//  The Apple TV app's Home: a featured banner, then shelves of what to watch.
//

import SwiftUI

@Observable
final class HomeModel {
    nonisolated struct LibraryShelf: Identifiable, Hashable, Codable, Sendable {
        var id: String { library.id }
        var library: BaseItem
        var items: [BaseItem]
    }

    private(set) var featured: [BaseItem] = []
    private(set) var continueWatching: [BaseItem] = []
    private(set) var nextUp: [BaseItem] = []
    private(set) var latestMovies: [BaseItem] = []
    private(set) var latestShows: [BaseItem] = []
    private(set) var latestAnime: [BaseItem] = []
    /// What the Movies and TV rows were built from, so anime found later
    /// only rebuilds what it affects.
    private var libraries: [BaseItem] = []
    private var moviesLibraryId: String?
    private var showsLibraryId: String?

    /// Sets `value` only when it differs, so an unchanged row isn't redrawn.
    private static func update<Value: Equatable>(_ value: inout Value, _ new: Value) {
        if value != new { value = new }
    }

    /// Anime libraries are found after Home first loads. Fills the anime
    /// row and swaps the Movies or TV row only if it came from one of them,
    /// leaving Continue Watching and the hero alone so focus stays put.
    func applyAnimeLibraries(_ anime: [BaseItem], client: any MediaServer) async {
        let animeIds = Set(anime.map(\.id))
        if let id = moviesLibraryId, animeIds.contains(id) {
            moviesLibraryId = libraries.first { $0.collectionType == "movies" && !animeIds.contains($0.id) }?.id
            latestMovies = (try? await client.latest(parentId: moviesLibraryId, limit: 20, kinds: [.movie])) ?? []
        }
        if let id = showsLibraryId, animeIds.contains(id) {
            showsLibraryId = libraries.first { $0.collectionType == "tvshows" && !animeIds.contains($0.id) }?.id
            latestShows = (try? await client.latest(parentId: showsLibraryId, limit: 20, kinds: [.series])) ?? []
        }
        latestAnime = await AnimeModel.recentlyAdded(client: client, libraries: anime)
    }
    private(set) var libraryShelves: [LibraryShelf] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Home as last shown, kept on disk to show at once on the next launch.
    nonisolated private struct Snapshot: Codable, Sendable {
        var featured: [BaseItem]
        var continueWatching: [BaseItem]
        var nextUp: [BaseItem]
        var latestMovies: [BaseItem]
        var latestShows: [BaseItem]
        var latestAnime: [BaseItem]
        var libraryShelves: [LibraryShelf]
        var libraries: [BaseItem]
        var moviesLibraryId: String?
        var showsLibraryId: String?
    }

    private static let snapshotName = "home"

    /// Home as it was last time, while the server's answer comes: no spinner.
    func restore(client: any MediaServer, userId: String?) async {
        guard featured.isEmpty, let userId,
              let kept = await ResponseCache.load(Snapshot.self, Self.snapshotName, server: client.baseURL, user: userId)?.value,
              featured.isEmpty else { return }
        featured = kept.featured
        continueWatching = kept.continueWatching
        nextUp = kept.nextUp
        latestMovies = kept.latestMovies
        latestShows = kept.latestShows
        latestAnime = kept.latestAnime
        libraryShelves = kept.libraryShelves
        libraries = kept.libraries
        moviesLibraryId = kept.moviesLibraryId
        showsLibraryId = kept.showsLibraryId
    }

    private func keep(client: any MediaServer, userId: String?) {
        guard let userId, !featured.isEmpty else { return }
        ResponseCache.save(Snapshot(featured: featured, continueWatching: continueWatching, nextUp: nextUp,
                                    latestMovies: latestMovies, latestShows: latestShows, latestAnime: latestAnime,
                                    libraryShelves: libraryShelves, libraries: libraries,
                                    moviesLibraryId: moviesLibraryId, showsLibraryId: showsLibraryId),
                           Self.snapshotName, server: client.baseURL, user: userId)
    }

    func load(client: any MediaServer, animeLibraries: [BaseItem] = [], userId: String? = nil) async {
        isLoading = featured.isEmpty
        errorMessage = nil
        defer { keep(client: client, userId: userId) }
        do {
            async let resume = client.resume(limit: 20)
            async let next = client.nextUp(limit: 20)
            async let views = client.libraries()
            let (resumeItems, nextItems, libraries) = try await (resume, next, views)
            // Only what changed is replaced: the rows shown from last time
            // stay as they are, and focus with them.
            Self.update(&continueWatching, resumeItems)
            Self.update(&nextUp, nextItems.filter { episode in !resumeItems.contains { $0.id == episode.id } })

            // Anime has its own row, so the Movies and TV rows skip its libraries.
            let animeIds = Set(animeLibraries.map(\.id))
            let movieLibraries = libraries.filter { $0.collectionType == "movies" && !animeIds.contains($0.id) }
            let showLibraries = libraries.filter { $0.collectionType == "tvshows" && !animeIds.contains($0.id) }
            moviesLibraryId = movieLibraries.first?.id
            showsLibraryId = showLibraries.first?.id
            self.libraries = libraries
            async let movies = client.latest(parentId: moviesLibraryId, limit: 20, kinds: [.movie])
            async let shows = client.latest(parentId: showsLibraryId, limit: 20, kinds: [.series])
            async let anime = AnimeModel.recentlyAdded(client: client, libraries: animeLibraries)
            Self.update(&latestMovies, (try? await movies) ?? [])
            Self.update(&latestShows, (try? await shows) ?? [])
            Self.update(&latestAnime, await anime)

            // The hero as soon as its rows are in, not after every shelf.
            var picks: [BaseItem] = []
            for item in continueWatching.prefix(3) + nextUp.prefix(3) + latestMovies.prefix(4) + latestShows.prefix(3) where !picks.contains(where: { $0.id == item.id }) {
                picks.append(item)
            }
            Self.update(&featured, Array(picks.prefix(8)))

            // The other libraries' shelves side by side, kept in library order.
            let others = libraries.filter { !["movies", "tvshows", "music", "playlists", "livetv", "books", "photos"].contains($0.collectionType ?? "") }
            let shelves = await withTaskGroup(of: (Int, LibraryShelf?).self) { group in
                for (position, library) in others.enumerated() {
                    group.addTask {
                        let items = (try? await client.latest(parentId: library.id, limit: 20)) ?? []
                        return (position, items.isEmpty ? nil : LibraryShelf(library: library, items: items))
                    }
                }
                var found: [(Int, LibraryShelf?)] = []
                for await shelf in group { found.append(shelf) }
                return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            Self.update(&libraryShelves, shelves)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// Where the keyboard is among a page's shelves on a Mac.
struct ShelfCursor: Equatable {
    var row = 0
    var column = 0
}

/// Which part of Home the Mac keyboard is moving through.
enum HomeKeyboardArea {
    case hero, shelves
}

struct HomeView: View {
    @Environment(AppSession.self) private var session
    @State private var model = HomeModel()
    @FocusState private var focusedLockup: String?
    /// Whether the hero has focus, so a press down lands on the first card.
    @State private var heroFocused = false
    #if os(macOS)
    @Environment(\.openItem) private var openItem
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// Scrolled all the way up, with the hero filling the window.
    @State private var atTop = true
    /// The page holds the keyboard; this says whether it's paging the hero
    /// or moving through the shelves. One focusable view for the whole page,
    /// since a focusable hero inside a focusable page shares its focus.
    @State private var keyboardArea = HomeKeyboardArea.hero
    @State private var heroPage = 0
    /// The keyboard's place in the shelves: which row, and which card in it.
    @State private var cursor = ShelfCursor()
    @Environment(KeyboardNavigation.self) private var keyboard
    #endif

    /// The shelves in the order they're shown, each with a key.
    private var shelfRows: [(key: String, items: [BaseItem])] {
        [
            ("continue", model.continueWatching),
            ("nextUp", model.nextUp),
            ("movies", model.latestMovies),
            ("shows", model.latestShows),
            ("anime", model.latestAnime),
        ] + model.libraryShelves.map { ($0.id, $0.items) }
    }

    /// The first non-empty shelf and its first item: where focus goes when
    /// pressing down from the hero. Only that shelf binds the focus state, because
    /// the same title can appear in several shelves and the binding is keyed by
    /// item id.
    private var firstShelf: (key: String, itemID: String)? {
        for (key, items) in shelfRows {
            if let first = items.first { return (key, first.id) }
        }
        return nil
    }

    private var firstShelfItemID: String? { firstShelf?.itemID }

    private func lockupFocus(for shelfKey: String) -> FocusState<String?>.Binding? {
        firstShelf?.key == shelfKey ? $focusedLockup : nil
    }

    var body: some View {
        // Home is full-bleed like the Apple TV app: the scroll view ignores the
        // safe area and the hero and shelves keep their own 80-point margins.
        content
            .task { await reload() }
            .refreshable { await reload() }
            .onChange(of: session.animeLibraries.map(\.id)) { _, _ in
                guard let client = session.client else { return }
                Task { await model.applyAnimeLibraries(session.animeLibraries, client: client) }
            }
            .onChange(of: session.userDataRevision) { _, _ in
                Task { await reload() }
            }
            .onChange(of: focusedLockup) { old, new in
                #if DEBUG
                print("DEBUG focus: focusedLockup \(old ?? "nil") -> \(new ?? "nil")")
                #endif
            }
            .onChange(of: model.featured.map(\.id)) { _, ids in
                #if DEBUG
                print("DEBUG focus: featured changed (\(ids.count))")
                #endif
            }
            .onChange(of: model.continueWatching.map(\.id)) { _, ids in
                #if DEBUG
                print("DEBUG focus: continueWatching changed (\(ids.count))")
                #endif
            }
    }

    private var content: some View {
        Group {
            if let error = model.errorMessage, model.featured.isEmpty {
                MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load your library", detail: error) {
                    Task { await reload() }
                }
            } else if model.isLoading && model.featured.isEmpty {
                ProgressView()
            } else {
                ScrollView(.vertical) {
                    // A plain VStack: the shelves sit below the fold behind a
                    // full-screen hero, and focus can only move to a poster that
                    // has actually been created. Each shelf is still lazy sideways.
                    VStack(alignment: .leading, spacing: 20) {
                        if !model.featured.isEmpty {
                            HeroCarousel(items: model.featured, moveDown: {
                                #if DEBUG
                                print("DEBUG focus: hero moveDown -> \(firstShelfItemID ?? "nil")")
                                #endif
                                #if os(macOS)
                                // No focus engine to carry the keyboard down:
                                // the shelves keep their own selection.
                                enterShelves()
                                #else
                                if let target = firstShelfItemID { focusedLockup = target }
                                #endif
                            }, focusChanged: { focused in
                                #if DEBUG
                                print("DEBUG focus: hero focused=\(focused)")
                                #endif
                                // Once the hero has focus again, forget the shelf target so a
                                // re-rendered poster cannot pull focus back down later.
                                if focused { focusedLockup = nil }
                                heroFocused = focused
                            }, keyboardPage: heroKeyboardPage, pageChanged: { page in
                                #if os(macOS)
                                heroPage = page
                                #endif
                            })
                        }
                        // Each shelf in turn; only the first holds the card.
                        Group {
                        Shelf(title: "Continue Watching", items: model.continueWatching, keyboardSelection: keyboardSelection(in: "continue")) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "continue"))
                        }
                        .id(Self.rowID("continue"))
                        Shelf(title: "Up Next", items: model.nextUp, keyboardSelection: keyboardSelection(in: "nextUp")) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "nextUp"))
                        }
                        .id(Self.rowID("nextUp"))
                        Shelf(title: "Recently Added Movies", items: model.latestMovies, keyboardSelection: keyboardSelection(in: "movies")) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "movies"))
                        }
                        .id(Self.rowID("movies"))
                        Shelf(title: "Recently Added TV Shows", items: model.latestShows, keyboardSelection: keyboardSelection(in: "shows")) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "shows"))
                        }
                        .id(Self.rowID("shows"))
                        Shelf(title: "Recently Added Anime", items: model.latestAnime, keyboardSelection: keyboardSelection(in: "anime")) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "anime"))
                        }
                        .id(Self.rowID("anime"))
                        ForEach(model.libraryShelves) { shelf in
                            Shelf(title: shelf.library.displayTitle, items: shelf.items, keyboardSelection: keyboardSelection(in: shelf.id)) { item in
                                LandscapeLockup(item: item, focus: lockupFocus(for: shelf.id))
                            }
                            .id(Self.rowID(shelf.id))
                        }
                        }
                        .heroLanding($focusedLockup, on: firstShelfItemID, fromHero: heroFocused)
                    }
                    .padding(.bottom, 80)
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
                    if top { keyboardArea = .hero }
                }
                // At the top the arrows page the hero and down goes on to
                // the shelves; there they move the selection, and up from the
                // top row goes back. Return opens what's chosen; left past the
                // first page or card goes on to the sidebar.
                .onAppear {
                    keyboard.register(.home) { key in handleKey(key) }
                }
                .onDisappear { keyboard.unregister(.home) }
                #endif
            }
        }
    }

    /// A shelf's id in the page, for scrolling it into view.
    private static func rowID(_ key: String) -> String { "home-row-\(key)" }

    /// The card the keyboard has selected in the shelf `key`, if any.
    private func keyboardSelection(in key: String) -> String? {
        #if os(macOS)
        guard keyboardArea == .shelves, !keyboard.inSidebar, let row = keyboardRows.indices.contains(cursor.row) ? keyboardRows[cursor.row] : nil,
              row.key == key else { return nil }
        return selectedItem?.id
        #else
        nil
        #endif
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
    /// The shelves that are showing, which the keyboard moves between.
    private var keyboardRows: [(key: String, items: [BaseItem])] {
        shelfRows.filter { !$0.items.isEmpty }
    }

    private var selectedItem: BaseItem? {
        guard keyboardRows.indices.contains(cursor.row) else { return nil }
        let items = keyboardRows[cursor.row].items
        return items[min(cursor.column, items.count - 1)]
    }

    /// Down from the hero: the first card of the first shelf.
    private func enterShelves() {
        guard !keyboardRows.isEmpty else { return }
        cursor = ShelfCursor()
        keyboardArea = .shelves
        scrollToCursorRow()
    }

    private func handleKey(_ key: KeyboardNavigation.Key) -> KeyPress.Result {
        if key == .exit { return .ignored }
        if key == .select {
            let item = keyboardArea == .hero
                ? (model.featured.indices.contains(heroPage) ? model.featured[heroPage] : nil)
                : selectedItem
            guard let item else { return .ignored }
            openItem?(item)
            return .handled
        }
        let (rows, columns) = switch key {
        case .up: (-1, 0)
        case .down: (1, 0)
        case .left: (0, -1)
        case .right: (0, 1)
        case .select, .exit: (0, 0)
        }
        guard keyboardArea == .hero else { return moveCursor(rows: rows, columns: columns) }
        if rows > 0 {
            enterShelves()
        } else if rows < 0 {
            // Up from the hero is the sidebar's.
            return .ignored
        } else if columns != 0, !model.featured.isEmpty {
            // Left on the first page is the sidebar's.
            if columns < 0, heroPage == 0 { return .ignored }
            heroPage = min(max(heroPage + columns, 0), model.featured.count - 1)
        }
        return .handled
    }

    private func moveCursor(rows: Int, columns: Int) -> KeyPress.Result {
        let rowsShown = keyboardRows
        guard !rowsShown.isEmpty, rowsShown.indices.contains(cursor.row) else { return .ignored }
        // Left on a shelf's first card is the sidebar's.
        if columns < 0, min(cursor.column, rowsShown[cursor.row].items.count - 1) == 0 { return .ignored }
        if rows < 0, cursor.row == 0 {
            // Back up to the hero.
            keyboardArea = .hero
            withAnimation(.easeInOut(duration: 0.4)) {
                scrollPosition.scrollTo(edge: .top)
            }
            return .handled
        }
        let row = min(max(cursor.row + rows, 0), rowsShown.count - 1)
        // A row keeps the card under the selection, as far as it reaches.
        let column = min(max(min(cursor.column, rowsShown[cursor.row].items.count - 1) + columns, 0), rowsShown[row].items.count - 1)
        cursor = ShelfCursor(row: row, column: column)
        if rows != 0 { scrollToCursorRow() }
        return .handled
    }

    private func scrollToCursorRow() {
        guard keyboardRows.indices.contains(cursor.row) else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            scrollPosition.scrollTo(id: Self.rowID(keyboardRows[cursor.row].key), anchor: .center)
        }
    }
    #endif

    private func reload() async {
        guard let client = session.client else { return }
        await model.restore(client: client, userId: session.userId)
        await model.load(client: client, animeLibraries: session.animeLibraries, userId: session.userId)
    }
}

// MARK: - Hero

/// The big featured banner at the top of Home. One focusable banner that pages
/// left and right itself: the focus engine cannot reach a page that is fully
/// off screen, so paging is driven by move commands.
struct HeroCarousel: View {
    let items: [BaseItem]
    /// Called when the viewer presses down, so Home can focus the first shelf.
    var moveDown: () -> Void
    /// Reports when the banner gains or loses focus.
    var focusChanged: (Bool) -> Void = { _ in }
    /// Mac: the page Home's keyboard asks for (Home owns the keyboard, as
    /// nested focusable views don't route keys reliably there), and the
    /// page shown, reported back as it changes, including by a swipe.
    var keyboardPage: Int?
    var pageChanged: (Int) -> Void = { _ in }
    /// A short label over a page's title, e.g. Upcoming's countdown.
    var tag: (BaseItem) -> String? = { _ in nil }
    /// The page's button, in place of Play / Resume.
    var action: (BaseItem) -> HeroCard.Action? = { _ in nil }
    /// What selecting a page opens; the page's own title unless given.
    var destination: (BaseItem) -> BaseItem = { $0 }
    /// Draws a page in place of `HeroCard`, given whether the banner has
    /// focus; for pages without a wide backdrop, like a book's square cover.
    var card: ((BaseItem, Bool) -> AnyView)? = nil
    /// What selecting a page does, in place of opening its page and playing.
    var onSelect: ((BaseItem) -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.openItem) private var openItem
    @Environment(\.displayScale) private var displayScale
    @State private var index = 0
    @State private var scrollID: String?
    #if os(macOS)
    /// How far a mouse drag has pulled the banner from its page.
    @State private var dragOffset: CGFloat = 0
    #endif
    @FocusState private var isFocused: Bool
    @FocusState private var guardFocused: Bool
    /// When the banner last gained focus. The press that brings focus here from
    /// the sidebar also arrives as a move command; ignore it.
    @State private var focusGainedAt = Date.distantPast
    /// When the viewer last moved sideways, and a down move waiting to be honoured.
    /// A click on the clickpad's edge often also registers as a short swipe, so a
    /// down that lands right next to a left or right is treated as that swipe.
    @State private var lastHorizontalMoveAt = Date.distantPast
    @State private var pendingMoveDown: Task<Void, Never>?
    #if os(tvOS)
    /// Every page's backdrop, decoded and held here (8 at 1080p is about
    /// 64 MB). The shared image cache could let one go under memory
    /// pressure, and that page slid in grey.
    @State private var backdrops: [String: PlatformImage] = [:]
    #endif

    private var current: BaseItem { items[min(index, items.count - 1)] }

    /// Play and Resume play: the title's page opens and starts playing at
    /// once, so closing the player leaves the viewer on that page. A page
    /// with its own button (Upcoming's) only opens.
    private func select(_ item: BaseItem) {
        if let onSelect {
            onSelect(item)
            return
        }
        let target = destination(item)
        if action(item) == nil {
            session.playOnOpen = target.id
        }
        openItem?(target)
    }

    /// A click on the banner itself opens the title's page and nothing more
    /// (on the Mac, where the Play button is the one thing that plays).
    private func open(_ item: BaseItem) {
        if let onSelect {
            onSelect(item)
            return
        }
        openItem?(destination(item))
    }

    private func noteHorizontalMove() {
        lastHorizontalMoveAt = Date()
        pendingMoveDown?.cancel()
        pendingMoveDown = nil
    }

    var body: some View {
        #if os(tvOS)
        // A move command does not stop the focus engine from moving focus when a
        // candidate exists, so a left press on page 2+ would also open the
        // sidebar. A sliver of focusable space at the leading edge catches that
        // move and pages instead; on page 1 it is gone, so left opens the sidebar.
        HStack(spacing: 0) {
            if index > 0 {
                Color.clear
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .focusable()
                    .focused($guardFocused)
                    .accessibilityHidden(true)
            }
            banner
        }
        .onChange(of: guardFocused) { _, focused in
            guard focused else { return }
            noteHorizontalMove()
            show(max(index - 1, 0))
            isFocused = true
        }
        .tvFocusSection()
        .task(id: items.map(\.id)) {
            // Every page's backdrop, the one shown first, held for as long
            // as the hero is; pages no longer featured are let go. A page
            // drawn by `card` brings its own picture.
            guard card == nil else { return }
            let client = session.client
            var held = backdrops.filter { id, _ in items.contains { $0.id == id } }
            let order = items.indices.sorted { abs($0 - index) < abs($1 - index) }.map { items[$0] }
            for item in order where held[item.id] == nil {
                guard let url = HeroCard.imageURL(for: item, portrait: false, screenPixels: tvScreenPixels, client: client),
                      let image = await ImageStore.shared.image(for: url, client: client) else { continue }
                guard !Task.isCancelled else { return }
                held[item.id] = image
                backdrops[item.id] = image
            }
            backdrops = held
        }
        #else
        touchBanner
        #endif
    }

    #if !os(tvOS)
    /// One page of the touch and Mac banner.
    @ViewBuilder
    private func bannerPage(_ item: BaseItem, in size: CGSize) -> some View {
        if let card {
            card(item, false)
        } else {
            HeroCard(
                item: item,
                isFocused: false,
                isPortrait: size.height > size.width,
                screenPixels: pixels(size),
                tag: tag(item),
                action: action(item),
                onPlay: playButtonAction(item)
            )
        }
    }

    /// The Play button's own action where it's a button of its own (the
    /// Mac), nil where the whole banner is the button.
    private func playButtonAction(_ item: BaseItem) -> (() -> Void)? {
        #if os(macOS)
        return { select(item) }
        #else
        return nil
        #endif
    }

    /// What the hero prefetches for: the featured titles at a banner size.
    private struct PrefetchKey: Equatable {
        var ids: [String]
        var pixels: CGSize
    }

    /// A size in points as pixels on this screen.
    private func pixels(_ size: CGSize) -> CGSize {
        CGSize(width: size.width * displayScale, height: size.height * displayScale)
    }

    /// On touch screens the banner is swiped: each page is its own link, the
    /// scroll view pages between them, and the dots follow the page shown.
    private var touchBanner: some View {
        // Pages take the banner's measured size, which also says which way up
        // the phone is: the poster upright, the backdrop on its side. Both
        // are prefetched below, so rotating swaps from the cache.
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(items) { item in
                            #if os(macOS)
                            // Clicking the art, title or text opens the page; only the
                            // Play / Resume button inside the card plays.
                            bannerPage(item, in: proxy.size)
                                .contentShape(Rectangle())
                                .onTapGesture { open(item) }
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .id(item.id)
                            #else
                            Button {
                                select(item)
                            } label: {
                                bannerPage(item, in: proxy.size)
                            }
                            .buttonStyle(.plain)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .id(item.id)
                            #endif
                        }
                    }
                    .scrollTargetLayout()
                    #if os(macOS)
                    .offset(x: dragOffset)
                    #endif
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollID)
                .scrollIndicators(.hidden)
                #if os(macOS)
                // A mouse can't swipe: click, hold and drag pages it instead.
                // High priority, so letting go after a drag doesn't also open
                // the title; a click without moving still does.
                .highPriorityGesture(heroDrag(pageWidth: proxy.size.width))
                #endif
                // The page changes only when a swipe comes to rest. A rotation
                // keeps the old offset in points, which lands between pages
                // at the new width, so it must not count as a page change.
                .onScrollPhaseChange { _, phase in
                    guard phase == .idle, let id = scrollID,
                          let page = items.firstIndex(where: { $0.id == id }) else { return }
                    index = page
                }
                // After a rotation, snap straight back to the page that was showing.
                .onChange(of: proxy.size) { _, _ in
                    guard items.indices.contains(index) else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        reader.scrollTo(items[index].id, anchor: .leading)
                    }
                }
            }
            .task(id: PrefetchKey(ids: items.map(\.id), pixels: pixels(proxy.size))) {
                // Every page's picture for this way up and for the phone turned
                // 90 degrees, at the sizes the cards will ask for, so rotating
                // swaps from the cache.
                let client = session.client
                let upright = pixels(proxy.size)
                let turned = CGSize(width: upright.height, height: upright.width)
                let urls = items.flatMap { item in
                    [upright, turned].compactMap { size in
                        HeroCard.imageURL(for: item, portrait: size.height > size.width, screenPixels: size, client: client)
                    }
                }
                ImageStore.shared.prefetch(urls, client: client)
            }
        }
        .containerRelativeFrame(.vertical)
        .overlay(alignment: .bottomTrailing) {
            if items.count > 1 {
                PageDots(count: items.count, index: index)
                    .padding(.trailing, Lockup.screenPadding)
                    .padding(.bottom, HeroCard.bottomPadding - 40)
            }
        }
        .onAppear { scrollID = items.first?.id }
        .onChange(of: items) { oldItems, newItems in
            let currentID = oldItems.indices.contains(index) ? oldItems[index].id : nil
            index = currentID.flatMap { id in newItems.firstIndex { $0.id == id } } ?? 0
            scrollID = newItems.indices.contains(index) ? newItems[index].id : newItems.first?.id
        }
        #if os(macOS)
        .onChange(of: keyboardPage) { _, page in
            if let page { show(page) }
        }
        .onChange(of: index) { _, page in pageChanged(page) }
        #endif
    }
    #endif

    #if os(macOS)
    /// Follows the pointer while dragging, then pages on when the drag went
    /// a quarter of the way (or was flung that far), else springs back. Past
    /// the first or last page it gives a little, like a scroll view's edge.
    /// A mostly vertical drag isn't the banner's: the page scrolls with it
    /// (see `DragScroller`).
    private func heroDrag(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // A mostly vertical drag doesn't slide the pages.
                guard abs(value.translation.width) >= abs(value.translation.height) else {
                    dragOffset = 0
                    return
                }
                let distance = value.translation.width
                let pastEdge = (index == 0 && distance > 0) || (index == items.count - 1 && distance < 0)
                dragOffset = pastEdge ? distance / 3 : distance
            }
            .onEnded { value in
                // A vertical drag leaves the banner where it is.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let threshold = pageWidth / 4
                let flung = value.predictedEndTranslation.width
                var target = index
                if value.translation.width < -threshold || flung < -pageWidth / 2 {
                    target = min(index + 1, items.count - 1)
                } else if value.translation.width > threshold || flung > pageWidth / 2 {
                    target = max(index - 1, 0)
                }
                withAnimation(.easeInOut(duration: 0.35)) {
                    dragOffset = 0
                }
                show(target)
            }
    }
    #endif

    #if os(tvOS)
    /// An Apple TV screen in points, always. The hero's height is set from
    /// it: sized from the page, Home's and Upcoming's heroes were first laid
    /// out before the page went full-screen (1080 less the 60-point margins
    /// top and bottom), and their cards kept that height, leaving bars
    /// above and below. The width still follows the page: a fixed 1920
    /// beside the 2-point focus guard made the row wider than the screen.
    static let tvScreen = CGSize(width: 1920, height: 1080)

    /// The hero's backdrops are asked for at 1080p, even on a 4K set: a 4K
    /// backdrop is about 33 MB decoded and slow to fetch, and under the
    /// hero's gradients 1080p looks the same.
    private var tvScreenPixels: CGSize {
        CGSize(width: 1920, height: 1080)
    }
    #endif

    private var banner: some View {
        Button {
            select(current)
        } label: {
            ScrollView(.horizontal) {
                // Every page made up front, each with its held backdrop, so
                // none is still being made (or fetching) as it slides in.
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        #if os(tvOS)
                        Group {
                            if let card {
                                card(item, isFocused)
                            } else {
                                HeroCard(item: item, isFocused: isFocused, screenPixels: tvScreenPixels, backdrop: backdrops[item.id], tag: tag(item), action: action(item))
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                        .frame(height: Self.tvScreen.height)
                        .id(item.id)
                        #else
                        Group {
                            if let card {
                                card(item, isFocused)
                            } else {
                                HeroCard(item: item, isFocused: isFocused, tag: tag(item), action: action(item))
                            }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(item.id)
                        #endif
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollID)
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            // Fill the whole screen; the shelves start below the fold.
            #if os(tvOS)
            .frame(height: Self.tvScreen.height)
            #else
            .containerRelativeFrame(.vertical)
            #endif
            .overlay(alignment: .bottomTrailing) {
                if items.count > 1 {
                    PageDots(count: items.count, index: index)
                        .padding(.trailing, 80)
                        .padding(.bottom, 40)
                }
            }
        }
        .buttonStyle(HeroButtonStyle())
        .focused($isFocused)
        #if os(tvOS)
        .onMoveCommand { direction in
            #if DEBUG
            print("DEBUG focus: hero onMoveCommand \(direction)")
            #endif
            switch direction {
            case .right:
                noteHorizontalMove()
                guard Date().timeIntervalSince(focusGainedAt) > 0.4 else { return }
                show(min(index + 1, items.count - 1))
            case .left:
                noteHorizontalMove()
            case .down:
                // Ignore a down that follows a sideways move, and hold one briefly
                // so a sideways move arriving just after it can cancel it.
                guard Date().timeIntervalSince(lastHorizontalMoveAt) > 0.5 else { return }
                // Likewise just after the banner gains focus: the right click
                // that brings focus in from the sidebar goes to the sidebar,
                // not here, but its stray down swipe arrives here.
                guard Date().timeIntervalSince(focusGainedAt) > 0.5 else { return }
                pendingMoveDown?.cancel()
                pendingMoveDown = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    moveDown()
                }
            default:
                break
            }
        }
        #endif
        .onChange(of: isFocused) { _, focused in
            if focused { focusGainedAt = Date() }
            focusChanged(focused)
        }
        .accessibilityLabel(current.kind == .episode ? [current.seriesName, current.episodeCode, current.name].compactMap { $0 }.joined(separator: ", ") : current.displayTitle)
        .accessibilityHint(items.count > 1 ? "Swipe left or right for more" : "")
        .onAppear {
            scrollID = items.first?.id
        }
        .onChange(of: items) { oldItems, newItems in
            // Keep the page the viewer was on if that title is still featured.
            let currentID = oldItems.indices.contains(index) ? oldItems[index].id : nil
            index = currentID.flatMap { id in newItems.firstIndex { $0.id == id } } ?? 0
            scrollID = newItems.indices.contains(index) ? newItems[index].id : newItems.first?.id
        }
    }

    private func show(_ newIndex: Int) {
        guard newIndex != index, items.indices.contains(newIndex) else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            index = newIndex
            scrollID = items[newIndex].id
        }
    }
}

struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { dot in
                Circle()
                    .fill(.white.opacity(dot == index ? 0.95 : 0.35))
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.35), in: Capsule())
        .accessibilityHidden(true)
    }
}

struct HeroCard: View {
    let item: BaseItem
    let isFocused: Bool
    /// Whether the banner is taller than it is wide (a phone held upright).
    var isPortrait = false
    /// The banner's size in pixels, which sets the size of picture to fetch.
    var screenPixels: CGSize = .zero
    /// The picture already decoded (Apple TV's hero holds its own), drawn
    /// as is rather than looked up.
    var backdrop: PlatformImage? = nil
    /// A short label over the title (Upcoming's countdown).
    var tag: String? = nil
    /// The button's wording and symbol, in place of Play / Resume.
    var action: Action? = nil
    /// Where the Play button is a button of its own, what it does; nil where
    /// the whole banner is the button.
    var onPlay: (() -> Void)? = nil

    struct Action {
        var title: String
        var systemImage: String
    }

    @Environment(AppSession.self) private var session

    /// The banner's picture: the wide backdrop, or on a touch screen held
    /// upright the poster, which fills a tall screen instead of a thin slice
    /// of the backdrop. Shared with the carousel's prefetch so both cache
    /// the same URLs.
    ///
    /// `screenPixels` is the banner's size in pixels; the picture is asked
    /// for at just the size that fills it without being enlarged: on tvOS
    /// 3840 wide on a 4K TV and 1920 on a 1080p one.
    static func imageURL(for item: BaseItem, portrait: Bool, screenPixels: CGSize = .zero, client: (any MediaServer)?) -> URL? {
        #if os(tvOS)
        return client?.backdropURL(for: item, width: screenPixels.width > 0 ? Int(screenPixels.width) : Lockup.fullScreenImageWidth(displayScale: 1))
        #else
        guard let client else { return nil }
        if portrait {
            // A 2:3 poster filling the screen is as tall as the screen, or
            // taller when the screen is wide enough to need the extra width.
            let height = bucketed(max(screenPixels.height, screenPixels.width * 1.5), fallback: 2800)
            // An episode's own picture is a wide still; use its series' poster.
            if item.kind == .episode {
                if let series = item.seriesId, let tag = item.seriesPrimaryImageTag {
                    return client.imageURL(itemId: series, kind: .primary, tag: tag, maxHeight: height)
                }
            } else if let poster = posterURL(for: item, maxHeight: height, client: client) {
                return poster
            }
        }
        // A 16:9 backdrop filling the screen: as wide as the screen, or wider.
        let width = bucketed(max(screenPixels.width, screenPixels.height * 16 / 9), fallback: 2800)
        return client.backdropURL(for: item, width: width)
        #endif
    }

    #if !os(tvOS)
    /// Rounds a pixel length up to the next 100, so small layout changes keep
    /// the same URL and the cache still hits.
    private static func bucketed(_ pixels: CGFloat, fallback: Int) -> Int {
        guard pixels > 0 else { return fallback }
        return Int((pixels / 100).rounded(.up)) * 100
    }

    /// `JellyfinClient.posterURL` limits by width; the hero needs a height.
    private static func posterURL(for item: BaseItem, maxHeight: Int, client: any MediaServer) -> URL? {
        if let tag = item.imageTags?["Primary"] {
            return client.imageURL(itemId: item.id, kind: .primary, tag: tag, maxHeight: maxHeight)
        }
        if let series = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return client.imageURL(itemId: series, kind: .primary, tag: tag, maxHeight: maxHeight)
        }
        return nil
    }
    #endif

    #if os(tvOS)
    private static let titleSize: CGFloat = 64
    private static let logoSize = CGSize(width: 520, height: 180)
    private static let overviewWidth: CGFloat = 900
    static let bottomPadding: CGFloat = 90
    #else
    private static let titleSize: CGFloat = 34
    private static let logoSize = CGSize(width: 260, height: 90)
    private static let overviewWidth: CGFloat = 600
    /// Clears the floating tab bar, which sits over the bottom of the banner.
    static let bottomPadding: CGFloat = 110
    #endif

    /// The white Play / Resume capsule.
    private var playPill: some View {
        HStack(spacing: 14) {
            if let action {
                Image(systemName: action.systemImage)
                Text(action.title)
            } else {
                Image(systemName: "play.fill")
                Text(item.canResume ? "Resume" : (item.kind == .series ? "Watch Now" : "Play"))
                if let remaining = item.remainingText {
                    Text("·  \(remaining)").foregroundStyle(.secondary)
                }
            }
        }
        .font(.headline)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.white.opacity(isFocused ? 1 : 0.9), in: Capsule())
        .foregroundStyle(.black)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let backdrop {
                    Color.clear
                        .overlay {
                            Image(platformImage: backdrop)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                } else {
                    RemoteImage(url: Self.imageURL(for: item, portrait: isPortrait, screenPixels: screenPixels, client: session.client), systemImage: "film")
                }
            }
            .extendsUnderSidebar()
            LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.9)], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center)

            VStack(alignment: .leading, spacing: 18) {
                if let tag {
                    // White with black text, readable over any backdrop.
                    Text(tag.uppercased())
                        .font(.headline.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.white, in: Capsule())
                }
                if let logo = session.client?.logoURL(for: item) {
                    RemoteImage(url: logo, contentMode: .fit) { EmptyView() }
                        .frame(maxWidth: Self.logoSize.width, maxHeight: Self.logoSize.height, alignment: .leading)
                } else {
                    Text(item.kind == .episode ? (item.seriesName ?? item.displayTitle) : item.displayTitle)
                        .font(.system(size: Self.titleSize, weight: .bold))
                        .lineLimit(2)
                }
                if item.kind == .episode {
                    Text([item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · "))
                        .font(.title3.weight(.semibold))
                }
                MetadataLine(item: item)
                if let overview = item.overview {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: Self.overviewWidth, alignment: .leading)
                }
                if let onPlay {
                    Button(action: onPlay) { playPill }
                        .buttonStyle(.plain)
                } else {
                    playPill
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.bottom, Self.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// A gentle scale with no card chrome, so the banner stays full-bleed.
struct HeroButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.01 : 1)
            .brightness(isFocused ? 0.05 : 0)
            .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}
