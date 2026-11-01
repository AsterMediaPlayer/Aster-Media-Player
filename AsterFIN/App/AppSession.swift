//
//  AppSession.swift
//  AsterFIN
//
//  Who is signed in to which server, and the client the rest of the app uses.
//

import Foundation
import Observation

@Observable
final class AppSession {
    enum Phase: Equatable {
        case loading
        case needsServer
        case needsUser
        case signedIn
    }

    private(set) var phase: Phase = .loading
    /// The server signed in to: browsing, Home, title pages, search and
    /// playback go through this, whichever server it is.
    private(set) var client: (any MediaServer)?
    /// The same server as Jellyfin (or Emby), for what only they have
    /// (music, audiobooks, Live TV, channels, Aster's plugins); nil on Plex.
    var jellyfin: JellyfinClient? { client as? JellyfinClient }
    private(set) var serverURL: URL?
    private(set) var serverName: String?
    /// Jellyfin or Emby. Jellyfin's plugins and extras (Quick Connect, OP/ED,
    /// disc menus, Aster Channels) hide on Emby.
    private(set) var serverKind: ServerKind = .jellyfin
    static let serverKindKey = "AsterFIN.serverKind"

    var isJellyfin: Bool { serverKind == .jellyfin }
    /// Every server signed in to, to switch between.
    private(set) var savedServers: [SavedServer] = []
    /// Bumped on switching server, so the main screen starts afresh.
    private(set) var serverGeneration = 0
    /// The server in use asks for its password: it was away longer than its
    /// lock-after setting.
    private(set) var isLocked = false
    private static let leftAtKey = "AsterFIN.leftAt"

    /// The saved server in use.
    var currentServerID: String? {
        guard let serverURL, let userId else { return nil }
        if let plexLink { return SavedServer.plexID(plexLink.machineId, userId) }
        return SavedServer.id(serverURL, userId)
    }
    /// A Plex sign-in's plex.tv side; nil on Jellyfin and Emby.
    private(set) var plexLink: PlexLink?
    private(set) var userName: String?
    private(set) var userId: String?

    /// The saved servers whose welcome screen (what Aster and its plugins
    /// do) has been seen.
    private var welcomeSeen = Set(UserDefaults.standard.stringArray(forKey: AppSettings.welcomeSeenKey) ?? [])

    /// The welcome screen is due: once for each Jellyfin server signed in
    /// to (the plugins are Jellyfin's), people signed in before it included.
    var needsWelcome: Bool {
        guard isJellyfin, let id = currentServerID else { return false }
        return !welcomeSeen.contains(id)
    }

    func markWelcomeSeen() {
        guard let id = currentServerID else { return }
        welcomeSeen.insert(id)
        UserDefaults.standard.set(Array(welcomeSeen), forKey: AppSettings.welcomeSeenKey)
    }

    /// Brings the welcome screen back for the server in use.
    func showWelcomeAgain() {
        guard let id = currentServerID else { return }
        welcomeSeen.remove(id)
        UserDefaults.standard.set(Array(welcomeSeen), forKey: AppSettings.welcomeSeenKey)
    }

    /// The one audio player, so music keeps going while the viewer browses.
    let music = MusicPlayer()
    /// Audiobooks have their own player (resume, chapters, speed). Only one
    /// of the two plays at a time.
    let audiobooks = AudiobookPlayer()
    /// Theme music and videos for title pages.
    let theme = ThemePlayer()
    /// Anime openings and endings picked on a show's Music tab: one player
    /// for the whole app, so one keeps playing while you browse.
    let themeDeck = ThemeDeck()
    /// The opening or ending playing in the Now Playing panel (or the slim
    /// one) is up full screen: the same player, so it carries on.
    var themeFullScreen = false
    /// The title page showing the deck's full Now Playing panel, while one
    /// is on screen; everywhere else the slim one floats on the right.
    var themePanelPage: String?
    /// Bumped by holding the remote's Play/Pause: the Now Playing panel on
    /// screen takes focus, on its play button.
    var themePanelFocusRequest = 0
    /// The panel takes focus as it appears (a card was just played and the
    /// panel wasn't up yet). Open for a moment, not taken by the first panel
    /// to look: the panel is laid out more than once (`ViewThatFits`), and
    /// only the copy on screen can take focus.
    var themePanelFocusPending = false

    /// Asks the Now Playing panel to take focus, now or as it appears.
    func focusThemePanel() {
        themePanelFocusPending = true
        themePanelFocusRequest += 1
        let request = themePanelFocusRequest
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.themePanelFocusRequest == request else { return }
            self.themePanelFocusPending = false
        }
    }
    /// The Music tab card that started what's playing, for Back in the
    /// panel to go back to; nil once its page has gone.
    var themeReturnCard: String?
    /// Bumped by Back in the panel: focus goes to `themeReturnCard`.
    var themeReturnFocusRequest = 0
    /// Links arriving from the Top Shelf.
    let router = DeepLinkRouter()

    /// Shared with the Top Shelf extension so it reports as this same device.
    static let appGroup = "group.app.asterfin"

    /// The user's server-side settings, once fetched after sign-in.
    private(set) var userConfiguration: UserConfiguration?

    /// Bumped when watched state or favourites change outside a title page,
    /// so screens like Home can reload their rows.
    private(set) var userDataRevision = 0

    func userDataChanged() {
        userDataRevision += 1
    }

    /// Libraries holding anime (see `BaseItem.isAnime`), found when the main
    /// screen loads. They get the Anime tab and are left out of Movies and
    /// TV Shows.
    private(set) var animeLibraries: [BaseItem] = []
    /// The series and films in those libraries, which Movies and TV Shows
    /// skip. Split by library, not by title, so an anime film filed in an
    /// ordinary library stays where it was put.
    private(set) var animeItemIds: Set<String> = []

    /// Whether the server has a music or Live TV library, which their tabs
    /// need. Set when the main screen loads.
    private(set) var hasMusic = false
    private(set) var hasLiveTV = false
    /// The server's book libraries, which the Audiobooks tab browses.
    private(set) var bookLibraries: [BaseItem] = []

    /// Whether shows in the library have episodes airing soon, which the
    /// Upcoming tab needs. Checked when the main screen loads.
    private(set) var hasUpcoming = false

    /// A title whose page should start playing as soon as it opens: a hero's
    /// Play or Resume plays at once, and closing the player leaves the
    /// viewer on that title's page. Cleared by the page that takes it.
    var playOnOpen: String?

    func refreshUpcoming() async {
        guard let client = jellyfin else { return }
        if let soonest = try? await client.upcoming(limit: 1) {
            hasUpcoming = !soonest.isEmpty
        }
    }

    func noteLibraries(_ views: [BaseItem]) {
        hasMusic = views.contains { $0.collectionType == "music" }
        hasLiveTV = views.contains { $0.collectionType == "livetv" }
        bookLibraries = views.filter { $0.collectionType == "books" }
    }

    /// The tabs this server has something for.
    func hasContent(for tab: AppTab) -> Bool {
        switch tab {
        case .anime: !animeLibraries.isEmpty
        case .music: hasMusic
        case .liveTV: hasLiveTV
        case .audiobooks: !bookLibraries.isEmpty
        case .upcoming: hasUpcoming
        case .channels: hasChannels
        #if !os(iOS)
        // Apple TV has no storage to download to; the Mac doesn't download yet.
        case .downloads: false
        #endif
        #if os(macOS)
        // The Mac has a Settings window (⌘,) instead.
        case .settings: false
        #endif
        default: true
        }
    }

    /// Every music video library on the server: the choices for the Anime
    /// tab's music video setting.
    private(set) var musicVideoLibraries: [BaseItem] = []
    /// The OP/ED plugin's published Music Videos library, when it has one.
    private(set) var opEdVideosLibraryId: String?
    /// The music video libraries the Anime tab shows: the OP/ED plugin's,
    /// and those chosen in Settings (AMVs).
    private(set) var animeMusicVideoLibraries: [BaseItem] = []

    func detectAnimeMusic(among views: [BaseItem]) async {
        musicVideoLibraries = views.filter { $0.collectionType == "musicvideos" }
        opEdVideosLibraryId = await jellyfin?.opEdLibraries()?.videosLibraryId
        updateAnimeMusicVideoLibraries()
    }

    /// After the Settings choice changes, or the libraries are found.
    func updateAnimeMusicVideoLibraries() {
        let chosen = Set((UserDefaults.standard.string(forKey: AppSettings.animeMusicVideoLibrariesKey) ?? "")
            .split(separator: "\n").map(String.init))
        let opEd = opEdVideosLibraryId.map(Self.plainId)
        animeMusicVideoLibraries = musicVideoLibraries.filter { Self.plainId($0.id) == opEd || chosen.contains($0.displayTitle) }
    }

    /// An id as Jellyfin writes it either way: lowercase, without dashes.
    nonisolated private static func plainId(_ id: String) -> String {
        id.lowercased().replacingOccurrences(of: "-", with: "")
    }

    func detectAnimeLibraries(among views: [BaseItem]) async {
        guard let client else { return }
        let libraries = await client.animeLibraries(among: views)
        let ids = await client.itemIds(inLibraries: libraries.map(\.id), types: "Series,Movie")
        animeLibraries = libraries
        animeItemIds = ids
        // Their shows' songs, from AnimeThemes, got ready in the background.
        SongWarmer.shared.warmInBackground(client: client, libraries: libraries)
    }

    /// The one session, shared with scenes outside SwiftUI (CarPlay).
    static let shared = AppSession()

    init() {
        #if os(iOS)
        NetworkPath.shared.start()
        #endif
        // Before anything's read: a reinstall starts signed out.
        Keychain.clearIfFreshInstall()
        restore()
        // 0.7's "Prefer full versions" becomes the Full Version choice.
        let defaults = UserDefaults.standard
        if defaults.string(forKey: AppSettings.themeCutKey) == nil, defaults.bool(forKey: AppSettings.themePrefersFullKey) {
            defaults.set(ThemeCut.full.rawValue, forKey: AppSettings.themeCutKey)
        }
        music.onStart = { [weak self] in
            self?.theme.hide(evenIfShowing: true)
            self?.audiobooks.stop()
            self?.themeDeck.stop()
        }
        audiobooks.onStart = { [weak self] in
            self?.theme.hide(evenIfShowing: true)
            self?.music.stop()
            self?.themeDeck.stop()
        }
        // Title pages' theme music and videos stay quiet while an opening
        // or ending plays, whichever page is showing; so does a song or book.
        themeDeck.onActiveChange = { [weak self] active in
            if active {
                self?.pauseAudio()
                self?.theme.suspend()
            } else {
                self?.theme.resume()
            }
        }
        UserDefaults(suiteName: Self.appGroup)?.set(JellyfinDevice.deviceId, forKey: "AsterFIN.deviceId")
    }

    /// Track choices for the player: from the server settings when known,
    /// else from what was last chosen on this Apple TV.
    var playbackPreferences: PlaybackPreferences {
        func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        if let config = userConfiguration {
            return PlaybackPreferences(
                audioLanguage: nonEmpty(config.audioLanguagePreference),
                subtitleLanguage: nonEmpty(config.subtitleLanguagePreference),
                subtitleMode: SubtitleMode(rawValue: config.subtitleMode ?? "") ?? .default
            )
        }
        let defaults = UserDefaults.standard
        return PlaybackPreferences(
            audioLanguage: nonEmpty(defaults.string(forKey: AppSettings.audioLanguageKey)),
            subtitleLanguage: nonEmpty(defaults.string(forKey: AppSettings.subtitleLanguageKey)),
            subtitleMode: SubtitleMode(rawValue: defaults.string(forKey: AppSettings.subtitleModeKey) ?? "") ?? .default
        )
    }

    /// Whether the server lets this user download media; false until known.
    private(set) var canDownload = false
    /// Whether this user can change playlists' tags, which is how channels
    /// are set up (an administrator); false until known.
    private(set) var canEditChannels = false
    /// Whether any playlist on the server is tagged as a channel, which the
    /// Channels tab needs. Checked when the main screen loads, on returning
    /// to the app, and after Edit Channels changes something.
    private(set) var hasChannels = false

    func refreshChannels() async {
        // Channels are playlist tags in Jellyfin's shape; Emby's differ.
        guard isJellyfin else { hasChannels = false; return }
        guard let client = jellyfin, let playlists = try? await client.playlists(mediaType: "Video") else { return }
        hasChannels = ChannelsModel.taggedChannels(in: playlists).contains { $0.tags.isShown(to: userName) }
    }

    func refreshUserConfiguration() async {
        guard let client = jellyfin, let me = try? await client.me() else { return }
        canDownload = me.policy?.enableContentDownloading ?? false
        canEditChannels = me.policy?.isAdministrator ?? false
        if let config = me.configuration {
            userConfiguration = config
        }
        if canEditChannels && isJellyfin { await convertOldChannelTags() }
    }

    /// Renames channel tags from the app's earlier name, "asterfin:…", to
    /// "aster:…" on every playlist that still has them. It only finds any
    /// the first time an administrator signs in after the change (or if
    /// someone types an old one in Jellyfin); old tags are read meanwhile.
    private func convertOldChannelTags() async {
        guard let client = jellyfin, let playlists = try? await client.playlists(mediaType: "Video") else { return }
        var converted = false
        for playlist in playlists {
            guard let tags = ChannelTags.converted(playlist.tags) else { continue }
            if (try? await client.setTags(tags, onItem: playlist.id)) != nil { converted = true }
        }
        if converted { await refreshChannels() }
    }

    /// Changes one or more settings and saves them to the server, keeping the
    /// local copy if the save fails so the UI does not lie.
    func updateUserConfiguration(_ mutate: (inout UserConfiguration) -> Void) async {
        guard let client = jellyfin else { return }
        let previous = userConfiguration
        var config = userConfiguration ?? UserConfiguration()
        mutate(&config)
        userConfiguration = config
        do {
            try await client.updateConfiguration(config)
        } catch {
            userConfiguration = previous
        }
    }

    /// A client for the chosen server before anyone has signed in.
    var anonymousClient: JellyfinClient? {
        serverURL.map { JellyfinClient(baseURL: $0, kind: serverKind) }
    }

    func restore() {
        savedServers = SavedServers.load()
        // Signed in before servers were saved: that one is the first.
        if savedServers.isEmpty, let stored = StoredSession.load() {
            savedServers = [SavedServer(session: stored)]
            SavedServers.save(savedServers)
        }
        if let stored = StoredSession.load() {
            serverURL = stored.serverURL
            serverName = stored.serverName
            serverKind = stored.kind
            userName = stored.userName
            userId = stored.userId
            plexLink = stored.plex
            client = MediaServerFactory.client(for: stored)
            phase = .signedIn
        } else if let saved = UserDefaults.standard.url(forKey: "AsterFIN.serverURL") {
            serverURL = saved
            serverName = UserDefaults.standard.string(forKey: "AsterFIN.serverName")
            serverKind = UserDefaults.standard.string(forKey: Self.serverKindKey).flatMap(ServerKind.init(rawValue:)) ?? .jellyfin
            phase = .needsUser
        } else {
            phase = .needsServer
        }
    }

    func useServer(_ url: URL, info: PublicSystemInfo) {
        serverURL = url
        serverName = info.serverName
        serverKind = info.kind
        UserDefaults.standard.set(url, forKey: "AsterFIN.serverURL")
        UserDefaults.standard.set(info.serverName, forKey: "AsterFIN.serverName")
        UserDefaults.standard.set(info.kind.rawValue, forKey: Self.serverKindKey)
        phase = .needsUser
    }

    /// Off to sign in to another server. The one in use stays saved and
    /// signed in, to switch back to.
    func changeServer() {
        isLocked = false
        stopMedia()
        StoredSession.clear()
        client = nil
        userId = nil
        userName = nil
        plexLink = nil
        phase = .needsServer
    }

    /// Back to a saved server, with its saved sign-in or (`session`) a fresh
    /// one from its password.
    func switchServer(to saved: SavedServer, session fresh: StoredSession? = nil) {
        let stored = fresh ?? saved.session
        stopMedia()
        resetServerState()
        stored.save()
        serverURL = stored.serverURL
        serverName = stored.serverName
        serverKind = stored.kind
        userId = stored.userId
        userName = stored.userName
        UserDefaults.standard.set(stored.serverURL, forKey: "AsterFIN.serverURL")
        UserDefaults.standard.set(stored.serverName, forKey: "AsterFIN.serverName")
        UserDefaults.standard.set(stored.kind.rawValue, forKey: Self.serverKindKey)
        plexLink = stored.plex
        client = MediaServerFactory.client(for: stored)
        remember(stored)
        isLocked = false
        serverGeneration += 1
        phase = .signedIn
        #if os(iOS)
        WidgetRefresh.continueWatching()
        #endif
    }

    /// Checks a saved server's password with the server itself, for one that
    /// asks for it before switching; the fresh sign-in to switch with.
    func signInAgain(to saved: SavedServer, password: String) async throws -> StoredSession {
        let session = saved.session
        // Plex: the Home profile's PIN, checked by plex.tv by switching to it.
        if session.kind == .plex {
            guard var link = session.plex, let uuid = link.homeUserUUID, let homeToken = link.homeToken else { throw PlexError.notBuilt }
            // plex.tv lets a profile switch to itself with no PIN at all, so
            // an empty one must never be sent.
            guard !password.isEmpty else { throw PlexError.pinNeeded }
            let profile = PlexHomeUser(id: 0, uuid: uuid, title: session.userName)
            let switched: PlexAccountUser
            do {
                switched = try await PlexAccount.switchUser(profile, pin: password, token: homeToken)
            } catch PlexError.http(let code) where code == 401 || code == 403 {
                throw PlexError.wrongPin
            }
            if let token = switched.authToken { link.accountToken = token }
            var fresh = session
            fresh.plex = link
            return fresh
        }
        let client = JellyfinClient(baseURL: session.serverURL, kind: session.kind)
        let result = try await client.authenticate(username: session.userName, password: password)
        return StoredSession(serverURL: session.serverURL, serverName: session.serverName, userId: result.user.id, userName: result.user.name, accessToken: result.accessToken, serverKind: session.kind)
    }

    /// Keeps the sign-in a password or PIN check just made, which can stand
    /// in for the one saved (Jellyfin ends the old one), for the server in
    /// use too.
    func keepSignIn(_ fresh: StoredSession) {
        if SavedServer(session: fresh).id == currentServerID {
            fresh.save()
            client = MediaServerFactory.client(for: fresh)
        }
        remember(fresh)
    }

    func setLockAfter(_ minutes: Int?, for id: String) {
        guard let index = savedServers.firstIndex(where: { $0.id == id }) else { return }
        savedServers[index].lockAfterMinutes = minutes
        SavedServers.save(savedServers)
    }

    /// The app left the screen: the clock for the lock starts.
    func noteLeftApp() {
        UserDefaults.standard.set(Date(), forKey: Self.leftAtKey)
    }

    /// The app is back (or just opened): locks the server in use if it was
    /// away past its lock-after setting.
    func checkLock() {
        defer { UserDefaults.standard.removeObject(forKey: Self.leftAtKey) }
        guard phase == .signedIn, !isLocked,
              let id = currentServerID,
              // Only a server that can check its password or PIN is locked.
              let server = savedServers.first(where: { $0.id == id }), server.canBeLocked,
              let minutes = server.lockAfterMinutes,
              let leftAt = UserDefaults.standard.object(forKey: Self.leftAtKey) as? Date,
              Date().timeIntervalSince(leftAt) >= TimeInterval(minutes * 60) else { return }
        stopMedia()
        isLocked = true
    }

    /// The password was right: carry on, with the fresh sign-in.
    func unlock(with fresh: StoredSession) {
        fresh.save()
        client = MediaServerFactory.client(for: fresh)
        remember(fresh)
        isLocked = false
    }

    /// The saved server in use, for the lock screen.
    var currentServer: SavedServer? {
        currentServerID.flatMap { id in savedServers.first { $0.id == id } }
    }

    func setAsksPasswordToSwitch(_ asks: Bool, for id: String) {
        guard let index = savedServers.firstIndex(where: { $0.id == id }) else { return }
        savedServers[index].asksPasswordToSwitch = asks
        SavedServers.save(savedServers)
    }

    /// Forgets a saved server (not the one in use), signing it out.
    func removeServer(_ id: String) {
        guard id != currentServerID, let saved = savedServers.first(where: { $0.id == id }) else { return }
        savedServers.removeAll { $0.id == id }
        SavedServers.save(savedServers)
        TopShelfServers.setShown(true, for: id)
        let session = saved.session
        Task { await MediaServerFactory.client(for: session).logout() }
    }

    /// Adds or updates a server in the saved list, keeping its password setting.
    private func remember(_ stored: StoredSession) {
        let id = SavedServer(session: stored).id
        if let index = savedServers.firstIndex(where: { $0.id == id }) {
            savedServers[index].session = stored
        } else {
            savedServers.append(SavedServer(session: stored))
        }
        SavedServers.save(savedServers)
    }

    private func stopMedia() {
        music.stop()
        audiobooks.stop()
    }

    /// What was learned about the last server, cleared for the next.
    private func resetServerState() {
        animeLibraries = []
        animeItemIds = []
        hasMusic = false
        hasLiveTV = false
        bookLibraries = []
        hasUpcoming = false
        musicVideoLibraries = []
        opEdVideosLibraryId = nil
        animeMusicVideoLibraries = []
        canDownload = false
        canEditChannels = false
        hasChannels = false
        userConfiguration = nil
    }

    func signIn(_ result: AuthenticationResult) {
        guard let serverURL else { return }
        let stored = StoredSession(serverURL: serverURL, serverName: serverName, userId: result.user.id, userName: result.user.name, accessToken: result.accessToken, serverKind: serverKind)
        stored.save()
        userId = result.user.id
        userName = result.user.name
        plexLink = nil
        client = JellyfinClient(baseURL: serverURL, accessToken: result.accessToken, userId: result.user.id, kind: serverKind)
        remember(stored)
        resetServerState()
        serverGeneration += 1
        phase = .signedIn
    }

    /// A Plex server's saved address can stop answering (this device on
    /// another network, the server's address changed): its other
    /// addresses are tried, then plex.tv's latest list, and the first that
    /// answers takes over. Checked on opening and on coming back.
    func refreshPlexConnection() async {
        guard let plexLink, phase == .signedIn, let stored = StoredSession.load(), stored.kind == .plex else { return }
        let token = stored.accessToken
        let saved = PlexConnectionInfo(uri: stored.serverURL, local: true, relay: false)
        if await PlexConnectionRace.fastest([saved], token: token, timeout: 4) != nil { return }

        var connections = plexLink.connections
        var serverToken = token
        var reached = await PlexConnectionRace.fastest(connections, token: token)
        if reached == nil,
           let server = try? await PlexAccount.servers(token: plexLink.accountToken).first(where: { $0.clientIdentifier == plexLink.machineId }) {
            connections = server.rankedConnections
            serverToken = server.accessToken ?? token
            reached = await PlexConnectionRace.fastest(connections, token: serverToken)
        }
        // Signed out or switched meanwhile: leave it.
        guard let reached, reached.uri != stored.serverURL, currentServerID == SavedServer(session: stored).id else { return }
        var updated = stored
        updated.serverURL = reached.uri
        updated.accessToken = serverToken
        updated.plex?.connections = connections
        updated.save()
        serverURL = reached.uri
        self.plexLink = updated.plex
        UserDefaults.standard.set(reached.uri, forKey: "AsterFIN.serverURL")
        client = MediaServerFactory.client(for: updated)
        remember(updated)
        serverGeneration += 1
    }

    /// Signed in through plex.tv, to the server and Home user picked.
    func signIn(plex stored: StoredSession) {
        stopMedia()
        stored.save()
        serverURL = stored.serverURL
        serverName = stored.serverName
        serverKind = .plex
        userId = stored.userId
        userName = stored.userName
        plexLink = stored.plex
        UserDefaults.standard.set(stored.serverURL, forKey: "AsterFIN.serverURL")
        UserDefaults.standard.set(stored.serverName, forKey: "AsterFIN.serverName")
        UserDefaults.standard.set(ServerKind.plex.rawValue, forKey: Self.serverKindKey)
        client = MediaServerFactory.client(for: stored)
        remember(stored)
        resetServerState()
        isLocked = false
        serverGeneration += 1
        phase = .signedIn
    }

    /// Signs out of the server in use (it's forgotten too); others stay saved.
    func signOut() {
        isLocked = false
        stopMedia()
        let old = client
        Task { await old?.logout() }
        if let id = currentServerID {
            savedServers.removeAll { $0.id == id }
            SavedServers.save(savedServers)
        }
        StoredSession.clear()
        client = nil
        userId = nil
        userName = nil
        // Plex signs in through plex.tv, from the first screen.
        let wasPlex = plexLink != nil
        plexLink = nil
        phase = wasPlex ? .needsServer : .needsUser
    }

    /// Forgets the server in use, even the last one: signed out of it, and
    /// back to adding a server.
    func removeCurrentServer() {
        guard let id = currentServerID else { return }
        TopShelfServers.setShown(true, for: id)
        signOut()
        serverURL = nil
        serverName = nil
        phase = .needsServer
    }
}

/// User-adjustable preferences, stored in UserDefaults.
enum AppSettings {
    static let preferDiscMenuKey = "AsterFIN.preferDiscMenu"
    /// Mac: show how to scroll with two fingers while the window is on an
    /// iPad used as a display (Sidecar), where one finger can't.
    static let sidecarHintKey = "AsterFIN.sidecarHint"
    /// The saved servers (`SavedServer.id`) whose welcome screen was seen.
    static let welcomeSeenKey = "AsterFIN.welcomeSeen"
    /// Music video libraries (AMVs) shown in the Anime tab, by name, one per
    /// line; the OP/ED plugin's own library is always shown.
    static let animeMusicVideoLibrariesKey = "AsterFIN.animeMusicVideoLibraries"
    static let maxBitrateKey = "AsterFIN.maxBitrate"
    /// iPhone and iPad: the limit on cellular data (or a Personal Hotspot);
    /// 0 for the same as on Wi-Fi. 8 Mbps by default.
    static let cellularMaxBitrateKey = "AsterFIN.cellularMaxBitrate"
    static let defaultCellularMaxBitrate = 8_000_000
    static let discMenuSoundsKey = "AsterFIN.discMenuSounds"
    static let autoplayNextKey = "AsterFIN.autoplayNext"
    static let autoSkipIntroKey = "AsterFIN.autoSkipIntro"
    // Fallbacks for when the server's user settings are unavailable.
    static let audioLanguageKey = "AsterFIN.audioLanguage"
    static let subtitleLanguageKey = "AsterFIN.subtitleLanguage"
    static let subtitleModeKey = "AsterFIN.subtitleMode"
    static let themeMusicKey = "AsterFIN.themeMusic"
    static let themeVideosKey = "AsterFIN.themeVideos"
    /// Whether an anime opening used as the theme video plays its sound.
    static let openingSoundKey = "AsterFIN.openingSound"
    /// The song card as an episode's opening or ending plays. On by default.
    static let themeCardsKey = "AsterFIN.themeCards"
    /// Whether song names may be asked of AnimeThemes, on a server without
    /// the OP/ED plugin (see `AnimeThemesLookup`). On by default; kept on
    /// the device.
    static let songLookupsKey = "AsterFIN.songLookups"
    /// Openings and endings picked on a show's Music tab play in the Now
    /// Playing panel (and keep playing, slim, while browsing); off, they
    /// play full screen. On by default.
    static let themePanelKey = "AsterFIN.themePanel"
    /// Which version of openings and endings a show's Music tab plays where
    /// the server has it (Play All, and a card pressed): a `ThemeCut`, the
    /// TV size by default; each card can play any. Watch OP and title-page
    /// themes always use the TV size.
    static let themeCutKey = "AsterFIN.themeCut"
    /// 0.7's on/off for full versions, carried over into `themeCutKey`.
    static let themePrefersFullKey = "AsterFIN.themePrefersFull"
    /// ASS/SSA tracks drawn with libass (positions, drawings, fonts) rather
    /// than as plain text. On by default.
    static let styledSubtitlesKey = "AsterFIN.styledSubtitles"
    /// iPhone and iPad: the tabs in the order chosen, and those hidden (see
    /// `TabLayout`).
    static let tabOrderKey = "AsterFIN.tabOrder"
    static let hiddenTabsKey = "AsterFIN.hiddenTabs"
    /// Downloads (iPhone and iPad; see `DownloadStore`).
    static let downloadsEnabledKey = "AsterFIN.downloadsEnabled"
    static let downloadsSetUpKey = "AsterFIN.downloadsSetUp"
    /// The most the downloads may take, in gigabytes; 0 for no limit.
    static let downloadStorageLimitKey = "AsterFIN.downloadStorageLimit"
    static let downloadQualityKey = "AsterFIN.downloadQuality"
    static let downloadHEVCKey = "AsterFIN.downloadHEVC"
    static let downloadSubtitlesKey = "AsterFIN.downloadSubtitles"
    static let downloadCellularKey = "AsterFIN.downloadCellular"
    /// Video through the system player instead of AetherEngine, the main
    /// player (see `AetherPlayback`). Off by default. (Replaces the old
    /// "AsterFIN.useAetherEngine" test switch, which is no longer read.)
    static let useSystemPlayerKey = "AsterFIN.useSystemPlayer"
    /// Mac: videos play full screen, the window going back as they close.
    /// On by default.
    static let fullScreenPlaybackKey = "AsterFIN.fullScreenPlayback"
    /// iPhone and iPad: minutes of an audiobook kept saved ahead of where
    /// it's playing (see `ListenAhead`); 0 for off. 30 by default.
    static let listenAheadKey = "AsterFIN.listenAhead"

    /// Whether the limit right now is a real one: a choice below Auto, or
    /// the cellular limit on cellular data. Then a file over it is converted
    /// down to it, rather than played as it is.
    static var limitsQuality: Bool { maxBitrate < 120_000_000 }

    /// The streaming limit right now: on iPhone and iPad, the cellular one
    /// while on cellular data. Read as each stream starts.
    static var maxBitrate: Int {
        let stored = UserDefaults.standard.integer(forKey: maxBitrateKey)
        let wifi = stored > 0 ? stored : 120_000_000
        #if os(iOS)
        if NetworkPath.shared.isCellular {
            let cellular = UserDefaults.standard.object(forKey: cellularMaxBitrateKey) as? Int ?? defaultCellularMaxBitrate
            return cellular > 0 ? min(cellular, wifi) : wifi
        }
        #endif
        return wifi
    }

    /// Start the next episode when one ends. On by default.
    static var listenAheadMinutes: Int {
        UserDefaults.standard.object(forKey: listenAheadKey) as? Int ?? 30
    }

    static var autoplayNext: Bool {
        UserDefaults.standard.object(forKey: autoplayNextKey) as? Bool ?? true
    }

    static var themeCards: Bool {
        UserDefaults.standard.object(forKey: themeCardsKey) as? Bool ?? true
    }

    /// Watched anime episodes and films sent to the tracking accounts.
    /// On by default; kept on the device.
    static let trackWatchingKey = "AsterFIN.trackWatching"
    static var trackWatching: Bool {
        UserDefaults.standard.object(forKey: trackWatchingKey) as? Bool ?? true
    }

    static var songLookups: Bool {
        UserDefaults.standard.object(forKey: songLookupsKey) as? Bool ?? true
    }

    static var styledSubtitles: Bool {
        UserDefaults.standard.object(forKey: styledSubtitlesKey) as? Bool ?? true
    }

    /// Jump past intros without asking. Off by default.
    static var autoSkipIntro: Bool {
        UserDefaults.standard.bool(forKey: autoSkipIntroKey)
    }

    static var useAetherEngine: Bool {
        !UserDefaults.standard.bool(forKey: useSystemPlayerKey)
    }
}
