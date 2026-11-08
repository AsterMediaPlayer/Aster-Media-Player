//
//  SiriMusicActions.swift
//  AsterFIN
//
//  The rest of what Siri can do with Aster's music: "add this song to my
//  road trip playlist" and "I like this song" (a favorite on the server).
//  "This song" is the one playing, which the music player tags in Now
//  Playing for Siri.
//

#if os(iOS)
import AppIntents
import MediaPlayer

/// What "this" means to Siri while a song plays: the song, then its album
/// and artist, narrowest first, for the Now Playing info.
@available(iOS 27.0, *)
enum SiriNowPlaying {
    static func identifiers(for track: BaseItem) -> [MPAppEntityIdentifier] {
        var ids = [EntityIdentifier(for: SongEntity.self, identifier: track.id)]
        if let album = track.albumId { ids.append(EntityIdentifier(for: AlbumEntity.self, identifier: album)) }
        if let artist = track.primaryArtist?.id { ids.append(EntityIdentifier(for: ArtistEntity.self, identifier: artist)) }
        return ids.compactMap(MPAppEntityIdentifier.init(entityIdentifier:))
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.addToPlaylist)
struct AddToPlaylistIntent {
    static let title: LocalizedStringResource = "Add to Playlist"

    var audioEntity: AudioEntity
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let songs: [BaseItem]
        switch audioEntity {
        case .song(let song): songs = try await SiriLibrary.items([song.id])
        default: songs = try await SiriLibrary.tracks(for: audioEntity)
        }
        guard !songs.isEmpty else { throw SiriMusicError.nothingToPlay }
        try await SiriLibrary.client().addToPlaylist(playlist.id, itemIds: songs.map(\.id))
        let what = songs.count == 1 ? songs[0].displayTitle : "\(songs.count) songs"
        return .result(dialog: "Added \(what) to \(playlist.title).")
    }
}

/// Like (a favorite), dislike or neither, as the affinity schema has it.
@available(iOS 27.0, *)
@AppEnum(schema: .audio.affinityState)
nonisolated enum AffinityState: String {
    case like
    case dislike
    case unset

    static let caseDisplayRepresentations: [AffinityState: DisplayRepresentation] = [
        .like: "Like",
        .dislike: "Dislike",
        .unset: "Unset",
    ]
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.updateAudioAffinity)
struct UpdateAudioAffinityIntent {
    static let title: LocalizedStringResource = "Like or Unlike"

    var affinityState: AffinityState
    var target: AudioEntity

    /// Jellyfin has favorites but no dislikes, so "I don't like this" and
    /// "clear that" both take the favorite away.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (id, title): (String, String)
        switch target {
        case .song(let song): (id, title) = (song.id, song.title)
        case .album(let album): (id, title) = (album.id, album.title)
        case .artist(let artist): (id, title) = (artist.id, artist.name)
        case .playlist(let playlist): (id, title) = (playlist.id, playlist.title)
        }
        let favorite = affinityState == .like
        try await SiriLibrary.client().setFavorite(id, favorite)
        return .result(dialog: favorite ? "Added \(title) to your favorites." : "Removed \(title) from your favorites.")
    }
}
#endif
