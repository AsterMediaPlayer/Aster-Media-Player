//
//  HomeView.swift
//  AsterFIN
//
//  The Apple TV app's Home: a featured banner, then shelves of what to watch.
//

import SwiftUI

@Observable
final class HomeModel {
    struct LibraryShelf: Identifiable, Hashable {
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

    /// Anime libraries are found after Home first loads. Fills the anime
    /// row and swaps the Movies or TV row only if it came from one of them,
    /// leaving Continue Watching and the hero alone so focus stays put.
    func applyAnimeLibraries(_ anime: [BaseItem], client: JellyfinClient) async {
        let animeIds = Set(anime.map(\.id))
        if let id = moviesLibraryId, animeIds.contains(id) {
            moviesLibraryId = libraries.first { $0.collectionType == "movies" && !animeIds.contains($0.id) }?.id
            latestMovies = (try? await client.latest(parentId: moviesLibraryId, limit: 20, includeTypes: "Movie")) ?? []
        }
        if let id = showsLibraryId, animeIds.contains(id) {
            showsLibraryId = libraries.first { $0.collectionType == "tvshows" && !animeIds.contains($0.id) }?.id
            latestShows = (try? await client.latest(parentId: showsLibraryId, limit: 20, includeTypes: "Series")) ?? []
        }
        latestAnime = await AnimeModel.recentlyAdded(client: client, libraries: anime)
    }
    private(set) var libraryShelves: [LibraryShelf] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func load(client: JellyfinClient, animeLibraries: [BaseItem] = []) async {
        isLoading = featured.isEmpty
        errorMessage = nil
        do {
            async let resume = client.resume(limit: 20)
            async let next = client.nextUp(limit: 20)
            async let views = client.userViews()
            let (resumeItems, nextItems, libraries) = try await (resume, next, views)
            continueWatching = resumeItems
            nextUp = nextItems.filter { episode in !resumeItems.contains { $0.id == episode.id } }

            // Anime has its own row, so the Movies and TV rows skip its libraries.
            let animeIds = Set(animeLibraries.map(\.id))
            let movieLibraries = libraries.filter { $0.collectionType == "movies" && !animeIds.contains($0.id) }
            let showLibraries = libraries.filter { $0.collectionType == "tvshows" && !animeIds.contains($0.id) }
            moviesLibraryId = movieLibraries.first?.id
            showsLibraryId = showLibraries.first?.id
            self.libraries = libraries
            async let movies = client.latest(parentId: moviesLibraryId, limit: 20, includeTypes: "Movie")
            async let shows = client.latest(parentId: showsLibraryId, limit: 20, includeTypes: "Series")
            async let anime = AnimeModel.recentlyAdded(client: client, libraries: animeLibraries)
            latestMovies = (try? await movies) ?? []
            latestShows = (try? await shows) ?? []
            latestAnime = await anime

            var shelves: [LibraryShelf] = []
            for library in libraries where !["movies", "tvshows", "music", "playlists", "livetv", "books", "photos"].contains(library.collectionType ?? "") {
                if let items = try? await client.latest(parentId: library.id, limit: 20), !items.isEmpty {
                    shelves.append(LibraryShelf(library: library, items: items))
                }
            }
            libraryShelves = shelves

            var picks: [BaseItem] = []
            for item in continueWatching.prefix(3) + nextUp.prefix(3) + latestMovies.prefix(4) + latestShows.prefix(3) where !picks.contains(where: { $0.id == item.id }) {
                picks.append(item)
            }
            featured = Array(picks.prefix(8))
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct HomeView: View {
    @Environment(AppSession.self) private var session
    @State private var model = HomeModel()
    @FocusState private var focusedLockup: String?

    /// The first non-empty shelf and its first item: where focus goes when
    /// pressing down from the hero. Only that shelf binds the focus state, because
    /// the same title can appear in several shelves and the binding is keyed by
    /// item id.
    private var firstShelf: (key: String, itemID: String)? {
        let named: [(String, [BaseItem])] = [
            ("continue", model.continueWatching),
            ("nextUp", model.nextUp),
            ("movies", model.latestMovies),
            ("shows", model.latestShows),
            ("anime", model.latestAnime),
        ] + model.libraryShelves.map { ($0.id, $0.items) }
        for (key, items) in named {
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
                                if let target = firstShelfItemID { focusedLockup = target }
                            }, focusChanged: { focused in
                                #if DEBUG
                                print("DEBUG focus: hero focused=\(focused)")
                                #endif
                                // Once the hero has focus again, forget the shelf target so a
                                // re-rendered poster cannot pull focus back down later.
                                if focused { focusedLockup = nil }
                            })
                        }
                        Shelf(title: "Continue Watching", items: model.continueWatching) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "continue"))
                        }
                        Shelf(title: "Up Next", items: model.nextUp) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "nextUp"))
                        }
                        Shelf(title: "Recently Added Movies", items: model.latestMovies) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "movies"))
                        }
                        Shelf(title: "Recently Added TV Shows", items: model.latestShows) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "shows"))
                        }
                        Shelf(title: "Recently Added Anime", items: model.latestAnime) { item in
                            LandscapeLockup(item: item, focus: lockupFocus(for: "anime"))
                        }
                        ForEach(model.libraryShelves) { shelf in
                            Shelf(title: shelf.library.displayTitle, items: shelf.items) { item in
                                LandscapeLockup(item: item, focus: lockupFocus(for: shelf.id))
                            }
                        }
                    }
                    .padding(.bottom, 80)
                }
                .scrollClipDisabled()
                .ignoresSafeArea()
            }
        }
    }

    private func reload() async {
        guard let client = session.client else { return }
        await model.load(client: client, animeLibraries: session.animeLibraries)
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

    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var index = 0
    @State private var scrollID: String?
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

    private var current: BaseItem { items[min(index, items.count - 1)] }

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
        .task(id: "\(index)|\(items.map(\.id))|\(displayScale)") {
            // The page shown and those either side, at the TV's resolution,
            // so a slide to either finds its backdrop already loaded.
            guard !items.isEmpty else { return }
            let client = session.client
            let nearby = (index - 1 ... index + 1).compactMap { items.indices.contains($0) ? items[$0] : nil }
            let urls = nearby.compactMap { HeroCard.imageURL(for: $0, portrait: false, screenPixels: tvScreenPixels, client: client) }
            ImageStore.shared.prefetch(urls, client: client)
        }
        #else
        touchBanner
        #endif
    }

    #if !os(tvOS)
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
                            NavigationLink(value: item) {
                                HeroCard(
                                    item: item,
                                    isFocused: false,
                                    isPortrait: proxy.size.height > proxy.size.width,
                                    screenPixels: pixels(proxy.size)
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollID)
                .scrollIndicators(.hidden)
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
    }
    #endif

    #if os(tvOS)
    /// The TV's pixels: tvOS lays out 1920 by 1080 points at a scale of 2 on
    /// a 4K set and 1 on a 1080p one, so the backdrop is asked for at the
    /// resolution actually shown.
    private var tvScreenPixels: CGSize {
        CGSize(width: 1920 * displayScale, height: 1080 * displayScale)
    }
    #endif

    private var banner: some View {
        NavigationLink(value: current) {
            ScrollView(.horizontal) {
                // Lazy: a decoded 4K backdrop is about 33 MB, too much to hold
                // for every page at once. The pages beside the one shown are
                // prefetched below, so sliding to them doesn't wait.
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        #if os(tvOS)
                        HeroCard(item: item, isFocused: isFocused, screenPixels: tvScreenPixels)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(item.id)
                        #else
                        HeroCard(item: item, isFocused: isFocused)
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
            .containerRelativeFrame(.vertical)
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
        .onAppear { scrollID = items.first?.id }
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

    @Environment(AppSession.self) private var session

    /// The banner's picture: the wide backdrop, or on a touch screen held
    /// upright the poster, which fills a tall screen instead of a thin slice
    /// of the backdrop. Shared with the carousel's prefetch so both cache
    /// the same URLs.
    ///
    /// `screenPixels` is the banner's size in pixels; the picture is asked
    /// for at just the size that fills it without being enlarged: on tvOS
    /// 3840 wide on a 4K TV and 1920 on a 1080p one.
    static func imageURL(for item: BaseItem, portrait: Bool, screenPixels: CGSize = .zero, client: JellyfinClient?) -> URL? {
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
    private static func posterURL(for item: BaseItem, maxHeight: Int, client: JellyfinClient) -> URL? {
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

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: Self.imageURL(for: item, portrait: isPortrait, screenPixels: screenPixels, client: session.client), systemImage: "film")
            LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.9)], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center)

            VStack(alignment: .leading, spacing: 18) {
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
                HStack(spacing: 14) {
                    Image(systemName: "play.fill")
                    Text(item.canResume ? "Resume" : (item.kind == .series ? "Watch Now" : "Play"))
                    if let remaining = item.remainingText {
                        Text("·  \(remaining)").foregroundStyle(.secondary)
                    }
                }
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(.white.opacity(isFocused ? 1 : 0.9), in: Capsule())
                .foregroundStyle(.black)
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
