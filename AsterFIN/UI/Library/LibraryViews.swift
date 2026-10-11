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
            LazyVStack(alignment: .leading, spacing: 30) {
                Text("Library")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, 80)
                    .padding(.top, 40)

                if !libraries.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 36) {
                            ForEach(libraries) { library in
                                LibraryTile(library: library)
                            }
                        }
                        .padding(.horizontal, 80)
                        .padding(.vertical, 30)
                    }
                    .scrollClipDisabled()
                    .focusSection()
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
                    Text(errorMessage).foregroundStyle(.red).padding(.horizontal, 80)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            libraries = try await client.userViews().filter { $0.collectionType != "playlists" }
            favorites = try await client.items([
                "recursive": "true",
                "filters": "IsFavorite",
                "includeItemTypes": "Movie,Series,Episode",
                "sortBy": "SortName",
                "limit": "40",
            ]).items
            videoPlaylists = (try? await client.playlists(mediaType: "Video")) ?? []
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

    var query: (sortBy: String, order: String) {
        switch self {
        case .name: return ("SortName", "Ascending")
        case .dateAdded: return ("DateCreated,SortName", "Descending")
        case .releaseDate: return ("PremiereDate,SortName", "Descending")
        case .rating: return ("CommunityRating,SortName", "Descending")
        }
    }
}

@Observable
final class GridModel {
    private(set) var items: [BaseItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var totalCount = 0
    private var loadedWith: String?
    /// How far into the server's results loading has got, counting items
    /// left out by `excluding`, so pages carry on from the right place.
    private var fetched = 0

    /// Loads the next page. Items whose ids are in `excluding` are skipped,
    /// e.g. anime, which has its own tab.
    func load(client: JellyfinClient, query: [String: String?], excluding: Set<String> = [], reset: Bool = false) async {
        let key = query.description + "|\(excluding.count)"
        if reset || loadedWith != key {
            items = []
            fetched = 0
            loadedWith = key
        }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        var merged = query
        merged["startIndex"] = String(fetched)
        merged["limit"] = "100"
        do {
            let result = try await client.items(merged)
            fetched += result.items.count
            let kept = result.items.filter { new in !excluding.contains(new.id) && !items.contains { $0.id == new.id } }
            items.append(contentsOf: kept)
            totalCount = result.totalRecordCount ?? fetched
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    var hasMore: Bool { fetched < totalCount }
}

/// Everything inside one library or collection, as a grid with sort options.
struct LibraryGridView: View {
    let parent: BaseItem

    @Environment(AppSession.self) private var session
    @State private var model = GridModel()
    @State private var sort: LibrarySort = .name

    private var landscape: Bool {
        parent.collectionType == "homevideos" || parent.collectionType == "tvshows" && false
    }

    private var query: [String: String?] {
        var query: [String: String?] = [
            "parentId": parent.id,
            "sortBy": sort.query.sortBy,
            "sortOrder": sort.query.order,
        ]
        switch parent.collectionType {
        case "movies":
            query["includeItemTypes"] = "Movie"
            query["recursive"] = "true"
        case "tvshows":
            query["includeItemTypes"] = "Series"
            query["recursive"] = "true"
        case "boxsets":
            query["includeItemTypes"] = "BoxSet"
            query["recursive"] = "true"
        default:
            break
        }
        return query
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
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
                .padding(.horizontal, 80)
                .padding(.top, 40)

                if model.items.isEmpty, let error = model.errorMessage {
                    MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                        .frame(height: 600)
                } else if model.items.isEmpty, !model.isLoading {
                    MessageView(systemImage: "tray", title: "Nothing here yet")
                        .frame(height: 600)
                } else {
                    ItemGrid(items: model.items, landscape: landscape)
                    if model.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(40)
                            .task { await load() }
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .task(id: sort) { await load(reset: true) }
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

    private var title: String { kind == .movie ? "Movies" : "TV Shows" }

    private var query: [String: String?] {
        [
            "includeItemTypes": kind.rawValue,
            "recursive": "true",
            "sortBy": sort.query.sortBy,
            "sortOrder": sort.query.order,
        ]
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
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
                .padding(.horizontal, 80)
                .padding(.top, 40)

                Shelf(title: "Recently Added", items: recent) { item in
                    LandscapeLockup(item: item)
                }

                if model.items.isEmpty, let error = model.errorMessage {
                    MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                        .frame(height: 500)
                } else {
                    Text("All \(title)")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 80)
                        .padding(.top, 20)
                    ItemGrid(items: model.items)
                    if model.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(40)
                            .task { await load() }
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        // Reloads once anime detection finishes, so its titles drop out.
        .task(id: "\(sort.rawValue)|\(session.animeItemIds.count)") { await load(reset: true) }
        .task(id: session.animeItemIds.count) {
            guard let client = session.client else { return }
            // Ask for extra, as anime ones are taken out.
            let latest = (try? await client.latest(parentId: nil, limit: 40, includeTypes: kind.rawValue)) ?? []
            recent = Array(latest.filter { !session.animeItemIds.contains($0.id) }.prefix(20))
        }
    }

    private func load(reset: Bool = false) async {
        guard let client = session.client else { return }
        await model.load(client: client, query: query, excluding: session.animeItemIds, reset: reset)
    }
}

// MARK: - People

struct PersonView: View {
    let person: PersonInfo

    @Environment(AppSession.self) private var session
    @State private var items: [BaseItem] = []
    @State private var details: BaseItem?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top, spacing: 40) {
                    RemoteImage(url: session.client?.personImageURL(person, width: 500), systemImage: "person.fill")
                        .frame(width: 260, height: 260)
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
                .padding(.horizontal, 80)
                .padding(.top, 40)

                Text("Filmography")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 80)
                ItemGrid(items: items)
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .task {
            guard let client = session.client else { return }
            details = try? await client.item(person.id)
            items = (try? await client.items([
                "personIds": person.id,
                "recursive": "true",
                "includeItemTypes": "Movie,Series",
                "sortBy": "PremiereDate,SortName",
                "sortOrder": "Descending",
            ]).items) ?? []
        }
    }
}
