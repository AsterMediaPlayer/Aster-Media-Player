//
//  ItemDetailView.swift
//  AsterFIN
//
//  The page for a movie, series, season or episode, laid out like the Apple
//  TV app: full-bleed artwork, title and actions, then shelves.
//

import SwiftUI

@Observable
final class DetailModel {
    private(set) var item: BaseItem?
    private(set) var seasons: [BaseItem] = []
    private(set) var selectedSeasonId: String?
    private(set) var episodes: [BaseItem] = []
    /// An episode's page: the episodes of its season, for the bar under
    /// the header. Kept apart from `episodes`, which follows the season
    /// picked on a show's page.
    private(set) var seasonEpisodes: [BaseItem] = []
    private(set) var extras: [BaseItem] = []
    private(set) var cast: [PersonInfo] = []
    private(set) var similar: [BaseItem] = []
    /// The title's scores from MDBList, with a key in Settings.
    private(set) var addedScores: [TitleScore] = []
    private(set) var nextEpisode: BaseItem?
    private(set) var discMenu: DiscMenuDocument?
    /// The item the disc menu belongs to: the page's own, or for a show
    /// without one, the season it's showing.
    private(set) var discMenuItemId: String?
    /// Openings and endings for anime series: the OP/ED plugin's, else ones
    /// found in the episodes' chapters.
    private(set) var openingsEndings: [OpeningEnding] = []

    /// The OP/ED plugin's themes per season, as asked for: each season is one
    /// AniDB entry, and the plugin answers for it by season id.
    private var seasonThemes: [String: [OpEdTheme]] = [:]

    /// The plugin's playable opening (or ending) for one season specifically
    /// (not a show-wide one), skipping spoilers and NSFW: one with video if
    /// there is one, else one with only audio. Asked once per season.
    func pluginTheme(forSeason seasonId: String, opening: Bool, client: JellyfinClient, allowFlagged: Bool = false) async -> OpEdTheme? {
        if seasonThemes[seasonId] == nil {
            seasonThemes[seasonId] = await client.opEdThemes(for: seasonId) ?? []
        }
        return Self.preferredTheme(in: (seasonThemes[seasonId] ?? []).filter { $0.seasonId == seasonId }, opening: opening, allowFlagged: allowFlagged)
    }

    /// The first opening (or ending) that plays, video before audio. Spoilers
    /// and NSFW are skipped unless `allowFlagged` (the viewer is asked first
    /// instead).
    static func preferredTheme(in themes: [OpEdTheme], opening: Bool, allowFlagged: Bool = false) -> OpEdTheme? {
        let matching = themes.filter { $0.isOpening == opening && $0.playablePath != nil && (allowFlagged || (!$0.spoiler && !$0.nsfw)) }
        return matching.first { $0.videoMp4Url != nil } ?? matching.first
    }

    /// What the Watch OP and Watch ED buttons play: on a series page the
    /// selected season's, on an episode page the ones that play in it.
    private(set) var watchOpening: OpeningEnding?
    private(set) var watchEnding: OpeningEnding?

    func updateWatchThemes(client: any MediaServer, isAnime: Bool) async {
        // An episode asks the plugin (Jellyfin's) once for both.
        let episodeThemes = item?.kind == .episode ? await (client as? JellyfinClient)?.opEdThemes(for: item?.id ?? "") ?? [] : []
        watchOpening = await watchTheme(opening: true, episodeThemes: episodeThemes, client: client, isAnime: isAnime)
        watchEnding = await watchTheme(opening: false, episodeThemes: episodeThemes, client: client, isAnime: isAnime)
    }

    /// Series: the plugin's theme for the selected season, else that
    /// season's chapter clip, else the show's first. Episode: the plugin's
    /// theme that plays in it (then its season's, then a show-wide one),
    /// else the episode's own chapter when the show is anime.
    private func watchTheme(opening: Bool, episodeThemes: [OpEdTheme], client: any MediaServer, isAnime: Bool) async -> OpeningEnding? {
        guard let item else { return nil }
        let kind: ThemeClip.Kind = opening ? .opening : .ending
        switch item.kind {
        case .series:
            let themes = openingsEndings.compactMap { if case .theme(let theme) = $0 { theme } else { nil } }
            let clips = openingsEndings.compactMap { if case .chapter(let clip) = $0 { clip } else { nil } }.filter { $0.kind == kind }
            if let seasonId = selectedSeasonId {
                if !themes.isEmpty, let jellyfin = client as? JellyfinClient,
                   let theme = await pluginTheme(forSeason: seasonId, opening: opening, client: jellyfin, allowFlagged: true) {
                    return .theme(theme)
                }
                let number = seasons.first { $0.id == seasonId }?.indexNumber
                if let clip = clips.first(where: { $0.season == number }) {
                    return .chapter(clip)
                }
            }
            if let theme = Self.preferredTheme(in: themes, opening: opening, allowFlagged: true) {
                return .theme(theme)
            }
            return clips.first.map(OpeningEnding.chapter)
        case .episode:
            let candidates = episodeThemes.filter { $0.isOpening == opening && $0.playablePath != nil }
            let pick = candidates.first { $0.playsInEpisode == true }
                ?? candidates.first { $0.seasonId != nil && $0.seasonId == item.seasonId }
                ?? candidates.filter { $0.seasonId == nil }.min { $0.sequence < $1.sequence }
            if let pick {
                return .theme(pick)
            }
            if isAnime, let clip = OpeningsEndings.find(in: [item]).first(where: { $0.kind == kind }) {
                return .chapter(clip)
            }
            return nil
        default:
            return nil
        }
    }

    /// The plugin's themes (Jellyfin's) when it has any that play (or soon
    /// will) for the show, so chapters needn't be read; otherwise clips from
    /// chapters, on every server.
    static func openingsEndings(for series: BaseItem, client: any MediaServer) async -> [OpeningEnding] {
        let themes = (await (client as? JellyfinClient)?.opEdThemes(for: series.id) ?? []).filter { $0.playablePath != nil || $0.isPreparing }
        if !themes.isEmpty { return themes.map(OpeningEnding.theme) }
        // The clips as last read, while the show has as many episodes; else
        // read from the chapters and kept. A failed read isn't kept.
        let server = AnimeThemesLookup.serverKey(client)
        let version = series.recursiveItemCount ?? series.childCount
        let clips: [ThemeClip]
        if let kept = await SongThemeCache.shared.clips(server: server, seriesId: series.id, version: version) {
            clips = kept
        } else {
            guard let episodes = try? await client.episodesWithChapters(seriesId: series.id) else { return [] }
            clips = OpeningsEndings.find(in: episodes)
            await SongThemeCache.shared.putClips(server: server, seriesId: series.id, version: version, clips: clips)
        }
        // Their songs, from AnimeThemes, asked once a season (as it lists
        // each season apart); a few seasons, each asked once per launch.
        var known: [Int: [KnownTheme]] = [:]
        for clip in clips where known[clip.season] == nil {
            known[clip.season] = await PlaybackCoordinator.knownThemes(for: clip.episode, client: client, isAnime: true)
        }
        return clips.map { clip in
            var named = clip
            named.song = OpeningsEndings.song(for: clip, in: known[clip.season] ?? [])
            return .chapter(named)
        }
    }
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func load(_ summary: BaseItem, client: any MediaServer) async {
        isLoading = item == nil
        errorMessage = nil
        do {
            let full = try await client.item(summary.id)
            item = full
            cast = full.cast
            isLoading = false

            // Everything the page needs once it has the item goes out at
            // once, rather than one after another.
            async let similarItems = client.similar(to: full.id, limit: 20)
            async let mdbScores = MDBList.scores(for: full)
            // Openings and endings come from Jellyfin's OP/ED plugin, else
            // from the episodes' chapters on any server.
            async let themes: [OpeningEnding] = full.kind == .series && full.isAnime(on: client.kind)
                ? Self.openingsEndings(for: full, client: client)
                : []
            let hasExtras = full.kind == .movie || full.kind == .series || full.kind == .season
            async let extraItems: [BaseItem] = hasExtras ? ((try? await client.specialFeatures(of: full.id)) ?? []) : []
            // A show's menu waits for its season (selectSeason loads it);
            // anything else's goes out now.
            async let menu: Void = full.kind == .series ? () : loadDiscMenu(client: client)

            switch full.kind {
            case .series:
                async let loadedSeasons = client.seasons(seriesId: full.id)
                async let next = client.nextUp(limit: 1, seriesId: full.id)
                seasons = try await loadedSeasons
                nextEpisode = try? await next.first
                let preferred = nextEpisode?.seasonId ?? seasons.first { ($0.indexNumber ?? 0) > 0 }?.id ?? seasons.first?.id
                if let preferred {
                    await selectSeason(preferred, client: client)
                }
            case .season:
                if let seriesId = full.seriesId {
                    seasons = (try? await client.seasons(seriesId: seriesId)) ?? []
                    await selectSeason(full.id, client: client)
                }
            case .episode:
                if let seriesId = full.seriesId, let seasonId = full.seasonId {
                    seasonEpisodes = (try? await client.episodes(seriesId: seriesId, seasonId: seasonId)) ?? []
                }
            default:
                break
            }

            await menu
            extras = await extraItems
            similar = (try? await similarItems) ?? []
            addedScores = await mdbScores
            openingsEndings = await themes
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func refresh(client: any MediaServer) async {
        guard let current = item else { return }
        if let fresh = try? await client.item(current.id) {
            item = fresh
        }
        if let seasonId = selectedSeasonId, let seriesId = current.kind == .series ? current.id : current.seriesId {
            episodes = (try? await client.episodes(seriesId: seriesId, seasonId: seasonId)) ?? episodes
        }
        if current.kind == .series {
            nextEpisode = try? await client.nextUp(limit: 1, seriesId: current.id).first
        }
        if current.kind == .episode, let seriesId = current.seriesId, let seasonId = current.seasonId {
            seasonEpisodes = (try? await client.episodes(seriesId: seriesId, seasonId: seasonId)) ?? seasonEpisodes
        }
        await loadDiscMenu(client: client)
    }

    func selectSeason(_ seasonId: String, client: any MediaServer) async {
        guard let item, let seriesId = item.kind == .series ? item.id : item.seriesId else { return }
        selectedSeasonId = seasonId
        episodes = (try? await client.episodes(seriesId: seriesId, seasonId: seasonId)) ?? []
        // A show's menu can be its season's: follow the season picked.
        if item.kind == .series, discMenuItemId != item.id {
            await loadDiscMenu(client: client)
        }
    }

    /// The page's disc menu: its own (a movie's, show's or season's), or for
    /// a show without one, the menu of the season it's showing, which is
    /// where a one-season show's menu is often bound.
    func loadDiscMenu(client: any MediaServer) async {
        // Disc menus come from Jellyfin's Aster Disc plugin.
        guard let client = client as? JellyfinClient,
              let item, item.kind == .movie || item.kind == .series || item.kind == .season else { return }
        if let own = (try? await client.discMenu(for: item.id)) ?? nil {
            discMenu = own
            discMenuItemId = item.id
        } else if item.kind == .series, let seasonId = selectedSeasonId,
                  let seasons = (try? await client.discMenu(for: seasonId)) ?? nil {
            discMenu = seasons
            discMenuItemId = seasonId
        } else {
            discMenu = nil
            discMenuItemId = nil
        }
    }

    func toggleFavorite(client: any MediaServer) async {
        guard var current = item else { return }
        let newValue = !(current.userData?.isFavorite ?? false)
        current.userData?.isFavorite = newValue
        item = current
        try? await client.setFavorite(current.id, newValue)
    }

    func togglePlayed(client: any MediaServer) async {
        guard var current = item else { return }
        let newValue = !(current.userData?.played ?? false)
        current.userData?.played = newValue
        if newValue { current.userData?.playbackPositionTicks = 0 }
        item = current
        try? await client.setPlayed(current.id, newValue)
    }

    /// What Play should start: the item itself, or the next episode of a show.
    func playRequest(fromBeginning: Bool = false) -> PlaybackRequest? {
        guard let item else { return nil }
        switch item.kind {
        case .series:
            if let next = nextEpisode {
                return PlaybackRequest(itemId: next.id, startTicks: fromBeginning ? 0 : (next.userData?.playbackPositionTicks ?? 0))
            }
            if let first = episodes.first {
                return PlaybackRequest(itemId: first.id)
            }
            return nil
        case .season:
            let target = episodes.first { $0.userData?.played != true } ?? episodes.first
            return target.map { PlaybackRequest(itemId: $0.id, startTicks: fromBeginning ? 0 : ($0.userData?.playbackPositionTicks ?? 0)) }
        default:
            return PlaybackRequest(
                itemId: item.id,
                startTicks: fromBeginning ? 0 : (item.userData?.playbackPositionTicks ?? 0)
            )
        }
    }
}

struct ItemDetailView: View {
    let item: BaseItem

    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @AppStorage(AppSettings.preferDiscMenuKey) private var preferDiscMenu = false
    @AppStorage(AppSettings.themeMusicKey) private var themeMusic = false
    @AppStorage(AppSettings.themeVideosKey) private var themeVideos = false
    @AppStorage(AppSettings.openingSoundKey) private var openingSound = false
    @State private var model = DetailModel()
    #if os(tvOS)
    /// The page as one focus scope, the Now Playing panel included, so Back
    /// there can hand focus back to the card that started it.
    @Namespace private var pageFocus
    /// A tab was just picked: the section it shows is the page's preferred
    /// focus for a moment, so a reset of the page hands focus to its first
    /// item (a reset only acts in the scope focus is in, the whole page).
    @State private var focusesSection = false
    /// The shown section's first card (see `SectionLead`).
    @FocusState private var sectionLeadFocused: Bool
    @Environment(\.resetFocus) private var resetFocus
    #endif
    @State private var playback: PlaybackRequest?
    /// Where the Play button's middle is across the screen, which the
    /// episode bar centers the next episode under.
    @State private var playButtonMidX: CGFloat?
    /// The episode the player moved on to by itself (autoplay), which the
    /// page follows once the player closes.
    @State private var playedOnTo: BaseItem?
    #if os(iOS)
    @AppStorage(AppSettings.downloadsEnabledKey) private var downloadsEnabled = true
    /// A title waiting on the first-download setup sheet.
    @State private var downloadSetupItem: BaseItem?
    /// Set up, waiting for the setup sheet to finish closing.
    @State private var downloadAfterSetup: BaseItem?
    /// A title waiting on its audio and subtitle choice.
    @State private var downloadTracksItem: BaseItem?
    @State private var downloadError: String?
    #endif
    /// An OP/ED plugin theme playing, which isn't a Jellyfin item.
    @State private var urlPlayback: URLPlayback?
    /// A spoiler or NSFW theme waiting for the viewer's go-ahead.
    @State private var confirmTheme: OpEdTheme?
    @State private var showDiscMenu = false
    /// The tab a show's page is on.
    @State private var section: DetailSection = .episodes
    /// The Music tab's openings and endings, playing in the Now Playing
    /// panel; it keeps going across tabs, and stops on leaving the page.
    @Environment(\.themeMiniInset) private var themeMiniInset
    /// The app's openings-and-endings player, shared so one keeps playing
    /// after this page closes.
    private var themeDeck: ThemeDeck { session.themeDeck }
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var message: String?
    @State private var notice: String?
    @State private var playlistRequest: PlaylistRequest?
    @State private var confirmDeleteRecording = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedAction: String?
    @FocusState private var actionGuardFocused: Bool
    /// Watch OP with the opening already behind the page: everything else
    /// fades away and it plays with full sound, with its card.
    @State private var watchingOpening = false
    #if os(macOS)
    /// The window's height, which the header is sized from (`headerMinHeight`).
    @State private var pageHeight: CGFloat = 0
    #endif
    @State private var watchingInfo: ThemeInfo?
    @FocusState private var watchingFocused: Bool

    private var detail: BaseItem { model.item ?? item }

    /// The theme video only shows when it belongs to this title (or its series).
    private var themeVideo: DiscTrailerPlayer? {
        session.theme.key == (item.seriesId ?? item.id) ? session.theme.videoPlayer : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Backdrop(url: session.client?.backdropURL(for: detail, width: Lockup.fullScreenImageWidth(displayScale: displayScale)), video: themeVideo, showsShade: !watchingOpening, watching: watchingOpening)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    header
                        .frame(maxWidth: .infinity, minHeight: headerMinHeight, alignment: .bottomLeading)

                    if usesSections {
                        // A show's page in tabs, so its episodes, songs,
                        // extras and details aren't one long scroll.
                        DetailSectionBar(sections: sections, selection: shownSectionBinding)
                        sectionContent
                            #if os(tvOS)
                            .environment(\.sectionLead, SectionLead(focus: $sectionLeadFocused, scope: pageFocus, active: focusesSection))
                            #endif
                    } else {
                        shelves
                    }
                }
                .padding(.bottom, 80)
                // Room for the Now Playing panel on the right: everything,
                // the header's description too, moves over beside it.
                // (or for the slim one, playing another show's theme)
                .padding(.trailing, showsThemePanel ? ThemePanelMetrics.width + ThemePanelMetrics.gap : themeMiniInset)
                .animation(.smooth(duration: 0.4), value: showsThemePanel)
                .animation(.smooth(duration: 0.4), value: themeMiniInset)
            }
            .scrollClipDisabled()
            #if os(macOS)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
            #endif
            .opacity(watchingOpening ? 0 : 1)
            .disabled(watchingOpening)

            if watchingOpening {
                // Holds focus while the page is hidden, so Back returns to it
                // instead of leaving the page.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focused($watchingFocused)
                    .tvExitCommand { stopWatchingOpening() }
                    .accessibilityLabel("Opening")
                if let watchingInfo {
                    ThemeInfoOverlay(info: watchingInfo)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        // The Now Playing panel, fixed on the right of the screen (within
        // the safe area) whatever the page is scrolled to.
        .overlay(alignment: .topTrailing) {
            if showsThemePanel {
                ThemeNowPlayingPanel(
                    deck: themeDeck,
                    artwork: session.client?.landscapeURL(for: detail, width: 800),
                    seasonName: { ThemeMusicSection.seasonName($0, in: model.seasons) }
                )
                .frame(width: ThemePanelMetrics.width)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .padding(.trailing, ThemePanelMetrics.trailing)
                .padding(.vertical, ThemePanelMetrics.vertical)
                .frame(maxHeight: .infinity, alignment: .top)
                // A fade, not a slide: moving its glass controls across the screen
                // has the system re-render the glass every frame off the main
                // thread, filling the console with setPresentationValue faults.
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: showsThemePanel)
        #if os(tvOS)
        .focusScope(pageFocus)
        #endif
        #if os(tvOS)
        // A tab picked: focus goes down into what it shows (the first
        // episode, song or show), once the new section is laid out. One with
        // nothing to focus (Details) leaves it on the tab.
        .onChange(of: shownSection) { _, _ in
            focusesSection = true
            Task {
                // Once the new section is laid out: straight to its first card,
                // and if the focus engine won't move there directly, a reset
                // of the page with that card as its preferred focus.
                try? await Task.sleep(for: .milliseconds(300))
                sectionLeadFocused = true
                try? await Task.sleep(for: .milliseconds(150))
                if !sectionLeadFocused { resetFocus(in: pageFocus) }
                #if DEBUG
                try? await Task.sleep(for: .milliseconds(100))
                print("DEBUG focus: tab picked; the section's first card \(sectionLeadFocused ? "has" : "didn't get") focus")
                #endif
                // Back to the page's own default once focus has moved.
                try? await Task.sleep(for: .milliseconds(500))
                focusesSection = false
            }
        }
        #endif
        // While this page shows the full panel, the slim one stays away.
        .onChange(of: showsThemePanel, initial: true) { _, shows in
            if shows {
                session.themePanelPage = item.id
            } else if session.themePanelPage == item.id {
                session.themePanelPage = nil
            }
        }
        #if !os(tvOS)
        // No remote Back here: this ends the opening, back to the page. An
        // overlay keeps to the safe area, clear of the camera.
        .overlay(alignment: .topLeading) {
            if watchingOpening {
                Button {
                    stopWatchingOpening()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(.white)
                .accessibilityLabel("Stop watching")
                .padding(.leading, Lockup.screenPadding)
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        // Watching an opening takes the whole screen: the page's own back
        // button would leave the page rather than end the opening.
        #if os(iOS)
        .toolbar(watchingOpening ? .hidden : .automatic, for: .navigationBar)
        .toolbar(watchingOpening ? .hidden : .automatic, for: .tabBar)
        .statusBarHidden(watchingOpening)
        #endif
        #endif
        .onChange(of: watchingOpening) { _, watching in
            if watching {
                watchingFocused = true
            } else {
                // Once the page is enabled again.
                Task { focusedAction = "watchOP" }
            }
        }
        // Once the opening has played through, the page comes back.
        .onChange(of: themeVideo?.loops) { _, _ in
            if watchingOpening { stopWatchingOpening() }
        }
        .task(id: item.id) {
            guard let client = session.client else { return }
            // Theme songs and videos are Jellyfin's; an opening stands in on any server.
            session.theme.show(item: item, client: client, music: themeMusic, video: themeVideos, musicPlaying: session.music.isPlaying || session.audiobooks.isPlaying)
            await model.load(item, client: client)
            // Opened from a hero's Play: play now, with this page behind.
            if session.playOnOpen == item.id {
                session.playOnOpen = nil
                play(fromBeginning: false)
            }
            await showOpening(client: client)
            await model.updateWatchThemes(client: client, isAnime: isAnimeShow)
        }
        // Picking another season swaps in that season's opening, both behind
        // the page and for Watch OP.
        .onChange(of: model.selectedSeasonId) { _, _ in
            guard let client = session.client else { return }
            Task {
                await showOpening(client: client)
                await model.updateWatchThemes(client: client, isAnime: isAnimeShow)
            }
        }
        .onAppear { session.theme.pageAppeared(for: item) }
        .onDisappear {
            if watchingOpening { stopWatchingOpening() }
            // The theme keeps playing, in the slim panel.
            if session.themePanelPage == item.id { session.themePanelPage = nil }
            session.theme.pageDisappeared(for: item)
        }
        .onChange(of: playback != nil || urlPlayback != nil || showDiscMenu) { _, covered in
            // Quiet the theme while a video or disc menu is on screen.
            if covered {
                themeDeck.stop()
                session.theme.suspend()
            } else {
                session.theme.resume()
            }
        }
        .appCover(item: $playback, onDismiss: {
            let reached = playedOnTo
            playedOnTo = nil
            Task { await followPlayback(to: reached) }
        }) { request in
            PlayerView(request: request, onItemStarted: { started in
                // Only an episode after the one asked for: not the first
                // item, and not an opening clip.
                if started.kind == .episode, started.id != request.items.first?.itemId {
                    playedOnTo = started
                }
            }) { playback = nil }
        }
        .appCover(item: $urlPlayback) { theme in
            URLPlayerView(playback: theme) { urlPlayback = nil }
        }
        .alert(confirmTheme?.nsfw == true ? "NSFW" : "Spoilers", isPresented: Binding(get: { confirmTheme != nil }, set: { if !$0 { confirmTheme = nil } })) {
            Button("Play") {
                if let theme = confirmTheme { play(theme) }
                confirmTheme = nil
            }
            Button("Cancel", role: .cancel) { confirmTheme = nil }
        } message: {
            Text(confirmTheme?.nsfw == true
                 ? "This opening or ending is marked as not safe for work."
                 : "This opening or ending is marked as containing spoilers.")
        }
        .appCover(isPresented: $showDiscMenu, onDismiss: {
            Task { if let client = session.client { await model.refresh(client: client) } }
        }) {
            if let document = model.discMenu {
                DiscMenuView(document: document, itemId: model.discMenuItemId ?? detail.id)
            }
        }
        .alert("Can't Play", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .alert("Playlist", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        .alert("Delete this recording?", isPresented: $confirmDeleteRecording) {
            Button("Delete Recording", role: .destructive) { deleteRecording() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The recording is removed from the server and cannot be recovered.")
        }
        .appCover(item: $playlistRequest) { request in
            PlaylistPickerView(itemIds: request.itemIds, mediaType: "Video") { name in
                notice = "Added to \(name)."
            }
        }
        #if os(iOS)
        .sheet(item: $downloadSetupItem, onDismiss: {
            // One sheet at a time: the track choice opens once setup has gone.
            if let item = downloadAfterSetup {
                downloadAfterSetup = nil
                requestDownload(item)
            }
        }) { item in
            DownloadSetupView { proceed in
                if proceed { downloadAfterSetup = item }
                downloadSetupItem = nil
            }
        }
        .sheet(item: $downloadTracksItem) { item in
            DownloadTracksView(item: item) { choice in
                downloadTracksItem = nil
                if let choice { beginDownload(item, audio: choice.audio, subtitle: choice.subtitle) }
            }
        }
        .alert("Couldn't Download", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
        #endif
    }

    // MARK: Sections

    /// Shows and seasons are laid out in tabs; everything else is one scroll.
    private var usesSections: Bool { detail.kind == .series || detail.kind == .season }

    /// The tabs with something in them, in order.
    private var sections: [DetailSection] {
        var found: [DetailSection] = [.episodes]
        if !model.openingsEndings.isEmpty { found.append(.music) }
        if !model.extras.isEmpty { found.append(.extras) }
        if !model.similar.isEmpty { found.append(.related) }
        found.append(.details)
        return found
    }

    /// The chosen tab, or Episodes while the chosen one has nothing (yet).
    private var shownSection: DetailSection { sections.contains(section) ? section : .episodes }

    private var shownSectionBinding: Binding<DetailSection> {
        Binding(get: { shownSection }, set: { section = $0 })
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch shownSection {
        case .episodes:
            episodesSection
        case .music:
            // The panel's Full Screen hands its theme to the full-screen
            // player; it was already OK'd if it's a spoiler.
            ThemeMusicSection(entries: model.openingsEndings, seasons: model.seasons, fallbackArtwork: session.client?.landscapeURL(for: detail, width: 800),
                              show: detail, deck: themeDeck, panelBesidePage: themePanelBesidePage,
                              focusScope: pageFocusScope,
                              fullScreen: { entry in themeFullScreen(entry) },
                              addToPlaylist: { ids in playlistRequest = PlaylistRequest(itemIds: ids) })
        case .extras:
            extrasShelf
        case .related:
            relatedShelf
        case .details:
            detailsContent
        }
    }

    /// Everything after the header, one shelf after another: a movie's or
    /// an episode's page.
    @ViewBuilder
    private var shelves: some View {
        if detail.kind == .episode {
            EpisodeStrip(season: model.seasonEpisodes, currentId: detail.id, centerX: playButtonMidX)
        }

        Shelf(title: "Openings & Endings", items: model.openingsEndings) { entry in
            switch entry {
            case .theme(let theme):
                OpEdThemeLockup(
                    theme: theme,
                    seasonName: model.seasons.first { $0.id == theme.seasonId }?.displayTitle,
                    artwork: session.client?.landscapeURL(for: detail, width: 800)
                ) {
                    if theme.spoiler || theme.nsfw {
                        confirmTheme = theme
                    } else {
                        play(theme)
                    }
                }
            case .chapter(let clip):
                // Plays just that stretch of the episode; its resume
                // point and watched state are left alone.
                ThemeClipLockup(clip: clip) {
                    playThemeCard(.chapter(clip))
                }
            }
        }

        extrasShelf
        relatedShelf
        detailsContent
    }

    private var extrasShelf: some View {
        Shelf(title: "Extras", items: model.extras) { extra in
            ExtraLockup(item: extra) {
                playback = PlaybackRequest(itemId: extra.id)
            }
        }

    }

    private var relatedShelf: some View {
        Shelf(title: "Related", items: model.similar) { related in
            LandscapeLockup(item: related)
        }

    }

    /// Who's in it, and the facts about it.
    @ViewBuilder
    private var detailsContent: some View {
        Shelf(title: "Cast & Crew", items: model.cast, spacing: Lockup.personSpacing) { person in
            PersonLockup(person: person)
        }

        InformationSection(item: detail)
            .padding(.horizontal, Lockup.screenPadding)
    }

    /// The Now Playing panel's size and place. It sits inside the safe area,
    /// which on the TV already keeps it off the screen's edges.
    private enum ThemePanelMetrics {
        #if os(tvOS)
        static let width: CGFloat = 560
        static let gap: CGFloat = 40
        static let trailing: CGFloat = 0
        static let vertical: CGFloat = 0
        #else
        static let width: CGFloat = 340
        static let gap: CGFloat = 24
        static let trailing: CGFloat = 20
        static let vertical: CGFloat = 16
        #endif
    }

    /// Whether the panel goes on the right of the page: not on a phone,
    /// where it's in the Music tab instead.
    private var themePanelBesidePage: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    /// The full panel: on the page of the show whose theme is playing.
    /// The page's focus scope, for the Music tab's cards (Apple TV).
    private var pageFocusScope: Namespace.ID? {
        #if os(tvOS)
        pageFocus
        #else
        nil
        #endif
    }

    private var showsThemePanel: Bool {
        themeDeck.isActive && themeDeck.showItem?.id == detail.id && themePanelBesidePage && usesSections && !watchingOpening
    }

    /// The panel's Full Screen: the full-screen player takes it over (a
    /// spoiler was OK'd already), and covering the page stops the panel.
    private func themeFullScreen(_ entry: OpeningEnding) {
        switch entry {
        case .theme(let theme): play(theme)
        case .chapter: playThemeCard(entry)
        }
    }

    /// A theme's card pressed: a plugin theme asks first when it's marked as
    /// a spoiler or NSFW; a chapter clip plays just that stretch of its
    /// episode, leaving its resume point and watched state alone.
    private func playThemeCard(_ entry: OpeningEnding) {
        switch entry {
        case .theme(let theme):
            if theme.spoiler || theme.nsfw {
                confirmTheme = theme
            } else {
                play(theme)
            }
        case .chapter(let clip):
            playback = PlaybackRequest(clipOf: clip.episode.id, fromTicks: clip.startTicks, toTicks: clip.endTicks, info: info(for: clip))
        }
    }

    // MARK: Header

    /// The space the header fills before the rest of the page, its details
    /// along the bottom over the backdrop. A Mac window is often shorter than
    /// a phone, so there it takes the TV's share of the window (780 of 1080
    /// points) and the details show without scrolling.
    private var headerMinHeight: CGFloat {
        #if os(macOS)
        pageHeight > 0 ? pageHeight * 0.72 : 520
        #else
        780
        #endif
    }

    /// Header sizes: TV-sized on tvOS, phone-sized elsewhere.
    private enum HeaderMetrics {
        #if os(tvOS)
        static let titleSize: CGFloat = 64
        static let logoSize = CGSize(width: 600, height: 200)
        static let seriesLogoSize = CGSize(width: 420, height: 130)
        #else
        static let titleSize: CGFloat = 30
        static let logoSize = CGSize(width: 280, height: 100)
        static let seriesLogoSize = CGSize(width: 220, height: 70)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            // An episode or season page names its show above its own title:
            // the show's logo when it has one, else its name.
            if detail.kind == .episode || detail.kind == .season, let series = detail.seriesName {
                let seriesName = Text(series)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let logo = session.client?.logoURL(for: detail) {
                    RemoteImage(url: logo, contentMode: .fit) { seriesName }
                        .frame(maxWidth: HeaderMetrics.seriesLogoSize.width, maxHeight: HeaderMetrics.seriesLogoSize.height, alignment: .leading)
                        .accessibilityLabel(series)
                } else {
                    seriesName
                }
            }

            if let logo = session.client?.logoURL(for: detail), detail.kind != .episode, detail.kind != .season {
                RemoteImage(url: logo, contentMode: .fit) {
                    Text(detail.displayTitle).font(.system(size: HeaderMetrics.titleSize * 1.125, weight: .bold))
                }
                .frame(maxWidth: HeaderMetrics.logoSize.width, maxHeight: HeaderMetrics.logoSize.height, alignment: .leading)
            } else {
                Text(detail.displayTitle)
                    .font(.system(size: HeaderMetrics.titleSize, weight: .bold))
                    .lineLimit(2)
            }

            if detail.kind == .episode, let code = detail.episodeCode {
                Text(code).font(.headline).foregroundStyle(.secondary)
            }

            MetadataLine(item: detail, showsUnwatched: true, addedScores: model.addedScores)

            if let tagline = detail.taglines?.first {
                Text(tagline)
                    .font(.title3.italic())
                    .foregroundStyle(.secondary)
            }

            if let overview = detail.overview {
                Text(overview)
                    .font(.callout)
                    .lineLimit(5)
                    .frame(maxWidth: 1000, alignment: .leading)
            }

            if detail.kind == .series, let next = model.nextEpisode {
                Text("Up next: \([next.episodeCode, next.name].compactMap { $0 }.joined(separator: " · "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            #if os(tvOS)
            actionRow
                .padding(.top, 8)
            #else
            // A phone can't fit every action across; let the row scroll sideways.
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal) {
                    actionRow
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()

                if model.watchOpening != nil || model.watchEnding != nil {
                    HStack(spacing: 12) {
                        themeButtons
                    }
                }
            }
            .padding(.top, 8)
            #endif
        }
        #if os(tvOS)
        .padding(.horizontal, 90)
        #else
        .padding(.horizontal, Lockup.screenPadding)
        #endif
        .padding(.bottom, 20)
        .tvFocusSection()
    }

    private var showsWatchedButton: Bool { detail.kind != .series && detail.kind != .season }

    /// Everything that can go in a playlist, be deleted, or lead to its series.
    private var showsMoreMenu: Bool {
        let kinds: [ItemKind] = [.movie, .episode, .series, .season, .video, .recording, .musicVideo]
        return kinds.contains(detail.kind)
    }

    /// The id of the rightmost button in the action row, where focus returns
    /// when a right press runs off the end of the row.
    private var trailingActionID: String {
        if model.watchEnding != nil { return "watchED" }
        if model.watchOpening != nil { return "watchOP" }
        if showsMoreMenu { return "more" }
        if showsWatchedButton { return "watched" }
        return "favorite"
    }

    /// An episode that hasn't aired (Jellyfin's placeholder from the show's
    /// schedule): nothing to play yet.
    private var isUnaired: Bool { detail.kind == .episode && detail.locationType == "Virtual" }

    private var actionRow: some View {
        HStack(spacing: 20) {
            let resumable = detail.kind == .series ? (model.nextEpisode?.canResume ?? false) : detail.canResume
            if isUnaired {
                // When it airs, and its show, in Play's place.
                if let seriesId = detail.seriesId {
                    NavigationLink(value: BaseItem(id: seriesId, name: detail.seriesName, type: ItemKind.series.rawValue)) {
                        Label("Go to Show", systemImage: "tv")
                    }
                    .actionButtonStyle(prominent: true)
                    .focused($focusedAction, equals: "play")
                }
                if let airs = UpcomingSchedule.airsLine(for: detail) {
                    Label(airs, systemImage: "calendar")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
            } else {
            ActionButton(title: playTitle(resumable: resumable), systemImage: "play.fill", prominent: true, focus: $focusedAction, focusID: "play") {
                play(fromBeginning: false)
            }
            // For the episode bar, which lines the next episode up under it.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { playButtonMidX = $0 }
            }
            if resumable, !isUnaired {
                ActionButton(title: "From Beginning", systemImage: "arrow.counterclockwise", focus: $focusedAction, focusID: "beginning") {
                    play(fromBeginning: true)
                }
            }
            if model.discMenu != nil {
                ActionButton(title: "Disc Menu", systemImage: "opticaldisc", focus: $focusedAction, focusID: "disc") {
                    showDiscMenu = true
                }
            }
            // Plex keeps no favourites.
            if session.client?.capabilities.contains(.favorites) == true {
                IconButton(systemImage: detail.userData?.isFavorite == true ? "heart.fill" : "heart", accessibilityLabel: "Favorite", focus: $focusedAction, focusID: "favorite") {
                    Task { if let client = session.client { await model.toggleFavorite(client: client) } }
                }
            }
            // A film or show onto the person's Simkl watchlist, through the server.
            WatchlistButton(title: WatchlistTitle(item: detail), iconOnly: true, focus: $focusedAction)
            if showsWatchedButton {
                IconButton(systemImage: detail.userData?.played == true ? "checkmark.circle.fill" : "checkmark.circle", accessibilityLabel: "Watched", focus: $focusedAction, focusID: "watched") {
                    Task { if let client = session.client { await model.togglePlayed(client: client) } }
                }
            }
            if showsMoreMenu {
                moreMenu
            }
            #if os(tvOS)
            // Last in the row, so a press to the right ends here.
            themeButtons
            #endif
            if let remaining = detail.remainingText, detail.kind != .series {
                Text(remaining)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            #if os(tvOS)
            // With nothing directly to the right of the last button, the focus
            // engine widens its search and can land on a lockup in the shelf
            // below, which scrolls the page. This sliver sits squarely to the
            // right, so it catches that press and hands focus straight back.
            Color.clear
                .frame(width: 2, height: 44)
                .focusable()
                .focused($actionGuardFocused)
                .accessibilityHidden(true)
            #endif
        }
        #if os(tvOS)
        .onChange(of: actionGuardFocused) { _, focused in
            guard focused else { return }
            focusedAction = trailingActionID
        }
        #endif
    }

    /// Watch OP and Watch ED: at the end of the action row on tvOS, and in a
    /// row of their own under it on iOS.
    @ViewBuilder
    private var themeButtons: some View {
        if let opening = model.watchOpening {
            ActionButton(title: "Watch OP", systemImage: "music.note.tv", focus: $focusedAction, focusID: "watchOP") {
                watch(opening)
            }
        }
        if let ending = model.watchEnding {
            ActionButton(title: "Watch ED", systemImage: "music.note.list", focus: $focusedAction, focusID: "watchED") {
                watch(ending)
            }
        }
    }

    /// The "…" menu: Go to Series on episodes (a stub item is enough, the page
    /// reloads it), Add to Playlist, and Delete Recording for recordings.
    private var moreMenu: some View {
        Menu {
            if detail.kind == .episode, let seriesId = detail.seriesId {
                NavigationLink(value: BaseItem(id: seriesId, name: detail.seriesName, type: ItemKind.series.rawValue)) {
                    Label("Go to Series", systemImage: "tv")
                }
            }
            Button {
                addToPlaylist()
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            if detail.kind == .recording {
                Button(role: .destructive) {
                    confirmDeleteRecording = true
                } label: {
                    Label("Delete Recording", systemImage: "trash")
                }
            }
            #if os(iOS)
            downloadMenuItem
            #endif
        } label: {
            Image(systemName: "ellipsis")
                .font(Lockup.iconButtonFont)
                .frame(width: Lockup.iconButtonSize, height: Lockup.iconButtonSize)
                #if os(iOS)
                // Pulses while this title downloads, and when its download failed.
                .symbolEffect(.pulse, options: .repeating, isActive: downloadRecord.map { $0.state != .finished } ?? false)
                #endif
        }
        .actionButtonStyle()
        #if os(iOS)
        .overlay {
            if downloadRecord?.state == .failed {
                DownloadFailedGlow()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: downloadRecord?.state)
        .overlay { downloadProgressRing }
        .overlay(alignment: .topTrailing) { downloadedBadge }
        #endif
        .accessibilityLabel("More")
        .focused($focusedAction, equals: "more")
    }

    #if os(iOS)
    private var downloadRecord: DownloadRecord? {
        DownloadStore.shared.record(for: detail.id)
    }

    /// Around the ⋯ button while this title downloads, filling as it goes.
    @ViewBuilder
    private var downloadProgressRing: some View {
        if let record = downloadRecord, record.state == .downloading {
            ZStack {
                Capsule().stroke(.white.opacity(0.25), lineWidth: 3)
                Capsule()
                    .trim(from: 0, to: max(record.progress, 0.02))
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .animation(.linear(duration: 0.3), value: record.progress)
            }
            .padding(-3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Red over the ⋯ button, pulsing, when this title's download failed.
    private struct DownloadFailedGlow: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var bright = false

        var body: some View {
            Capsule()
                .fill(Color.red.opacity(bright ? 0.65 : 0.3))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onAppear {
                    guard !reduceMotion else {
                        bright = true
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        bright = true
                    }
                }
        }
    }

    /// On the ⋯ button's corner once this title is downloaded.
    @ViewBuilder
    private var downloadedBadge: some View {
        if downloadRecord?.state == .finished {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .white)
                .offset(x: 4, y: -4)
                .allowsHitTesting(false)
                .accessibilityLabel("Downloaded")
        }
    }
    #endif



    #if os(iOS)
    /// Download, its progress (tap to cancel), or Remove Download: movies and
    /// episodes, when downloads are on and the server allows them.
    @ViewBuilder
    private var downloadMenuItem: some View {
        let downloadable: [ItemKind] = [.movie, .episode, .video]
        if downloadsEnabled, session.canDownload, downloadable.contains(detail.kind) {
            let store = DownloadStore.shared
            switch store.record(for: detail.id)?.state {
            case .downloading:
                let percent = Int((store.record(for: detail.id)?.progress ?? 0) * 100)
                Button(role: .destructive) {
                    store.remove(detail.id)
                } label: {
                    Label("Cancel Download (\(percent)%)", systemImage: "xmark.circle")
                }
            case .finished:
                Button(role: .destructive) {
                    store.remove(detail.id)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            case .failed:
                Button {
                    resumeDownload(detail)
                } label: {
                    Label("Resume Download", systemImage: "arrow.clockwise.circle")
                }
                Button(role: .destructive) {
                    store.remove(detail.id)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            case nil:
                Button {
                    requestDownload(detail)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    /// Setup the first time, then the track choice when there is one, then
    /// the download.
    private func requestDownload(_ item: BaseItem) {
        if !DownloadSettings.isSetUp {
            downloadSetupItem = item
        } else if DownloadTracksView.hasChoice(for: item) {
            downloadTracksItem = item
        } else {
            beginDownload(item)
        }
    }

    /// Carries on with a failed download from where it stopped.
    private func resumeDownload(_ item: BaseItem) {
        guard let client = session.jellyfin else { return }
        Task {
            do {
                try await DownloadStore.shared.retry(item.id, client: client, preferences: session.playbackPreferences, canDownload: session.canDownload)
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    private func beginDownload(_ item: BaseItem, audio: Int? = nil, subtitle: Int? = nil) {
        guard let client = session.jellyfin else { return }
        Task {
            do {
                let store = DownloadStore.shared
                // A failed attempt is replaced by this one.
                if store.record(for: item.id)?.state == .failed {
                    store.remove(item.id)
                }
                try await store.start(item, client: client, preferences: session.playbackPreferences, canDownload: session.canDownload, audioStreamIndex: audio, subtitleChoice: subtitle)
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }
    #endif

    /// Series and seasons add their episodes; everything else adds itself.
    private func addToPlaylist() {
        guard let client = session.jellyfin else { return }
        Task {
            let ids: [String]
            switch detail.kind {
            case .series:
                ids = ((try? await client.episodes(seriesId: detail.id, seasonId: nil)) ?? []).map(\.id)
            case .season:
                ids = model.episodes.map(\.id)
            default:
                ids = [detail.id]
            }
            guard !ids.isEmpty else {
                notice = "There is nothing to add yet."
                return
            }
            playlistRequest = PlaylistRequest(itemIds: ids)
        }
    }

    private func deleteRecording() {
        guard let client = session.jellyfin else { return }
        Task {
            do {
                try await client.deleteRecording(detail.id)
                dismiss()
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// Anime with no theme video of its own loops an opening behind the page
    /// instead, never one marked as a spoiler or NSFW. Preference: the
    /// plugin's opening for the selected season, then one found in that
    /// season's chapters, then the show's first opening of either kind.
    private func showOpening(client: any MediaServer) async {
        guard themeVideos, detail.kind == .series, !model.openingsEndings.isEmpty else {
            #if DEBUG
            if detail.kind == .series {
                print("DEBUG theme: no opening behind \(detail.displayTitle): themeVideos=\(themeVideos) entries=\(model.openingsEndings.count)")
            }
            #endif
            return
        }
        let themes = model.openingsEndings.compactMap { if case .theme(let theme) = $0 { theme } else { nil } }
        let clips = model.openingsEndings.compactMap { if case .chapter(let clip) = $0 { clip } else { nil } }.filter { $0.kind == .opening }
        #if DEBUG
        let described = themes.filter(\.isOpening).map { "\($0.slug) video=\($0.videoMp4Status ?? "none") url=\($0.videoMp4Url != nil) audio=\($0.audioM4aStatus ?? "none")" }
        print("DEBUG theme: \(detail.displayTitle): plugin openings [\(described.joined(separator: "; "))], chapter openings \(clips.count) (seasons \(clips.map(\.season))), season picked \(model.seasons.first { $0.id == model.selectedSeasonId }?.indexNumber.map(String.init) ?? "none"), sound \(openingSoundNow)")
        #endif
        // The plugin's themes are Jellyfin's.
        let jellyfin = client as? JellyfinClient

        if let seasonId = model.selectedSeasonId {
            if !themes.isEmpty, let jellyfin, let theme = await model.pluginTheme(forSeason: seasonId, opening: true, client: jellyfin), show(theme, client: jellyfin) {
                return
            }
            let number = model.seasons.first { $0.id == seasonId }?.indexNumber
            if let clip = clips.first(where: { $0.season == number }) {
                session.theme.showOpeningIfNoVideo(clip, for: item, client: client, sound: openingSoundNow)
                return
            }
            // Nothing for this season: keep whatever opening is already playing.
            if session.theme.isShowingOpening {
                #if DEBUG
                print("DEBUG theme: \(detail.displayTitle): nothing for season \(number.map(String.init) ?? "?"), keeping the opening already playing")
                #endif
                return
            }
        }
        if let jellyfin, let theme = DetailModel.preferredTheme(in: themes, opening: true), show(theme, client: jellyfin) {
            return
        }
        if let clip = clips.first {
            session.theme.showOpeningIfNoVideo(clip, for: item, client: client, sound: openingSoundNow)
        } else {
            #if DEBUG
            print("DEBUG theme: \(detail.displayTitle): no opening to play (no plugin video ready, no opening chapter)")
            #endif
        }
    }

    /// Openings behind the page have sound when that's on, unless a song or
    /// book is playing: then they're silent, or (with only a song) left out.
    private var openingSoundNow: Bool { openingSound && !session.isAudioPlaying }

    /// Puts a plugin opening behind the page: its video, or with only audio,
    /// its song as the theme music when openings have sound. Returns whether
    /// it could.
    private func show(_ theme: OpEdTheme, client: JellyfinClient) -> Bool {
        if let path = theme.videoMp4Url {
            session.theme.showOpeningIfNoVideo(theme, url: client.opEdMediaURL(path), for: item, sound: openingSoundNow)
            return true
        }
        if openingSoundNow, let path = theme.audioM4aUrl {
            session.theme.showOpeningSongIfNoVideo(theme, url: client.opEdMediaURL(path), for: item)
            return true
        }
        return false
    }

    /// Watch OP or Watch ED at full volume. When it's the video already
    /// looping behind the page, the page just fades away around it;
    /// otherwise it opens in the player. Either way its card shows in the
    /// lower left. Plugin themes marked as spoilers or NSFW ask first, as
    /// their cards do (they never play behind the page).
    private func watch(_ entry: OpeningEnding) {
        themeDeck.stop()
        let entryId: String
        let info: ThemeInfo
        switch entry {
        case .theme(let theme):
            entryId = theme.id
            info = self.info(for: theme)
        case .chapter(let clip):
            entryId = clip.id
            info = self.info(for: clip)
        }
        if themeVideo != nil, session.theme.isShowingOpeningVideo(entryId) {
            session.theme.watchOpening()
            watchingInfo = info
            withAnimation(.easeInOut(duration: 0.6)) { watchingOpening = true }
            return
        }
        switch entry {
        case .theme(let theme):
            if theme.spoiler || theme.nsfw {
                confirmTheme = theme
            } else {
                play(theme)
            }
        case .chapter(let clip):
            playback = PlaybackRequest(clipOf: clip.episode.id, fromTicks: clip.startTicks, toTicks: clip.endTicks, info: info)
        }
    }

    private func stopWatchingOpening() {
        session.theme.stopWatchingOpening()
        withAnimation(.easeInOut(duration: 0.6)) {
            watchingOpening = false
            watchingInfo = nil
        }
    }

    /// The show's name for a theme's card: on an episode page, its series.
    private var seriesName: String { detail.seriesName ?? detail.displayTitle }

    private func info(for theme: OpEdTheme) -> ThemeInfo {
        ThemeInfo(theme: theme, series: seriesName, seasonName: model.seasons.first { $0.id == theme.seasonId }?.displayTitle)
    }

    private func info(for clip: ThemeClip) -> ThemeInfo {
        ThemeInfo(clip: clip, series: seriesName)
    }

    /// Whether this page's show is anime, for finding OPs in chapters.
    private var isAnimeShow: Bool {
        detail.kind == .series ? detail.isAnime(on: session.client?.kind ?? .jellyfin) : session.animeItemIds.contains(detail.seriesId ?? "")
    }

    /// Plays an OP/ED plugin theme: its MP4, or audio tvOS can play.
    private func play(_ theme: OpEdTheme) {
        guard let path = theme.playablePath, let client = session.jellyfin else { return }
        urlPlayback = URLPlayback(
            url: client.opEdMediaURL(path),
            title: theme.songLine ?? theme.code,
            subtitle: [detail.displayTitle, theme.code].joined(separator: " · "),
            artwork: client.landscapeURL(for: detail, width: 1920),
            info: info(for: theme)
        )
    }

    /// After the player closes: the page shows where viewing got to. When
    /// later episodes played on their own, an episode's page becomes the
    /// last one, and a show's page turns to its season; otherwise the page
    /// just picks up the new watched state.
    private func followPlayback(to reached: BaseItem?) async {
        guard let client = session.client else { return }
        if let reached, reached.id != detail.id, reached.seriesId != nil, reached.seriesId == (detail.kind == .series ? detail.id : detail.seriesId) {
            switch detail.kind {
            case .episode:
                await model.load(reached, client: client)
                await model.updateWatchThemes(client: client, isAnime: isAnimeShow)
                return
            case .series, .season:
                if let seasonId = reached.seasonId, seasonId != model.selectedSeasonId, detail.kind == .series {
                    await model.selectSeason(seasonId, client: client)
                }
            default:
                break
            }
        }
        await model.refresh(client: client)
    }

    private func playTitle(resumable: Bool) -> String {
        switch detail.kind {
        case .series: return model.nextEpisode == nil ? "Play" : (resumable ? "Resume" : "Play Next")
        default: return resumable ? "Resume" : "Play"
        }
    }

    private func play(fromBeginning: Bool) {
        if preferDiscMenu, model.discMenu != nil, !fromBeginning {
            showDiscMenu = true
            return
        }
        guard let request = model.playRequest(fromBeginning: fromBeginning) else {
            message = "There is nothing to play yet."
            return
        }
        playback = request
    }

    // MARK: Episodes

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(model.seasons) { season in
                            Button {
                                Task { if let client = session.client { await model.selectSeason(season.id, client: client) } }
                            } label: {
                                Text(season.displayTitle)
                                    .font(.callout.weight(.semibold))
                                    .padding(.horizontal, 6)
                            }
                            .chipStyle(selected: model.selectedSeasonId == season.id)
                            .keyboardTarget {
                                Task { if let client = session.client { await model.selectSeason(season.id, client: client) } }
                            }
                        }
                    }
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.vertical, 16)
                }
                .scrollClipDisabled()
                .tvFocusSection()
            }
            Shelf(title: "Episodes", items: model.episodes) { episode in
                LandscapeLockup(item: episode, showSeriesTitle: false)
            }
        }
    }
}

// MARK: - Pieces

/// An episode's page: the rest of its season in a row (not this episode),
/// scrolled so the one after it sits centered under the Play button, earlier
/// ones off to its left and later ones to its right. Pressing down from Play
/// lands on it.
private struct EpisodeStrip: View {
    let season: [BaseItem]
    let currentId: String
    /// The Play button's middle, across the screen.
    let centerX: CGFloat?

    /// The scroll view's left edge across the screen, and its width.
    @State private var frame: CGRect = .zero
    /// The episode the row was last lined up for.
    @State private var linedUpFor: String?
    /// This row's own scroll position. Scrolling to a card with a scroll
    /// reader also moves the views around the row when the row itself
    /// can't scroll far enough (the next episode first in the row), and that
    /// shifted the whole page sideways, leaving a bar down the left.
    @State private var position = ScrollPosition()

    private var episodes: [BaseItem] { season.filter { $0.id != currentId } }

    /// The card under Play: the next episode, or the one before on the
    /// season's last.
    private var targetId: String? {
        guard let index = season.firstIndex(where: { $0.id == currentId }) else { return nil }
        if index + 1 < season.count { return season[index + 1].id }
        return index > 0 ? season[index - 1].id : nil
    }

    var body: some View {
        if !episodes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Episodes")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, Lockup.screenPadding)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Lockup.shelfSpacing) {
                        ForEach(episodes) { episode in
                            LandscapeLockup(item: episode, showSeriesTitle: false)
                                .id(episode.id)
                        }
                    }
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.vertical, Lockup.shelfVerticalPadding)
                }
                .scrollPosition($position)
                .scrollClipDisabled()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                .onAppear { lineUp(animated: false) }
                .onChange(of: frame.width) { _, _ in lineUp(animated: false) }
                .onChange(of: centerX) { _, _ in lineUp(animated: false) }
                .onChange(of: episodes.map(\.id)) { _, _ in lineUp(animated: false) }
                .onChange(of: currentId) { _, _ in lineUp(animated: true) }
            }
            .tvFocusSection()
        }
    }

    /// Scrolls this row (and only this row) so the next episode's card sits
    /// centered under the Play button, as near as the row can scroll: the
    /// card's place in the row, less where it should appear in the view.
    private func lineUp(animated: Bool) {
        guard let targetId, let centerX, frame.width > Lockup.landscapeWidth, linedUpFor != currentId,
              let index = episodes.firstIndex(where: { $0.id == targetId }) else { return }
        let card = Lockup.landscapeWidth
        let cardStart = Lockup.screenPadding + CGFloat(index) * (card + Lockup.shelfSpacing)
        let wanted = centerX - frame.minX - card / 2
        let offset = max(cardStart - wanted, 0)
        linedUpFor = currentId
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) { position.scrollTo(x: offset) }
        } else {
            position.scrollTo(x: offset)
        }
    }
}

private struct Backdrop: View {
    let url: URL?
    /// A looping theme video shown over the still once it is playing.
    var video: DiscTrailerPlayer?
    /// The darkening behind the page's text; off while an opening is watched.
    var showsShade = true
    /// An opening is being watched: the whole picture shows, letterboxed on
    /// black, rather than filling the screen and losing its sides.
    var watching = false

    var body: some View {
        ZStack {
            RemoteImage(url: url) { Color(white: 0.08) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .extendsUnderSidebar()
                .opacity(watching && video != nil ? 0 : 1)
            if watching, video != nil {
                Color.black
            }
            if let video {
                DiscTrailerLayer(player: video.player, fits: watching)
                    .opacity(video.isPlaying ? 1 : 0)
                    .animation(.easeIn(duration: 0.8), value: video.isPlaying)
            }
            Group {
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.55), .black.opacity(0.97)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .leading, endPoint: .center)
            }
            .opacity(showsShade ? 1 : 0)
        }
        .ignoresSafeArea()
    }
}

/// A special feature: plays immediately when selected.
struct ExtraLockup: View {
    let item: BaseItem
    var play: () -> Void

    @Environment(AppSession.self) private var session
    /// The section's first card, for focus after a tab is picked.
    @Environment(\.itemLead) private var itemLead

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                ZStack {
                    RemoteImage(url: session.client?.landscapeURL(for: item, width: 800), systemImage: "sparkles.tv")
                        .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 6)
                }
                .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
            }
            .sectionLead(itemLead)
            .cardButtonStyle()
            .keyboardTarget(action: play)
            .accessibilityLabel("Play \(item.displayTitle)")

            Text(item.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: Lockup.landscapeWidth, alignment: .leading)
            if let runtime = item.runtimeText {
                Text(runtime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InformationSection: View {
    let item: BaseItem

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        if !item.directors.isEmpty { rows.append(("Director", item.directors.joined(separator: ", "))) }
        if !item.writers.isEmpty { rows.append(("Writers", item.writers.prefix(4).joined(separator: ", "))) }
        if let studios = item.studios, !studios.isEmpty { rows.append(("Studio", studios.compactMap(\.name).prefix(3).joined(separator: ", "))) }
        if let genres = item.genres, !genres.isEmpty { rows.append(("Genres", genres.joined(separator: ", "))) }
        if let rating = item.officialRating { rows.append(("Rated", rating)) }
        if let date = item.premiereDate, date.count >= 10 { rows.append(("Released", String(date.prefix(10)))) }
        return rows
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Information")
                    .font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 24) {
                    ForEach(rows, id: \.0) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.0)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(row.1)
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }
}
