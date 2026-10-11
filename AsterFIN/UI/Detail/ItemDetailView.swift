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
    private(set) var extras: [BaseItem] = []
    private(set) var cast: [PersonInfo] = []
    private(set) var similar: [BaseItem] = []
    private(set) var nextEpisode: BaseItem?
    private(set) var discMenu: DiscMenuDocument?
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

    func updateWatchThemes(client: JellyfinClient, isAnime: Bool) async {
        // An episode asks the plugin once for both.
        let episodeThemes = item?.kind == .episode ? await client.opEdThemes(for: item?.id ?? "") ?? [] : []
        watchOpening = await watchTheme(opening: true, episodeThemes: episodeThemes, client: client, isAnime: isAnime)
        watchEnding = await watchTheme(opening: false, episodeThemes: episodeThemes, client: client, isAnime: isAnime)
    }

    /// Series: the plugin's theme for the selected season, else that
    /// season's chapter clip, else the show's first. Episode: the plugin's
    /// theme that plays in it (then its season's, then a show-wide one),
    /// else the episode's own chapter when the show is anime.
    private func watchTheme(opening: Bool, episodeThemes: [OpEdTheme], client: JellyfinClient, isAnime: Bool) async -> OpeningEnding? {
        guard let item else { return nil }
        let kind: ThemeClip.Kind = opening ? .opening : .ending
        switch item.kind {
        case .series:
            let themes = openingsEndings.compactMap { if case .theme(let theme) = $0 { theme } else { nil } }
            let clips = openingsEndings.compactMap { if case .chapter(let clip) = $0 { clip } else { nil } }.filter { $0.kind == kind }
            if let seasonId = selectedSeasonId {
                if !themes.isEmpty, let theme = await pluginTheme(forSeason: seasonId, opening: opening, client: client, allowFlagged: true) {
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

    /// The plugin's themes when it has any that play (or soon will) for the
    /// show, so chapters needn't be read; otherwise clips from chapters.
    static func openingsEndings(for series: BaseItem, client: JellyfinClient) async -> [OpeningEnding] {
        let themes = (await client.opEdThemes(for: series.id) ?? []).filter { $0.playablePath != nil || $0.isPreparing }
        if !themes.isEmpty { return themes.map(OpeningEnding.theme) }
        let episodes = (try? await client.episodesWithChapters(seriesId: series.id)) ?? []
        return OpeningsEndings.find(in: episodes).map(OpeningEnding.chapter)
    }
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func load(_ summary: BaseItem, client: JellyfinClient) async {
        isLoading = item == nil
        errorMessage = nil
        do {
            let full = try await client.item(summary.id)
            item = full
            cast = full.cast
            isLoading = false

            async let similarItems = client.similar(to: full.id, limit: 20)
            async let menu = client.discMenu(for: full.id)
            async let themes: [OpeningEnding] = full.kind == .series && full.isAnime
                ? Self.openingsEndings(for: full, client: client)
                : []

            switch full.kind {
            case .series:
                let loadedSeasons = try await client.seasons(seriesId: full.id)
                seasons = loadedSeasons
                nextEpisode = try? await client.nextUp(limit: 1, seriesId: full.id).first
                let preferred = nextEpisode?.seasonId ?? loadedSeasons.first { ($0.indexNumber ?? 0) > 0 }?.id ?? loadedSeasons.first?.id
                if let preferred {
                    await selectSeason(preferred, client: client)
                }
            case .season:
                if let seriesId = full.seriesId {
                    seasons = (try? await client.seasons(seriesId: seriesId)) ?? []
                    await selectSeason(full.id, client: client)
                }
            default:
                break
            }

            if full.kind == .movie || full.kind == .series || full.kind == .season {
                extras = (try? await client.specialFeatures(of: full.id)) ?? []
            }
            similar = (try? await similarItems) ?? []
            if full.kind == .movie || full.kind == .series || full.kind == .season {
                discMenu = try? await menu
            }
            openingsEndings = await themes
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func refresh(client: JellyfinClient) async {
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
        discMenu = (try? await client.discMenu(for: current.id)) ?? discMenu
    }

    func selectSeason(_ seasonId: String, client: JellyfinClient) async {
        guard let item, let seriesId = item.kind == .series ? item.id : item.seriesId else { return }
        selectedSeasonId = seasonId
        episodes = (try? await client.episodes(seriesId: seriesId, seasonId: seasonId)) ?? []
    }

    func toggleFavorite(client: JellyfinClient) async {
        guard var current = item else { return }
        let newValue = !(current.userData?.isFavorite ?? false)
        current.userData?.isFavorite = newValue
        item = current
        try? await client.setFavorite(current.id, newValue)
    }

    func togglePlayed(client: JellyfinClient) async {
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
    @AppStorage(AppSettings.preferDiscMenuKey) private var preferDiscMenu = false
    @AppStorage(AppSettings.themeMusicKey) private var themeMusic = false
    @AppStorage(AppSettings.themeVideosKey) private var themeVideos = false
    @AppStorage(AppSettings.openingSoundKey) private var openingSound = false
    @State private var model = DetailModel()
    @State private var playback: PlaybackRequest?
    /// An OP/ED plugin theme playing, which isn't a Jellyfin item.
    @State private var urlPlayback: URLPlayback?
    /// A spoiler or NSFW theme waiting for the viewer's go-ahead.
    @State private var confirmTheme: OpEdTheme?
    @State private var showDiscMenu = false
    @State private var message: String?
    @State private var notice: String?
    @State private var showPlaylistPicker = false
    @State private var playlistTargets: [String] = []
    @State private var confirmDeleteRecording = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedAction: String?
    @FocusState private var actionGuardFocused: Bool
    /// Watch OP with the opening already behind the page: everything else
    /// fades away and it plays with full sound, with its card.
    @State private var watchingOpening = false
    @State private var watchingInfo: ThemeInfo?
    @FocusState private var watchingFocused: Bool

    private var detail: BaseItem { model.item ?? item }

    /// The theme video only shows when it belongs to this title (or its series).
    private var themeVideo: DiscTrailerPlayer? {
        session.theme.key == (item.seriesId ?? item.id) ? session.theme.videoPlayer : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Backdrop(url: session.client?.backdropURL(for: detail, width: 1920), video: themeVideo, showsShade: !watchingOpening)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    header
                        .frame(maxWidth: .infinity, minHeight: 780, alignment: .bottomLeading)

                    if detail.kind == .series || detail.kind == .season {
                        episodesSection
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
                                playback = PlaybackRequest(clipOf: clip.episode.id, fromTicks: clip.startTicks, toTicks: clip.endTicks, info: info(for: clip))
                            }
                        }
                    }

                    Shelf(title: "Extras", items: model.extras) { extra in
                        ExtraLockup(item: extra) {
                            playback = PlaybackRequest(itemId: extra.id)
                        }
                    }

                    Shelf(title: "Cast & Crew", items: model.cast, spacing: 28) { person in
                        PersonLockup(person: person)
                    }

                    Shelf(title: "Related", items: model.similar) { related in
                        LandscapeLockup(item: related)
                    }

                    InformationSection(item: detail)
                        .padding(.horizontal, 80)
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
            .opacity(watchingOpening ? 0 : 1)
            .disabled(watchingOpening)

            if watchingOpening {
                // Holds focus while the page is hidden, so Back returns to it
                // instead of leaving the page.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focused($watchingFocused)
                    .onExitCommand { stopWatchingOpening() }
                    .accessibilityLabel("Opening")
                if let watchingInfo {
                    ThemeInfoOverlay(info: watchingInfo)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
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
            session.theme.show(item: item, client: client, music: themeMusic, video: themeVideos, musicPlaying: session.music.isPlaying)
            await model.load(item, client: client)
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
        .onDisappear {
            if watchingOpening { stopWatchingOpening() }
            session.theme.hide()
        }
        .onChange(of: playback != nil || urlPlayback != nil || showDiscMenu) { _, covered in
            // Quiet the theme while a video or disc menu is on screen.
            if covered {
                session.theme.suspend()
            } else {
                session.theme.resume()
            }
        }
        .fullScreenCover(item: $playback, onDismiss: {
            Task { if let client = session.client { await model.refresh(client: client) } }
        }) { request in
            PlayerView(request: request) { playback = nil }
        }
        .fullScreenCover(item: $urlPlayback) { theme in
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
        .fullScreenCover(isPresented: $showDiscMenu, onDismiss: {
            Task { if let client = session.client { await model.refresh(client: client) } }
        }) {
            if let document = model.discMenu {
                DiscMenuView(document: document, itemId: detail.id)
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
        .fullScreenCover(isPresented: $showPlaylistPicker) {
            PlaylistPickerView(itemIds: playlistTargets, mediaType: "Video") { name in
                notice = "Added to \(name)."
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            if detail.kind == .episode, let series = detail.seriesName {
                Text(series)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if detail.kind == .season, let series = detail.seriesName {
                Text(series)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let logo = session.client?.logoURL(for: detail), detail.kind != .episode, detail.kind != .season {
                RemoteImage(url: logo, contentMode: .fit) {
                    Text(detail.displayTitle).font(.system(size: 72, weight: .bold))
                }
                .frame(maxWidth: 600, maxHeight: 200, alignment: .leading)
            } else {
                Text(detail.displayTitle)
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(2)
            }

            if detail.kind == .episode, let code = detail.episodeCode {
                Text(code).font(.headline).foregroundStyle(.secondary)
            }

            MetadataLine(item: detail)

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

            actionRow
                .padding(.top, 8)
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 20)
        .focusSection()
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

    private var actionRow: some View {
        HStack(spacing: 20) {
            let resumable = detail.kind == .series ? (model.nextEpisode?.canResume ?? false) : detail.canResume
            ActionButton(title: playTitle(resumable: resumable), systemImage: "play.fill", prominent: true, focus: $focusedAction, focusID: "play") {
                play(fromBeginning: false)
            }
            if resumable {
                ActionButton(title: "From Beginning", systemImage: "arrow.counterclockwise", focus: $focusedAction, focusID: "beginning") {
                    play(fromBeginning: true)
                }
            }
            if model.discMenu != nil {
                ActionButton(title: "Disc Menu", systemImage: "opticaldisc", focus: $focusedAction, focusID: "disc") {
                    showDiscMenu = true
                }
            }
            IconButton(systemImage: detail.userData?.isFavorite == true ? "heart.fill" : "heart", accessibilityLabel: "Favorite", focus: $focusedAction, focusID: "favorite") {
                Task { if let client = session.client { await model.toggleFavorite(client: client) } }
            }
            if showsWatchedButton {
                IconButton(systemImage: detail.userData?.played == true ? "checkmark.circle.fill" : "checkmark.circle", accessibilityLabel: "Watched", focus: $focusedAction, focusID: "watched") {
                    Task { if let client = session.client { await model.togglePlayed(client: client) } }
                }
            }
            if showsMoreMenu {
                moreMenu
            }
            // Last in the row, so a press to the right ends here.
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
            if let remaining = detail.remainingText, detail.kind != .series {
                Text(remaining)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // With nothing directly to the right of the last button, the focus
            // engine widens its search and can land on a lockup in the shelf
            // below, which scrolls the page. This sliver sits squarely to the
            // right, so it catches that press and hands focus straight back.
            Color.clear
                .frame(width: 2, height: 44)
                .focusable()
                .focused($actionGuardFocused)
                .accessibilityHidden(true)
        }
        .onChange(of: actionGuardFocused) { _, focused in
            guard focused else { return }
            focusedAction = trailingActionID
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(white: 0.3))
        .foregroundStyle(.white)
        .accessibilityLabel("More")
        .focused($focusedAction, equals: "more")
    }



    /// Series and seasons add their episodes; everything else adds itself.
    private func addToPlaylist() {
        guard let client = session.client else { return }
        Task {
            switch detail.kind {
            case .series:
                playlistTargets = ((try? await client.episodes(seriesId: detail.id, seasonId: nil)) ?? []).map(\.id)
            case .season:
                playlistTargets = model.episodes.map(\.id)
            default:
                playlistTargets = [detail.id]
            }
            guard !playlistTargets.isEmpty else {
                notice = "There is nothing to add yet."
                return
            }
            showPlaylistPicker = true
        }
    }

    private func deleteRecording() {
        guard let client = session.client else { return }
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
    private func showOpening(client: JellyfinClient) async {
        guard themeVideos, detail.kind == .series, !model.openingsEndings.isEmpty else { return }
        let themes = model.openingsEndings.compactMap { if case .theme(let theme) = $0 { theme } else { nil } }
        let clips = model.openingsEndings.compactMap { if case .chapter(let clip) = $0 { clip } else { nil } }.filter { $0.kind == .opening }

        if let seasonId = model.selectedSeasonId {
            if !themes.isEmpty, let theme = await model.pluginTheme(forSeason: seasonId, opening: true, client: client), show(theme, client: client) {
                return
            }
            let number = model.seasons.first { $0.id == seasonId }?.indexNumber
            if let clip = clips.first(where: { $0.season == number }) {
                session.theme.showOpeningIfNoVideo(clip, for: item, client: client, sound: openingSound)
                return
            }
            // Nothing for this season: keep whatever opening is already playing.
            if session.theme.isShowingOpening { return }
        }
        if let theme = DetailModel.preferredTheme(in: themes, opening: true), show(theme, client: client) {
            return
        }
        if let clip = clips.first {
            session.theme.showOpeningIfNoVideo(clip, for: item, client: client, sound: openingSound)
        }
    }

    /// Puts a plugin opening behind the page: its video, or with only audio,
    /// its song as the theme music when openings have sound. Returns whether
    /// it could.
    private func show(_ theme: OpEdTheme, client: JellyfinClient) -> Bool {
        if let path = theme.videoMp4Url {
            session.theme.showOpeningIfNoVideo(theme, url: client.opEdMediaURL(path), for: item, sound: openingSound)
            return true
        }
        if openingSound, let path = theme.audioM4aUrl {
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
        detail.kind == .series ? detail.isAnime : session.animeItemIds.contains(detail.seriesId ?? "")
    }

    /// Plays an OP/ED plugin theme: its MP4, or audio tvOS can play.
    private func play(_ theme: OpEdTheme) {
        guard let path = theme.playablePath, let client = session.client else { return }
        urlPlayback = URLPlayback(
            url: client.opEdMediaURL(path),
            title: theme.songLine ?? theme.code,
            subtitle: [detail.displayTitle, theme.code].joined(separator: " · "),
            artwork: client.landscapeURL(for: detail, width: 1920),
            info: info(for: theme)
        )
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
                            .buttonStyle(.bordered)
                            .tint(model.selectedSeasonId == season.id ? .white : Color(white: 0.3))
                            .foregroundStyle(model.selectedSeasonId == season.id ? .black : .white)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 16)
                }
                .scrollClipDisabled()
                .focusSection()
            }
            Shelf(title: "Episodes", items: model.episodes) { episode in
                LandscapeLockup(item: episode, showSeriesTitle: false)
            }
        }
    }
}

// MARK: - Pieces

private struct Backdrop: View {
    let url: URL?
    /// A looping theme video shown over the still once it is playing.
    var video: DiscTrailerPlayer?
    /// The darkening behind the page's text; off while an opening is watched.
    var showsShade = true

    var body: some View {
        ZStack {
            RemoteImage(url: url) { Color(white: 0.08) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if let video {
                DiscTrailerLayer(player: video.player)
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
            .buttonStyle(.card)
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
