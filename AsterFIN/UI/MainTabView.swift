//
//  MainTabView.swift
//  AsterFIN
//
//  The Apple TV app's sidebar navigation: Home, Movies, TV Shows, Music,
//  Live TV, Library, Settings and Search. Also lands Top Shelf links.
//

import SwiftUI

enum AppTab: Hashable {
    case home, movies, shows, anime, music, liveTV, library, settings, search
}

struct MainTabView: View {
    @Environment(AppSession.self) private var session
    @State private var hasLiveTV = false
    @State private var hasMusic = false
    @State private var tab: AppTab = .home
    @State private var homePath = NavigationPath()
    @State private var linkedPlayback: PlaybackRequest?

    var body: some View {
        @Bindable var player = session.music
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                BrowseStack(path: $homePath) { HomeView() }
            }
            Tab("Movies", systemImage: "film.fill", value: AppTab.movies) {
                BrowseStack { TypeGridView(kind: .movie) }
            }
            Tab("TV Shows", systemImage: "tv.fill", value: AppTab.shows) {
                BrowseStack { TypeGridView(kind: .series) }
            }
            if !session.animeLibraries.isEmpty {
                Tab("Anime", systemImage: "sparkles", value: AppTab.anime) {
                    BrowseStack { AnimeView() }
                }
            }
            if hasMusic {
                Tab("Music", systemImage: "music.note", value: AppTab.music) {
                    BrowseStack { MusicView() }
                }
            }
            if hasLiveTV {
                Tab("Live TV", systemImage: "antenna.radiowaves.left.and.right", value: AppTab.liveTV) {
                    BrowseStack { LiveTVView() }
                }
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                BrowseStack { LibraryView() }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                BrowseStack { SettingsView() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                BrowseStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
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
            hasLiveTV = views.contains { $0.collectionType == "livetv" }
            hasMusic = views.contains { $0.collectionType == "music" }
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
