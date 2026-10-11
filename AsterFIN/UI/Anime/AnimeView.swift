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
    private(set) var shelves: [HomeModel.LibraryShelf] = []
    private(set) var isLoading = false

    func load(client: JellyfinClient, libraries: [BaseItem]) async {
        isLoading = shelves.isEmpty && !libraries.isEmpty
        let ids = libraries.map(\.id)
        let showIds = libraries.filter { $0.collectionType == "tvshows" }.map(\.id)

        async let resume = Self.merged(ids) { try await client.resume(limit: 20, parentId: $0) }
        async let next = Self.merged(showIds) { try await client.nextUp(limit: 20, parentId: $0) }
        async let latest = Self.recentlyAdded(client: client, libraries: libraries)
        async let browse = Self.shelves(client: client, libraries: libraries)

        // Newest first across libraries; ISO 8601 dates sort as text.
        let resumed = await resume
        continueWatching = Array(resumed.sorted { ($0.userData?.lastPlayedDate ?? "") > ($1.userData?.lastPlayedDate ?? "") }.prefix(20))
        nextUp = Array(await next.filter { episode in !resumed.contains { $0.id == episode.id } }.prefix(20))
        recentlyAdded = await latest
        shelves = await browse
        isLoading = false
    }

    /// The newest series and films across the anime libraries. Home's
    /// Recently Added Anime shelf uses this too.
    static func recentlyAdded(client: JellyfinClient, libraries: [BaseItem], limit: Int = 20) async -> [BaseItem] {
        let all = await merged(libraries.map(\.id)) { try await client.latest(parentId: $0, limit: limit) }
        let newest = all.sorted { ($0.dateCreated ?? "") > ($1.dateCreated ?? "") }

        // Jellyfin reports a season when new episodes land in it. Show its
        // series instead, as the library rows below do, and each show once.
        let seriesIds = Set(newest.filter { $0.kind == .season }.compactMap(\.seriesId))
        var series: [String: BaseItem] = [:]
        if !seriesIds.isEmpty, let found = try? await client.items(["ids": seriesIds.joined(separator: ",")]) {
            series = Dictionary(found.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var shown: [BaseItem] = []
        for item in newest {
            let entry = item.kind == .season ? (item.seriesId.flatMap { series[$0] } ?? item) : item
            if !shown.contains(where: { $0.id == entry.id }) { shown.append(entry) }
        }
        return Array(shown.prefix(limit))
    }

    /// A row of each library's titles, A to Z, in the server's library order.
    private static func shelves(client: JellyfinClient, libraries: [BaseItem]) async -> [HomeModel.LibraryShelf] {
        await withTaskGroup(of: (Int, HomeModel.LibraryShelf?).self) { group in
            for (position, library) in libraries.enumerated() {
                group.addTask {
                    let result = try? await client.items([
                        "parentId": library.id,
                        "recursive": "true",
                        "includeItemTypes": library.collectionType == "movies" ? "Movie" : "Series",
                        "sortBy": "SortName",
                        "sortOrder": "Ascending",
                        "limit": "20",
                    ])
                    let items = result?.items ?? []
                    return (position, items.isEmpty ? nil : HomeModel.LibraryShelf(library: library, items: items))
                }
            }
            var found: [(Int, HomeModel.LibraryShelf)] = []
            for await (position, shelf) in group {
                if let shelf { found.append((position, shelf)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
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
    @State private var model = AnimeModel()

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 20) {
                Text("Anime")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.top, 40)

                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(80)
                }
                Shelf(title: "Continue Watching", items: model.continueWatching) { item in
                    LandscapeLockup(item: item)
                }
                Shelf(title: "Next Up", items: model.nextUp) { item in
                    LandscapeLockup(item: item)
                }
                Shelf(title: "Recently Added", items: model.recentlyAdded) { item in
                    LandscapeLockup(item: item)
                }
                ForEach(model.shelves) { shelf in
                    Shelf(title: shelf.library.displayTitle, items: shelf.items) { item in
                        PosterLockup(item: item)
                    }
                }
                // Each opens the whole library as a sortable grid.
                Shelf(title: "Libraries", items: session.animeLibraries) { library in
                    LibraryTile(library: library)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .task(id: session.animeLibraries.map(\.id)) { await reload() }
        .onChange(of: session.userDataRevision) { _, _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        guard let client = session.client else { return }
        await model.load(client: client, libraries: session.animeLibraries)
    }
}
