//
//  MainTabView.swift
//  AsterFIN
//
//  The Apple TV app's sidebar navigation: Home, Movies, TV Shows, Music,
//  Live TV, Library, Settings and Search. Also lands Top Shelf links.
//

import SwiftUI

enum AppTab: String, CaseIterable, Hashable {
    case home, movies, shows, anime, music, liveTV, library, downloads, settings, search

    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .anime: "Anime"
        case .music: "Music"
        case .liveTV: "Live TV"
        case .library: "Library"
        case .downloads: "Downloads"
        case .settings: "Settings"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film.fill"
        case .shows: "tv.fill"
        case .anime: "sparkles"
        case .music: "music.note"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .library: "square.stack.fill"
        case .downloads: "arrow.down.circle.fill"
        case .settings: "gearshape.fill"
        case .search: "magnifyingglass"
        }
    }
}

/// The tab order and hidden tabs chosen in Settings › Tab Bar on iPhone and
/// iPad, stored as comma-separated tab names. Tabs missing from a stored
/// order (new ones, say) follow in their usual place.
enum TabLayout {
    /// Home is where the app opens, and Settings is where a hidden tab is
    /// brought back, so neither can be hidden.
    static let alwaysShown: Set<AppTab> = [.home, .settings]

    static func order(from stored: String) -> [AppTab] {
        let saved = stored.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }
        var seen = Set<AppTab>()
        return (saved + AppTab.allCases).filter { seen.insert($0).inserted }
    }

    static func hidden(from stored: String) -> Set<AppTab> {
        Set(stored.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }).subtracting(alwaysShown)
    }

    static func encode(_ tabs: some Sequence<AppTab>) -> String {
        tabs.map(\.rawValue).joined(separator: ",")
    }
}

struct MainTabView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.tabOrderKey) private var tabOrder = ""
    @AppStorage(AppSettings.hiddenTabsKey) private var hiddenTabs = ""
    @AppStorage(AppSettings.downloadsEnabledKey) private var downloadsEnabled = true
    @State private var tab: AppTab = .home
    @State private var homePath = NavigationPath()
    @State private var linkedPlayback: PlaybackRequest?

    /// The tabs to show, in order: tvOS's fixed sidebar, or on iPhone and
    /// iPad the viewer's choice. Tabs the server has nothing for are left out.
    private var shownTabs: [AppTab] {
        #if os(tvOS)
        let order = AppTab.allCases
        let hidden: Set<AppTab> = []
        #else
        let order = TabLayout.order(from: tabOrder)
        let hidden = TabLayout.hidden(from: hiddenTabs)
        #endif
        return order.filter { !hidden.contains($0) && session.hasContent(for: $0) && ($0 != .downloads || downloadsEnabled) }
    }

    var body: some View {
        @Bindable var player = session.music
        TabView(selection: $tab) {
            ForEach(shownTabs, id: \.self) { item in
                Tab(item.title, systemImage: item.systemImage, value: item, role: item == .search ? .search : nil) {
                    content(for: item)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // A tab hidden while showing hands over to Home.
        .onChange(of: shownTabs) { _, tabs in
            if !tabs.contains(tab) { tab = .home }
        }
        // Music can start from any tab (Search, Library), so the player is
        // presented from here rather than from the Music screen.
        .fullScreenCover(isPresented: $player.isNowPlayingPresented) {
            NowPlayingView()
        }
        // A second presentation needs its own host view.
        .background {
            Color.clear
                .fullScreenCover(item: $linkedPlayback, onDismiss: {
                    // Progress changed, so Continue Watching and Next Up should too.
                    session.userDataChanged()
                }) { request in
                    PlayerView(request: request) { linkedPlayback = nil }
                }
        }
        .task {
            guard let client = session.client else { return }
            await session.refreshUserConfiguration()
            let views = (try? await client.userViews()) ?? []
            session.noteLibraries(views)
            await session.detectAnimeLibraries(among: views)
            await followPendingLinks()
        }
        .onChange(of: session.router.pendingItemId) { _, _ in
            Task { await followPendingLinks() }
        }
        .onChange(of: session.router.pendingPlayItemId) { _, _ in
            Task { await followPendingLinks() }
        }
        .onChange(of: session.router.pendingPlayback) { _, _ in
            if let request = session.router.takePlayback() {
                linkedPlayback = request
            }
        }
    }

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .home: BrowseStack(path: $homePath) { HomeView() }
        case .movies: BrowseStack { TypeGridView(kind: .movie) }
        case .shows: BrowseStack { TypeGridView(kind: .series) }
        case .anime: BrowseStack { AnimeView() }
        case .music: BrowseStack { MusicView() }
        case .liveTV: BrowseStack { LiveTVView() }
        case .library: BrowseStack { LibraryView() }
        case .downloads:
            #if os(tvOS)
            EmptyView()
            #else
            BrowseStack { DownloadsView() }
            #endif
        case .settings: BrowseStack { SettingsView() }
        case .search: BrowseStack { SearchView() }
        }
    }

    /// Opens or plays whatever the Top Shelf asked for. Pages open on the Home
    /// tab's stack so Back returns somewhere sensible.
    private func followPendingLinks() async {
        guard let client = session.client else { return }
        if let id = session.router.pendingPlayItemId {
            session.router.clear()
            if let item = try? await client.item(id) {
                linkedPlayback = PlaybackRequest(itemId: item.id, startTicks: item.userData?.playbackPositionTicks ?? 0)
            }
            return
        }
        if let id = session.router.pendingItemId {
            session.router.clear()
            if let item = try? await client.item(id) {
                tab = .home
                homePath = NavigationPath()
                homePath.append(item)
            }
        }
    }
}

#if !os(tvOS)
/// On iPhone, tabs past the fifth sit under iOS's More tab, whose own
/// navigation bar stacks above the tab's. Once the tab has pushed a page,
/// this hides More's bar so there's one back button, the tab's, which steps
/// back a page. At the tab's top level More's "back to the list" shows again.
/// SwiftUI's toolbar visibility doesn't reach More's bar, so this goes
/// through UIKit; tabs that aren't under More are left alone.
private struct MoreBarHider: UIViewControllerRepresentable {
    var hidden: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // Usually in the hierarchy already, so the bar changes in the same
        // update as the push and the page slides in at its final height.
        // Animating it, or waiting a turn, let the page arrive low and then
        // jump up as the bar left. The first time, the controller joins the
        // hierarchy after this runs, so that one waits.
        if !Self.apply(hidden, from: controller) {
            let hidden = hidden
            DispatchQueue.main.async { [weak controller] in
                guard let controller else { return }
                Self.apply(hidden, from: controller)
            }
        }
    }

    /// Sets the More bar's visibility when `controller` is under More.
    /// Returns false when it isn't in a tab bar controller yet.
    @discardableResult
    private static func apply(_ hidden: Bool, from controller: UIViewController) -> Bool {
        guard let more = controller.tabBarController?.moreNavigationController else { return false }
        var ancestor = controller.parent
        while let current = ancestor, current !== more {
            ancestor = current.parent
        }
        if ancestor === more, more.isNavigationBarHidden != hidden {
            more.setNavigationBarHidden(hidden, animated: false)
        }
        return true
    }
}
#endif

/// Pushes an item's page onto the surrounding browse stack.
struct OpenItemAction {
    let open: (BaseItem) -> Void

    func callAsFunction(_ item: BaseItem) { open(item) }
}

extension EnvironmentValues {
    @Entry var openItem: OpenItemAction? = nil
}

/// A navigation stack that knows how to open items, libraries and people.
/// Given a path binding, the owner can push pages into it.
struct BrowseStack<Root: View>: View {
    var path: Binding<NavigationPath>? = nil
    @ViewBuilder var root: () -> Root
    /// Used when the owner does not supply a path.
    @State private var ownPath = NavigationPath()

    var body: some View {
        let path = path ?? $ownPath
        NavigationStack(path: path) { content }
            // Lets menus, which can't hold navigation links reliably, push pages.
            .environment(\.openItem, OpenItemAction { path.wrappedValue.append($0) })
            #if !os(tvOS)
            .background(MoreBarHider(hidden: !path.wrappedValue.isEmpty))
            #endif
    }

    private var content: some View {
        root()
            .navigationDestination(for: BaseItem.self) { item in
                destination(for: item)
            }
            .navigationDestination(for: PersonInfo.self) { person in
                PersonView(person: person)
            }
    }

    @ViewBuilder
    private func destination(for item: BaseItem) -> some View {
        switch item.kind {
        case .collectionFolder, .userView, .folder, .boxSet:
            if item.collectionType == "livetv" {
                LiveTVView()
            } else if item.collectionType == "music" {
                MusicView(library: item)
            } else {
                LibraryGridView(parent: item)
            }
        case .musicAlbum:
            AlbumView(item: item)
        case .playlist:
            if item.mediaType == "Video" {
                VideoPlaylistView(playlist: item)
            } else {
                AlbumView(item: item)
            }
        case .musicArtist:
            ArtistView(artist: item)
        case .audio:
            // A song opens its album, where it can be played in context.
            if let albumId = item.albumId {
                AlbumView(item: BaseItem(id: albumId, name: item.album, type: ItemKind.musicAlbum.rawValue))
            } else {
                ItemDetailView(item: item)
            }
        default:
            ItemDetailView(item: item)
        }
    }
}
