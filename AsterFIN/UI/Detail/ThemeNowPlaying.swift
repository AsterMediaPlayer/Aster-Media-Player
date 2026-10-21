//
//  ThemeNowPlaying.swift
//  AsterFIN
//
//  The Music tab's Now Playing panel: an opening or ending plays right
//  there, its video (or, for a song alone, the show's picture) above what
//  it is and the controls, then the next one, so a show's songs play
//  through like a playlist. It plays both kinds: the OP/ED plugin's files,
//  and clips found in episodes' chapters, which are that stretch of the
//  episode's stream.
//

import AVFoundation
import SwiftUI

extension OpeningEnding {
    var isOpening: Bool {
        switch self {
        case .theme(let theme): theme.isOpening
        case .chapter(let clip): clip.kind == .opening
        }
    }

    /// Plays without asking: not marked as a spoiler or NSFW, and playable
    /// (a chapter clip always is).
    var playsUnasked: Bool {
        switch self {
        case .theme(let theme): theme.playablePath != nil && !theme.spoiler && !theme.nsfw
        case .chapter: true
        }
    }

    /// Asks first: marked as a spoiler or NSFW.
    var isFlagged: Bool {
        if case .theme(let theme) = self { return theme.spoiler || theme.nsfw }
        return false
    }
}

/// The openings and endings the Music tab plays, one after another, and
/// where it's got to.
@MainActor
@Observable
final class ThemeDeck {
    private(set) var queue: [OpeningEnding] = []
    private(set) var current: OpeningEnding?
    private(set) var isPlaying = false
    /// Into the current one, and its length, in seconds: a chapter clip's
    /// count from the clip's start, not the episode's.
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    /// A chapter clip's stream is being asked for.
    private(set) var isLoading = false
    let player = AVPlayer()
    /// The show's page it was started from (to go back to it), and its
    /// picture, for a song with no video.
    var showItem: BaseItem?
    var artwork: URL?
    /// Called as playing starts (true) and stops (false): the session quiets
    /// title-page theme music meanwhile.
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endWatcher: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Where the current one starts on its item's timeline: a chapter
    /// clip's start in the episode, else zero.
    @ObservationIgnored private var offset: Double = 0
    /// A chapter clip's server transcode, ended once it's done with.
    @ObservationIgnored private var transcode: (JellyfinClient, String)?

    /// Whether something is loaded, playing or paused.
    var isActive: Bool { current != nil }

    /// Whether there's a picture: an MP4 from the plugin, or an episode.
    var hasVideo: Bool {
        switch current {
        case .theme(let theme): theme.videoMp4Url != nil
        case .chapter: true
        case nil: false
        }
    }

    /// Plays `entry`, then the rest of `queue` after it.
    func play(_ entry: OpeningEnding, in queue: [OpeningEnding], client: JellyfinClient) {
        let wasActive = current != nil
        defer { if !wasActive { onActiveChange?(true) } }
        loadTask?.cancel()
        endTranscode()
        self.client = client
        self.queue = queue
        current = entry
        elapsed = 0
        isPlaying = true
        switch entry {
        case .theme(let theme):
            guard let path = theme.playablePath else { return }
            offset = 0
            duration = 0
            isLoading = false
            start(AVPlayerItem(url: client.opEdMediaURL(path)))
        case .chapter(let clip):
            offset = Double(clip.startTicks) / 10_000_000
            duration = Double(clip.endTicks - clip.startTicks) / 10_000_000
            isLoading = true
            player.replaceCurrentItem(with: nil)
            loadTask = Task { [weak self] in
                let stream = await ThemePlayer.stream(for: clip, client: client)
                guard let self, !Task.isCancelled, self.current?.id == entry.id else {
                    if let session = stream?.playSessionId { await client.stopTranscoding(playSessionId: session) }
                    return
                }
                self.isLoading = false
                guard let stream else {
                    self.next()
                    return
                }
                self.transcode = stream.playSessionId.map { (client, $0) }
                let item = AVPlayerItem(url: stream.url)
                // Just the clip: the episode's stream, from the clip's start
                // to its end, where it counts as played through.
                item.forwardPlaybackEndTime = CMTime(value: clip.endTicks, timescale: 10_000_000)
                self.start(item, at: CMTime(value: clip.startTicks, timescale: 10_000_000))
            }
        }
    }

    /// After the player was driven by something else (the full-screen
    /// player's own controls, or the remote there): what it's really doing.
    func syncPlaying() {
        guard current != nil else { return }
        isPlaying = player.timeControlStatus != .paused
    }

    /// The song card for what's playing, and for a chapter clip the stretch
    /// of its episode it covers (in the player's own time).
    var songCard: (info: ThemeInfo, range: ClosedRange<Double>?)? {
        let series = showItem?.seriesName ?? showItem?.displayTitle ?? ""
        switch current {
        case .theme(let theme):
            return (ThemeInfo(theme: theme, series: series, seasonName: nil), nil)
        case .chapter(let clip):
            let range = Double(clip.startTicks) / 10_000_000 ... Double(clip.endTicks) / 10_000_000
            return (ThemeInfo(clip: clip, series: series), range)
        case nil:
            return nil
        }
    }

    func togglePlaying() {
        guard current != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    /// The next one that plays without asking (not a spoiler or NSFW).
    func next() {
        guard let client, let upcoming = neighbour(after: true) else {
            stop()
            return
        }
        play(upcoming, in: queue, client: client)
    }

    /// Back to the start, or a few seconds in, back to the one before.
    func previous() {
        if elapsed > 3 || neighbour(after: false) == nil {
            player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            elapsed = 0
            return
        }
        if let client, let earlier = neighbour(after: false) {
            play(earlier, in: queue, client: client)
        }
    }

    func stop() {
        let wasActive = current != nil
        defer { if wasActive { onActiveChange?(false) } }
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        endWatcher?.cancel()
        endWatcher = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        endTranscode()
        current = nil
        isPlaying = false
        isLoading = false
        elapsed = 0
        duration = 0
        offset = 0
    }

    private func start(_ item: AVPlayerItem, at time: CMTime? = nil) {
        player.replaceCurrentItem(with: item)
        observe()
        if let time {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if isPlaying { player.play() }
    }

    private func endTranscode() {
        if let (client, session) = transcode {
            Task { await client.stopTranscoding(playSessionId: session) }
        }
        transcode = nil
    }

    private func neighbour(after: Bool) -> OpeningEnding? {
        guard let current, let index = queue.firstIndex(where: { $0.id == current.id }) else { return nil }
        let candidates = after ? Array(queue[(index + 1)...]) : Array(queue[..<index].reversed())
        return candidates.first { $0.playsUnasked }
    }

    private func observe() {
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let seconds = time.seconds.isFinite ? time.seconds - self.offset : 0
                    self.elapsed = max(seconds, 0)
                    // A plugin file's length comes from the file; a clip's
                    // is known from its chapters.
                    if case .theme = self.current, let length = self.player.currentItem?.duration.seconds, length.isFinite, length > 0 {
                        self.duration = length
                    }
                }
            }
        }
        endWatcher?.cancel()
        let item = player.currentItem
        endWatcher = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                self?.next()
                return
            }
        }
    }
}

/// The panel: the picture, Now Playing, the progress and controls, and what
/// it is. Nothing while nothing plays. When the screen is too short for all
/// of it, what it is gives way first.
struct ThemeNowPlayingPanel: View {
    let deck: ThemeDeck
    var artwork: URL?
    var seasonName: (OpEdTheme) -> String? = { _ in nil }
    /// Back to the show's page (the slim panel, away from it).
    var openShow: (() -> Void)?
    /// The slim panel that floats while browsing: no details, smaller.
    var compact = false

    @Environment(AppSession.self) private var session
    /// Holding Play/Pause on the remote brings focus here.
    @FocusState private var playFocused: Bool

    private enum Metrics {
        #if os(tvOS)
        static let spacing: CGFloat = 22
        static let padding: CGFloat = 28
        static let corner: CGFloat = 28
        static let titleFont: Font = .title3.weight(.bold)
        static let controlSize: CGFloat = 34
        static let compactControlSize: CGFloat = 32
        #else
        static let spacing: CGFloat = 12
        static let padding: CGFloat = 16
        static let corner: CGFloat = 18
        static let titleFont: Font = .headline
        static let controlSize: CGFloat = 20
        static let compactControlSize: CGFloat = 18
        #endif
    }

    private var spacing: CGFloat { compact ? Metrics.spacing * 0.7 : Metrics.spacing }
    private var controlSize: CGFloat { compact ? Metrics.compactControlSize : Metrics.controlSize }

    var body: some View {
        if let entry = deck.current {
            Group {
                if compact {
                    panel(entry, showsDetails: false)
                } else {
                    ViewThatFits(in: .vertical) {
                        panel(entry, showsDetails: true)
                        panel(entry, showsDetails: false)
                    }
                }
            }
            // Back goes to the card that started it, while its page is up;
            // otherwise Back does what it always does.
            .tvExitCommand(perform: session.themeReturnCard == nil ? nil : {
                #if DEBUG
                print("DEBUG focus: Back in the panel, returning to \(session.themeReturnCard ?? "-")")
                #endif
                session.themeReturnFocusRequest += 1
            })
        }
    }

    private func panel(_ entry: OpeningEnding, showsDetails: Bool) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            picture
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.corner / 1.6))
            playing(entry)
            if showsDetails {
                details(entry)
            }
            #if os(tvOS)
            if compact {
                // How to get here from anywhere (see PlayPauseHoldDetector).
                Text("Hold \(Image(systemName: "playpause.fill")) to focus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("Hold Play/Pause on the remote to focus the player")
            }
            #endif
        }
        .padding(compact ? Metrics.padding * 0.7 : Metrics.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .tvFocusSection()
    }

    @ViewBuilder
    private var picture: some View {
        if deck.hasVideo {
            VideoLayerView(player: deck.player)
                .background(.black)
                .overlay {
                    if deck.isLoading { ProgressView() }
                }
                .accessibilityHidden(true)
        } else {
            RemoteImage(url: artwork ?? deck.artwork, systemImage: "music.note.tv")
                .overlay {
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .padding()
                        .background(.black.opacity(0.5), in: Circle())
                }
        }
    }

    /// The big line and the one under it: the song and artist, or for a
    /// chapter clip, which opening it is and where it's from.
    private func titles(_ entry: OpeningEnding) -> (title: String, subtitle: String?) {
        switch entry {
        case .theme(let theme):
            ((theme.songTitle ?? theme.code) + (theme.playedCut.label.map { " (\($0))" } ?? ""), theme.artists.isEmpty ? nil : theme.artists.joined(separator: ", "))
        case .chapter(let clip):
            (clip.title, clip.episode.episodeCode.map { "From \($0)" })
        }
    }

    @ViewBuilder
    private func playing(_ entry: OpeningEnding) -> some View {
        let lines = titles(entry)
        VStack(alignment: .leading, spacing: 4) {
            Label("Now Playing", systemImage: "music.note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(lines.title)
                .font(compact ? .headline : Metrics.titleFont)
                .lineLimit(2)
            if let subtitle = lines.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .lineLimit(1)
            }
        }

        VStack(spacing: 4) {
            ProgressView(value: deck.duration > 0 ? min(deck.elapsed / deck.duration, 1) : 0)
                .tint(.accentColor)
            HStack {
                Text(Self.time(deck.elapsed))
                Spacer()
                Text(deck.duration > 0 ? Self.time(deck.duration) : "–:––")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.time(deck.elapsed)) of \(deck.duration > 0 ? Self.time(deck.duration) : "unknown")")

        HStack(spacing: spacing) {
            control("backward.fill", label: "Previous") { deck.previous() }
            control(deck.isPlaying ? "pause.fill" : "play.fill", label: deck.isPlaying ? "Pause" : "Play", prominent: true) { deck.togglePlaying() }
                .focused($playFocused)
                #if DEBUG
                .onChange(of: playFocused) { _, focused in
                    print("DEBUG focus: panel's Play button \(focused ? "has" : "lost") focus\(compact ? " (slim panel)" : "")")
                }
                #endif
                .task(id: session.themePanelFocusRequest) {
                    // Asked for (a card played, or Play/Pause held): once the
                    // press and the panel's own arrival have settled, as the
                    // focus engine ignores a move it can't make yet.
                    guard session.themePanelFocusPending else { return }
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, session.themePanelFocusPending else { return }
                    playFocused = true
                    #if DEBUG
                    print("DEBUG focus: panel's Play button asked for focus (request \(session.themePanelFocusRequest))")
                    #endif
                }
            control("forward.fill", label: "Next") { deck.next() }
            control("stop.fill", label: "Stop") {
                // Like Back: focus goes to the card that started it, rather
                // than wherever the system puts it as the panel goes.
                if session.themeReturnCard != nil { session.themeReturnFocusRequest += 1 }
                deck.stop()
            }
            Spacer(minLength: 0)
            // The same player, bigger: it carries on rather than starting over.
            control("arrow.up.left.and.arrow.down.right", label: "Full Screen") { session.themeFullScreen = true }
            if let openShow {
                control("chevron.forward", label: "Go to the Show", action: openShow)
            }
        }
    }

    private func control(_ systemImage: String, label: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: controlSize * 0.6, weight: .semibold))
                .frame(width: controlSize, height: controlSize)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(prominent ? .accentColor : nil)
        .keyboardTarget(action: action)
        .accessibilityLabel(label)
    }

    /// What it is, in rows: the mockup's Theme Info, from what's known.
    private func details(_ entry: OpeningEnding) -> some View {
        let rows: [(String, String)]
        switch entry {
        case .theme(let theme):
            rows = [
                ("Type", "\(theme.isOpening ? "Opening" : "Ending") \(theme.sequence)" + (theme.version > 1 ? ", version \(theme.version)" : "")),
                theme.variant.flatMap { $0.isEmpty ? nil : ("Variant", $0) },
                seasonName(theme).map { ("Season", $0) },
                theme.episodes.map { ("Episodes", $0) },
                theme.artists.isEmpty ? nil : (theme.artists.count == 1 ? "Artist" : "Artists", theme.artists.joined(separator: ", ")),
                ("Plays", theme.isAudioOnly ? "Song only" : "Music video")
            ].compactMap { $0 }
        case .chapter(let clip):
            rows = [
                ("Type", clip.number > 1 ? "\(clip.kind.rawValue) \(clip.number)" : clip.kind.rawValue),
                ("Season", "Season \(clip.season)"),
                ("From", [clip.episode.episodeCode, clip.episode.name].compactMap { $0 }.joined(separator: " · ")),
                ("Plays", "From the episode")
            ]
        }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).lineLimit(2)
                }
            }
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private static func time(_ seconds: Double) -> String {
        let whole = max(Int(seconds.rounded(.down)), 0)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

/// The panel's opening or ending full screen, in the system player: its own
/// player, so it goes on from where it was, and the panel (or the slim one)
/// carries on from there once this closes. Closes by itself when the panel's
/// list runs out.
struct ThemeDeckFullScreen: View {
    let deck: ThemeDeck
    var close: () -> Void

    var body: some View {
        SystemPlayer(player: deck.player)
            .ignoresSafeArea()
            .background(Color.black)
            .overlay {
                if let card = deck.songCard {
                    ThemeInfoOverlay(player: deck.player, range: card.range, info: card.info)
                        .id(deck.current?.id)
                }
            }
            .onChange(of: deck.isActive) { _, active in
                if !active { close() }
            }
            .onDisappear { deck.syncPlaying() }
    }
}

/// The slim Now Playing panel that floats on the right while browsing, once
/// a theme is playing and its show's page (with the full panel) isn't on
/// screen. Go to the Show opens that page again.
struct ThemeMiniPlayer: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openItem) private var openItem

    /// Its width, and the room it leaves on the right for pages that make way.
    static let width: CGFloat = Metrics.width
    static let inset: CGFloat = Metrics.width + Metrics.gap

    private enum Metrics {
        #if os(tvOS)
        static let width: CGFloat = 460
        static let gap: CGFloat = 40
        #else
        static let width: CGFloat = 300
        static let gap: CGFloat = 20
        #endif
    }

    var body: some View {
        let deck = session.themeDeck
        ThemeNowPlayingPanel(
            deck: deck,
            openShow: deck.showItem.map { show in { openItem?(show) } },
            compact: true
        )
        .frame(width: Metrics.width)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
    }
}

extension EnvironmentValues {
    /// Room on the right that pages leave for the floating Now Playing panel,
    /// while it shows.
    @Entry var themeMiniInset: CGFloat = 0
}

/// Lays the slim Now Playing panel over a page, top right, while it shows.
struct ThemeMiniPlayerHost: ViewModifier {
    let shows: Bool
    let openAction: OpenItemAction

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if shows {
                    ThemeMiniPlayer()
                        .environment(\.openItem, openAction)
                        #if os(tvOS)
                        .padding(.top, 20)
                        #else
                        .padding(.top, 12)
                        .padding(.trailing, 16)
                        #endif
                        // A fade, not a slide: moving its glass controls across the screen
                        // has the system re-render the glass every frame off the main
                        // thread, filling the console with setPresentationValue faults.
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.4), value: shows)
    }
}
