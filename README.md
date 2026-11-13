<p align="center">
  <img src="docs/screenshots/home.jpg" alt="Aster Media Player Home screen" width="100%">
</p>

# Aster Media Player

A native client for Jellyfin, Emby and Plex on Apple TV, iPhone, iPad and the Mac, written in SwiftUI.

Aster covers movies, TV, anime, music, audiobooks and live TV, and can turn your Jellyfin playlists into TV-style channels. Title pages are laid out like the Apple TV app, with theme music and theme videos, and Aster plays DVD/Blu-ray-style disc menus. Videos play in **AetherEngine**, a player that plays the original file and switches every audio and subtitle track on the device, with Apple's own player as a fallback.

With Aster's server plugin you can discover and request new titles through Seerr, and keep Simkl, AniList, MyAnimeList and others up to date. With Bonfire profiles or a Plex Home, a household shares one account, with a profile and a PIN each, and a lock. Emby and Plex servers work too: see [Servers](#servers) for what each one gets.

> Aster is in beta (0.11). Expect rough edges, and please report what you find (Settings ▸ About ▸ Send Debug Report helps).

## Get Aster

Aster Media Player (formerly AsterFIN) is free, and always will be: on every platform, with every feature, and no paid version. It's open source, and there are three ways to get it:

- **[App Store](https://apps.apple.com/us/app/aster-media-player/id6821328142)**: free, with one download for Apple TV, iPhone, iPad and the Mac. It installs in one click and updates automatically.
- **IPA**: download the latest from [Releases](https://github.com/AsterMediaPlayer/aster-apple/releases): an IPA for iPhone and iPad, one for Apple TV, and the Mac app. Apple TV, iPhone and iPad only run signed apps, so you need to re-sign the IPA with your own Apple ID before installing it. With a free Apple ID the signature expires after 7 days; with a paid Apple Developer account it lasts a year.
- **Build it yourself**: see [Building](#building) below.

All three are the same app with the same features.

## Screenshots

Taken on Apple TV, with openly licensed films from the Blender Foundation and friends.

| | |
| --- | --- |
| ![Home](docs/screenshots/home.jpg) | ![Title page](docs/screenshots/detail.jpg) |
| **Home**: featured banner, Continue Watching, Up Next, recently added | **Title page**: full-bleed art, extras, cast, related titles |
| ![Music](docs/screenshots/music.jpg) | ![Disc menu](docs/screenshots/disc-menu.jpg) |
| **Music**: albums, artists, lyrics, Now Playing | **Disc menus**: menus from the Aster Disc plugin, with transitions and sounds |
| ![Channels](docs/screenshots/channels.jpg) | ![Channel row](docs/screenshots/channel-row.jpg) |
| **Channels**: playlists as TV channels, movies and shows in the same guide | **Channel row**: press Up while watching to flick through channels, or Go to Episode |

## Platforms

| | Apple TV | iPhone & iPad | Mac |
| --- | :---: | :---: | :---: |
| Browsing, title pages, search | ✓ | ✓ | ✓ |
| AetherEngine player (the default) | ✓ | ✓ | ✓ |
| System player (fallback, or by choice) | ✓ | ✓ | ✓ |
| Music and audiobooks, with a now-playing bar | ✓ | ✓ | ✓ |
| Live TV and Channels | ✓ | ✓ | ✓ |
| Discover and Seerr requests | ✓ | ✓ | ✓ |
| Tracking and watchlists | ✓ | ✓ | ✓ |
| Household profiles and the PIN lock | ✓ | ✓ | ✓ |
| Disc menus | ✓ | ✓ | ✓ |
| Picture in Picture | | ✓ | |
| Downloads for offline viewing and listening | | ✓ | |
| Widgets and Live Activities | | ✓ | |
| CarPlay (music and audiobooks) | | ✓ | |
| Siri for music (iOS 27) | | ✓ | |
| AirPlay 2 and Sonos for music | | ✓ | |
| Top Shelf | ✓ | | |
| Keyboard, game controllers, full-screen playback | | | ✓ |

## Features

### Watching
- **Home**: a featured banner, then shelves for Continue Watching, Up Next, recently added Movies, TV Shows and Anime, and one shelf per library. Play or Resume on the banner starts the title straight away, and Back lands on its page.
- **Title pages**: theme music and muted, looping theme videos fade in and out (episodes and seasons share their show's). A show's page has tabs for Episodes, Music, Extras, Related and Details. On an episode, a bar under Play lists the rest of the season.
- **Scores**: IMDb, Rotten Tomatoes (critics and audience), Metacritic, Letterboxd and TMDB, from the server, with the rest from MDBList if you add an MDBList API key.
- **Libraries**: sort by name, date added, release date or rating, and jump with an A–Z index (a strip down the side on iPhone, iPad and the Mac, a row of letters on Apple TV) that also knows kana, Korean and pinyin.
- **Search**: movies, shows, episodes and music in one place, with titles you can request from Seerr when your library doesn't have them.
- **Upcoming**: episodes airing soon from the shows in your library, day by day, with a banner of what's next.
- **Up Next**: at the end of an episode an Up Next card counts down to the next one. Skip Intro, Skip Credits and Play Next Episode come from the server's media segments, and intros can be skipped automatically.
- **Playlists**: Add to Playlist from any title, into a playlist you have or a new one. Video playlists have Play All and Shuffle, and you can reorder or remove items.

### Two players
- **AetherEngine** (the default): plays the original file through [AetherEngine](https://github.com/superuser404notfound/AetherEngine) (FFmpeg demuxing, VideoToolbox decoding), so nothing is transcoded unless it has to be.
  - **Tracks:** every audio and subtitle track switches on the device instantly, PGS/DVB/VobSub picture subtitles are drawn as they are, and HDR10, Dolby Vision (Profile 7 FEL included) and TrueHD Atmos and DTS:X pass through.
  - **When the file is too much:** AV1 and VP9 on Apple TV, which has no hardware for them, are converted by the server and still play in AetherEngine. So does a lower quality, picked from the Quality menu or from the card that comes up when playback keeps stalling.
  - **When it can't play something:** the title moves to the system player by itself, from the same spot and on the same tracks.
  - **Apple TV controls:** they work like the system player's. Click to pause, swipe to scrub while paused (with a preview frame), swipe down for Chapters, Audio, Subtitles and Quality, and Back steps out one level at a time.
  - **iPhone and iPad controls:** double-tap either side to skip 10 seconds, pinch to fill the screen, a scrub preview, and menus for chapters, speed (0.5x to 2x), audio, subtitles and quality, plus AirPlay and Picture in Picture.
  - **Mac controls:** Space or Return to pause, ← → to skip 10 seconds, Esc to leave. Videos play full screen, or in the window if you'd rather.
  - **Scrub previews:** Jellyfin's trickplay images or Emby's, when the server has made them, else stills from what's already downloaded.
  - **Now Playing:** the lock screen, Control Center and headphone buttons on iPhone and iPad, the Apple TV's remote, and the Mac's Now Playing.
  - **Pause screen:** on Apple TV and the Mac, the title's logo and details appear, with a long description scrolling slowly. On a channel it shows what's on and what's next.
- **System player** (Settings ▸ Playback ▸ Video ▸ "Use the system player"): Apple's player. Aster direct plays when it can and asks the server to transcode when it can't. If a stream fails, it retries with a fresh H.264/AAC encode. Playlists (Play All, Shuffle), downloads and opening/ending clips always use it.

### Subtitles
- **Text subtitles:** Aster draws them itself from the server's cue data, so they work in direct play as well as HLS.
- **ASS/SSA:** drawn with [libass](https://github.com/libass/libass) as the release intended: signs where they belong, vector drawings, blur and clips, in the fonts embedded in the file. You can turn this off for plain text in Settings ▸ Playback ▸ Audio & Subtitles.

### Anime
- **Anime tab:** libraries matched by Shoko/AniDB get their own tab and are left out of Movies and TV Shows. The tab has its own banner and appears only when the server has anime.
- **Openings and endings:** a show's Music tab has its openings and endings, to watch on their own or play back to back, with Watch OP and Watch ED in the action row. They come from the Aster OP-ED plugin, or from chapter markers without it.
- **Song cards:** while an opening or ending plays, a "music video" card shows the song, artists and series. Without the plugin (and on Emby and Plex), the song and artists come from [AnimeThemes](https://animethemes.moe). The card moves up out of the way while the player's controls are on screen.

### Music
- **Library:** albums, artists, playlists and songs, with Shuffle and Instant Mix on albums and playlists.
- **The player:** shuffle, repeat (all or one), synced lyrics, and Up Next to skip ahead to any song in the queue.
- **Gapless playback** between songs of the same format, on by default (Settings ▸ Playback ▸ Music).
- **Save upcoming songs:** the next five songs are kept on the device as you listen (on Wi-Fi by default, never in Low Data Mode), so music plays on through a patch with no signal. They're deleted once heard.
- **Speakers:** on iPhone and iPad, AirPlay 2 speakers and groups (HomePod pairs, Sonos) play on with the phone locked, and Sonos rooms can be picked directly; each speaker fetches the songs from your server itself.
- **Siri** (iPhone and iPad, iOS 27): play a song, album, artist or playlist by name, play next or later, add the song playing to a playlist, or like it. "Play some music" plays your favourites.

### Audiobooks
- **Books from your files:** a library's files are put together into books, with authors and series taken from the folders (`Author/Series/Book/`).
- **Listening:** chapters, skip back 15 seconds or ahead 30, speeds from 0.75x to 3x remembered per book, and progress synced with your server.
- **Offline** (iPhone and iPad): download a book to listen without a connection, and Listen Ahead (Settings ▸ Playback; 30 minutes by default) keeps the next stretch of a streamed book on the device. What you listen to offline syncs back later.
- **Back to the player from anywhere**, for music and books:
  - on iPhone and iPad, a bar under the tab bar;
  - on the Mac, a bar at the foot of the sidebar and the Space bar;
  - on Apple TV, the remote's Play/Pause button.
- **Background audio:** music and books keep playing in the background.

### Live TV
- What's on now, a programme guide, a channel list, and shelves of what's on in movies, sports, kids and news, plus your favourite channels.
- **Recordings:** record a programme, or set series rules (which episodes, how many to keep, and padding). Recorded and Scheduled are kept apart from the rules.
- **Changing channels:**
  - on Apple TV, press Up for the channel row and go left or right; click to tune;
  - on an iPhone or iPad held sideways, a dial on the right edge: drag or flick it, with ticks you feel and hear, and let go to tune;
  - on an iPhone held upright, the picture on top and the channel list under it.
- **A mini player** keeps the channel playing in the header after you press Back, and choosing another channel switches it in the same player.
- **Channel groups:** with the Aster Channels plugin, channels are grouped into sports, news, kids and more, in the guide and as you flip.

### Channels
Channels turn your own movies and shows into TV you can just put on. Each channel runs around the clock on a schedule, with a guide like Live TV's. Tune in and you join whatever's on, partway through, then it carries on to the next thing, the way real TV does. Every device shows the same thing at the same moment.

**Make your first channel** (you need to be a server administrator):
1. Open the **Channels** tab and choose **Edit Channels**. (If you don't have the tab yet, it's in **Settings ▸ Channels**.)
2. Under **New Channel**, pick **From a Show**, then a show.
3. That's it: the channel is playing. Go back to the Channels tab, choose it in the guide and press Select to tune in.

You can also make a channel **from a genre** (all your horror, say), **a network** (everything from NBC), **a collection**, or **one of your playlists**. Want a mix, like two shows on one channel? Make a playlist with both in Jellyfin, then pick **From One of Your Playlists**.

**Change a channel:** in Edit Channels, open a channel to see the basics: its name, number, what it plays, how it plays (**Mode**), its logo, and breaks. Everything else is under **Advanced**, including a group for the guide and a channel logo in the corner of the picture. On Apple TV you can also move left onto a channel in the guide and press Select to open its settings.

**Add commercial breaks** (optional):
1. Add your clips to Jellyfin as ordinary videos: commercials, trailers, promos, short filler videos ("interstitials"), and bumpers (the channel's own "We'll be right back" clips).
2. In Jellyfin, tag each clip with what it is: `aster:commercial`, `aster:trailer`, `aster:promo`, `aster:interstitial` or `aster:bumper`. A clip without one of these tags is skipped.
3. Put them in a playlist, any mix, and tag the playlist `aster:filler`.
4. In Edit Channels, pick that playlist under **Breaks**.

Now there's a break after each programme, and the channel lines itself up so shows start on the hour and half hour. One playlist of breaks can serve as many channels as you like.

**How a channel picks what to play:**
- **Rotation** (the usual): one episode of each show in turn, like a channel of reruns.
- **Blocks:** two to four episodes of a show in a row, then the next show.
- **Shuffle:** everything in a random order.
- **In Order:** the playlist exactly as you arranged it, round and round.
- **Air Date:** everything in the order it first aired.

Shows always play their episodes in order and pick up where they left off. Specials are left out.

**Good to know:**
- **Your watch history is safe:** watching a channel doesn't change resume points, watched marks or Continue Watching.
- **Want to watch something properly?** On Apple TV, press Up for the channel row, then Up again to **Go to Episode**. It plays the episode on its own, from where you left off, with skipping, scrubbing and Up Next. On a channel itself you can pause but not skip, so everyone stays on the same schedule.
- **Who sees a channel:** everyone on your server, as long as its playlist is shared with them or public. To keep a channel to certain people, pick them under **Advanced ▸ Users**.
- **The guide covers a week ahead,** with a day picker at the top.
- **Your channels live on your server:** every setting is saved as a tag on the playlist in Jellyfin, so every device finds the same channels, and you can edit the tags in Jellyfin too (or, with the Aster Channels plugin, from Jellyfin's dashboard). The full list is in [docs/channel-tags.md](docs/channel-tags.md).

### Disc menus
- Aster renders DVD/Blu-ray-style menus from the **Aster Disc** plugin (menus in the JellyDisc format). They support moving backgrounds, chapter and trailer screens, and theme songs. Pick menus from a community catalogue, or design your own.
- Screens change with fade, slide, rise, zoom or wipe transitions. Menu music and click, chime or beep sounds are built in, or a menu can ship its own sound files.
- A title with a menu has a Disc Menu button, and Settings ▸ Playback ▸ Video ▸ Disc Menus can open the menu when you press Play, like putting in the disc.
- Conformance tests check the menu rules against the plugin's published test vectors.

### Discover and requests
With the **Aster Discovery and Tracking** plugin on your Jellyfin server, the Discover tab has:
- **Discover:** rows the server builds for you: what to carry on with, recommendations, "because you watched", your watchlist, trending, and new seasons.
- **Upcoming:** what's coming to your library, by day.
- **Movies, Series and Requests**, when the server is linked to [Seerr](https://github.com/seerr-team/seerr) (Jellyseerr or Overseerr). Browse with filters, open a title to see its seasons, cast and trailer, and **Request** it (a season at a time, or in 4K where the server has it). Requests shows everyone's or just yours; people who manage requests can approve or decline them here.

Aster never signs in to Seerr itself: everything goes through the plugin, as you.

### Tracking and watchlists
- **Through the server** (with the Aster Discovery and Tracking plugin): link Simkl, AniList, MyAnimeList, Last.fm, ListenBrainz and Hardcover once in Settings ▸ Tracking, and the server sends what you watch, listen to and read from then on, from every app. Each service has a switch and a list of what was sent lately. On Apple TV, link from Jellyfin's dashboard or the iPhone app.
- **Add to Watchlist** on title pages, Seerr's pages and Discover: Simkl for anything, and AniList and MyAnimeList for anime. With more than one service that fits, it's a menu.
- **Without the plugin**, Aster updates them itself: AniList and MyAnimeList for anime, and Trakt and Simkl for films and shows (signed in with a code, which works on the TV), once you're 85% through. The sign-ins are kept, encrypted, on your server, so a TV picks up what you linked on your phone. Trakt stays on the device either way, until the plugin handles it.

### Household profiles
For a household on one account: profiles from the [Bonfire](https://github.com/AHouseOfBards/Bonfire-JellyProfiles) plugin on Jellyfin, or a Plex Home.
- **Who's watching?** Pick a profile from the picture at the top of Home on iPhone and iPad, or at the top of the sidebar on Apple TV and the Mac. Switching is instant, and a profile with a PIN asks for it on a PIN pad.
- **Asking as Aster opens:** Settings ▸ Account ▸ Ask on Opening. Choose As the Server Is Set (Bonfire's own "Ask on startup"), Every Time or Never.
- **Adding and changing profiles** (Bonfire, from the main account): Manage Profiles on the picker. Each profile has a name, a picture, a PIN (which can be skipped on the home network), a viewing limit and the libraries it sees. Removing a profile takes its watch history with it.
- **PIN lock:** set Settings ▸ Account ▸ Ask for PIN After, from a minute to four hours. After that long away, and whenever Aster opens, the profile's PIN is asked before anything plays. The main account can lock this way too, once it has a PIN. Anyone else at the lock screen can choose **Switch Profile** to pick their own profile. Adding and changing profiles stays off from behind a lock.

### Apple TV
- A **Top Shelf** of Continue Watching, Next Up and your recent Live TV channels, from the servers you choose (Settings ▸ Account).
- The native search tab, and controls that work like the system player's.

### iPhone and iPad
- **Downloads**, in the background: the original file, or 1080p, 720p or 480p (smaller still in HEVC), with the audio track and subtitles you pick, a storage limit, and cellular use if you allow it. Progress made offline syncs back to the server.
- **Widgets:** Continue Watching (small, medium and large), and On Now for your channels.
- **Live Activities** on the Lock Screen and in the Dynamic Island, for downloads and for the channel you're watching (what's on, with a countdown, and what's next).
- **CarPlay:** Music (recent, albums, artists, playlists, shuffle) and Audiobooks (continue listening, series, authors, every book, by chapter), with favourite, shuffle, repeat, Up Next, chapters and speed in Now Playing.
- **Picture in Picture**: a video carries on in a floating window when you leave the app.
- A tab bar you can reorder, and turn tabs off in.

### Mac
- A sidebar (⌃⌘S to show or hide it) and a Settings window (⌘,).
- Text, buttons and cards sized after the Apple TV app's, a step smaller for a nearer screen, rather than the Mac's usual small type.
- **Keyboard:** the arrow keys move around every page and Return opens; Esc, Delete, ⌘[ or the mouse's back button go back; ⌘F searches; Space plays or pauses music.
- **Game controllers** drive the app: the d-pad or left stick moves, A opens, B goes back, X plays or pauses, and the shoulder buttons skip songs or chapters. A Nintendo-style layout swaps A and B, X and Y (Settings ▸ General).
- **An iPad as a display** (Sidecar): drags scroll the page, and a hint shows the two-finger scroll.

### Everywhere
- **Sign-in:** password or Quick Connect on Jellyfin, password on Emby, and a plex.tv link code on Plex (then a Plex Home profile, with its PIN, and a server). Several servers and users can be saved, each can ask for its password or PIN before switching to it, and each can lock after a while away.
- **Welcome:** the first time on a Jellyfin server, a few cards show what Aster does, and a server administrator can install Aster's companion plugins and restart the server from there.
- **Settings that follow you** (Jellyfin and Emby): Up Next, skipping intros, styled subtitles, disc menus, theme music and videos, the opening sound, and song cards are kept on your server (in Aster's display preferences), so they match on every device you sign in on. Audio and subtitle languages use your Jellyfin user settings. Streaming quality, the system player switch, the tab bar, downloads and the Mac's full-screen playback stay per device.
- **Server plugins** (Settings ▸ Server Plugins, Jellyfin): see which of Aster's plugins your server has. An administrator can install them, turn them on or off, and restart the server.
- **Deep links:** `aster://item/{id}` opens a title page, `aster://play/{id}` starts playback, `aster://channel/{id}` tunes a channel, and `aster://downloads` opens Downloads.
- **Debug reports:** Settings ▸ About ▸ Send Debug Report sends what happened, with the app's recent log, settings and last crash, to the Aster team, and gives you a report number to quote in a GitHub issue. Passwords, tokens, addresses, names and file paths are taken out first. On iPhone, iPad and the Mac, Aster offers to send one after it closes unexpectedly.

## Servers

| | Jellyfin | Emby | Plex |
| --- | :---: | :---: | :---: |
| Home, libraries, title pages, search | ✓ | ✓ | ✓ |
| Playback with resume and watched | ✓ | ✓ | ✓ |
| Skip Intro and Skip Credits | ✓ | ✓ (chapter markers) | ✓ (Plex Pass markers, or chapters) |
| Anime tab and song cards | ✓ | ✓ | ✓ |
| Tracking from the device (Trakt, Simkl, AniList, MyAnimeList) | ✓ | ✓ | ✓ |
| Household profiles, with PINs and a PIN lock | ✓ (Bonfire) | | ✓ (Plex Home) |
| Music, audiobooks, Live TV, channels, playlists, Upcoming | ✓ | ✓ | |
| Downloads, favourites, trickplay previews, lyrics | ✓ | ✓ | |
| Widgets, Top Shelf, CarPlay, Siri, settings that follow you | ✓ | ✓ | |
| Quick Connect, disc menus, Discover, Seerr, tracking through the server | ✓ | | |

More detail, including what each server needs, is in [docs/emby-plex.md](docs/emby-plex.md).

### Jellyfin

Aster works with a recent Jellyfin server. All plugins are optional, and features that depend on them turn on when they're present:

| Plugin | Enables |
| --- | --- |
| Aster Channels | Live TV channel groups, and editing Aster's channels from Jellyfin's dashboard (Jellyfin 12.1 or later) |
| Aster Disc | Disc menus (Jellyfin 12.0 or later) |
| Aster OP-ED | Anime openings and endings with song details (Jellyfin 12.0 or later) |
| Aster Discovery and Tracking | The Discover tab, Seerr requests, tracking through the server, Add to Watchlist |
| [Bonfire](https://github.com/AHouseOfBards/Bonfire-JellyProfiles) (JellyProfiles) | Household profiles: switching, PINs, adding and changing profiles |
| Intro Skipper (or chapters / EDL) | Skip Intro and Skip Credits |
| Shoko | Detecting Anime libraries |

Aster Channels, Aster Disc and Aster OP-ED are published in the [Aster Companion Plugins](https://github.com/AsterMediaPlayer/aster-companion-plugins) repository, which Aster can add to your server for you. It also has **Aster Aurora**, which brings some of Aster's look (big hero banners, trailers behind titles) to Jellyfin's own web app.

Theme songs and theme videos use Jellyfin's standard theme media.

### Emby and Plex

- **Emby:** sign in with the server's address and your password, as on Jellyfin. Live TV needs Emby Premiere on the server.
- **Plex:** choose **Sign in with Plex** and enter the code shown at plex.tv/link, then pick a Plex Home profile and a server. Intro and credits markers need Plex Pass on the server, with marker detection turned on in its Library settings; without them, chapters named Opening and Ending are used. Away from home, the server needs Remote Access turned on.

## Building

Requirements:
- Xcode 27
- The tvOS 27, iOS 27 and macOS 27 SDKs. The app runs on iOS and iPadOS 26.1, tvOS 26 and macOS 26 or later.
- An Apple silicon Mac. AetherEngine's decoders ship for arm64 only, so the simulators run as arm64.

```sh
git clone https://github.com/AsterMediaPlayer/aster-apple.git
open aster-apple/AsterFIN.xcodeproj
```

Xcode fetches the Swift packages on first open. Select the **AsterFIN** scheme (the project keeps its earlier name for now) and an Apple TV, iPhone, iPad or Mac destination, then build and run.

To run on a device, set your own development team in **Signing & Capabilities** for the `AsterFIN`, `AsterFINWidgetsExtension` and `AsterFINTopShelf` targets. The app, its widgets and Top Shelf share an App Group (`group.app.asterfin` by default), so change it to one your team owns. iPhone and iPad builds sign with `AsterFIN/AsterFIN-CarPlay.entitlements`, which asks for Apple's CarPlay audio entitlement. If Apple hasn't given your team that, point the iOS **Code Signing Entitlements** setting at `AsterFIN/AsterFIN.entitlements` instead.

### Project layout

| Folder | Contents |
| --- | --- |
| `AsterFIN/App` | Session state, settings and their sync, household profiles, deep link routing |
| `AsterFIN/Server` | The server-neutral `MediaServer` protocol and typed queries every screen uses |
| `AsterFIN/Jellyfin` | Jellyfin and Emby client, the Bonfire profiles client, the app's models, Keychain storage |
| `AsterFIN/Plex` | Plex client, plex.tv sign-in and Plex Home, and the mapping of Plex's titles into the app's models |
| `AsterFIN/Player` | Both video players, subtitles (text and libass), music, audiobook and theme players, channel changing |
| `AsterFIN/DiscMenu` | Disc menu models, rules, rendering, transitions, audio |
| `AsterFIN/Seerr` | Discover, Seerr requests and title pages, watchlists, through the Aster Discovery and Tracking plugin |
| `AsterFIN/Trackers` | Tracking from the device: Trakt, Simkl, AniList, MyAnimeList |
| `AsterFIN/Downloads` | Video and audiobook downloads (iPhone and iPad) |
| `AsterFIN/CarPlay`, `AsterFIN/Siri`, `AsterFIN/Sonos` | CarPlay (needs Apple's entitlement), Siri for music, Sonos playback |
| `AsterFIN/Diagnostics` | The debug log, debug reports, crash reports, redaction |
| `AsterFIN/UI` | Feature screens (Home, Library, Detail, Upcoming, Live TV, Channels, Music, Audiobooks, Anime, Profiles, Settings, …) |
| `AsterFINWidgets` | Widgets and Live Activities |
| `AsterFINTopShelf` | Top Shelf extension |
| `AsterFINTests` | Unit tests, and the disc menu and channel tag conformance vectors |

## Known limitations

- **System player:**
  - Picture-based subtitles (PGS, VobSub) are burned in by the server, which forces a transcode.
  - A transcoded stream has one audio track, so switching audio needs direct play.
  - Use AetherEngine for both.
- **Jellyfin HLS subtitles:** Jellyfin's fMP4 HLS output times subtitles about 10 seconds late (jellyfin/jellyfin#16647). Aster avoids this by drawing subtitles itself.
- **AetherEngine:**
  - Picture in Picture is on iPhone and iPad only; not yet on Apple TV or the Mac.
  - A converted stream (AV1 on Apple TV, or a lower quality) carries one audio track, so switching audio asks the server for a new stream.
  - Video the engine decodes in software has no system Now Playing info.
  - The Apple TV's Control Center doesn't list Aster's video, with either player.
- **Channels:**
  - Each day starts at local midnight, so devices in different time zones show different schedules.
  - Editing a playlist changes that channel's schedule from then on, including how far each show has got.
- **Mac:** no downloads, and no way to flip channels while watching yet (choose another from the guide).
- **Discover and tracking through the server** need the Aster Discovery and Tracking plugin, so they're Jellyfin only. The plugin doesn't handle Trakt yet.
- **Siri** plays music only, on iPhone and iPad with iOS 27.
- **Profiles:**
  - A profile's picture can be one of Bonfire's own, but not one of your photos yet.
  - On Apple TV with tvOS 26, the sidebar has no profile picture to switch from (that's tvOS 27 and later).
  - Plex Home profiles are switched between here, but not added or changed. Do that at plex.tv.
- **Anime without the OP-ED plugin:** openings and endings are found from chapter names, and their songs from AnimeThemes by the show's name and year, which can miss or pick the wrong season.
- **Plex:**
  - Music, audiobooks, Live TV, channels, playlists, Upcoming, downloads and favourites aren't built yet, so they're hidden on Plex. So are the widgets' and Top Shelf's rows.
  - Plex won't hand out subtitle tracks inside a file, so Aster reads them from the file itself. The first time a text track is picked, it takes a few seconds to appear (longer over Wi-Fi), as Aster reads through the file. Picture subtitles (PGS) on a converted stream are burned in, as on Jellyfin.
  - A stream the server has to convert fails while its transcoder is at its limit (Settings ▸ Transcoder in Plex); Aster says so rather than showing a playback error.

## Open-source components

| Component | License |
| --- | --- |
| [AetherEngine](https://github.com/superuser404notfound/AetherEngine) | LGPL-3.0, with an exception for App Store distribution |
| ↳ [FFmpeg](https://ffmpeg.org) (via FFmpegBuild, as separate frameworks) | LGPL-2.1 |
| ↳ dav1d | BSD-2-Clause |
| ↳ zimg | WTFPL |
| ↳ libzvbi | LGPL-2.1 (ure.c: MIT) |
| ↳ libdovi | MIT |
| ↳ the TrueHD decoder | MIT (truehd and oamd crates: Apache-2.0) |
| ↳ the DTS:X decoder | Apache-2.0 |
| ↳ SMBClient | MIT |
| [swift-ass-renderer](https://github.com/mihai8804858/swift-ass-renderer) and swift-libass | MIT |
| ↳ [libass](https://github.com/libass/libass) | ISC |
| ↳ FreeType | FreeType License (FTL) |
| ↳ HarfBuzz | MIT ("Old MIT") |
| ↳ FriBidi | LGPL-2.1 |
| ↳ Fontconfig | MIT-style |
| ↳ libpng | PNG Reference Library License v2 |
| Point-Free's swift-issue-reporting, swift-concurrency-extras, combine-schedulers | MIT |

Every license text ships in the app, under Settings ▸ About ▸ Open Source & Licenses (also on the welcome screen); they're in [AsterFIN/Licenses](AsterFIN/Licenses).

## License

Aster is licensed under the [Mozilla Public License 2.0](LICENSE). You're free to use, modify and redistribute it. If you distribute a modified version, the files of Aster you changed must stay available under the MPL. New files you add can use any license. The components above keep their own licenses.

The Aster name and app icon aren't covered by the license. If you publish your own build, for example on the App Store, give it a different name and icon so people don't confuse it with the official app.

Aster isn't affiliated with or endorsed by the Jellyfin project.
