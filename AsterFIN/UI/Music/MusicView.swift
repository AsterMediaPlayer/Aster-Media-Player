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

/// Music sizes: TV-sized on tvOS, phone-sized elsewhere. Square artwork in
/// grids and shelves uses `Lockup.squareWidth`.
enum MusicMetrics {
    #if os(tvOS)
    static let artistSize: CGFloat = 220
    /// How much wider than the photo an artist's name may run.
    static let artistLabelExtra: CGFloat = 20
    /// Album and playlist pages.
    static let pageArtwork: CGFloat = 400
    static let artistPhoto: CGFloat = 320
    static let pageTitleSize: CGFloat = 56
    static let pagePadding: CGFloat = 90
    static let pageTopPadding: CGFloat = 60
    static let pageHeaderSpacing: CGFloat = 50
    static let upNextSize: CGFloat = 180
    #else
    static let artistSize: CGFloat = 100
    static let artistLabelExtra: CGFloat = 10
    static let pageArtwork: CGFloat = 180
    static let artistPhoto: CGFloat = 140
    static let pageTitleSize: CGFloat = 26
    static let pagePadding: CGFloat = Lockup.screenPadding
    static let pageTopPadding: CGFloat = 16
    static let pageHeaderSpacing: CGFloat = 20
    static let upNextSize: CGFloat = 90
    #endif
}

/// An album, playlist or artist page's header: the artwork beside the
/// details, or above them on a phone held upright.
struct MusicPageHeader<Artwork: View, Details: View>: View {
    var alignment: VerticalAlignment = .bottom
    @ViewBuilder var artwork: Artwork
    @ViewBuilder var details: Details

    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var layout: AnyLayout {
        #if !os(tvOS)
        if horizontalSizeClass == .compact && verticalSizeClass == .regular {
            return AnyLayout(VStackLayout(alignment: .leading, spacing: MusicMetrics.pageHeaderSpacing))
        }
        #endif
        return AnyLayout(HStackLayout(alignment: alignment, spacing: MusicMetrics.pageHeaderSpacing))
    }

    var body: some View {
        layout {
            artwork
            details
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
                header
                    .padding(.horizontal, Lockup.screenPadding)
                    #if os(tvOS)
                    .padding(.top, 40)
                    #else
                    .padding(.top, 8)
                    #endif
                    .tvFocusSection()

                if session.music.current != nil {
                    NowPlayingBar()
                        .padding(.horizontal, Lockup.screenPadding)
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

    /// The title and the section picker: side by side on a TV, the picker
    /// across the full width below the title on a phone.
    private var header: some View {
        let title = Text(library?.displayTitle ?? "Music")
            .font(.largeTitle.weight(.bold))
        let picker = Picker("Section", selection: $section) {
            ForEach(MusicSection.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        #if os(tvOS)
        return HStack(alignment: .firstTextBaseline) {
            title
            Spacer()
            picker.frame(width: 980)
        }
        #else
        return VStack(alignment: .leading, spacing: 12) {
            title
            picker
        }
        #endif
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
        .padding(.horizontal, Lockup.screenPadding)
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

    private let columns = [GridItem(.adaptive(minimum: Lockup.squareWidth, maximum: Lockup.squareWidth), spacing: Lockup.gridSpacing, alignment: .top)]

    var body: some View {
        Text("Artists")
            .font(.title3.weight(.semibold))
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.top, 20)

        if model.items.isEmpty, let error = model.errorMessage {
            MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                .frame(height: 400)
        } else if model.items.isEmpty, !model.isLoading {
            MessageView(systemImage: "music.mic", title: "No artists yet")
                .frame(height: 400)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Lockup.gridRowSpacing) {
                ForEach(model.items) { artist in
                    ArtistLockup(artist: artist)
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
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
            .padding(.horizontal, Lockup.screenPadding)
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
            .padding(.horizontal, Lockup.screenPadding)
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
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.vertical, 20)
            .tvFocusSection()
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
            .appCover(isPresented: $showPlaylistPicker) {
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
    var size: CGFloat = Lockup.squareWidth
    var action: (() -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.openItem) private var openItem

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
            .cardButtonStyle()
            .keyboardTarget { if let action { action() } else { openItem?(item) } }
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
    var size: CGFloat = MusicMetrics.artistSize

    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 12) {
            NavigationLink(value: artist) {
                RemoteImage(url: session.client?.posterURL(for: artist, width: 500), systemImage: "music.mic")
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
            .cardButtonStyle()
            .keyboardTarget(opening: artist)
            .clipShape(Circle())
            .accessibilityLabel(artist.displayTitle)

            Text(artist.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: size + MusicMetrics.artistLabelExtra)
        }
    }
}

struct SquareGrid: View {
    let items: [BaseItem]

    private let columns = [GridItem(.adaptive(minimum: Lockup.squareWidth, maximum: Lockup.squareWidth), spacing: Lockup.gridSpacing, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Lockup.gridRowSpacing) {
            ForEach(items) { item in
                SquareLockup(item: item)
            }
        }
        .padding(.horizontal, Lockup.screenPadding)
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

    #if os(tvOS)
    private static let spacing: CGFloat = 20
    private static let artworkSize: CGFloat = 64
    private static let numberWidth: CGFloat = 48
    private static let padding = EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
    private static let cornerRadius: CGFloat = 12
    #else
    private static let spacing: CGFloat = 12
    private static let artworkSize: CGFloat = 44
    private static let numberWidth: CGFloat = 28
    private static let padding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    private static let cornerRadius: CGFloat = 10
    #endif

    var body: some View {
        Group {
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
        .keyboardTarget(action: action)
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: Self.spacing) {
                if showArtwork {
                    RemoteImage(url: session.client?.posterURL(for: track, width: 200), systemImage: "music.note")
                        .frame(width: Self.artworkSize, height: Self.artworkSize)
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
                    .frame(width: Self.numberWidth, alignment: .trailing)
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
            .padding(Self.padding)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(Color.white.opacity(isCurrent ? 0.12 : 0.06)))
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
                        .padding(.horizontal, MusicMetrics.pagePadding)
                        .padding(.top, MusicMetrics.pageTopPadding)
                        .tvFocusSection()

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
        .appCover(isPresented: $showPlaylistPicker) {
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
        MusicPageHeader {
            RemoteImage(url: session.client?.posterURL(for: current, width: 800), systemImage: isPlaylist ? "music.note.list" : "music.note")
                .frame(width: MusicMetrics.pageArtwork, height: MusicMetrics.pageArtwork)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        } details: {
            VStack(alignment: .leading, spacing: 16) {
                Text(current.displayTitle)
                    .font(.system(size: MusicMetrics.pageTitleSize, weight: .bold))
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

                // On a phone held upright: Play and Shuffle, then the rest.
                ActionRows {
                    ActionButton(title: "Play", systemImage: "play.fill", prominent: true) {
                        play(from: 0, shuffled: false)
                    }
                    ActionButton(title: "Shuffle", systemImage: "shuffle") {
                        play(from: Int.random(in: 0..<max(tracks.count, 1)), shuffled: true)
                    }
                } second: {
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
                            .font(Lockup.iconButtonFont)
                            .frame(width: Lockup.iconButtonSize, height: Lockup.iconButtonSize)
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
        .padding(.horizontal, MusicMetrics.pagePadding)
        .tvFocusSection()
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
                    MusicPageHeader(alignment: .center) {
                        RemoteImage(url: session.client?.posterURL(for: current, width: 600), systemImage: "music.mic")
                            .frame(width: MusicMetrics.artistPhoto, height: MusicMetrics.artistPhoto)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                    } details: {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(current.displayTitle)
                                .font(.system(size: MusicMetrics.pageTitleSize, weight: .bold))
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
                            ActionRows {
                                ActionButton(title: "Play", systemImage: "play.fill", prominent: true) {
                                    playAll(shuffled: false)
                                }
                                ActionButton(title: "Shuffle", systemImage: "shuffle") {
                                    playAll(shuffled: true)
                                }
                            } second: {
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
                    .padding(.horizontal, MusicMetrics.pagePadding)
                    .padding(.top, MusicMetrics.pageTopPadding)
                    .tvFocusSection()

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

    #if os(tvOS)
    private static let spacing: CGFloat = 20
    private static let artworkSize: CGFloat = 80
    private static let padding = EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
    #else
    private static let spacing: CGFloat = 12
    private static let artworkSize: CGFloat = 48
    private static let padding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 16)
    #endif

    var body: some View {
        if let track = session.music.current {
            Button {
                session.music.isNowPlayingPresented = true
            } label: {
                HStack(spacing: Self.spacing) {
                    RemoteImage(url: session.client?.posterURL(for: track, width: 200), systemImage: "music.note")
                        .frame(width: Self.artworkSize, height: Self.artworkSize)
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
                .padding(Self.padding)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing: \(track.displayTitle)")
            .tvFocusSection()
        }
    }
}

/// The full-screen player: artwork, progress, transport controls and what's next.
struct NowPlayingView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.coverDismiss) private var dismiss
    @FocusState private var focusedControl: String?
    @State private var showLyrics = false

    private var player: MusicPlayer { session.music }

    var body: some View {
        ZStack {
            RemoteImage(url: player.current.flatMap { session.client?.posterURL(for: $0, width: 400) }) { Color(white: 0.06) }
                // Opaque so the blur doesn't fade the edges to clear and let
                // the screen under this full-screen cover show through.
                .blur(radius: 100, opaque: true)
                .overlay(Color.black.opacity(0.7))
                .ignoresSafeArea()

            if let track = player.current {
                #if os(tvOS)
                VStack(spacing: 36) {
                    HStack(alignment: .center, spacing: 70) {
                        artwork(track, size: 560)

                        VStack(alignment: .leading, spacing: 24) {
                            trackInfo(track, titleSize: 48)
                            progress
                            controls
                            errorText
                        }
                        .frame(width: 900, alignment: .leading)
                    }
                    .padding(.horizontal, 120)
                    .tvFocusSection()

                    lowerPanel()
                }
                .padding(.top, 60)
                #else
                phoneLayout(track)
                #endif
            } else {
                MessageView(systemImage: "music.note", title: "Nothing playing")
            }
        }
        #if !os(tvOS)
        // No remote Back button on iOS: a way to put the player away.
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.white)
            .accessibilityLabel("Close")
            .padding(Lockup.screenPadding)
        }
        #endif
        .tvPlayPauseCommand { player.togglePlayPause() }
        .onChange(of: player.current == nil) { _, empty in
            if empty { dismiss() }
        }
        .onAppear { focusedControl = "play" }
    }

    // MARK: Pieces shared by the TV and phone layouts

    private func artwork(_ track: BaseItem, size: CGFloat) -> some View {
        RemoteImage(url: session.client?.posterURL(for: track, width: 800), systemImage: "music.note")
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 300 ? 20 : 14))
            .shadow(color: .black.opacity(0.6), radius: size > 300 ? 40 : 20, y: size > 300 ? 16 : 8)
    }

    private func trackInfo(_ track: BaseItem, titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(track.displayTitle)
                .font(.system(size: titleSize, weight: .bold))
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
    }

    private var progress: some View {
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
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = player.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// Whether the lyrics are on screen (turned on, and the song has some).
    private var lyricsShowing: Bool { showLyrics && player.lyrics != nil }

    /// Lyrics when they're turned on, else what's coming up. `lyricsHeight`
    /// overrides the panel's usual height.
    @ViewBuilder
    private func lowerPanel(lyricsHeight: CGFloat? = nil) -> some View {
        if showLyrics, let lyrics = player.lyrics {
            LyricsPanel(lyrics: lyrics, currentIndex: player.currentLyricIndex, height: lyricsHeight)
        } else {
            Shelf(title: "Up Next", items: player.upNext) { song in
                SquareLockup(item: song, size: MusicMetrics.upNextSize) {
                    player.skip(to: song)
                }
            }
        }
    }

    #if !os(tvOS)
    /// A phone: the artwork on top with everything under it when upright,
    /// the artwork beside the controls on its side. With the lyrics on, the
    /// artwork shrinks to give them the room. Scrolls if the lyrics or Up
    /// Next don't fit.
    private func phoneLayout(_ track: BaseItem) -> some View {
        GeometryReader { proxy in
            let upright = proxy.size.height > proxy.size.width
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    if upright {
                        VStack(alignment: .leading, spacing: 20) {
                            if lyricsShowing {
                                // A compact header: small cover beside the song.
                                HStack(spacing: 16) {
                                    artwork(track, size: 96)
                                    trackInfo(track, titleSize: 20)
                                }
                            } else {
                                artwork(track, size: min(proxy.size.width - 48, 340))
                                    .frame(maxWidth: .infinity)
                                trackInfo(track, titleSize: 24)
                            }
                            progress
                            controls
                                .frame(maxWidth: .infinity)
                            errorText
                        }
                        .padding(.horizontal, 24)
                    } else {
                        HStack(alignment: .center, spacing: 28) {
                            artwork(track, size: min(proxy.size.height - 60, lyricsShowing ? 140 : 260))
                            VStack(alignment: .leading, spacing: 14) {
                                trackInfo(track, titleSize: 22)
                                progress
                                controls
                                errorText
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                    // Upright with the compact header, the lyrics take the
                    // rest of the screen: everything above them is about 300 pt.
                    lowerPanel(lyricsHeight: upright && lyricsShowing ? max(260, proxy.size.height - 300) : nil)
                }
                // Clear of the close button.
                .padding(.top, upright ? 68 : 20)
                .padding(.bottom, 24)
                // Never wider than the screen, whatever a row wants.
                .frame(width: proxy.size.width)
            }
            .scrollIndicators(.hidden)
            .animation(.easeInOut(duration: 0.3), value: lyricsShowing)
        }
    }
    #endif

    private var controls: some View {
        HStack(spacing: PlayerControl.spacing) {
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
    /// Overrides the usual height, e.g. to fill a phone held upright.
    var height: CGFloat? = nil

    #if os(tvOS)
    private static let horizontalPadding: CGFloat = 120
    private static let verticalPadding: CGFloat = 60
    private static let height: CGFloat = 320
    #else
    private static let horizontalPadding: CGFloat = 24
    private static let verticalPadding: CGFloat = 24
    private static let height: CGFloat = 260
    #endif

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
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: currentIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .frame(height: height ?? Self.height)
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

    #if os(tvOS)
    static let spacing: CGFloat = 28
    private static let size: (prominent: CGFloat, regular: CGFloat) = (96, 76)
    private static let iconSize: (prominent: CGFloat, regular: CGFloat) = (34, 26)
    #else
    // Six across fit a phone held upright.
    static let spacing: CGFloat = 10
    private static let size: (prominent: CGFloat, regular: CGFloat) = (64, 46)
    private static let iconSize: (prominent: CGFloat, regular: CGFloat) = (24, 18)
    #endif

    private var fill: Color {
        prominent ? .white : (active ? Color.accentColor : Color(white: 0.3))
    }

    var body: some View {
        let diameter = prominent ? Self.size.prominent : Self.size.regular
        let icon = Image(systemName: systemImage)
            .font(.system(size: prominent ? Self.iconSize.prominent : Self.iconSize.regular, weight: .semibold))
            .frame(width: diameter, height: diameter)
        #if os(tvOS)
        Button(action: action) { icon }
            .buttonStyle(.borderedProminent)
            .tint(fill)
            .foregroundStyle(prominent ? .black : .white)
            .clipShape(Circle())
            .accessibilityLabel(label)
        #else
        // The system's filled style pads the button out past its circle,
        // which on a phone made six controls wider than the screen. Drawn
        // here, each is exactly its diameter.
        Button(action: action) {
            icon
                .foregroundStyle(prominent ? .black : .white)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        #endif
    }
}
