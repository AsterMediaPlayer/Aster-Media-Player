//
//  OpeningsEndings.swift
//  AsterFIN
//
//  Anime openings and endings, found in episodes' chapters. Fansub and
//  Blu-ray releases usually mark them ("OP", "Opening", "ED", "Ending"...),
//  so a clip of just that stretch can play on its own. Chapters say where an
//  OP is, not which song it is, so a new clip is kept each time the length
//  changes noticeably: a rough sign the song changed.
//

import AVFoundation
import SwiftUI

nonisolated struct ThemeClip: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case opening = "Opening"
        case ending = "Ending"
    }

    var kind: Kind
    var season: Int
    /// 1 for the season's first opening (or ending), 2 for the next...
    var number: Int
    var episode: BaseItem
    var chapterIndex: Int
    var chapterImageTag: String?
    var startTicks: Int64
    var endTicks: Int64

    var id: String { "\(episode.id)-\(kind.rawValue)-\(startTicks)" }

    var title: String {
        number > 1 ? "Season \(season) \(kind.rawValue) \(number)" : "Season \(season) \(kind.rawValue)"
    }

    var duration: Int { Int((endTicks - startTicks) / 10_000_000) }
}

nonisolated enum OpeningsEndings {
    /// Whole words at the start of a chapter name. "OP"/"Opening" and
    /// "ED"/"Ending" are definite; "Intro" and "Outro"/"Credits" are used
    /// only when an episode has no definite one, since many releases call
    /// the cold open "Intro".
    private static let openingWords: Set<String> = ["op", "opening"]
    private static let endingWords: Set<String> = ["ed", "ending"]
    private static let looseOpeningWords: Set<String> = ["intro"]
    private static let looseEndingWords: Set<String> = ["outro", "credits"]

    /// Clips shorter or longer than this aren't really an OP or ED (a cold
    /// open marked "Intro", say), so they're left out.
    private static let durationRange: ClosedRange<Int64> = 30 * 10_000_000 ... 210 * 10_000_000
    /// A change in length bigger than this starts a new clip.
    private static let sameSongSlack: Int64 = 3 * 10_000_000

    /// Episodes must be in airing order, as `/Shows/{id}/Episodes` returns
    /// them. Specials (season 0) are skipped.
    static func find(in episodes: [BaseItem]) -> [ThemeClip] {
        var clips: [ThemeClip] = []
        // Every clip kept so far for each kind in each season: a length close
        // to any of them is the same song, even when lengths alternate.
        var kept: [String: [ThemeClip]] = [:]

        for episode in episodes {
            guard let season = episode.parentIndexNumber, season > 0,
                  let chapters = episode.chapters?.sorted(by: { $0.startPositionTicks < $1.startPositionTicks }),
                  !chapters.isEmpty else { continue }
            let marks = chapters.map { mark(of: $0.name) }
            let hasDefiniteOpening = marks.contains { if case (.opening, true)? = $0 { true } else { false } }
            let hasDefiniteEnding = marks.contains { if case (.ending, true)? = $0 { true } else { false } }

            for (index, chapter) in chapters.enumerated() {
                guard let (kind, definite) = marks[index] else { continue }
                // An "Intro" beside a real "OP" is the cold open.
                if !definite, kind == .opening ? hasDefiniteOpening : hasDefiniteEnding { continue }
                let start = chapter.startPositionTicks
                let end = index + 1 < chapters.count ? chapters[index + 1].startPositionTicks : (episode.runTimeTicks ?? 0)
                guard durationRange.contains(end - start) else { continue }

                let key = "\(season)-\(kind.rawValue)"
                let earlier = kept[key] ?? []
                if earlier.contains(where: { abs((end - start) - ($0.endTicks - $0.startTicks)) <= sameSongSlack }) {
                    continue
                }
                let clip = ThemeClip(
                    kind: kind,
                    season: season,
                    number: earlier.count + 1,
                    episode: episode,
                    chapterIndex: index,
                    chapterImageTag: chapter.imageTag,
                    startTicks: start,
                    endTicks: end
                )
                clips.append(clip)
                kept[key] = earlier + [clip]
            }
        }
        // Season by season, each season's openings before its endings.
        return clips.sorted {
            ($0.season, $0.kind == .opening ? 0 : 1, $0.number) < ($1.season, $1.kind == .opening ? 0 : 1, $1.number)
        }
    }

    /// What a chapter name marks, and whether the name is definite.
    private static func mark(of name: String?) -> (ThemeClip.Kind, Bool)? {
        guard let first = name?.lowercased()
            .split(whereSeparator: { !$0.isLetter }).first.map(String.init) else { return nil }
        if openingWords.contains(first) { return (.opening, true) }
        if endingWords.contains(first) { return (.ending, true) }
        if looseOpeningWords.contains(first) { return (.opening, false) }
        if looseEndingWords.contains(first) { return (.ending, false) }
        return nil
    }
}

/// A clip in the Openings & Endings row: the chapter's frame when the server
/// has one, else the episode's picture, with where it comes from.
struct ThemeClipLockup: View {
    let clip: ThemeClip
    /// Whether it's the one in the Now Playing panel.
    var isPlaying = false
    var play: () -> Void

    @Environment(AppSession.self) private var session

    private var imageURL: URL? {
        guard let client = session.client else { return nil }
        if let tag = clip.chapterImageTag {
            return client.chapterImageURL(itemId: clip.episode.id, index: clip.chapterIndex, tag: tag)
        }
        return client.landscapeURL(for: clip.episode, width: 800)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteImage(url: imageURL, systemImage: clip.kind == .opening ? "music.note.tv" : "music.note.list")
                        .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
                    Text(Self.time(clip.duration))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(12)
                    if isPlaying {
                        Label("Playing", systemImage: "speaker.wave.2.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
            }
            .cardButtonStyle()
            .keyboardTarget(action: play)
            .accessibilityLabel("\(clip.title), from episode \(clip.episode.indexNumber.map(String.init) ?? "")")

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(clip.episode.episodeCode.map { "From \($0)" } ?? clip.episode.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Lockup.landscapeWidth, alignment: .leading)
        }
    }

    private static func time(_ seconds: Int) -> String {
        "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

// MARK: - Music video card

/// What the lower-left card says while an opening or ending plays, like
/// the credit a music channel shows: which theme it is, the song, who
/// performs it, and the show it belongs to.
nonisolated struct ThemeInfo: Hashable, Sendable {
    /// "Opening 1", "Ending 2 · Version 2".
    var kicker: String
    /// The song, or the show when the song is unknown.
    var title: String
    var artists: String?
    var series: String?
    /// "Season 2 · Episodes 1–12", "Season 1 · From S01E03".
    var detail: String?

    init(theme: OpEdTheme, series: String, seasonName: String?) {
        var kicker = "\(theme.isOpening ? "Opening" : "Ending") \(theme.sequence)"
        if theme.version > 1 { kicker += " · Version \(theme.version)" }
        if let variant = theme.variant, !variant.isEmpty { kicker += " · \(variant)" }
        if theme.isFull { kicker += " · Full Version" }
        self.kicker = kicker
        title = theme.songTitle ?? series
        artists = theme.artists.isEmpty ? nil : theme.artists.joined(separator: ", ")
        self.series = theme.songTitle == nil ? nil : series
        let parts = [seasonName, theme.episodes.map { "Episodes \($0)" }].compactMap { $0 }
        detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    init(kicker: String, title: String, artists: String? = nil, series: String? = nil, detail: String? = nil) {
        self.kicker = kicker
        self.title = title
        self.artists = artists
        self.series = series
        self.detail = detail
    }

    init(clip: ThemeClip, series: String) {
        kicker = clip.number > 1 ? "\(clip.kind.rawValue) \(clip.number)" : clip.kind.rawValue
        title = series
        artists = nil
        self.series = nil
        let parts = ["Season \(clip.season)", clip.episode.episodeCode.map { "From \($0)" }].compactMap { $0 }
        detail = parts.joined(separator: " · ")
    }
}

/// The card itself, drawn in the lower left over the video.
struct ThemeInfoCard: View {
    let info: ThemeInfo
    /// The screen's safe area on the leading side (a Dynamic Island or the
    /// notch, in landscape): the text keeps clear of it, though the shade
    /// still runs to the corner.
    var safeLeading: CGFloat = 0

    /// The card at TV size, or scaled down for a phone or tablet.
    private enum Metrics {
        #if os(tvOS)
        static let barGap: CGFloat = 22
        static let barWidth: CGFloat = 5
        static let lineSpacing: CGFloat = 8
        static let titleSize: CGFloat = 50
        static let artistsFont: Font = .title3.weight(.medium)
        static let seriesFont: Font = .headline
        static let detailFont: Font = .callout
        static let maxWidth: CGFloat = 900
        static let leading: CGFloat = 90
        static let bottom: CGFloat = 120
        static let shade = CGSize(width: 1100, height: 500)
        #else
        static let barGap: CGFloat = 12
        static let barWidth: CGFloat = 3
        static let lineSpacing: CGFloat = 4
        static let titleSize: CGFloat = 24
        static let artistsFont: Font = .subheadline.weight(.medium)
        static let seriesFont: Font = .footnote.weight(.semibold)
        static let detailFont: Font = .caption
        static let maxWidth: CGFloat = 420
        static let leading: CGFloat = 24
        static let bottom: CGFloat = 40
        static let shade = CGSize(width: 520, height: 240)
        #endif
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.barGap) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: Metrics.barWidth)
            VStack(alignment: .leading, spacing: Metrics.lineSpacing) {
                Text(info.kicker.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(2.5)
                    .foregroundStyle(.white.opacity(0.75))
                Text(info.title)
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .lineLimit(2)
                if let artists = info.artists {
                    Text(artists)
                        .font(Metrics.artistsFont)
                        .lineLimit(1)
                }
                if let series = info.series {
                    Text(series)
                        .font(Metrics.seriesFont)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                if let detail = info.detail {
                    Text(detail)
                        .font(Metrics.detailFont)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: 6, x: 0, y: 2)
        .frame(maxWidth: Metrics.maxWidth, alignment: .leading)
        .padding(.leading, max(Metrics.leading, safeLeading + 8))
        .padding(.bottom, Metrics.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(alignment: .bottomLeading) {
            // A soft shade behind the text so it reads over bright frames.
            // Elliptical from the corner so it reaches clear at both the top
            // and right edges; a diagonal linear gradient left a hard box.
            EllipticalGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.3), location: 0.55),
                    .init(color: .clear, location: 1),
                ],
                center: .bottomLeading,
                startRadiusFraction: 0,
                endRadiusFraction: 1
            )
            .frame(width: Metrics.shade.width, height: Metrics.shade.height)
        }
    }
}

/// Shows the card for the first seconds of a theme and, when the player's
/// clock is known, again for its last seconds. Without a player the card
/// simply shows once when it appears.
struct ThemeInfoOverlay: View {
    var player: AVPlayer?
    /// Where playback is, in seconds, for a player that isn't an `AVPlayer`
    /// (AetherEngine); read four times a second. Takes the place of `player`.
    var currentTime: (() -> Double)? = nil
    /// The stretch of `player`'s timeline the theme occupies, in seconds,
    /// when it is part of a longer video (an episode's OP chapter).
    var range: ClosedRange<Double>?
    let info: ThemeInfo

    @State private var visible = false
    /// The leading safe area, measured before the overlay ignores it.
    @State private var safeLeading: CGFloat = 0
    @State private var observer: Any?
    @State private var clock: Task<Void, Never>?

    private static let showFor: Double = 16

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if visible {
                ThemeInfoCard(info: info, safeLeading: safeLeading)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { safeLeading = $0 }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.6), value: visible)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        if let currentTime {
            stop()
            clock = Task {
                while !Task.isCancelled {
                    update(at: currentTime(), end: range?.upperBound ?? .nan)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            return
        }
        guard let player else {
            visible = true
            Task {
                try? await Task.sleep(for: .seconds(Self.showFor))
                visible = false
            }
            return
        }
        stop()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            Task { @MainActor in update(at: time, of: player) }
        }
    }

    private func stop() {
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
        observer = nil
        clock?.cancel()
        clock = nil
    }

    private func update(at time: CMTime, of player: AVPlayer) {
        update(at: time.seconds, end: range?.upperBound ?? player.currentItem?.duration.seconds ?? .nan)
    }

    private func update(at seconds: Double, end: Double) {
        guard seconds.isFinite else { return }
        let start = range?.lowerBound ?? 0
        // Only inside the theme: an episode's opening comes after its start.
        let inside = seconds >= start - 0.5 && (!end.isFinite || seconds <= end)
        let atStart = inside && seconds - start < Self.showFor
        // The closing card only when the theme is long enough for two.
        let atEnd = inside && end.isFinite && end - start > Self.showFor * 3 && end - seconds < Self.showFor
        let show = atStart || atEnd
        if show != visible { visible = show }
    }
}

// MARK: - Plugin themes

/// An entry in the Openings & Endings row: a theme file from the OP/ED
/// server plugin, or a clip of an episode found from its chapters (used when
/// the plugin has nothing playable for the show).
nonisolated enum OpeningEnding: Identifiable, Hashable, Sendable {
    case theme(OpEdTheme)
    case chapter(ThemeClip)

    var id: String {
        switch self {
        case .theme(let theme): "theme-\(theme.id)"
        case .chapter(let clip): "chapter-\(clip.id)"
        }
    }
}

/// A plugin theme's card: the series artwork (there are no theme pictures),
/// blurred for spoilers and NSFW, with the song and the season it's from.
struct OpEdThemeLockup: View {
    let theme: OpEdTheme
    /// The season's name, since OP1 repeats across seasons.
    var seasonName: String?
    var artwork: URL?
    var play: () -> Void

    private var hidden: Bool { theme.spoiler || theme.nsfw }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                ZStack {
                    RemoteImage(url: artwork, systemImage: theme.isOpening ? "music.note.tv" : "music.note.list")
                        .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
                        .blur(radius: hidden ? 24 : 0)
                    if hidden || theme.isPreparing {
                        Label(theme.isPreparing ? "Preparing…" : (theme.nsfw ? "NSFW" : "Spoiler"),
                              systemImage: theme.isPreparing ? "hourglass" : "eye.slash")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: Capsule())
                    }
                    if theme.isAudioOnly {
                        // No video copy: only the song plays.
                        Label("Audio only", systemImage: "music.note")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
                .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
            }
            .cardButtonStyle()
            .keyboardTarget(action: play)
            .disabled(theme.isPreparing)
            .accessibilityLabel([theme.code, theme.songLine, seasonName, theme.isAudioOnly ? "audio only" : nil].compactMap { $0 }.joined(separator: ", "))

            VStack(alignment: .leading, spacing: 2) {
                Text(theme.songLine.map { "\(theme.code) · \($0)" } ?? theme.code)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text([seasonName, theme.episodes.map { "Episodes \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Lockup.landscapeWidth, alignment: .leading)
        }
    }
}
