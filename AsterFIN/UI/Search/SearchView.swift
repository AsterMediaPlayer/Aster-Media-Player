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

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 20) {
                if query.isEmpty {
                    MessageView(systemImage: "magnifyingglass", title: "Search", detail: "Find movies, TV shows, episodes and music in your library.")
                        .frame(height: 500)
                } else if results.isEmpty, !isSearching {
                    MessageView(systemImage: "questionmark.circle", title: "No Results", detail: "Nothing matched \"\(query)\".")
                        .frame(height: 500)
                } else {
                    let shows = results.filter { $0.kind == .movie || $0.kind == .series }
                    let episodes = results.filter { $0.kind == .episode }
                    let albums = results.filter { $0.kind == .musicAlbum || $0.kind == .playlist }
                    let artists = results.filter { $0.kind == .musicArtist }
                    let songs = results.filter { $0.kind == .audio }
                    if !shows.isEmpty {
                        Text("Movies & TV Shows")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 80)
                            .padding(.top, 30)
                        ItemGrid(items: shows)
                    }
                    Shelf(title: "Episodes", items: episodes) { item in
                        LandscapeLockup(item: item)
                    }
                    Shelf(title: "Albums & Playlists", items: albums) { item in
                        SquareLockup(item: item)
                    }
                    Shelf(title: "Artists", items: artists, spacing: 28) { item in
                        ArtistLockup(artist: item)
                    }
                    Shelf(title: "Songs", items: songs) { song in
                        SquareLockup(item: song) {
                            guard let client = session.client else { return }
                            let start = songs.firstIndex(where: { $0.id == song.id }) ?? 0
                            session.music.play(songs, startingAt: start, client: client)
                        }
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
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
}
