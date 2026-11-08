//
//  SearchView.swift
//  AsterFIN
//

import SwiftUI

struct SearchView: View {
    @Environment(AppSession.self) private var session
    @State private var query = ""
    @State private var results: [BaseItem] = []
    @State private var isSearching = false

    private var shows: [BaseItem] { results.filter { $0.kind == .movie || $0.kind == .series } }
    private var episodes: [BaseItem] { results.filter { $0.kind == .episode } }
    private var albums: [BaseItem] { results.filter { $0.kind == .musicAlbum || $0.kind == .playlist } }
    private var artists: [BaseItem] { results.filter { $0.kind == .musicArtist } }
    private var songs: [BaseItem] { results.filter { $0.kind == .audio } }

    /// Nothing to show yet, or nothing found.
    private var message: MessageView? {
        if query.isEmpty {
            return MessageView(systemImage: "magnifyingglass", title: "Search", detail: "Find movies, TV shows, episodes and music in your library.")
        } else if results.isEmpty, !isSearching {
            // With Seerr set up, what the library hasn't got is below to request.
            if AsterTracking.shared.seerr != nil {
                return MessageView(systemImage: "questionmark.circle", title: "Not in Your Library", detail: "Nothing in your library matched \"\(query)\". Anything you can request is below.")
            }
            return MessageView(systemImage: "questionmark.circle", title: "No Results", detail: "Nothing matched \"\(query)\".")
        }
        return nil
    }

    var body: some View {
        Group {
            #if os(tvOS)
            // The movies and shows as a collection grid, with the heading (or
            // the message) above and the music and episode rows below.
            TVCollectionGrid(
                sections: [IndexSection(key: "all", items: message == nil ? shows : [])],
                header: AnyView(header),
                footer: AnyView(footer)
            )
            #else
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header
                    if message == nil, !shows.isEmpty {
                        ItemGrid(items: shows)
                    }
                    footer
                }
                .padding(.bottom, Lockup.pageBottomPadding)
            }
            .scrollClipDisabled()
            #endif
        }
        .searchable(text: $query, prompt: "Movies, shows, episodes, music")
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, let client = session.client else {
                results = []
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isSearching = true
            results = (try? await client.search(term)) ?? []
            isSearching = false
        }
    }

    @ViewBuilder
    private var header: some View {
        if let message {
            message
                .frame(height: Lockup.emptyStateHeight)
        } else if !shows.isEmpty {
            Text("Movies & TV Shows")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, Lockup.screenPadding)
                .padding(.top, Lockup.sectionSpacing)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 20) {
            libraryFooter
            // Titles the server hasn't got, from Seerr once it's set up:
            // shown even when the library has nothing for the search.
            if !query.isEmpty {
                SeerrSearchShelf(query: query)
            }
        }
    }

    @ViewBuilder
    private var libraryFooter: some View {
        if message == nil {
            VStack(alignment: .leading, spacing: 20) {
                Shelf(title: "Episodes", items: episodes) { item in
                    LandscapeLockup(item: item)
                }
                Shelf(title: "Albums & Playlists", items: albums) { item in
                    SquareLockup(item: item)
                }
                Shelf(title: "Artists", items: artists, spacing: Lockup.personSpacing) { item in
                    ArtistLockup(artist: item)
                }
                Shelf(title: "Songs", items: songs) { song in
                    SquareLockup(item: song) {
                        guard let client = session.jellyfin else { return }
                        let songs = songs
                        let start = songs.firstIndex(where: { $0.id == song.id }) ?? 0
                        session.music.play(songs, startingAt: start, client: client)
                    }
                }
            }
        }
    }
}
