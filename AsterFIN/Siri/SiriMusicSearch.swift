//
//  SiriMusicSearch.swift
//  AsterFIN
//
//  What Siri asks Aster for: the server's music matching what was said
//  ("Radiohead", "OK Computer", "my road trip playlist"), and what to play
//  when nothing was named. Everything goes through the signed-in Jellyfin
//  server, as CarPlay does.
//

#if os(iOS)
import AppIntents
import Foundation
import MediaIntents

@available(iOS 27.0, *)
extension AudioEntity {
    /// Siri's search of Aster's music.
    nonisolated struct AudioIntentValueQuery: IntentValueQuery {
        func values(for input: AudioSearch) async throws -> [AudioEntity] {
            switch input.criteria {
            case .searchQuery(let query):
                return try await SiriLibrary.search(query).compactMap(AudioEntity.init(item:))
            case .unspecified:
                // "Play some music": the person's favorite songs.
                return try await SiriLibrary.favoriteSongs().map { .song(SongEntity(item: $0)) }
            case .url:
                return []
            @unknown default:
                return []
            }
        }
    }

    /// A song, album, artist or playlist from the server; nil for anything else.
    nonisolated init?(item: BaseItem) {
        switch item.kind {
        case .audio: self = .song(SongEntity(item: item))
        case .musicAlbum: self = .album(AlbumEntity(item: item))
        case .musicArtist: self = .artist(ArtistEntity(item: item))
        case .playlist: self = .playlist(PlaylistEntity(item: item))
        default: return nil
        }
    }
}

/// Why Siri couldn't do what was asked, in words it can say.
nonisolated enum SiriMusicError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case nothingToPlay
    case songsOnly

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Open Aster and sign in to your Jellyfin server first."
        case .nothingToPlay: "Aster didn't find any songs for that."
        case .songsOnly: "That only works with a song."
        }
    }
}

/// The signed-in server's music, for Siri.
@MainActor
enum SiriLibrary {
    static func client() throws -> JellyfinClient {
        guard let client = AppSession.shared.jellyfin else { throw SiriMusicError.signedOut }
        return client
    }

    /// Songs, albums, artists and playlists matching what was said, best first.
    static func search(_ term: String, kind: ItemKind? = nil) async throws -> [BaseItem] {
        let types = kind.map(\.rawValue) ?? "Audio,MusicAlbum,MusicArtist,Playlist"
        return try await client().items([
            "searchTerm": term,
            "recursive": "true",
            "includeItemTypes": types,
            "limit": "30",
        ]).items
    }

    static func items(_ ids: [String]) async throws -> [BaseItem] {
        guard !ids.isEmpty else { return [] }
        return try await client().items(["ids": ids.joined(separator: ","), "recursive": "true"]).items
    }

    static func playlists() async throws -> [BaseItem] {
        try await client().playlists(mediaType: "Audio")
    }

    static func favoriteSongs() async throws -> [BaseItem] {
        try await client().items([
            "includeItemTypes": "Audio",
            "recursive": "true",
            "filters": "IsFavorite",
            "sortBy": "Random",
            "limit": "100",
        ]).items
    }

    /// The songs to play for what Siri picked, in order.
    @available(iOS 27.0, *)
    static func tracks(for entity: AudioEntity) async throws -> [BaseItem] {
        let client = try client()
        switch entity {
        case .song(let song): return try await items([song.id])
        case .album(let album): return try await client.albumTracks(albumId: album.id)
        case .artist(let artist): return try await client.artistTracks(artistId: artist.id)
        case .playlist(let playlist): return try await client.playlistItems(playlistId: playlist.id)
        }
    }
}
#endif
