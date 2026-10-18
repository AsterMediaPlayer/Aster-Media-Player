//
//  ThemeNowPlaying.swift
//  AsterFIN
//
//  The Music tab's Now Playing panel: an opening or ending plays right
//  there, its video (or, for a song alone, the show's picture) above what
//  it is and the controls, then the next one, so a show's songs play
//  through like a playlist.
//

import AVFoundation
import SwiftUI

/// The themes the Music tab plays, one after another, and where it's got to.
@MainActor
@Observable
final class ThemeDeck {
    private(set) var queue: [OpEdTheme] = []
    private(set) var current: OpEdTheme?
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    let player = AVPlayer()

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endWatcher: Task<Void, Never>?

    /// Whether something is loaded, playing or paused.
    var isActive: Bool { current != nil }

    var hasVideo: Bool { current?.videoMp4Url != nil }

    /// Plays `theme`, then the rest of `queue` after it.
    func play(_ theme: OpEdTheme, in queue: [OpEdTheme], client: JellyfinClient) {
        guard let path = theme.playablePath else { return }
        self.client = client
        self.queue = queue
        current = theme
        elapsed = 0
        duration = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: client.opEdMediaURL(path)))
        observe()
        player.play()
        isPlaying = true
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

    /// The next theme that plays without asking (not a spoiler or NSFW).
    func next() {
        guard let client, let upcoming = neighbour(after: true) else {
            stop()
            return
        }
        play(upcoming, in: queue, client: client)
    }

    /// Back to the start, or a few seconds in, back to the theme before.
    func previous() {
        if elapsed > 3 || neighbour(after: false) == nil {
            player.seek(to: .zero)
            elapsed = 0
            return
        }
        if let client, let earlier = neighbour(after: false) {
            play(earlier, in: queue, client: client)
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        endWatcher?.cancel()
        endWatcher = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        current = nil
        isPlaying = false
        elapsed = 0
        duration = 0
    }

    private func neighbour(after: Bool) -> OpEdTheme? {
        guard let current, let index = queue.firstIndex(where: { $0.id == current.id }) else { return nil }
        let candidates = after ? Array(queue[(index + 1)...]) : Array(queue[..<index].reversed())
        return candidates.first { $0.playablePath != nil && !$0.spoiler && !$0.nsfw }
    }

    private func observe() {
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.elapsed = time.seconds.isFinite ? time.seconds : 0
                    if let length = self.player.currentItem?.duration.seconds, length.isFinite, length > 0 {
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
/// the theme is. With nothing playing it offers to play them all.
struct ThemeNowPlayingPanel: View {
    let deck: ThemeDeck
    var artwork: URL?
    var seasonName: (OpEdTheme) -> String?
    var playAll: () -> Void
    var fullScreen: (OpEdTheme) -> Void

    private enum Metrics {
        #if os(tvOS)
        static let spacing: CGFloat = 22
        static let padding: CGFloat = 28
        static let corner: CGFloat = 28
        static let titleFont: Font = .title3.weight(.bold)
        static let controlSize: CGFloat = 34
        #else
        static let spacing: CGFloat = 12
        static let padding: CGFloat = 16
        static let corner: CGFloat = 18
        static let titleFont: Font = .headline
        static let controlSize: CGFloat = 20
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            picture
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.corner / 1.6))

            if let theme = deck.current {
                playing(theme)
            } else {
                idle
            }
        }
        .padding(Metrics.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .tvFocusSection()
    }

    @ViewBuilder
    private var picture: some View {
        if deck.current != nil, deck.hasVideo {
            VideoLayerView(player: deck.player)
                .background(.black)
                .accessibilityHidden(true)
        } else {
            RemoteImage(url: artwork, systemImage: "music.note.tv")
                .overlay {
                    if deck.current != nil {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .padding()
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Label("Now Playing", systemImage: "music.note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Pick an opening or ending to play it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(action: playAll) {
                Label("Play All", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardTarget(action: playAll)
        }
    }

    @ViewBuilder
    private func playing(_ theme: OpEdTheme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Now Playing", systemImage: "music.note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(theme.songTitle ?? theme.code)
                .font(Metrics.titleFont)
                .lineLimit(2)
            if !theme.artists.isEmpty {
                Text(theme.artists.joined(separator: ", "))
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

        HStack(spacing: Metrics.spacing) {
            control("backward.fill", label: "Previous") { deck.previous() }
            control(deck.isPlaying ? "pause.fill" : "play.fill", label: deck.isPlaying ? "Pause" : "Play", prominent: true) { deck.togglePlaying() }
            control("forward.fill", label: "Next") { deck.next() }
            Spacer(minLength: 0)
            control("arrow.up.left.and.arrow.down.right", label: "Full Screen") { fullScreen(theme) }
        }

        details(theme)
    }

    private func control(_ systemImage: String, label: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Metrics.controlSize * 0.6, weight: .semibold))
                .frame(width: Metrics.controlSize, height: Metrics.controlSize)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(prominent ? .accentColor : nil)
        .keyboardTarget(action: action)
        .accessibilityLabel(label)
    }

    /// What it is, in rows: the mockup's Theme Info, from what the plugin knows.
    private func details(_ theme: OpEdTheme) -> some View {
        let rows: [(String, String)] = [
            ("Type", "\(theme.isOpening ? "Opening" : "Ending") \(theme.sequence)" + (theme.version > 1 ? ", version \(theme.version)" : "")),
            theme.variant.flatMap { $0.isEmpty ? nil : ("Variant", $0) },
            seasonName(theme).map { ("Season", $0) },
            theme.episodes.map { ("Episodes", $0) },
            theme.artists.isEmpty ? nil : (theme.artists.count == 1 ? "Artist" : "Artists", theme.artists.joined(separator: ", ")),
            ("Plays", theme.isAudioOnly ? "Song only" : "Music video")
        ].compactMap { $0 }
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
