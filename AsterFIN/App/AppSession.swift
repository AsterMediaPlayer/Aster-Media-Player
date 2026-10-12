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
    private(set) var client: JellyfinClient?
    private(set) var serverURL: URL?
    private(set) var serverName: String?
    private(set) var userName: String?
    private(set) var userId: String?

    /// The one audio player, so music keeps going while the viewer browses.
    let music = MusicPlayer()
    /// Theme music and videos for title pages.
    let theme = ThemePlayer()
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

    func noteLibraries(_ views: [BaseItem]) {
        hasMusic = views.contains { $0.collectionType == "music" }
        hasLiveTV = views.contains { $0.collectionType == "livetv" }
    }

    /// The tabs this server has something for.
    func hasContent(for tab: AppTab) -> Bool {
        switch tab {
        case .anime: !animeLibraries.isEmpty
        case .music: hasMusic
        case .liveTV: hasLiveTV
        #if os(tvOS)
        // Apple TV has no storage to download to.
        case .downloads: false
        #endif
        default: true
        }
    }

    func detectAnimeLibraries(among views: [BaseItem]) async {
        guard let client else { return }
        let libraries = await client.animeLibraries(among: views)
        let ids = await client.itemIds(inLibraries: libraries.map(\.id), types: "Series,Movie")
        animeLibraries = libraries
        animeItemIds = ids
    }

    /// The one session, shared with scenes outside SwiftUI (CarPlay).
    static let shared = AppSession()

    init() {
        restore()
        music.onStart = { [weak self] in self?.theme.hide() }
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

    func refreshUserConfiguration() async {
        guard let client, let me = try? await client.me() else { return }
        canDownload = me.policy?.enableContentDownloading ?? false
        if let config = me.configuration {
            userConfiguration = config
        }
    }

    /// Changes one or more settings and saves them to the server, keeping the
    /// local copy if the save fails so the UI does not lie.
    func updateUserConfiguration(_ mutate: (inout UserConfiguration) -> Void) async {
        guard let client else { return }
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
        serverURL.map { JellyfinClient(baseURL: $0) }
    }

    func restore() {
        if let stored = StoredSession.load() {
            serverURL = stored.serverURL
            serverName = stored.serverName
            userName = stored.userName
            userId = stored.userId
            client = JellyfinClient(baseURL: stored.serverURL, accessToken: stored.accessToken, userId: stored.userId)
            phase = .signedIn
        } else if let saved = UserDefaults.standard.url(forKey: "AsterFIN.serverURL") {
            serverURL = saved
            serverName = UserDefaults.standard.string(forKey: "AsterFIN.serverName")
            phase = .needsUser
        } else {
            phase = .needsServer
        }
    }

    func useServer(_ url: URL, info: PublicSystemInfo) {
        serverURL = url
        serverName = info.serverName
        UserDefaults.standard.set(url, forKey: "AsterFIN.serverURL")
        UserDefaults.standard.set(info.serverName, forKey: "AsterFIN.serverName")
        phase = .needsUser
    }

    func changeServer() {
        music.stop()
        Task { await client?.logout() }
        StoredSession.clear()
        client = nil
        userId = nil
        userName = nil
        phase = .needsServer
    }

    func signIn(_ result: AuthenticationResult) {
        guard let serverURL else { return }
        let stored = StoredSession(serverURL: serverURL, serverName: serverName, userId: result.user.id, userName: result.user.name, accessToken: result.accessToken)
        stored.save()
        userId = result.user.id
        userName = result.user.name
        client = JellyfinClient(baseURL: serverURL, accessToken: result.accessToken, userId: result.user.id)
        phase = .signedIn
    }

    func signOut() {
        music.stop()
        let old = client
        Task { await old?.logout() }
        StoredSession.clear()
        client = nil
        userId = nil
        userName = nil
        phase = .needsUser
    }
}

/// User-adjustable preferences, stored in UserDefaults.
enum AppSettings {
    static let preferDiscMenuKey = "AsterFIN.preferDiscMenu"
    static let maxBitrateKey = "AsterFIN.maxBitrate"
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

    static var maxBitrate: Int {
        let stored = UserDefaults.standard.integer(forKey: maxBitrateKey)
        return stored > 0 ? stored : 120_000_000
    }

    /// Start the next episode when one ends. On by default.
    static var autoplayNext: Bool {
        UserDefaults.standard.object(forKey: autoplayNextKey) as? Bool ?? true
    }

    static var themeCards: Bool {
        UserDefaults.standard.object(forKey: themeCardsKey) as? Bool ?? true
    }

    /// Jump past intros without asking. Off by default.
    static var autoSkipIntro: Bool {
        UserDefaults.standard.bool(forKey: autoSkipIntroKey)
    }
}
