//
//  SiriMusicEntities.swift
//  AsterFIN
//
//  The server's music as Siri knows it (iOS 27's audio schemas): songs,
//  albums, artists and playlists, by their Jellyfin ids, so "play Radiohead
//  in Aster" finds them, in the car or anywhere. Only what the schemas ask
//  for is filled in; the server is asked again when one is played.
//

#if os(iOS)
import AppIntents
import Foundation

@available(iOS 27.0, *)
@AppEntity(schema: .audio.song)
struct SongEntity {
    static let defaultQuery = SongEntityQuery()

    let id: String

    var title: String
    var artistName: String
    var composerName: String?
    var albumTitle: String?
    var artists: [ArtistEntity]
    var album: AlbumEntity?
    var composers: [ArtistEntity]
    var internationalStandardRecordingCode: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", synonyms: ["\(title) by \(artistName)"])
    }

    init(item: BaseItem) {
        id = item.id
        title = item.displayTitle
        artistName = item.artistText ?? ""
        composerName = nil
        albumTitle = item.album
        artists = (item.artistItems ?? item.albumArtists ?? []).compactMap(ArtistEntity.init(pair:))
        album = item.albumId.map { AlbumEntity(id: $0, title: item.album ?? "", artistName: item.albumArtist ?? item.artistText ?? "") }
        composers = []
        internationalStandardRecordingCode = nil
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.album)
struct AlbumEntity {
    static let defaultQuery = AlbumEntityQuery()

    let id: String

    var title: String
    var artistName: String
    var artists: [ArtistEntity]
    var universalProductCode: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", synonyms: ["\(title) by \(artistName)"])
    }

    init(id: String, title: String, artistName: String, artists: [ArtistEntity] = []) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artists = artists
        universalProductCode = nil
    }

    init(item: BaseItem) {
        self.init(
            id: item.id,
            title: item.displayTitle,
            artistName: item.artistText ?? "",
            artists: (item.albumArtists ?? []).compactMap(ArtistEntity.init(pair:))
        )
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct ArtistEntity {
    static let defaultQuery = ArtistEntityQuery()

    let id: String

    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(item: BaseItem) {
        self.init(id: item.id, name: item.displayTitle)
    }

    init?(pair: NameGuidPair) {
        guard let id = pair.id, let name = pair.name else { return nil }
        self.init(id: id, name: name)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct PlaylistEntity {
    static let defaultQuery = PlaylistEntityQuery()

    let id: String

    var title: String
    var owner: PlaylistOwner?
    var createdByMe: Bool?
    var curatedForMe: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "Playlist")
    }

    init(item: BaseItem) {
        id = item.id
        title = item.displayTitle
        owner = nil
        createdByMe = nil
        curatedForMe = nil
    }
}

/// Who a playlist belongs to, as the playlist schema has it.
@available(iOS 27.0, *)
@UnionValue
enum PlaylistOwner {
    case curator(String)
    case person(IntentPerson)
}

/// Anything Siri can play from Aster.
@available(iOS 27.0, *)
@UnionValue
enum AudioEntity {
    case song(SongEntity)
    case album(AlbumEntity)
    case artist(ArtistEntity)
    case playlist(PlaylistEntity)
}

/// How to play: shuffled, repeating.
@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
nonisolated enum PlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [PlaybackAttributes: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat",
    ]
}

/// Where in the queue: after the song playing, or at the end.
@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
nonisolated enum QueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [QueueInsertionLocation: DisplayRepresentation] = [
        .next: "Next",
        .tail: "Last",
    ]
}

/// The schema's marker that the queue is ready to play.
@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
nonisolated struct WarmupAudioQueueResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation { "Ready to Play" }

    init() {}
}

// MARK: Queries

@available(iOS 27.0, *)
nonisolated struct SongEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SongEntity] {
        try await SiriLibrary.items(identifiers).map(SongEntity.init(item:))
    }

    func entities(matching string: String) async throws -> [SongEntity] {
        try await SiriLibrary.search(string, kind: .audio).map(SongEntity.init(item:))
    }
}

@available(iOS 27.0, *)
nonisolated struct AlbumEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        try await SiriLibrary.items(identifiers).map(AlbumEntity.init(item:))
    }

    func entities(matching string: String) async throws -> [AlbumEntity] {
        try await SiriLibrary.search(string, kind: .musicAlbum).map(AlbumEntity.init(item:))
    }
}

@available(iOS 27.0, *)
nonisolated struct ArtistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        try await SiriLibrary.items(identifiers).map(ArtistEntity.init(item:))
    }

    func entities(matching string: String) async throws -> [ArtistEntity] {
        try await SiriLibrary.search(string, kind: .musicArtist).map(ArtistEntity.init(item:))
    }
}

@available(iOS 27.0, *)
nonisolated struct PlaylistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        try await SiriLibrary.items(identifiers).map(PlaylistEntity.init(item:))
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        try await SiriLibrary.search(string, kind: .playlist).map(PlaylistEntity.init(item:))
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await SiriLibrary.playlists().map(PlaylistEntity.init(item:))
    }
}
#endif
