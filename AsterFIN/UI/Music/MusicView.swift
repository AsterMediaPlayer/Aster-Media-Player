//
//  MusicView.swift
//  AsterFIN
//
//  Music browsing: albums, artists, playlists and songs, with album and
//  artist pages and a Now Playing bar that opens the full player.
//

import SwiftUI

enum MusicSection: String, CaseIterable, Identifiable {
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"
    case songs = "Songs"

    var id: String { rawValue }
}

enum MusicSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case dateAdded = "Recently Added"
    case artist = "Artist"
    case year = "Year"

    var id: String { rawValue }

    var query: (sortBy: String, order: String) {
        switch self {
        case .name: return ("SortName", "Ascending")
        case .dateAdded: return ("DateCreated,SortName", "Descending")
        case .artist: return ("AlbumArtist,SortName", "Ascending")
        case .year: return ("ProductionYear,SortName", "Descending")
        }
    }
}

// MARK: - Music tab

struct MusicView: View {
    /// Limits browsing to one music library when opened from the Library tab.
    var library: BaseItem? = nil

    @Environment(AppSession.self) private var session
    @State private var section: MusicSection = .albums
    @State private var sort: MusicSort = .name
    @State private var recentAlbums: [BaseItem] = []
    @State private var recentlyPlayed: [BaseItem] = []
    @State private var favoriteAlbums: [BaseItem] = []

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(library?.displayTitle ?? "Music")
                        .font(.largeTitle.weight(.bold))
                    Spacer()
                    Picker("Section", selection: $section) {
                        ForEach(MusicSection.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 980)
                }
                .padding(.horizontal, 80)
                .padding(.top, 40)
                .focusSection()

                if session.music.current != nil {
                    NowPlayingBar()
                        .padding(.horizontal, 80)
                }

                if section == .albums {
                    Shelf(title: "Recently Added", items: recentAlbums) { album in
                        SquareLockup(item: album)
                    }
                    Shelf(title: "Recently Played", items: recentlyPlayed) { song in
                        SquareLockup(item: song) {
                            playSongs(recentlyPlayed, from: song)
                        }
                    }
                    Shelf(title: "Favorite Albums", items: favoriteAlbums) { album in
                        SquareLockup(item: album)
                    }
                }

                switch section {
                case .albums:
                    AlbumsGrid(parentId: library?.id, sort: $sort)
                case .artists:
                    ArtistsGrid(parentId: library?.id)
                case .playlists:
                    PlaylistsGrid(parentId: library?.id)
                case .songs:
                    SongsList(parentId: library?.id)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .task { await loadShelves() }
    }

    private func loadShelves() async {
        guard let client = session.client else { return }
        async let recent = client.latest(parentId: library?.id, limit: 20, includeTypes: "MusicAlbum")
        async let played = client.items([
            "parentId": library?.id,
            "includeItemTypes": "Audio",
            "recursive": "true",
            "filters": "IsPlayed",
            "sortBy": "DatePlayed",
            "sortOrder": "Descending",
            "limit": "20",
        ])
        async let favorites = client.items([
            "parentId": library?.id,
            "includeItemTypes": "MusicAlbum",
            "recursive": "true",
            "filters": "IsFavorite",
            "sortBy": "SortName",
            "limit": "20",
        ])
        recentAlbums = (try? await recent) ?? []
        recentlyPlayed = (try? await played.items) ?? []
        favoriteAlbums = (try? await favorites.items) ?? []
    }

    private func playSongs(_ songs: [BaseItem], from song: BaseItem) {
        guard let client = session.client else { return }
        let start = songs.firstIndex(where: { $0.id == song.id }) ?? 0
        session.music.play(songs, startingAt: start, client: client)
    }
}

// MARK: - Sections

struct AlbumsGrid: View {
    let parentId: String?
    @Binding var sort: MusicSort

    @Environment(AppSession.self) private var session
    @State private var model = GridModel()

    private var query: [String: String?] {
        [
            "parentId": parentId,
            "includeItemTypes": "MusicAlbum",
            "recursive": "true",
            "sortBy": sort.query.sortBy,
            "sortOrder": sort.query.order,
        ]
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("All Albums")
                .font(.title3.weight(.semibold))
            Spacer()
            Picker("Sort", selection: $sort) {
                ForEach(MusicSort.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 80)
        .padding(.top, 20)

        if model.items.isEmpty, let error = model.errorMessage {
            MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                .frame(height: 400)
        } else if model.items.isEmpty, !model.isLoading {
            MessageView(systemImage: "music.note", title: "No albums yet")
                .frame(height: 400)
        } else {
            SquareGrid(items: model.items)
            if model.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .task { await load() }
            }
        }
        Color.clear
            .frame(height: 1)
            .task(id: sort) { await load(reset: true) }
    }

    private func load(reset: Bool = false) async {
        guard let client = session.client else { return }
        await model.load(client: client, query: query, reset: reset)
    }
}

@Observable
final class ArtistsModel {
    private(set) var items: [BaseItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var totalCount = 0

    var hasMore: Bool { items.count < totalCount }

    func load(client: JellyfinClient, parentId: String?) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await client.albumArtists(parentId: parentId, startIndex: items.count, limit: 100)
            items.append(contentsOf: result.items.filter { new in !items.contains { $0.id == new.id } })
            totalCount = result.totalRecordCount ?? items.count
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct ArtistsGrid: View {
    let parentId: String?

    @Environment(AppSession.self) private var session
    @State private var model = ArtistsModel()

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 240), spacing: 40, alignment: .top)]

    var body: some View {
        Text("Artists")
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 80)
            .padding(.top, 20)

        if model.items.isEmpty, let error = model.errorMessage {
            MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                .frame(height: 400)
        } else if model.items.isEmpty, !model.isLoading {
            MessageView(systemImage: "music.mic", title: "No artists yet")
                .frame(height: 400)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 48) {
                ForEach(model.items) { artist in
                    ArtistLockup(artist: artist)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
            if model.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .task { await load() }
            }
        }
        Color.clear
            .frame(height: 1)
            .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        await model.load(client: client, parentId: parentId)
    }
}

struct PlaylistsGrid: View {
    let parentId: String?

    @Environment(AppSession.self) private var session
    @State private var model = GridModel()

    private var query: [String: String?] {
        [
            "includeItemTypes": "Playlist",
            "mediaTypes": "Audio",
            "recursive": "true",
            "sortBy": "SortName",
            "sortOrder": "Ascending",
        ]
    }

    var body: some View {
        Text("Playlists")
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 80)
            .padding(.top, 20)

        if model.items.isEmpty, let error = model.errorMessage {
            MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                .frame(height: 400)
        } else if model.items.isEmpty, !model.isLoading {
            MessageView(systemImage: "music.note.list", title: "No playlists yet", detail: "Create playlists in the Jellyfin web app and they will show up here.")
                .frame(height: 400)
        } else {
            SquareGrid(items: model.items)
            if model.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .task { await load() }
            }
        }
        Color.clear
            .frame(height: 1)
            .task { await load(reset: true) }
    }

    private func load(reset: Bool = false) async {
        guard let client = session.client else { return }
        await model.load(client: client, query: query, reset: reset)
    }
}

struct SongsList: View {
    let parentId: String?

    @Environment(AppSession.self) private var session
    @State private var model = GridModel()
    @State private var showPlaylistPicker = false
    @State private var playlistTargets: [String] = []
    @State private var notice: String?

    private var query: [String: String?] {
        [
            "parentId": parentId,
            "includeItemTypes": "Audio",
            "recursive": "true",
            "sortBy": "SortName",
            "sortOrder": "Ascending",
        ]
    }

    var body: some View {
        Text("Songs")
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 80)
            .padding(.top, 20)

        if model.items.isEmpty, let error = model.errorMessage {
            MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                .frame(height: 400)
        } else if model.items.isEmpty, !model.isLoading {
            MessageView(systemImage: "music.note", title: "No songs yet")
                .frame(height: 400)
        } else {
            LazyVStack(spacing: 6) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { position, song in
                    TrackRow(
                        track: song,
                        number: nil,
                        showArtist: true,
                        showArtwork: true,
                        isCurrent: session.music.current?.id == song.id,
                        contextActions: [
                            TrackAction(title: "Add to Playlist", systemImage: "text.badge.plus") {
                                playlistTargets = [song.id]
                                showPlaylistPicker = true
                            },
                        ]
                    ) {
                        guard let client = session.client else { return }
                        session.music.play(model.items, startingAt: position, client: client)
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 20)
            .focusSection()
            if model.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .task { await load() }
            }
        }
        Color.clear
            .frame(height: 1)
            .task { await load(reset: true) }
            .fullScreenCover(isPresented: $showPlaylistPicker) {
                PlaylistPickerView(itemIds: playlistTargets, mediaType: "Audio") { name in
                    notice = "Added to \(name)."
                }
            }
            .alert("Playlist", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
    }

    private func load(reset: Bool = false) async {
        guard let client = session.client else { return }
        await model.load(client: client, query: query, reset: reset)
    }
}

// MARK: - Lockups

/// Square artwork with a title underneath: albums, playlists and songs.
/// Navigates to the item unless an action is given, in which case it runs that.
struct SquareLockup: View {
    let item: BaseItem
    var size: CGFloat = 240
    var action: (() -> Void)? = nil

    @Environment(AppSession.self) private var session

    private var subtitle: String? {
        switch item.kind {
        case .musicAlbum: return item.artistText ?? item.yearText
        case .audio: return item.artistText ?? item.album
        case .playlist: return item.childCount.map { "\($0) songs" }
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let action {
                    Button(action: action) { artwork }
                } else {
                    NavigationLink(value: item) { artwork }
                }
            }
            .buttonStyle(.card)
            .accessibilityLabel([item.displayTitle, subtitle].compactMap { $0 }.joined(separator: ", "))

            Text(item.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: size, alignment: .leading)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: size, alignment: .leading)
            }
        }
    }

    private var artwork: some View {
        RemoteImage(url: session.client?.posterURL(for: item, width: 500), systemImage: item.kind == .playlist ? "music.note.list" : "music.note")
            .frame(width: size, height: size)
    }
}

/// Round artwork for an artist.
struct ArtistLockup: View {
    let artist: BaseItem
    var size: CGFloat = 220

    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 12) {
            NavigationLink(value: artist) {
                RemoteImage(url: session.client?.posterURL(for: artist, width: 500), systemImage: "music.mic")
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
            .buttonStyle(.card)
            .clipShape(Circle())
            .accessibilityLabel(artist.displayTitle)

            Text(artist.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: size + 20)
        }
    }
}

struct SquareGrid: View {
    let items: [BaseItem]

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 240), spacing: 40, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 48) {
            ForEach(items) { item in
                SquareLockup(item: item)
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 40)
    }
}

/// An entry in a song row's long-press menu.
struct TrackAction: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String
    var role: ButtonRole?
    var action: () -> Void
}

/// One song in a list: number or art, title, artist and length. Extra actions
/// appear on a long press of the clickpad.
struct TrackRow: View {
    let track: BaseItem
    var number: Int?
    var showArtist = false
    var showArtwork = false
    var isCurrent = false
    var contextActions: [TrackAction] = []
    var action: () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        if contextActions.isEmpty {
            button
        } else {
            button.contextMenu {
                ForEach(contextActions) { entry in
                    Button(entry.title, systemImage: entry.systemImage, role: entry.role, action: entry.action)
                }
            }
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                if showArtwork {
                    RemoteImage(url: session.client?.posterURL(for: track, width: 200), systemImage: "music.note")
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Group {
                        if isCurrent {
                            Image(systemName: "speaker.wave.2.fill")
                        } else if let number {
                            Text(String(number))
                        }
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if showArtist, let artist = track.artistText {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if track.userData?.isFavorite == true {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let length = track.trackDurationText {
                    Text(length)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(isCurrent ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([number.map { "Track \($0)" }, track.displayTitle, track.artistText, track.trackDurationText].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Album and playlist

/// An album or playlist: artwork, details, Play and Shuffle, and the songs.
struct AlbumView: View {
    let item: BaseItem

    @Environment(AppSession.self) private var session
    @State private var detail: BaseItem?
    @State private var tracks: [BaseItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showPlaylistPicker = false
    @State private var playlistTargets: [String] = []
    @State private var notice: String?

    private var current: BaseItem { detail ?? item }
    private var isPlaylist: Bool { item.kind == .playlist }

    private var totalTicks: Int64 { tracks.reduce(0) { $0 + ($1.runTimeTicks ?? 0) } }

    private var infoLine: String {
        var parts: [String] = []
        if let year = current.yearText { parts.append(year) }
        if let genre = current.genres?.first { parts.append(genre) }
        parts.append("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
        if let length = MusicFormat.length(ticks: totalTicks) { parts.append(length) }
        return parts.joined(separator: " · ")
    }

    /// Discs in the album, when there is more than one.
    private var discs: [Int] {
        let numbers = Set(tracks.compactMap(\.parentIndexNumber))
        return numbers.count > 1 ? numbers.sorted() : []
    }

    var body: some View {
        ZStack {
            RemoteImage(url: session.client?.posterURL(for: current, width: 400)) { Color(white: 0.08) }
                .blur(radius: 80)
                .overlay(Color.black.opacity(0.72))
                .ignoresSafeArea()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    header
                        .padding(.horizontal, 90)
                        .padding(.top, 60)
                        .focusSection()

                    if let errorMessage {
                        MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: errorMessage)
                            .frame(height: 300)
                    } else if tracks.isEmpty, !isLoading {
                        MessageView(systemImage: "music.note", title: isPlaylist ? "This playlist is empty" : "No songs found")
                            .frame(height: 300)
                    } else if discs.isEmpty {
                        trackList(tracks, title: nil)
                    } else {
                        ForEach(discs, id: \.self) { disc in
                            trackList(tracks.filter { $0.parentIndexNumber == disc }, title: "Disc \(disc)")
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        }
        .task(id: item.id) { await load() }
        .fullScreenCover(isPresented: $showPlaylistPicker) {
            PlaylistPickerView(itemIds: playlistTargets, mediaType: "Audio") { name in
                notice = "Added to \(name)."
            }
        }
        .alert("Playlist", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 50) {
            RemoteImage(url: session.client?.posterURL(for: current, width: 800), systemImage: isPlaylist ? "music.note.list" : "music.note")
                .frame(width: 400, height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)

            VStack(alignment: .leading, spacing: 16) {
                Text(current.displayTitle)
                    .font(.system(size: 56, weight: .bold))
                    .lineLimit(2)

                if !isPlaylist, let artist = current.primaryArtist, let artistId = artist.id, let name = artist.name {
                    NavigationLink(value: BaseItem(id: artistId, name: name, type: ItemKind.musicArtist.rawValue)) {
                        Text(name)
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                } else if let artist = current.artistText {
                    Text(artist)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(infoLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let overview = current.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: 1000, alignment: .leading)
                }

                HStack(spacing: 20) {
                    ActionButton(title: "Play", systemImage: "play.fill", prominent: true) {
                        play(from: 0, shuffled: false)
                    }
                    ActionButton(title: "Shuffle", systemImage: "shuffle") {
                        play(from: Int.random(in: 0..<max(tracks.count, 1)), shuffled: true)
                    }
                    ActionButton(title: "Instant Mix", systemImage: "wand.and.stars") {
                        instantMix()
                    }
                    IconButton(systemImage: current.userData?.isFavorite == true ? "heart.fill" : "heart", accessibilityLabel: "Favorite") {
                        toggleFavorite()
                    }
                    Menu {
                        Button {
                            playlistTargets = tracks.map(\.id)
                            showPlaylistPicker = true
                        } label: {
                            Label("Add to Playlist", systemImage: "text.badge.plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(white: 0.3))
                    .foregroundStyle(.white)
                    .accessibilityLabel("More")
                }
                .disabled(tracks.isEmpty)
                .padding(.top, 8)
            }
        }
    }

    private func trackList(_ songs: [BaseItem], title: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 8)
            }
            ForEach(songs, id: \.playlistRowID) { song in
                let position = tracks.firstIndex(where: { $0.playlistRowID == song.playlistRowID }) ?? 0
                TrackRow(
                    track: song,
                    number: isPlaylist ? position + 1 : song.indexNumber,
                    showArtist: isPlaylist || song.artistText != current.artistText,
                    isCurrent: session.music.current?.id == song.id,
                    contextActions: rowActions(for: song, at: position)
                ) {
                    play(from: position, shuffled: false)
                }
            }
        }
        .padding(.horizontal, 90)
        .focusSection()
    }

    /// Long-press actions: Add to Playlist everywhere; reorder and remove on
    /// a playlist's own page.
    private func rowActions(for song: BaseItem, at position: Int) -> [TrackAction] {
        var actions = [
            TrackAction(title: "Add to Playlist", systemImage: "text.badge.plus") {
                playlistTargets = [song.id]
                showPlaylistPicker = true
            },
        ]
        guard isPlaylist, song.playlistItemId != nil else { return actions }
        if position > 0 {
            actions.append(TrackAction(title: "Move Up", systemImage: "arrow.up") { move(song, to: position - 1) })
        }
        if position < tracks.count - 1 {
            actions.append(TrackAction(title: "Move Down", systemImage: "arrow.down") { move(song, to: position + 1) })
        }
        actions.append(TrackAction(title: "Remove from Playlist", systemImage: "trash", role: .destructive) { remove(song) })
        return actions
    }

    private func remove(_ song: BaseItem) {
        guard let client = session.client, let entry = song.playlistItemId else { return }
        let previous = tracks
        tracks.removeAll { $0.playlistRowID == song.playlistRowID }
        Task {
            do {
                try await client.removeFromPlaylist(item.id, entryIds: [entry])
            } catch {
                tracks = previous
                notice = error.localizedDescription
            }
        }
    }

    private func move(_ song: BaseItem, to newIndex: Int) {
        guard let client = session.client, let entry = song.playlistItemId,
              let from = tracks.firstIndex(where: { $0.playlistRowID == song.playlistRowID }) else { return }
        let previous = tracks
        let moved = tracks.remove(at: from)
        tracks.insert(moved, at: newIndex)
        Task {
            do {
                try await client.movePlaylistItem(item.id, entryId: entry, to: newIndex)
            } catch {
                tracks = previous
                notice = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        errorMessage = nil
        async let full = client.item(item.id)
        do {
            tracks = isPlaylist ? try await client.playlistItems(playlistId: item.id) : try await client.albumTracks(albumId: item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        detail = try? await full
        isLoading = false
    }

    private func play(from position: Int, shuffled: Bool) {
        guard let client = session.client, !tracks.isEmpty else { return }
        session.music.play(tracks, startingAt: position, shuffled: shuffled, client: client)
    }

    private func instantMix() {
        guard let client = session.client else { return }
        Task {
            let mix = (try? await client.instantMix(for: item.id)) ?? tracks
            session.music.play(mix, client: client)
        }
    }

    private func toggleFavorite() {
        guard let client = session.client else { return }
        var updated = current
        let newValue = !(updated.userData?.isFavorite ?? false)
        updated.userData?.isFavorite = newValue
        detail = updated
        Task { try? await client.setFavorite(item.id, newValue) }
    }
}

// MARK: - Artist

struct ArtistView: View {
    let artist: BaseItem

    @Environment(AppSession.self) private var session
    @State private var detail: BaseItem?
    @State private var albums: [BaseItem] = []
    @State private var isLoading = true

    private var current: BaseItem { detail ?? artist }

    var body: some View {
        ZStack {
            RemoteImage(url: session.client?.backdropURL(for: current, width: 1920) ?? session.client?.posterURL(for: current, width: 800)) { Color(white: 0.08) }
                .blur(radius: 60)
                .overlay(Color.black.opacity(0.75))
                .ignoresSafeArea()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .center, spacing: 50) {
                        RemoteImage(url: session.client?.posterURL(for: current, width: 600), systemImage: "music.mic")
                            .frame(width: 320, height: 320)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)

                        VStack(alignment: .leading, spacing: 16) {
                            Text(current.displayTitle)
                                .font(.system(size: 56, weight: .bold))
                                .lineLimit(2)
                            if let genres = current.genres, !genres.isEmpty {
                                Text(genres.prefix(3).joined(separator: " · "))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            if let overview = current.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .frame(maxWidth: 1000, alignment: .leading)
                            }
                            HStack(spacing: 20) {
                                ActionButton(title: "Play", systemImage: "play.fill", prominent: true) {
                                    playAll(shuffled: false)
                                }
                                ActionButton(title: "Shuffle", systemImage: "shuffle") {
                                    playAll(shuffled: true)
                                }
                                ActionButton(title: "Instant Mix", systemImage: "wand.and.stars") {
                                    instantMix()
                                }
                                IconButton(systemImage: current.userData?.isFavorite == true ? "heart.fill" : "heart", accessibilityLabel: "Favorite") {
                                    toggleFavorite()
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 90)
                    .padding(.top, 60)
                    .focusSection()

                    if albums.isEmpty, !isLoading {
                        MessageView(systemImage: "music.note", title: "No albums found")
                            .frame(height: 300)
                    } else {
                        Shelf(title: "Albums", items: albums) { album in
                            SquareLockup(item: album)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        }
        .task(id: artist.id) { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        async let full = client.item(artist.id)
        albums = (try? await client.artistAlbums(artistId: artist.id)) ?? []
        detail = try? await full
        isLoading = false
    }

    private func playAll(shuffled: Bool) {
        guard let client = session.client else { return }
        Task {
            let songs = (try? await client.artistTracks(artistId: artist.id)) ?? []
            session.music.play(songs, startingAt: shuffled ? Int.random(in: 0..<max(songs.count, 1)) : 0, shuffled: shuffled, client: client)
        }
    }

    private func instantMix() {
        guard let client = session.client else { return }
        Task {
            let mix = (try? await client.instantMix(for: artist.id)) ?? []
            session.music.play(mix, client: client)
        }
    }

    private func toggleFavorite() {
        guard let client = session.client else { return }
        var updated = current
        let newValue = !(updated.userData?.isFavorite ?? false)
        updated.userData?.isFavorite = newValue
        detail = updated
        Task { try? await client.setFavorite(artist.id, newValue) }
    }
}

// MARK: - Now playing

/// A strip showing the current song; selecting it opens the full player.
struct NowPlayingBar: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if let track = session.music.current {
            Button {
                session.music.isNowPlayingPresented = true
            } label: {
                HStack(spacing: 20) {
                    RemoteImage(url: session.client?.posterURL(for: track, width: 200), systemImage: "music.note")
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.displayTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text([track.artistText, track.album].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: session.music.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                    Image(systemName: "chevron.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing: \(track.displayTitle)")
            .focusSection()
        }
    }
}

/// The full-screen player: artwork, progress, transport controls and what's next.
struct NowPlayingView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedControl: String?
    @State private var showLyrics = false

    private var player: MusicPlayer { session.music }

    var body: some View {
        ZStack {
            RemoteImage(url: player.current.flatMap { session.client?.posterURL(for: $0, width: 400) }) { Color(white: 0.06) }
                .blur(radius: 100)
                .overlay(Color.black.opacity(0.7))
                .ignoresSafeArea()

            if let track = player.current {
                VStack(spacing: 36) {
                    HStack(alignment: .center, spacing: 70) {
                        RemoteImage(url: session.client?.posterURL(for: track, width: 800), systemImage: "music.note")
                            .frame(width: 560, height: 560)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .shadow(color: .black.opacity(0.6), radius: 40, y: 16)

                        VStack(alignment: .leading, spacing: 24) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(track.displayTitle)
                                    .font(.system(size: 48, weight: .bold))
                                    .lineLimit(2)
                                if let artist = track.artistText {
                                    Text(artist)
                                        .font(.title3.weight(.semibold))
                                }
                                if let album = track.album {
                                    Text(album)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            VStack(spacing: 8) {
                                ProgressBar(progress: player.duration > 0 ? player.currentTime / player.duration : 0)
                                HStack {
                                    Text(MusicFormat.clock(player.currentTime))
                                    Spacer()
                                    Text("-" + MusicFormat.clock(max(player.duration - player.currentTime, 0)))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            }

                            controls

                            if let error = player.errorMessage {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(width: 900, alignment: .leading)
                    }
                    .padding(.horizontal, 120)
                    .focusSection()

                    if showLyrics, let lyrics = player.lyrics {
                        LyricsPanel(lyrics: lyrics, currentIndex: player.currentLyricIndex)
                    } else {
                        Shelf(title: "Up Next", items: player.upNext) { song in
                            SquareLockup(item: song, size: 180) {
                                player.skip(to: song)
                            }
                        }
                    }
                }
                .padding(.top, 60)
            } else {
                MessageView(systemImage: "music.note", title: "Nothing playing")
            }
        }
        .onPlayPauseCommand { player.togglePlayPause() }
        .onChange(of: player.current == nil) { _, empty in
            if empty { dismiss() }
        }
        .onAppear { focusedControl = "play" }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            PlayerControl(systemImage: "shuffle", label: "Shuffle", active: player.isShuffled) {
                player.toggleShuffle()
            }
            .focused($focusedControl, equals: "shuffle")
            PlayerControl(systemImage: "backward.fill", label: "Previous") {
                player.previous()
            }
            .focused($focusedControl, equals: "previous")
            PlayerControl(systemImage: player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pause" : "Play", prominent: true) {
                player.togglePlayPause()
            }
            .focused($focusedControl, equals: "play")
            PlayerControl(systemImage: "forward.fill", label: "Next") {
                player.next()
            }
            .focused($focusedControl, equals: "next")
            PlayerControl(systemImage: player.repeatMode.systemImage, label: "Repeat", active: player.repeatMode != .off) {
                player.cycleRepeat()
            }
            .focused($focusedControl, equals: "repeat")
            if player.lyrics != nil {
                PlayerControl(systemImage: "quote.bubble", label: "Lyrics", active: showLyrics) {
                    showLyrics.toggle()
                }
                .focused($focusedControl, equals: "lyrics")
            }
        }
    }
}

/// Lyrics under the player: synced lines highlight and scroll with the song,
/// unsynced lyrics read as a plain block. Lines are not focusable, so the
/// remote never has to step through them.
struct LyricsPanel: View {
    let lyrics: Lyrics
    let currentIndex: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lyrics.lyrics.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.title3.weight(index == currentIndex ? .semibold : .regular))
                            .foregroundStyle(index == currentIndex || !lyrics.isSynced ? Color.white : Color.white.opacity(0.4))
                            .id(index)
                    }
                }
                .padding(.horizontal, 120)
                .padding(.vertical, 60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: currentIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .frame(height: 320)
        .mask(LinearGradient(colors: [.clear, .black, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
    }
}

/// A round transport button.
struct PlayerControl: View {
    let systemImage: String
    let label: String
    var prominent = false
    var active = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 34 : 26, weight: .semibold))
                .frame(width: prominent ? 96 : 76, height: prominent ? 96 : 76)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? .white : (active ? Color.accentColor : Color(white: 0.3)))
        .foregroundStyle(prominent ? .black : .white)
        .clipShape(Circle())
        .accessibilityLabel(label)
    }
}
