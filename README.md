<p align="center">
  <img src="docs/screenshots/home.jpg" alt="AsterFIN Home screen" width="100%">
</p>

# AsterFIN

A native Jellyfin client for Apple TV, written in SwiftUI with no third-party dependencies.

AsterFIN covers movies, TV, music and live TV. It also has an Anime section, a DVD/Blu-ray-style disc menu player for the JellyDisc plugin, and title pages laid out like the Apple TV app, with theme music and theme videos.

## Get AsterFIN

AsterFIN is open source, and there are three ways to get it:

- **App Store** (coming soon): a paid download that installs in one click and updates automatically. Buying it supports development.
- **Free IPA**: download `AsterFIN.ipa` from [Releases](https://github.com/AsterFIN-app/AsterFIN/releases). tvOS only runs signed apps, so you need to re-sign the IPA with your own Apple ID and install it on your Apple TV. With a free Apple ID the signature expires after 7 days; with a paid Apple Developer account it lasts a year.
- **Build it yourself**: see [Building](#building) below.

All three are the same app with the same features.

## Screenshots

| | |
| --- | --- |
| ![Home](docs/screenshots/home.jpg) | ![Title page](docs/screenshots/detail.jpg) |
| **Home** — featured banner, Continue Watching, Up Next, recently added | **Title page** — full-bleed art, cast, and Watch OP / Watch ED for anime |
| ![Live TV guide](docs/screenshots/guide.jpg) | ![Music](docs/screenshots/music.jpg) |
| **Live TV** — guide, recordings, mini player | **Music** — albums, artists, lyrics, Now Playing |
| ![Anime](docs/screenshots/anime.jpg) | ![Disc menu](docs/screenshots/disc-menu.jpg) |
| **Anime** — openings and endings with theme info cards | **Disc menus** — JellyDisc menus with transitions and sounds |

## Features

### Watching
- **Home**: a featured banner, then shelves for Continue Watching, Up Next, recently added Movies, TV Shows and Anime, and one shelf per library.
- **Title pages**: theme music and muted looping theme videos fade in and out. Each page has cast, seasons, episodes and related shelves.
- **Player**: uses the system tvOS player. Skip Intro and Skip Credits come from the server's media segments, and an Up Next card appears at the end. AsterFIN direct plays when it can and transcodes when it has to. If a stream fails, it retries with a fresh H.264/AAC encode.
- **Subtitles**: AsterFIN draws text subtitles itself from Jellyfin's cue data, so they work in direct play as well as HLS.
- **Playlists**: Add to Playlist from any title. Video playlists have Play All and Shuffle, and you can reorder or remove items with a long press.

### Live TV
- What's on now, a programme guide, a channel list and recordings.
- A mini player keeps the channel playing in the header after you press Back.
- Record single programmes, or set series recording rules with options.

### Music
- Albums, artists, playlists and songs, with a persistent Now Playing bar.
- A full player with shuffle, repeat and lyrics, plus system Now Playing info.
- Audio keeps playing in the background.

### Anime
- Libraries matched by Shoko/AniDB get their own tab and are left out of Movies and TV Shows.
- Openings and endings come from the OP/ED plugin, or from chapter markers if it isn't installed. While a theme plays, a "music video" card shows the song, artists and series.

### Disc menus
- AsterFIN renders DVD/Blu-ray-style menus from the **JellyDisc** plugin. They support backgrounds, chapter and trailer screens, and theme songs.
- Screens change with fade, slide, rise, zoom or wipe transitions. Menu music and click, chime or beep sounds are built in, or a menu can ship its own sound files.
- Conformance tests check the menu rules against the plugin's published test vectors.

### Apple TV integration
- **Top Shelf**: shows Continue Watching, Next Up and recently played Live TV channels.
- **Deep links**: `asterfin://item/{id}` opens a title page, and `asterfin://play/{id}` starts playback.
- **Search**: uses the native tvOS search tab.
- **Sign-in**: password or Quick Connect, with multiple users per server.

## Server requirements

AsterFIN works with a recent Jellyfin server (10.10 or later recommended). All plugins are optional, and features that depend on them turn on when they're present:

| Plugin | Enables |
| --- | --- |
| JellyDisc | Disc menus |
| Intro Skipper (or chapters / EDL) | Skip Intro and Skip Credits |
| OP/ED | Anime openings and endings with song details |
| Shoko | Detecting Anime libraries |

Theme songs and theme videos use Jellyfin's standard theme media.

## Building

Requirements:
- Xcode 27
- tvOS 27 SDK (the deployment target is tvOS 27.0)

```sh
git clone https://github.com/AsterFIN-app/AsterFIN.git
open AsterFIN/AsterFIN.xcodeproj
```

Select the **AsterFIN** scheme and an Apple TV simulator or device, then build and run. To run on a device, set your own development team in **Signing & Capabilities** for both the `AsterFIN` and `AsterFINTopShelf` targets. Top Shelf needs an App Group that both targets share (`group.app.asterfin` by default), so change it to one your team owns.

### Project layout

| Folder | Contents |
| --- | --- |
| `AsterFIN/App` | Session state, deep link routing |
| `AsterFIN/Jellyfin` | API client, models, Keychain storage |
| `AsterFIN/Player` | Playback coordinator, player UI, subtitles, music and theme players |
| `AsterFIN/DiscMenu` | JellyDisc menu models, rules, rendering, transitions, audio |
| `AsterFIN/UI` | Feature screens (Home, Library, Detail, Live TV, Music, Anime, …) |
| `AsterFINTopShelf` | Top Shelf extension |
| `AsterFINTests` | Unit tests and JellyDisc conformance vectors |

## Known limitations

- Picture-based subtitles (PGS, VobSub) are burned in by the server, which forces a transcode.
- A transcoded stream has a single audio track. Switching audio tracks needs direct play.
- Jellyfin's fMP4 HLS output times subtitles about 10 seconds late (jellyfin/jellyfin#16647). AsterFIN works around this by drawing subtitles itself.
- Without the OP/ED plugin, anime openings and endings are guessed from chapter names.

## License

AsterFIN is licensed under the [Mozilla Public License 2.0](LICENSE). You're free to use, modify and redistribute it. If you distribute a modified version, the files of AsterFIN you changed must stay available under the MPL. New files you add can use any license.

The AsterFIN name and app icon aren't covered by the license. If you publish your own build, for example on the App Store, give it a different name and icon so people don't confuse it with the official app.

AsterFIN isn't affiliated with or endorsed by the Jellyfin project.
