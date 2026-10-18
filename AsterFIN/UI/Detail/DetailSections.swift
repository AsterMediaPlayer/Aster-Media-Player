//
//  DetailSections.swift
//  AsterFIN
//
//  A show's page in tabs, under its header: Episodes, Music (an anime's
//  openings and endings), Extras, Related and Details. Only the tabs with
//  something in them show.
//

import AVFoundation
import SwiftUI

/// One tab of a show's page.
enum DetailSection: String, CaseIterable, Identifiable {
    case episodes, music, extras, related, details

    var id: String { rawValue }

    var title: String {
        switch self {
        case .episodes: "Episodes"
        case .music: "Music"
        case .extras: "Extras"
        case .related: "Related"
        case .details: "Details"
        }
    }
}

/// The row of tabs. A phone or tablet gets the system's segmented control;
/// the TV and the Mac get capsule buttons, which focus and the keyboard can
/// reach. On the TV a tab is chosen by pressing it, not by focus landing on
/// it, so pressing up from a card never swaps the page under it.
struct DetailSectionBar: View {
    let sections: [DetailSection]
    @Binding var selection: DetailSection

    var body: some View {
        #if os(iOS)
        Picker("Section", selection: $selection) {
            ForEach(sections) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, Lockup.screenPadding)
        #else
        HStack(spacing: Metrics.spacing) {
            ForEach(sections) { section in
                tab(section)
            }
        }
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .tvFocusSection()
        #endif
    }

    #if !os(iOS)
    private enum Metrics {
        #if os(tvOS)
        static let spacing: CGFloat = 24
        static let verticalPadding: CGFloat = 12
        #else
        static let spacing: CGFloat = 10
        static let verticalPadding: CGFloat = 4
        #endif
    }

    @ViewBuilder
    private func tab(_ section: DetailSection) -> some View {
        let selected = selection == section
        let button = Button {
            selection = section
        } label: {
            Text(section.title)
                .font(.callout.weight(selected ? .bold : .medium))
                .padding(.horizontal, 6)
        }
        .buttonBorderShape(.capsule)
        .keyboardTarget { selection = section }
        .accessibilityAddTraits(selected ? .isSelected : [])
        if selected {
            button.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
        } else {
            button.buttonStyle(.bordered)
        }
    }
    #endif
}

// MARK: - Music

/// An anime's openings and endings, each in its own row: the OP/ED plugin's
/// themes when the server has them, else clips found in the episodes'
/// chapters. The plugin's play in the Now Playing panel beside the rows (on
/// a phone, above them); chapter clips, which are stretches of episodes,
/// play full screen as before.
struct ThemeMusicSection: View {
    let entries: [OpeningEnding]
    let seasons: [BaseItem]
    /// The show's own picture, for a theme before (or without) its frame.
    let fallbackArtwork: URL?
    /// A chapter clip pressed.
    var play: (OpeningEnding) -> Void
    /// The panel's Full Screen.
    var fullScreen: (OpEdTheme) -> Void

    @Environment(AppSession.self) private var session
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var deck = ThemeDeck()
    /// A spoiler or NSFW theme waiting for the go-ahead.
    @State private var confirming: OpEdTheme?
    /// Going full screen: the full-screen player keeps the show's theme
    /// quiet, so the panel stopping mustn't bring it back.
    @State private var handingOff = false
    /// The theme card focus is on (the TV), which the panel previews and
    /// moves beside.
    @State private var focusedTheme: OpEdTheme?
    /// Where each row starts down the section (true: Openings), for the
    /// panel to line up with.
    @State private var rowTops: [Bool: CGFloat] = [:]

    private enum Metrics {
        #if os(tvOS)
        static let panelWidth: CGFloat = 560
        static let gap: CGFloat = 40
        #else
        static let panelWidth: CGFloat = 340
        static let gap: CGFloat = 20
        #endif
    }

    /// The row the panel floats beside: the focused card's, else the one
    /// playing's, else Openings.
    private var panelTop: CGFloat {
        let theme = focusedTheme ?? deck.current
        let opening = theme?.isOpening ?? true
        return rowTops[opening] ?? rowTops[!opening] ?? 0
    }

    /// Room for the panel beside the rows: not on a phone.
    private var isWide: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    /// The plugin's themes, in the order the rows show them.
    private var themes: [OpEdTheme] {
        (sorted(opening: true) + sorted(opening: false)).compactMap { if case .theme(let theme) = $0 { theme } else { nil } }
    }

    var body: some View {
        Group {
            if themes.isEmpty {
                rows
            } else if isWide {
                // The rows leave a lane on the right, and the panel floats
                // in it, gliding up or down to sit beside the row in use.
                ZStack(alignment: .topTrailing) {
                    rows
                        .padding(.trailing, Metrics.panelWidth + Metrics.gap)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    panel
                        .frame(width: Metrics.panelWidth)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                        .padding(.trailing, Lockup.screenPadding)
                        .padding(.top, panelTop)
                        .animation(.smooth(duration: 0.35), value: panelTop)
                }
                .coordinateSpace(.named(Self.space))
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if deck.isActive {
                        panel
                            .padding(.horizontal, Lockup.screenPadding)
                    }
                    rows
                }
            }
        }
        // The show's theme behind the page goes quiet while one plays here.
        .onChange(of: deck.isActive) { _, active in
            if active {
                session.theme.suspend()
            } else if handingOff {
                handingOff = false
            } else {
                session.theme.resume()
            }
        }
        .onDisappear { deck.stop() }
        .alert(confirming?.nsfw == true ? "NSFW" : "Spoilers", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Play") {
                if let theme = confirming { start(theme) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(confirming?.nsfw == true
                 ? "This opening or ending is marked as not safe for work."
                 : "This opening or ending is marked as containing spoilers.")
        }
    }

    private static let space = "music"

    private var rows: some View {
        VStack(alignment: .leading, spacing: 24) {
            row(title: "Openings", subtitle: "The songs that start each episode.", opening: true)
            row(title: "Endings", subtitle: "The songs over the closing credits.", opening: false)
        }
    }

    private var panel: some View {
        ThemeNowPlayingPanel(
            deck: deck,
            focused: focusedTheme,
            artwork: fallbackArtwork,
            seasonName: seasonName,
            playAll: {
                if let first = themes.first(where: { $0.playablePath != nil && !$0.spoiler && !$0.nsfw }) { start(first) }
            },
            fullScreen: { theme in
                handingOff = true
                deck.stop()
                fullScreen(theme)
            }
        )
    }

    /// A theme's card pressed: it plays in the panel, after asking when it's
    /// marked as a spoiler or NSFW.
    private func pressed(_ theme: OpEdTheme) {
        if theme.spoiler || theme.nsfw {
            confirming = theme
        } else {
            start(theme)
        }
    }

    private func start(_ theme: OpEdTheme) {
        guard let client = session.client else { return }
        deck.play(theme, in: themes, client: client)
    }

    @ViewBuilder
    private func row(title: String, subtitle: String, opening: Bool) -> some View {
        let entries = sorted(opening: opening)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: "music.note")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text(entries.count == 1 ? "1 song" : "\(entries.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Lockup.screenPadding)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Lockup.shelfSpacing) {
                    ForEach(entries) { entry in
                        card(entry)
                    }
                }
                .padding(.horizontal, Lockup.screenPadding)
                .padding(.vertical, Lockup.shelfVerticalPadding)
            }
            .scrollClipDisabled()
            .tvFocusSection()
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { rowTops[opening] = $0 }
        }
    }

    @ViewBuilder
    private func card(_ entry: OpeningEnding) -> some View {
        switch entry {
        case .theme(let theme):
            ThemeCard(theme: theme, seasonName: seasonName(theme), fallbackArtwork: fallbackArtwork, isPlaying: deck.current?.id == theme.id,
                      // Kept when focus moves on to the panel, so the panel
                      // doesn't move away from it.
                      focusChanged: { focused in if focused { focusedTheme = theme } }) { pressed(theme) }
        case .chapter(let clip):
            ThemeClipLockup(clip: clip) { play(entry) }
        }
    }

    /// A season's name when the show has more than one, since OP 1 comes
    /// round again each season.
    private func seasonName(_ theme: OpEdTheme) -> String? {
        guard seasons.filter({ ($0.indexNumber ?? 0) > 0 }).count > 1, let id = theme.seasonId else { return nil }
        return seasons.first { $0.id == id }?.displayTitle
    }

    /// Openings (or endings) season by season, in the show's order; themes
    /// for the whole show first.
    private func sorted(opening: Bool) -> [OpeningEnding] {
        let order = Dictionary(seasons.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return entries.filter { entry in
            switch entry {
            case .theme(let theme): theme.isOpening == opening
            case .chapter(let clip): (clip.kind == .opening) == opening
            }
        }.sorted { a, b in
            switch (a, b) {
            case (.theme(let x), .theme(let y)):
                let sx = x.seasonId.flatMap { order[$0] } ?? -1
                let sy = y.seasonId.flatMap { order[$0] } ?? -1
                return (sx, x.sequence, x.version) < (sy, y.sequence, y.version)
            default:
                return false
            }
        }
    }
}

/// An opening or ending from the OP/ED plugin: a frame from its own video
/// (the show's picture until then, or for a song alone), "OP 1" and its
/// length over it, and the song, artist and episodes below.
struct ThemeCard: View {
    let theme: OpEdTheme
    var seasonName: String?
    var fallbackArtwork: URL?
    /// Whether it's the one in the Now Playing panel.
    var isPlaying = false
    /// Focus coming to the card, or leaving it.
    var focusChanged: ((Bool) -> Void)?
    var play: () -> Void

    @Environment(AppSession.self) private var session
    @State private var preview: ThemePreview?
    @FocusState private var focused: Bool

    private var hidden: Bool { theme.spoiler || theme.nsfw }

    /// "OP 1", "ED 2 v2".
    private var badge: String {
        "\(theme.isOpening ? "OP" : "ED") \(theme.sequence)" + (theme.version > 1 ? " v\(theme.version)" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                ZStack {
                    artwork
                        .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
                        .clipped()
                        .blur(radius: hidden ? 24 : 0)
                    if hidden || theme.isPreparing {
                        Label(theme.isPreparing ? "Preparing…" : (theme.nsfw ? "NSFW" : "Spoiler"),
                              systemImage: theme.isPreparing ? "hourglass" : "eye.slash")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                    HStack(spacing: 6) {
                        pill(badge)
                        if isPlaying {
                            pill("Playing", systemImage: "speaker.wave.2.fill")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    HStack(spacing: 6) {
                        if theme.isAudioOnly {
                            pill("Audio only", systemImage: "music.note")
                        }
                        if let seconds = preview?.seconds {
                            pill(Self.time(seconds))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
            }
            .cardButtonStyle()
            .focused($focused)
            .onChange(of: focused) { _, now in focusChanged?(now) }
            .keyboardTarget(action: play)
            .disabled(theme.isPreparing)
            .accessibilityLabel(accessibilityText)

            VStack(alignment: .leading, spacing: 2) {
                Text(theme.songTitle ?? badge)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if !theme.artists.isEmpty {
                    Text(theme.artists.joined(separator: ", "))
                        .font(.caption)
                        .lineLimit(1)
                }
                if let detail = detailLine {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Lockup.landscapeWidth, alignment: .leading)
        }
        .task(id: theme.id) {
            guard let client = session.client else { return }
            preview = await ThemePreviews.shared.preview(for: theme, client: client)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = preview?.image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RemoteImage(url: fallbackArtwork, systemImage: theme.isOpening ? "music.note.tv" : "music.note.list")
        }
    }

    /// "Season 2 · Episodes 1–12".
    private var detailLine: String? {
        let parts = [seasonName, theme.episodes.map { "Episodes \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        [badge, theme.songTitle, theme.artists.isEmpty ? nil : "by " + theme.artists.joined(separator: ", "),
         detailLine, theme.isAudioOnly ? "audio only" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    private func pill(_ text: String, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(12)
    }

    private static func time(_ seconds: Int) -> String {
        "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// What a theme's card shows that the plugin doesn't say: its length, and a
/// frame from its video. (A CGImage is immutable, so it's safe to hand over.)
struct ThemePreview: @unchecked Sendable {
    var seconds: Int?
    var image: CGImage?
}

/// Reads each theme's length (and grabs a frame, when it has video) from
/// the file itself, once per theme while the app runs, a few at a time.
@MainActor
final class ThemePreviews {
    static let shared = ThemePreviews()

    private var done: [String: ThemePreview] = [:]
    private var running: [String: Task<ThemePreview, Never>] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private static let mostAtOnce = 3

    func preview(for theme: OpEdTheme, client: JellyfinClient) async -> ThemePreview? {
        if let found = done[theme.id] { return found }
        if let task = running[theme.id] { return await task.value }
        guard let path = theme.playablePath else { return nil }
        let url = client.opEdMediaURL(path)
        let hasVideo = theme.videoMp4Url != nil
        let task = Task { () -> ThemePreview in
            await turn()
            defer { finished() }
            return await Self.read(url: url, hasVideo: hasVideo)
        }
        running[theme.id] = task
        let result = await task.value
        running[theme.id] = nil
        done[theme.id] = result
        return result
    }

    private func turn() async {
        if active < Self.mostAtOnce {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func finished() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// A frame about a third of the way in, past any fade from black.
    nonisolated private static func read(url: URL, hasVideo: Bool) async -> ThemePreview {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            return ThemePreview()
        }
        var preview = ThemePreview(seconds: Int(duration.seconds.rounded()))
        if hasVideo {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 450)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let time = CMTime(seconds: min(duration.seconds * 0.35, 45), preferredTimescale: 600)
            preview.image = try? await generator.image(at: time).image
        }
        return preview
    }
}
