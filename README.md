<p align="center">
  <img src="docs/screenshots/home.jpg" alt="AsterFIN Home screen" width="100%">
</p>

# AsterFIN

A native Jellyfin client for Apple TV, iPhone, iPad and the Mac, written in SwiftUI.

AsterFIN covers movies, TV, anime, music, audiobooks and live TV, and can turn your Jellyfin playlists into TV-style channels. Title pages are laid out like the Apple TV app, with theme music and theme videos, and it plays JellyDisc DVD/Blu-ray-style disc menus. You can watch with the system player, or try **AetherEngine**, a player that plays the original file and switches every audio and subtitle track on the device.

> AsterFIN is in beta (0.3). Expect rough edges, and please report what you find.

## Get AsterFIN

AsterFIN is open source, and there are three ways to get it:

- **App Store** (coming soon): one purchase covers Apple TV, iPhone, iPad and the Mac. It installs in one click, updates automatically and supports development. The beta is on TestFlight now.
- **Free IPA**: download it from [Releases](https://github.com/AsterFIN-app/AsterFIN/releases) when one is posted. Apple TV, iPhone and iPad only run signed apps, so you need to re-sign the IPA with your own Apple ID before installing it. With a free Apple ID the signature expires after 7 days; with a paid Apple Developer account it lasts a year.
- **Build it yourself**: see [Building](#building) below.

All three are the same app with the same features.

## Screenshots

Taken on Apple TV.

| | |
| --- | --- |
| ![Home](docs/screenshots/home.jpg) | ![Title page](docs/screenshots/detail.jpg) |
| **Home**: featured banner, Continue Watching, Up Next, recently added | **Title page**: full-bleed art, episodes, cast, Watch OP / Watch ED for anime |
| ![Live TV guide](docs/screenshots/guide.jpg) | ![Music](docs/screenshots/music.jpg) |
| **Live TV**: guide, recordings, mini player | **Music**: albums, artists, lyrics, Now Playing |
| ![Anime](docs/screenshots/anime.jpg) | ![Disc menu](docs/screenshots/disc-menu.jpg) |
| **Anime**: openings and endings with song cards | **Disc menus**: JellyDisc menus with transitions and sounds |

## Platforms

| | Apple TV | iPhone & iPad | Mac |
| --- | :---: | :---: | :---: |
| Browsing, title pages, search | ✓ | ✓ | ✓ |
| System player | ✓ | ✓ | ✓ |
| AetherEngine player (test) | ✓ | ✓ | ✓ |
| Music and audiobooks, with a now-playing bar | ✓ | ✓ | ✓ |
| Live TV | ✓ | ✓ | ✓ |
| Channels from playlists (beta) | ✓ | ✓ | ✓ |
| Downloads for offline viewing | | ✓ | |
| Top Shelf | ✓ | | |
| Full-screen playback, keyboard shortcuts | | | ✓ |
| CarPlay audiobooks | | waiting on Apple's entitlement | |

## Features

### Watching
- **Home**: a featured banner, then shelves for Continue Watching, Up Next, recently added Movies, TV Shows and Anime, and one shelf per library. Play or Resume on the banner starts the title straight away, and Back lands on its page.
- **Title pages**: theme music and muted looping theme videos fade in and out. Each page has seasons and episodes, cast, and related titles. On an episode, a bar under Play lists the rest of the season.
- **Upcoming**: episodes airing soon from the shows in your library, day by day, with a banner of what's next.
- **Up Next**: at the end of an episode an Up Next card counts down to the next one. Skip Intro, Skip Credits and Play Next Episode come from the server's media segments. Intros can also be skipped automatically.
- **Playlists**: Add to Playlist from any title. Video playlists have Play All and Shuffle, and you can reorder or remove items.

### Two players
- **System player** (the default): Apple's player. AsterFIN direct plays when it can and asks the server to transcode when it can't. If a stream fails, it retries with a fresh H.264/AAC encode.
- **AetherEngine** (Settings ▸ Playback ▸ "Use AetherEngine (test)"): plays the original file through [AetherEngine](https://github.com/superuser404notfound/AetherEngine) (FFmpeg demuxing, VideoToolbox decoding), so nothing is transcoded.
  - **Tracks:** every audio and subtitle track switches on the device instantly, PGS/DVB/VobSub picture subtitles are drawn as they are, and HDR10, Dolby Vision and Atmos pass through.
  - **Apple TV controls:** they work like the system player's. Click to pause, swipe to scrub while paused, swipe down for Chapters, Audio and Subtitles, and Back steps out one level at a time.
  - **Pause screen:** on Apple TV and the Mac, the title's logo and details appear, with a long description scrolling slowly.
  - **Not yet:** music, audiobooks, Live TV, downloads and theme clips still use the system player.

### Subtitles
- **Text subtitles:** AsterFIN draws them itself from Jellyfin's cue data, so they work in direct play as well as HLS.
- **ASS/SSA:** drawn with [libass](https://github.com/libass/libass) as the release intended: signs where they belong, vector drawings, blur and clips, in the fonts embedded in the file. You can turn this off for plain text in Settings ▸ Audio & Subtitles.

### Anime
- **Anime tab:** libraries matched by Shoko/AniDB get their own tab and are left out of Movies and TV Shows. The tab has its own banner and appears only when the server has anime.
- **Openings and endings:** they come from the OP/ED plugin, or from chapter markers if it isn't installed. While one plays, a "music video" card shows the song, artists and series.

### Music and audiobooks
- **Music:** albums, artists, playlists and songs. The full player has shuffle, repeat and lyrics, plus system Now Playing info.
- **Audiobooks:** books are put together from a library's files, with authors and series taken from the folders. There are chapters, per-book playback speed, and progress synced with Jellyfin. On iPhone and iPad you can download a book and listen offline.
- **Back to the player from anywhere:**
  - on iPhone and iPad, a bar under the tab bar;
  - on the Mac, a bar at the foot of the sidebar and the Space bar;
  - on Apple TV, the remote's Play/Pause button.
- **Background audio:** both keep playing in the background.

### Live TV
- What's on now, a programme guide, a channel list and recordings.
- A mini player keeps the channel playing in the header after you press Back.
- Record single programmes, or set series recording rules with options.

### Channels (Beta)
Your Jellyfin video playlists become TV-style channels on a Channels tab, laid out in the same guide as Live TV. Tune in and you join whatever is on, partway through, and when it ends the channel carries on to what's on next.
- **Setup:** pick playlists and their order in Settings ▸ Channels (Beta). A channel can show its playlist's picture as its logo. The Channels tab appears once a channel is on.
- **Movies and TV:** a series plays its episodes in order and picks up where it left off, like reruns. Specials are left out, and each movie takes a turn of its own.
- **Two modes, chosen per channel:** **Rotation** plays one episode of each show in turn; **Blocks** plays two to four in a row. Either way the order is reshuffled every day.
- **Same guide everywhere, without a server:** each channel's schedule is worked out on the device from the playlist and the clock, so every device shows the same programme at the same moment. Nothing is stored and no plugin is needed.
- **Synced settings:** your channels, modes and logos are saved in AsterFIN's own settings on your Jellyfin server (its display preferences), so they follow your Jellyfin account to your other devices.
- **Watch history is left alone:** watching a channel doesn't change resume points, watched marks or Continue Watching.

### Disc menus
- AsterFIN renders DVD/Blu-ray-style menus from the **JellyDisc** plugin. They support backgrounds, chapter and trailer screens, and theme songs.
- Screens change with fade, slide, rise, zoom or wipe transitions. Menu music and click, chime or beep sounds are built in, or a menu can ship its own sound files.
- Conformance tests check the menu rules against the plugin's published test vectors.

### Platform integration
- **Apple TV:** a Top Shelf showing Continue Watching, Next Up and recent Live TV channels, and the native search tab.
- **iPhone and iPad:**
  - Downloads, in the background, with your choice of quality, storage limit and cellular use. Progress made offline syncs back to the server.
  - A tab bar you can reorder.
- **Mac:**
  - A sidebar and a Settings window (⌘,).
  - Videos play full screen (or in the window, if you'd rather).
  - Keyboard shortcuts: Space to play or pause, ← → to jump, Esc to close.
- **Deep links:** `asterfin://item/{id}` opens a title page, and `asterfin://play/{id}` starts playback.
- **Sign-in:** password or Quick Connect, with multiple users per server.

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
- The tvOS 27, iOS 27 and macOS 27 SDKs (every platform's deployment target is 27.0)
- An Apple silicon Mac. AetherEngine's decoders ship for arm64 only, so the simulators run as arm64.

```sh
git clone https://github.com/AsterFIN-app/AsterFIN.git
open AsterFIN/AsterFIN.xcodeproj
```

Xcode fetches the Swift packages on first open. Select the **AsterFIN** scheme and an Apple TV, iPhone, iPad or Mac destination, then build and run.

To run on a device, set your own development team in **Signing & Capabilities** for both the `AsterFIN` and `AsterFINTopShelf` targets. Top Shelf needs an App Group that both targets share (`group.app.asterfin` by default), so change it to one your team owns.

### Project layout

| Folder | Contents |
| --- | --- |
| `AsterFIN/App` | Session state, settings, deep link routing |
| `AsterFIN/Jellyfin` | API client, models, Keychain storage |
| `AsterFIN/Player` | Both video players, subtitles (text and libass), music, audiobook and theme players |
| `AsterFIN/DiscMenu` | JellyDisc menu models, rules, rendering, transitions, audio |
| `AsterFIN/Downloads` | Video and audiobook downloads (iPhone and iPad) |
| `AsterFIN/CarPlay` | CarPlay scene (needs Apple's entitlement) |
| `AsterFIN/UI` | Feature screens (Home, Library, Detail, Upcoming, Live TV, Channels, Music, Audiobooks, Anime, …) |
| `AsterFINTopShelf` | Top Shelf extension |
| `AsterFINTests` | Unit tests and JellyDisc conformance vectors |

## Known limitations

- **System player:**
  - Picture-based subtitles (PGS, VobSub) are burned in by the server, which forces a transcode.
  - A transcoded stream has one audio track, so switching audio needs direct play.
  - Use AetherEngine for both.
- **Jellyfin HLS subtitles:** Jellyfin's fMP4 HLS output times subtitles about 10 seconds late (jellyfin/jellyfin#16647). AsterFIN avoids this by drawing subtitles itself.
- **AetherEngine:** it's a test. It doesn't yet do Picture in Picture, trickplay thumbnails or the system Now Playing info, and on iPhone and iPad its controls are basic.
- **Channels (beta):**
  - Each day starts at local midnight, so devices in different time zones show different schedules.
  - Editing a playlist changes that channel's schedule from then on, including how far each show has got.
  - There's no channel up/down inside the player yet.
- **Mac:** the Mac app has no downloads yet.
- **Anime without the OP/ED plugin:** openings and endings are guessed from chapter names.

## Open-source components

| Component | License |
| --- | --- |
| [AetherEngine](https://github.com/superuser404notfound/AetherEngine) | LGPL-3.0, with an exception for App Store distribution |
| ↳ [FFmpeg](https://ffmpeg.org) (via FFmpegBuild, as separate frameworks) | LGPL-2.1 |
| ↳ libdovi, the TrueHD decoder | MIT |
| ↳ the DTS:X decoder | Apache-2.0 |
| ↳ SMBClient | MIT |
| [swift-ass-renderer](https://github.com/mihai8804858/swift-ass-renderer) and swift-libass ([libass](https://github.com/libass/libass)) | MIT (libass: ISC) |
| Point-Free's swift-issue-reporting, swift-concurrency-extras, combine-schedulers | MIT |

## License

AsterFIN is licensed under the [Mozilla Public License 2.0](LICENSE). You're free to use, modify and redistribute it. If you distribute a modified version, the files of AsterFIN you changed must stay available under the MPL. New files you add can use any license. The components above keep their own licenses.

The AsterFIN name and app icon aren't covered by the license. If you publish your own build, for example on the App Store, give it a different name and icon so people don't confuse it with the official app.

AsterFIN isn't affiliated with or endorsed by the Jellyfin project.
