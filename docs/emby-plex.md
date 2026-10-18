# Emby and Plex support: feasibility breakdown

## Context
You asked what it would take for Aster to also support **Emby** and **Plex**, and wanted a written breakdown to decide from later. Scope, if built:
- **First:** sign in, Home, libraries, title pages, playback with resume and watched state, and search.
- **Later:** Live TV, music, audiobooks, downloads and Upcoming.
- **Never:** the Jellyfin-only extras (OP/ED plugin, disc menus, Shoko anime detection) stay Jellyfin-only.

You can set up a local Emby server and a local Plex server for testing.

## How tied Aster is to Jellyfin today (measured)
- **The client:** `Jellyfin/JellyfinClient.swift` is 1,183 lines with 99 API calls. About 38 files call it, and 28 files use Jellyfin's item model `BaseItem` (`Jellyfin/JellyfinModels.swift`) directly.
- **Routes:** the client uses **Jellyfin 10.9+ style routes**, e.g. `/UserViews`, `/UserItems/Resume`, `/UserPlayedItems/{id}`, `/UserFavoriteItems/{id}`, `/Items/Latest`, and `?ApiKey=` for media URLs.
- **The views:** they mostly ask the client for picture URLs (`posterURL` 17×, `landscapeURL`, `logoURL`, `backdropURL`) and for item lists.
- **The player** (`Player/PlaybackCoordinator.swift`) uses:
  - `playbackInfo` with a device profile;
  - `directStreamURL`;
  - `reportStart` / `reportProgress` / `reportStopped`;
  - `mediaSegments` for intro skipping;
  - `subtitleCues`, `closeLiveStream` and `stopTranscoding`.
- **Session:** the stored session (`StoredSession` in `Jellyfin/Keychain.swift`) is a server URL, user id, user name and token. It has no notion of server type.

## Emby: medium effort, mostly inside the client
Jellyfin forked from Emby 3.5 in late 2018, so the **data model is still nearly the same**: the same item JSON (`BaseItemDto`), image paths, `PlaybackInfo` and device profiles, HLS streaming, `/Sessions/Playing*` reporting, `/Shows/NextUp`, seasons/episodes, Live TV and subtitles. `BaseItem` should decode Emby items almost unchanged.

**What differs**
- **Routes:** Emby kept the older per-user routes:
  - `/Users/{id}/Views`
  - `/Users/{id}/Items`
  - `/Users/{id}/Items/{itemId}`
  - `/Users/{id}/Items/Latest`
  - `/Users/{id}/Items/Resume`
  - `/Users/{id}/PlayedItems/{id}`
  - `/Users/{id}/FavoriteItems/{id}`

  Each Jellyfin-style route needs an Emby branch. There are about 15 of them.
- **Auth:** the client already sends an `X-Emby-Authorization: MediaBrowser … Token=` header, which Emby accepts. Media URLs would use `api_key=` instead of `ApiKey=`.
- **Sign-in:** username/password works (`/Users/AuthenticateByName`). There's no Quick Connect, so that button hides.
- **Intro skipping:** no media-segments API. Emby 4.7+ marks intros as chapter markers (`MarkerType` IntroStart/IntroEnd), so skip-intro needs a small Emby path.
- **Lyrics:** Emby's lyrics come through a different route, and the lyrics view would hide or need a separate path.
- **Detecting the server:** `/System/Info/Public` answers on both. `ProductName` (and, on Jellyfin, `ProductName: "Jellyfin Server"`) tells them apart, so the user just types an address as today.
- **Licensing:** third-party clients can use the API. Live TV/DVR (and possibly some download/transcode features) need **Emby Premiere** on the server. That's to verify on your test server.

**Work involved**
1. **Server type:** add a `ServerKind` (jellyfin/emby) to `StoredSession` and the client, detected at connect time.
2. **Emby routes:** branch the ~15 differing routes and the media-URL key inside `JellyfinClient`. The views don't change.
3. **Features to hide:** Quick Connect, media segments (use chapter markers instead), lyrics, OP/ED, DiscMenu, Shoko detection and SyncPlay. These become `capabilities` on the session, and views already hide tabs/buttons per server.
4. **Testing:** test on your Emby server: sign-in, Home rows, libraries, title pages, playback (direct and transcoded), resume/watched, search, subtitles.

**Rough size:** about 1–2 weeks of sessions, mostly testing route by route. It's low risk to the Jellyfin side, because the changes are additive branches.

## Plex: large effort, needs a server-neutral layer first
Plex shares nothing with Jellyfin's API.

| Area | Plex |
|---|---|
| Sign-in | plex.tv account. A PIN/link code ("go to plex.tv/link, enter ABCD") gives a token. Then a list of the account's servers and their connections (local, remote, relay) to pick from. Plex Home profiles can be switched. |
| Requests | `X-Plex-Token` / `X-Plex-Client-Identifier` / `X-Plex-Product` headers, with `Accept: application/json`. |
| Ids & items | Numeric `ratingKey`. Metadata in a different shape (`MediaContainer` / `Metadata`, `Media` / `Part` / `Stream`). Libraries are `/library/sections`. Items are `/library/metadata/{key}` with `/children`. |
| Home | Hubs: `/hubs`, Continue Watching, On Deck, Recently Added. |
| Pictures | `/photo/:/transcode?url=…&width=…`, or `thumb` / `art` paths. Logos ("clearLogo") only on newer servers. |
| Playback | A direct file (`/library/parts/{id}/file`) or the universal transcoder (`/video/:/transcode/universal/start.m3u8` with a client profile, and `/decision`). |
| Progress | `/:/timeline?ratingKey=&state=&time=`, plus `/:/scrobble` / `/:/unscrobble` for watched. |
| Search | `/hubs/search?query=`. |
| Intro skip | Intro markers on items (`includeMarkers=1`); detecting them needs Plex Pass on the server. |
| Plex Pass | Needed on the server for downloads, Live TV/DVR, intro detection and some hardware transcoding. |

**Work involved**
1. **A server-neutral layer:** a `MediaServer` protocol covering what the views and player actually call:
   - lists (views, latest, resume, next up, items, seasons, episodes, search);
   - one item;
   - picture URLs;
   - "how to play this" (URL and tracks);
   - progress reports and watched/favourite.

   `JellyfinClient` (and the Emby branch) conform. `session.client` becomes `any MediaServer`.
2. **Keep `BaseItem` as the app's model:** the Plex adapter **translates Plex metadata into `BaseItem`**, mapping ratingKey to id, thumb/art to image URLs, and so on. Most views then don't change. Rewriting 28 files to a new model is avoided.
3. **Player:** split `PlaybackCoordinator`'s Jellyfin-specific start (PlaybackInfo, device profile) from the shared AVPlayer handling. Plex needs its own "decide direct play or transcode" step and timeline reporting.
4. **Sign-in UI:** a Plex path with the link-code screen, server picker and Plex Home user picker.
5. **Capabilities:** hide anything not built for Plex yet.

**Rough size:** about 4–6 weeks of sessions. Step 1 alone is about a week, touches the whole app, and needs a full retest of Jellyfin afterwards. The player work is the riskiest part.

## Recommendation (when you decide to build)
1. **Emby first**, on a feature branch. It's the quickest real gain, and it forces the "server kind + capabilities" groundwork that Plex needs too.
2. **Then the `MediaServer` protocol**, with Jellyfin and Emby behind it. This is a pure refactor, verified by Jellyfin working exactly as before.
3. **Then the Plex adapter** on top: sign-in, then browsing, then playback.

## What won't carry over (either server)
- **Jellyfin plugins:** your OP/ED and DiscMenu plugins, plus Shokofin, are Jellyfin plugins.
- **Jellyfin 12 specifics:** media segments and Quick Connect.
- **Upcoming:** Emby has a similar `/Shows/Upcoming`. Plex would need its own (DVR schedule or none).

## Verification (when built)
- **Emby:** sign in to your local Emby server, then check Home rows, each library type, title pages, playback (direct and transcoded) with resume and watched sync, search and subtitles.
- **Plex:** the link-code sign-in, server and user pickers, then the same checks.
- **Jellyfin:** a full retest after each step on your server and the demo server, plus the existing unit tests (RunAllTests on the Apple TV simulator).
