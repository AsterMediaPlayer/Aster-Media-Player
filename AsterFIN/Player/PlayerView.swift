//
//  PlayerView.swift
//  AsterFIN
//
//  The system tvOS video player, presented full screen for a playback request,
//  with Skip Intro / Skip Credits actions and an Up Next card for episodes.
//

import AVKit
import SwiftUI

struct PlayerView: View {
    private let request: PlaybackRequest?
    /// Playback owned by someone else, like the Live TV mini player. It is
    /// shown here but not stopped when this view goes away.
    private let sharedCoordinator: PlaybackCoordinator?
    var onFinished: () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: PlaybackCoordinator?
    /// The info panel's Audio and Subtitles tabs, made once per playback.
    @State private var audioTab: UIViewController?
    @State private var subtitlesTab: UIViewController?
    /// The last item that started playing. Artwork covers the player until
    /// each new item does, but not when the same one reloads mid-play.
    @State private var startedItemId: String?

    /// Plays `request`, and stops when the view goes away.
    init(request: PlaybackRequest, onFinished: @escaping () -> Void) {
        self.request = request
        self.sharedCoordinator = nil
        self.onFinished = onFinished
    }

    /// Shows playback that keeps going after the view goes away.
    init(coordinator: PlaybackCoordinator, onFinished: @escaping () -> Void) {
        self.request = nil
        self.sharedCoordinator = coordinator
        self.onFinished = onFinished
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let coordinator {
                SystemPlayer(
                    player: coordinator.player,
                    contextualActions: contextualActions(for: coordinator),
                    showsPlaybackControls: !coordinator.endCardVisible,
                    infoTabs: [
                        coordinator.audioTracks.count > 1 ? audioTab : nil,
                        coordinator.subtitleTracks.isEmpty ? nil : subtitlesTab,
                    ].compactMap { $0 }
                )
                .ignoresSafeArea()
                .onChange(of: coordinator.isFinished) { _, finished in
                    if finished {
                        coordinator.stop()
                        onFinished()
                    }
                }
                .overlay {
                    // The app's own subtitles, drawn over the system player.
                    if !coordinator.endCardVisible {
                        SubtitleOverlayView(text: coordinator.subtitleText)
                    }
                }
                .overlay {
                    // An opening or ending clip gets its music video card.
                    if let info = coordinator.themeInfo, coordinator.hasStarted {
                        ThemeInfoOverlay(player: coordinator.player, range: coordinator.clipRange, info: info)
                    }
                }
                .alert("Can't Play", isPresented: Binding(get: { coordinator.errorMessage != nil }, set: { _ in })) {
                    Button("OK") {
                        coordinator.stop()
                        onFinished()
                    }
                } message: {
                    Text(coordinator.errorMessage ?? "")
                }

                if startedItemId == nil || startedItemId != coordinator.currentItem?.id, coordinator.errorMessage == nil {
                    PlaybackLoadingView(item: coordinator.currentItem)
                        .transition(.opacity)
                }

                if coordinator.endCardVisible, let next = coordinator.upNext {
                    UpNextCard(episode: next, countdown: coordinator.countdown) {
                        coordinator.playUpNextNow()
                    } dismiss: {
                        coordinator.dismissEndCard()
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: coordinator?.endCardVisible ?? false)
        .animation(.easeInOut(duration: 0.6), value: startedItemId)
        .onChange(of: coordinator?.hasStarted) { _, started in
            if started == true { startedItemId = coordinator?.currentItem?.id }
        }
        .onAppear {
            guard coordinator == nil else { return }
            if let sharedCoordinator {
                coordinator = sharedCoordinator
                // Already playing (the Live TV mini player): no artwork.
                if sharedCoordinator.hasStarted { startedItemId = sharedCoordinator.currentItem?.id }
                audioTab = TracksTab.makeController(.audio, for: sharedCoordinator)
                subtitlesTab = TracksTab.makeController(.subtitles, for: sharedCoordinator)
                return
            }
            guard let request, let client = session.client else { return }
            let created = PlaybackCoordinator(
                client: client,
                request: request,
                autoplayNext: AppSettings.autoplayNext,
                autoSkipIntro: AppSettings.autoSkipIntro,
                preferences: session.playbackPreferences
            )
            coordinator = created
            audioTab = TracksTab.makeController(.audio, for: created)
            subtitlesTab = TracksTab.makeController(.subtitles, for: created)
            created.start()
        }
        .onDisappear {
            guard sharedCoordinator == nil else { return }
            coordinator?.stop()
        }
    }

    /// The buttons the system player shows in its lower trailing corner.
    private func contextualActions(for coordinator: PlaybackCoordinator) -> [UIAction] {
        var actions: [UIAction] = []
        if let segment = coordinator.activeSegment {
            actions.append(UIAction(title: segment.skipTitle, image: UIImage(systemName: "forward.fill")) { _ in
                coordinator.skipActiveSegment()
            })
        }
        if coordinator.showsUpNextAction {
            actions.append(UIAction(title: "Play Next Episode", image: UIImage(systemName: "forward.end.fill")) { _ in
                coordinator.playUpNextNow()
            })
        }
        return actions
    }
}

/// Covers the player while an item loads: the season's backdrop (or the
/// series' when the season has none) with the show's logo and a spinner.
/// Never focusable, so the remote still reaches the player underneath.
private struct PlaybackLoadingView: View {
    let item: BaseItem?

    @Environment(AppSession.self) private var session
    @State private var artwork: URL?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let artwork {
                RemoteImage(url: artwork) { Color.black }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transition(.opacity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)

            if let item {
                VStack(alignment: .leading, spacing: 12) {
                    if let logo = session.client?.logoURL(for: item) {
                        RemoteImage(url: logo, contentMode: .fit) { Text(item.seriesName ?? item.displayTitle).font(.title.bold()) }
                            .frame(maxWidth: 500, maxHeight: 160, alignment: .bottomLeading)
                    } else {
                        Text(item.seriesName ?? item.displayTitle)
                            .font(.title.bold())
                    }
                    HStack(spacing: 16) {
                        ProgressView()
                        Text([item.episodeCode, item.kind == .episode ? item.displayTitle : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 90)
                .padding(.bottom, 80)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeIn(duration: 0.4), value: artwork)
        .task(id: item?.id) {
            guard let item, let client = session.client else { return }
            artwork = await Self.artwork(for: item, client: client)
        }
    }

    /// An episode's season backdrop when it has its own, else the series'
    /// (episodes inherit that one); anything else uses its own backdrop.
    private static func artwork(for item: BaseItem, client: JellyfinClient) async -> URL? {
        if item.kind == .episode, let seasonId = item.seasonId,
           let season = try? await client.item(seasonId),
           let tag = season.backdropImageTags?.first {
            return client.imageURL(itemId: season.id, kind: .backdrop, tag: tag, index: 0, maxWidth: 1920)
        }
        return client.backdropURL(for: item, width: 1920)
    }
}

/// Something to play straight from a URL, outside Jellyfin's items: an
/// opening or ending from the OP/ED plugin.
nonisolated struct URLPlayback: Identifiable, Hashable, Sendable {
    var id = UUID()
    var url: URL
    var title: String
    var subtitle: String?
    /// Shown in the player's info, and as the picture for audio-only themes.
    var artwork: URL?
    /// The music video card shown in the lower left as it starts and ends.
    var info: ThemeInfo?
}

/// Plays a `URLPlayback` full screen in the system player and closes when it
/// ends. Nothing is reported to Jellyfin.
struct URLPlayerView: View {
    let playback: URLPlayback
    var onFinished: () -> Void

    @Environment(AppSession.self) private var session
    @State private var player = AVPlayer()

    var body: some View {
        SystemPlayer(player: player)
            .ignoresSafeArea()
            .background(Color.black)
            .overlay {
                if let info = playback.info {
                    ThemeInfoOverlay(player: player, info: info)
                }
            }
            .onAppear {
                let item = AVPlayerItem(url: playback.url)
                item.externalMetadata = Self.metadata(for: playback)
                player.replaceCurrentItem(with: item)
                // Full volume, unlike the quiet theme behind title pages.
                player.volume = 1
                player.play()
                // The artwork arrives a moment later; the player picks it up.
                if let artwork = playback.artwork, let client = session.client {
                    Task {
                        guard let data = try? await client.data(from: artwork) else { return }
                        let image = AVMutableMetadataItem()
                        image.identifier = .commonIdentifierArtwork
                        image.value = data as NSData
                        image.dataType = kCMMetadataBaseDataType_JPEG as String
                        image.extendedLanguageTag = "und"
                        item.externalMetadata += [image]
                    }
                }
            }
            .onDisappear {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            .task {
                for await note in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification) {
                    if (note.object as? AVPlayerItem) === player.currentItem {
                        onFinished()
                        return
                    }
                }
            }
    }

    private static func metadata(for playback: URLPlayback) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = playback.title as NSString
        title.extendedLanguageTag = "und"
        items.append(title)
        if let subtitle = playback.subtitle {
            let line = AVMutableMetadataItem()
            line.identifier = .iTunesMetadataTrackSubTitle
            line.value = subtitle as NSString
            line.extendedLanguageTag = "und"
            items.append(line)
        }
        return items
    }
}

/// AVPlayerViewController hosted in SwiftUI. The system UI supplies native
/// transport controls, info panel, chapters, audio options, and subtitles.
struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var contextualActions: [UIAction] = []
    var showsPlaybackControls = true
    /// Extra tabs for the swipe-down info panel.
    var infoTabs: [UIViewController] = []

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        #if os(tvOS)
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        #endif
        return controller
    }

    /// Lets go of the player as this view goes away, so playback that carries
    /// on elsewhere (the Live TV mini player) isn't still tied to a closed
    /// full-screen controller.
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        if controller.showsPlaybackControls != showsPlaybackControls {
            controller.showsPlaybackControls = showsPlaybackControls
        }
        // Skip buttons and the extra info tabs are tvOS player features; on
        // iOS they're ignored for now and need an overlay of their own.
        #if os(tvOS)
        if controller.contextualActions.map(\.title) != contextualActions.map(\.title) {
            controller.contextualActions = contextualActions
        }
        if controller.customInfoViewControllers.map(ObjectIdentifier.init) != infoTabs.map(ObjectIdentifier.init) {
            controller.customInfoViewControllers = infoTabs
        }
        #endif
    }
}

/// An "Audio" or "Subtitles" tab in the player's swipe-down info panel,
/// listing the server's tracks by their own titles. The system menus name
/// tracks only by language (so several in one language share a label), and
/// a transcoded stream carries just one audio track, so the system Audio
/// menu has nothing else to offer; this tab is how the rest are chosen.
struct TracksTab: View {
    enum Kind {
        case audio, subtitles

        var title: String { self == .audio ? "Audio" : "Subtitles" }
    }

    let kind: Kind
    let coordinator: PlaybackCoordinator

    /// Hosts the tab for `AVPlayerViewController.customInfoViewControllers`.
    static func makeController(_ kind: Kind, for coordinator: PlaybackCoordinator) -> UIViewController {
        let host = UIHostingController(rootView: TracksTab(kind: kind, coordinator: coordinator))
        host.title = kind.title
        host.preferredContentSize = CGSize(width: 1920, height: 220)
        host.view.backgroundColor = .clear
        return host
    }

    private var tracks: [MediaStream] {
        kind == .audio ? coordinator.audioTracks : coordinator.subtitleTracks
    }

    private var selectedIndex: Int? {
        kind == .audio ? coordinator.selectedAudioIndex : coordinator.selectedSubtitleIndex
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 30) {
                if kind == .subtitles {
                    trackButton(title: "Off", detail: nil, index: -1)
                }
                ForEach(tracks, id: \.index) { stream in
                    if let index = stream.index {
                        trackButton(title: stream.title ?? stream.trackTitle, detail: detail(for: stream), index: index)
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
    }

    private func trackButton(title: String, detail: String?, index: Int) -> some View {
        Button {
            switch kind {
            case .audio: coordinator.selectAudio(index)
            case .subtitles: coordinator.selectSubtitle(index)
            }
        } label: {
            HStack(spacing: 14) {
                if kind == .subtitles, selectedIndex == index, coordinator.isLoadingSubtitles {
                    // The server is still extracting this track.
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark")
                        .opacity(selectedIndex == index ? 1 : 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    /// Language, then Forced, the format and the channel layout, e.g.
    /// "English · Forced · ASS" or "Japanese · EAC3 · 5.1".
    private func detail(for stream: MediaStream) -> String? {
        let language = stream.language.flatMap { code in
            Locale.current.localizedString(forLanguageCode: LanguageTag.bcp47(from: code))
        }
        let channels: String? = switch stream.channels {
        case nil: nil
        case 1: "Mono"
        case 2: "Stereo"
        case let count?: "\(count - 1).1"
        }
        let parts = [language, stream.isForced == true ? "Forced" : nil, stream.codec?.uppercased(), channels].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Shown when an episode ends: the next episode, with a countdown when
/// autoplay is on.
struct UpNextCard: View {
    let episode: BaseItem
    let countdown: Int?
    var playNext: () -> Void
    var dismiss: () -> Void

    @Environment(AppSession.self) private var session
    @FocusState private var focused: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: session.client?.landscapeURL(for: episode, width: 1920)) { Color.black }
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75), .black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text("Up Next")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let series = episode.seriesName {
                    Text(series)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(episode.displayTitle)
                    .font(.system(size: 56, weight: .bold))
                    .lineLimit(2)
                if let code = episode.episodeCode {
                    Text(code)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                if let overview = episode.overview {
                    Text(overview)
                        .font(.callout)
                        .lineLimit(3)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                HStack(spacing: 20) {
                    ActionButton(title: countdown.map { "Play Next in \($0)s" } ?? "Play Next", systemImage: "play.fill", prominent: true, focus: $focused, focusID: "play", action: playNext)
                    ActionButton(title: "Done", systemImage: "xmark", focus: $focused, focusID: "done", action: dismiss)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 80)
        }
        .tvFocusSection()
        .tvExitCommand(perform: dismiss)
        .onAppear { focused = "play" }
    }
}
