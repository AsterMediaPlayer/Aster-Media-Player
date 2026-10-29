# Emby and Plex

Aster started as a Jellyfin client. Since 0.10 it also signs in to **Emby** and **Plex** servers. Every screen talks to a server through one protocol, `MediaServer` (`AsterFIN/Server/MediaServer.swift`), so Home, the libraries, title pages, search and both players are the same code on all three. Features a server doesn't have are hidden on it, through its `ServerCapabilities`, rather than shown broken.

## What each server gets

| | Jellyfin | Emby | Plex |
| --- | :---: | :---: | :---: |
| Home, libraries, title pages, search | ✓ | ✓ | ✓ |
| Playback (AetherEngine and the system player), resume, watched | ✓ | ✓ | ✓ |
| Skip Intro and Skip Credits | media segments | chapter markers | Plex Pass markers, or chapters |
| Anime tab | Shoko | AniDB ids | Shoko, HAMA or AniDB agents |
| Song cards for openings and endings | OP/ED plugin, or AnimeThemes | AnimeThemes | AnimeThemes |
| Styled ASS subtitles (libass), with the file's fonts | ✓ | ✓ (fonts read from the file) | ✓ (track and fonts read from the file) |
| Music, audiobooks, lyrics | ✓ | ✓ | |
| Live TV and recordings | ✓ | ✓ (Emby Premiere) | |
| Channels from playlists, playlists, Upcoming | ✓ | ✓ | |
| Downloads, favourites, trickplay previews | ✓ | ✓ | |
| Settings kept on the server | ✓ | ✓ | |
| Widget and Top Shelf rows | ✓ | ✓ | |
| Quick Connect, disc menus, OP/ED plugin, channel groups | ✓ | | |
| Saved servers, switching, Lock After | ✓ | ✓ | ✓ (Plex Home PIN) |

## Emby

Emby and Jellyfin share an API underneath (Jellyfin forked from Emby 3.5), so Emby goes through the same client, `JellyfinClient`, with its `kind` set to `.emby`:
- **Routes:** about 15 of Emby's routes still use the older per-user form (`/Users/{id}/Views`, `/Users/{id}/Items/Resume`, …). `route(_:emby:)` picks the right one.
- **Sign-in:** the server's address and a password, as on Jellyfin. There's no Quick Connect.
- **Skip Intro:** Emby has no media segments API. Its intro chapter markers become skip segments instead.
- **Scrub previews:** Emby's thumbnails come as one BIF file per title (`/Videos/{id}/index.bif`), made when the library has thumbnail extraction turned on. `BIFIndex` reads its index, and each frame is a JPEG cut from the file.
- **Lyrics:** Emby has no lyrics route. It lists a song's lyrics (an `.lrc` beside it, or the file's own tag) as a subtitle stream, fetched as text and read by `Lyrics(lrc:)`.
- **Converted streams:** MPEG-TS with H.264 only. Emby's fMP4 HLS fails on Apple TV.
- **Server detection:** `/System/Info/Public` answers on both; its product name tells them apart, so the user only types an address.

## Plex

Plex shares nothing with Jellyfin's API, so it has its own client, `PlexClient` (`AsterFIN/Plex/`). It answers in the app's own models: `PlexMapper` turns Plex's titles into `BaseItem`s, and its playback into the playback info the players already read.

**Signing in** (`PlexAccount.swift`, `PlexSignInView.swift`):
1. Aster shows a code to enter at plex.tv/link.
2. The user picks one of the account's servers. Owned servers come first, then shared ones, each with its own access token.
3. On a Plex Home, the user picks a profile, with its PIN if it has one.

All of a server's addresses are tried at once, and the first to answer is used; home addresses are preferred. If the saved address stops answering, Aster tries the others, then asks plex.tv for the latest list.

**Locking:** a Plex server can be locked, or ask before switching to it, with the profile's Plex Home PIN. The PIN is checked against plex.tv with the Home's own token, so a profile without a PIN, or a sign-in from before that token was kept, can't be locked. Its page offers **Sign In with Plex Again** instead.

**Playing:**
- **Direct play:** the file itself (`/library/parts/{id}/file`), played by AetherEngine, which plays MKV.
- **When it must be converted:** Plex's universal transcoder, as HLS. Tracks are chosen on the server first, as Plex's own apps do, which also makes them the title's default there.
- **Progress:** reported to `/:/timeline`, which also keeps the resume point. Watched marks use `/:/scrobble`.
- **Skip Intro and Skip Credits:** Plex Pass intro and credits markers. Without them, chapters named Opening and Ending are used.
- **Subtitles:**
  - Subtitle files beside the video are fetched and drawn by Aster.
  - Plex won't hand out tracks inside a file (it answers 501), so Aster reads a text track out of the file itself: AetherEngine opens the file a second time for that one stream, and the fonts come from the MKV's attachments (`MatroskaFonts`). ASS/SSA is then drawn by libass, as on Jellyfin, whether the picture plays from the file or from a conversion, and a text track never needs the stream restarted. Picture subtitles (PGS) are drawn by the engine on direct play and burned in by the server on a converted stream, as on Jellyfin.
  - Before each converted stream Aster asks for Plex's transcode decision, which Plex requires, and the video comes as H.264: AetherEngine can't show Plex's HEVC in MPEG-TS when a conversion starts partway in.

**When something goes wrong,** Aster says why:
- the server isn't answering (check it's on, and turn on Remote Access to use it away from home);
- Plex no longer takes the sign-in;
- the server's transcoder is busy with other streams;
- the stream goes through Plex's relay, which only allows low quality.

## Song cards without the OP/ED plugin

On Emby, Plex, and Jellyfin without the OP/ED plugin, an anime episode's openings and endings are found from its chapters. Their songs come from [AnimeThemes](https://animethemes.moe):
- **By AniDB id** when the server knows the season's (Jellyfin with Shoko).
- **Otherwise by name:** the show's name and the year the season began, since AnimeThemes lists each season apart and by its Japanese name.

Each theme lists the episodes it plays in, so an episode with its own ending gets that song. The card appears as soon as the episode plays, from the chapters alone. The song's details fill in when AnimeThemes answers.

## Testing

- **Unit tests** cover the parts that don't need a server, using replies trimmed from real servers with tokens stripped:
  - `ItemQueryTests`: Jellyfin's query parameters, pinned to what the screens sent before the protocol existed.
  - `ImageURLTests`.
  - `PlexAccountTests`, `PlexMapperTests`, `PlexPlaybackTests` and `PlexSessionTests`.
  - `AnimeThemesTests`.
  - `ServerKindTests`.
- **On devices:** sign in, Home, each library, title pages, direct and converted playback, resume and watched, search, subtitles and skip intro, on each kind of server.
