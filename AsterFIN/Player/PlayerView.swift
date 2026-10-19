//
//  PlayerView.swift
//  AsterFIN
//
//  The system tvOS video player, presented full screen for a playback request,
//  with Skip Intro / Skip Credits actions and an Up Next card for episodes.
//

import AVKit
import SwiftUI
#if DEBUG && os(macOS)
import os
#endif

struct PlayerView: View {
    private let request: PlaybackRequest?
    /// Playback owned by someone else, like the Live TV mini player. It is
    /// shown here but not stopped when this view goes away.
    private let sharedCoordinator: PlaybackCoordinator?
    var onFinished: () -> Void
    /// Told each time an item starts, so the page behind can follow when
    /// the next episode plays on its own.
    var onItemStarted: ((BaseItem) -> Void)?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator: PlaybackCoordinator?
    #if canImport(UIKit)
    /// The info panel's Audio and Subtitles tabs, made once per playback.
    @State private var audioTab: UIViewController?
    @State private var subtitlesTab: UIViewController?
    #endif
    /// The last item that started playing. Artwork covers the player until
    /// each new item does, but not when the same one reloads mid-play.
    @State private var startedItemId: String?
    /// iOS: when the video was last tapped, which brings up the system
    /// controls; the tracks button shows alongside them for a while. On a
    /// Mac, when the pointer last moved over the video.
    @State private var controlsShownAt: Date?
    @State private var trackMenuOpen = false
    #if canImport(AetherEngine)
    /// Playback through AetherEngine, the main player, when it can take the
    /// request; the system player otherwise, or once it hands over.
    @State private var aether: AetherPlayback?
    /// AetherEngine playback owned by someone else (the Live TV screen).
    private var sharedAether: AetherPlayback?
    #endif

    /// Plays `request`, and stops when the view goes away.
    init(request: PlaybackRequest, onItemStarted: ((BaseItem) -> Void)? = nil, onFinished: @escaping () -> Void) {
        self.request = request
        self.sharedCoordinator = nil
        self.onFinished = onFinished
        self.onItemStarted = onItemStarted
    }

    /// Shows playback that keeps going after the view goes away.
    init(coordinator: PlaybackCoordinator, onFinished: @escaping () -> Void) {
        self.request = nil
        self.sharedCoordinator = coordinator
        self.onFinished = onFinished
    }

    #if canImport(AetherEngine)
    /// Shows AetherEngine playback that keeps going after the view goes away,
    /// like a Live TV channel the mini player carries on with.
    init(aether: AetherPlayback, onFinished: @escaping () -> Void) {
        self.request = nil
        self.sharedCoordinator = nil
        self.sharedAether = aether
        self.onFinished = onFinished
    }
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                // Leaving the screen (the TV button, the app switcher) may be
                // the last chance to save where playback got to.
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    #if canImport(AetherEngine)
                    aether?.saveProgressNow()
                    #endif
                    coordinator?.saveProgressNow()
                }
            #if canImport(AetherEngine)
            if let aether {
                AetherPlayerView(playback: aether, onFinished: onFinished)
                    // Its own controls decide when Back closes the player
                    // (on Apple TV, only once the panel and controls are away).
                    .interactiveDismissDisabled()
            }
            #endif
            if let coordinator {
                systemPlayer(for: coordinator)
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
                        if let track = coordinator.assTrack {
                            AssSubtitleOverlay(track: track, videoSize: coordinator.videoSize)
                        } else {
                            SubtitleOverlayView(text: coordinator.subtitleText)
                        }
                    }
                }
                .overlay {
                    if coordinator.hasStarted, !coordinator.endCardVisible {
                        ChannelBug(
                            channelId: coordinator.channelId,
                            videoAspect: coordinator.videoSize.height > 0 ? coordinator.videoSize.width / coordinator.videoSize.height : nil,
                            playing: coordinator.currentItem
                        )
                    }
                }
                .overlay {
                    // An opening or ending clip gets its music video card.
                    if let info = coordinator.themeInfo, coordinator.hasStarted {
                        ThemeInfoOverlay(player: coordinator.player, range: coordinator.clipRange, info: info)
                    }
                }
                .overlay {
                    // So does an episode's own opening and ending, as it plays.
                    if coordinator.hasStarted, !coordinator.endCardVisible {
                        ForEach(coordinator.themeMoments) { moment in
                            ThemeInfoOverlay(player: coordinator.player, range: moment.range, info: moment.info)
                        }
                    }
                }
                #if !os(tvOS)
                .overlay(alignment: .bottomTrailing) {
                    // The tvOS player shows these as contextual actions; iOS
                    // and the Mac have no such thing, so they're buttons over
                    // the video.
                    if !coordinator.endCardVisible {
                        TouchPlayerActions(coordinator: coordinator)
                    }
                }
                #endif
                #if os(macOS)
                .overlay {
                    MacPlayerButtons(
                        coordinator: coordinator,
                        shown: !coordinator.endCardVisible && (controlsShownAt != nil || coordinator.isPaused),
                        close: onFinished
                    )
                }
                .onContinuousHover { phase in
                    // AVPlayerView shows its controls as the pointer moves;
                    // these buttons follow along.
                    guard case .active = phase else { return }
                    if controlsShownAt.map({ Date().timeIntervalSince($0) > 0.5 }) ?? true {
                        controlsShownAt = Date()
                    }
                }
                #endif
                #if os(iOS)
                .overlay {
                    // Sideways, the system player has its own subtitles button
                    // (beside the speed control, lower right), which only knows
                    // the stream's tracks: an invisible button sits over it so
                    // a tap opens this menu instead. Upright it has none, so a
                    // glass button sits beside its ⋯ button. Offsets are from
                    // the safe area, matching the system layout.
                    // Hidden by fading, never removed: the menu animates back
                    // into the button as it closes, and UIKit stops the app if
                    // the button has gone by then.
                    // iPad shows the subtitles button in either orientation, in
                    // the pill above the timeline; the iPad app on a Mac puts it
                    // at the far right of the bottom bar. Each gets the invisible
                    // button over its own, measured from the system layout.
                    GeometryReader { proxy in
                        let placement = TrackButtonPlacement(landscape: proxy.size.width > proxy.size.height)
                        let hasTracks = coordinator.audioTracks.count > 1 || !coordinator.subtitleTracks.isEmpty
                        let shown = hasTracks && !coordinator.endCardVisible && (controlsShownAt != nil || coordinator.isPaused || trackMenuOpen)
                        TrackMenuButton(menu: TrackMenu(coordinator: coordinator), invisible: placement.overSystemButton) { trackMenuOpen = $0 }
                            .frame(width: 44, height: 44)
                            .padding(.trailing, placement.trailing)
                            .padding(.bottom, placement.bottom)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .opacity(shown ? 1 : 0)
                            .allowsHitTesting(shown)
                            .accessibilityHidden(!shown)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: controlsShownAt != nil || coordinator.isPaused || trackMenuOpen)
                #endif
                #if !os(tvOS)
                .task(id: controlsShownAt) {
                    // Hides with the system controls, a few seconds after the tap.
                    guard controlsShownAt != nil else { return }
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { controlsShownAt = nil }
                }
                #endif
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
            if started == true {
                startedItemId = coordinator?.currentItem?.id
                if let item = coordinator?.currentItem { onItemStarted?(item) }
            }
        }
        .onAppear {
            // A video takes over from an opening or ending playing while browsing.
            session.themeDeck.stop()
            guard coordinator == nil else { return }
            if let sharedCoordinator {
                coordinator = sharedCoordinator
                // Already playing (the Live TV mini player): no artwork.
                if sharedCoordinator.hasStarted { startedItemId = sharedCoordinator.currentItem?.id }
                #if canImport(UIKit)
                audioTab = TracksTab.makeController(.audio, for: sharedCoordinator)
                subtitlesTab = TracksTab.makeController(.subtitles, for: sharedCoordinator)
                #endif
                return
            }
            #if canImport(AetherEngine)
            if let sharedAether {
                aether = sharedAether
                return
            }
            #endif
            guard let request, let client = session.client else { return }
            #if canImport(AetherEngine)
            guard aether == nil else { return }
            if AetherPlayback.canPlay(request), let playback = AetherPlayback(client: client, request: request, preferences: session.playbackPreferences) {
                aether = playback
                playback.onItemStarted = onItemStarted
                // What the engine can't play carries on in the system player,
                // which can ask the server to transcode.
                playback.onFallback = { handedOver in
                    aether = nil
                    startSystemPlayer(handedOver, client: client)
                }
                Task { await playback.start() }
                return
            }
            #endif
            startSystemPlayer(request, client: client)
        }
        .onDisappear {
            guard sharedCoordinator == nil else { return }
            #if canImport(AetherEngine)
            guard sharedAether == nil else { return }
            aether?.stop()
            #endif
            coordinator?.stop()
        }
        #if os(macOS)
        .modifier(FullScreenWhilePlaying())
        #endif
    }

    private func startSystemPlayer(_ request: PlaybackRequest, client: JellyfinClient) {
        let created = PlaybackCoordinator(
            client: client,
            request: request,
            autoplayNext: AppSettings.autoplayNext,
            autoSkipIntro: AppSettings.autoSkipIntro,
            preferences: session.playbackPreferences
        )
        coordinator = created
        #if canImport(UIKit)
        audioTab = TracksTab.makeController(.audio, for: created)
        subtitlesTab = TracksTab.makeController(.subtitles, for: created)
        #endif
        created.start()
    }

    /// The system player, with what each platform's version takes.
    @ViewBuilder
    private func systemPlayer(for coordinator: PlaybackCoordinator) -> some View {
        #if os(macOS)
        SystemPlayer(player: coordinator.player, showsPlaybackControls: !coordinator.endCardVisible)
        #else
        SystemPlayer(
            player: coordinator.player,
            contextualActions: contextualActions(for: coordinator),
            showsPlaybackControls: !coordinator.endCardVisible,
            requiresLinearPlayback: coordinator.followsTimeline,
            infoTabs: [
                coordinator.audioTracks.count > 1 ? audioTab : nil,
                coordinator.subtitleTracks.isEmpty ? nil : subtitlesTab,
            ].compactMap { $0 },
            onTap: { controlsShownAt = Date() }
        )
        #endif
    }

    #if canImport(UIKit)
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
    #endif
}

#if os(iOS)
/// The player's Audio & Subtitles menu on iOS, where the tvOS info tabs
/// don't exist: the server's tracks by their own titles, as in those tabs.
/// The signature changes whenever the menu would, so the button is only
/// handed a new one then.
private struct TrackMenu {
    var menu: UIMenu?
    var signature = ""

    init(coordinator: PlaybackCoordinator) {
        var sections: [UIMenuElement] = []
        if coordinator.audioTracks.count > 1 {
            let actions = coordinator.audioTracks.compactMap { stream -> UIAction? in
                guard let index = stream.index else { return nil }
                return UIAction(
                    title: stream.title ?? stream.trackTitle,
                    subtitle: TracksTab.detail(for: stream),
                    state: coordinator.selectedAudioIndex == index ? .on : .off
                ) { _ in coordinator.selectAudio(index) }
            }
            sections.append(UIMenu(title: "Audio", options: [.displayInline, .singleSelection], children: actions))
        }
        if !coordinator.subtitleTracks.isEmpty {
            let selected = coordinator.selectedSubtitleIndex
            var actions = [UIAction(title: "Off", state: selected == -1 ? .on : .off) { _ in coordinator.selectSubtitle(-1) }]
            actions += coordinator.subtitleTracks.compactMap { stream -> UIAction? in
                guard let index = stream.index else { return nil }
                // The server can take a while to extract a track the first time.
                let loading = selected == index && coordinator.isLoadingSubtitles
                let detail = TracksTab.detail(for: stream)
                return UIAction(
                    title: stream.title ?? stream.trackTitle,
                    subtitle: loading ? [detail, "Loading…"].compactMap { $0 }.joined(separator: " · ") : detail,
                    state: selected == index ? .on : .off
                ) { _ in coordinator.selectSubtitle(index) }
            }
            sections.append(UIMenu(title: "Subtitles", options: [.displayInline, .singleSelection], children: actions))
        }
        guard !sections.isEmpty else { return }
        menu = UIMenu(title: "Audio & Subtitles", children: sections)
        signature = [
            coordinator.audioTracks.compactMap(\.index).map(String.init).joined(separator: ","),
            String(coordinator.selectedAudioIndex ?? -1),
            coordinator.subtitleTracks.compactMap(\.index).map(String.init).joined(separator: ","),
            String(coordinator.selectedSubtitleIndex),
            String(coordinator.isLoadingSubtitles),
        ].joined(separator: "|")
    }
}

/// Where the track menu's button goes, from the bottom-trailing corner of
/// the safe area, per device: over the system's own subtitles button
/// (invisible), or, on an upright iPhone, which has none, beside its More.
private struct TrackButtonPlacement {
    var overSystemButton: Bool
    var trailing: CGFloat
    var bottom: CGFloat

    init(landscape: Bool) {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            (overSystemButton, trailing, bottom) = (true, 7, 4)
        } else if UIDevice.current.userInterfaceIdiom == .pad {
            (overSystemButton, trailing, bottom) = (true, 13, 56)
        } else if landscape {
            (overSystemButton, trailing, bottom) = (true, 3, 59)
        } else {
            (overSystemButton, trailing, bottom) = (false, 77, 56)
        }
    }
}

/// A round button that opens the track menu, reporting while it's open so
/// the button stays up. UIKit, since a UIMenu keeps each track's details
/// as a subtitle under its name. `invisible` draws nothing but still takes
/// taps, for sitting over the system's own button.
private struct TrackMenuButton: UIViewRepresentable {
    let menu: TrackMenu
    var invisible = false
    var onOpenChange: (Bool) -> Void

    final class MenuButton: UIButton {
        var signature: String?
        var isInvisible: Bool?
        var onOpenChange: ((Bool) -> Void)?

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            onOpenChange?(true)
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            onOpenChange?(false)
        }
    }

    func makeUIView(context: Context) -> MenuButton {
        let button = MenuButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "Audio and Subtitles"
        return button
    }

    func updateUIView(_ button: MenuButton, context: Context) {
        button.onOpenChange = onOpenChange
        if button.isInvisible != invisible {
            button.isInvisible = invisible
            if invisible {
                button.configuration = .plain()
            } else {
                // Matches the system player's own round glass buttons.
                var configuration = UIButton.Configuration.glass()
                configuration.image = UIImage(systemName: "captions.bubble", withConfiguration: UIImage.SymbolConfiguration(textStyle: .headline))
                configuration.baseForegroundColor = .white
                configuration.cornerStyle = .capsule
                button.configuration = configuration
            }
        }
        if button.signature != menu.signature {
            button.signature = menu.signature
            button.menu = menu.menu
        }
    }
}
#endif

#if os(macOS)
/// The Mac player's own buttons, shown while the pointer moves over the
/// video, as AVPlayerView's controls are: a close button (Esc works too),
/// and the server's audio and subtitle tracks by their own titles.
private struct MacPlayerButtons: View {
    let coordinator: PlaybackCoordinator
    var shown: Bool
    var close: () -> Void

    private var hasTracks: Bool {
        coordinator.audioTracks.count > 1 || !coordinator.subtitleTracks.isEmpty
    }

    var body: some View {
        HStack(alignment: .top) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 28, height: 28)
            }
            .buttonBorderShape(.circle)
            .help("Close")
            .accessibilityLabel("Close")
            Spacer()
            if hasTracks {
                Menu {
                    if coordinator.audioTracks.count > 1 {
                        Picker("Audio", selection: Binding(
                            get: { coordinator.selectedAudioIndex ?? -1 },
                            set: { coordinator.selectAudio($0) }
                        )) {
                            ForEach(coordinator.audioTracks, id: \.index) { stream in
                                if let index = stream.index {
                                    trackLabel(stream.title ?? stream.trackTitle, detail: TracksTab.detail(for: stream)).tag(index)
                                }
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    if !coordinator.subtitleTracks.isEmpty {
                        Picker("Subtitles", selection: Binding(
                            get: { coordinator.selectedSubtitleIndex },
                            set: { coordinator.selectSubtitle($0) }
                        )) {
                            Text("Off").tag(-1)
                            ForEach(coordinator.subtitleTracks, id: \.index) { stream in
                                if let index = stream.index {
                                    // The server can take a while to extract a track the first time.
                                    let loading = coordinator.selectedSubtitleIndex == index && coordinator.isLoadingSubtitles
                                    let detail = TracksTab.detail(for: stream)
                                    trackLabel(stream.title ?? stream.trackTitle, detail: loading ? [detail, "Loading…"].compactMap { $0 }.joined(separator: " · ") : detail).tag(index)
                                }
                            }
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                        .font(.headline)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Audio and Subtitles")
                .accessibilityLabel("Audio and Subtitles")
            }
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
        .tint(.white)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(.easeInOut(duration: 0.2), value: shown)
    }

    /// A track's name with its details as the menu item's second line.
    private func trackLabel(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            if let detail {
                Text(detail)
            }
        }
    }
}
#endif

#if !os(tvOS)
/// Skip Intro / Skip Credits and Play Next Episode on a touch screen: pills in
/// the lower right, above the system player's controls, shown only while they
/// apply. The same actions the tvOS player offers as contextual actions.
private struct TouchPlayerActions: View {
    let coordinator: PlaybackCoordinator

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let segment = coordinator.activeSegment {
                pill(segment.skipTitle, systemImage: "forward.fill") {
                    coordinator.skipActiveSegment()
                }
            }
            if coordinator.showsUpNextAction {
                pill("Play Next Episode", systemImage: "forward.end.fill") {
                    coordinator.playUpNextNow()
                }
            }
        }
        // Clear of the transport bar along the bottom.
        .padding(.trailing, 24)
        .padding(.bottom, 96)
        .animation(.easeInOut(duration: 0.25), value: coordinator.activeSegment != nil)
        .animation(.easeInOut(duration: 0.25), value: coordinator.showsUpNextAction)
    }

    private func pill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.white)
        .foregroundStyle(.black)
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}
#endif

/// Covers the player while an item loads: the season's backdrop (or the
/// series' when the season has none) with the show's logo and a spinner.
/// Never focusable, so the remote still reaches the player underneath.
struct PlaybackLoadingView: View {
    let item: BaseItem?

    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
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
            artwork = await Self.artwork(for: item, client: client, width: Lockup.fullScreenImageWidth(displayScale: displayScale))
        }
    }

    /// An episode's season backdrop when it has its own, else the series'
    /// (episodes inherit that one); anything else uses its own backdrop.
    private static func artwork(for item: BaseItem, client: JellyfinClient, width: Int) async -> URL? {
        if item.kind == .episode, let seasonId = item.seasonId,
           let season = try? await client.item(seasonId),
           let tag = season.backdropImageTags?.first {
            return client.imageURL(itemId: season.id, kind: .backdrop, tag: tag, index: 0, maxWidth: width)
        }
        return client.backdropURL(for: item, width: width)
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
                #if !os(macOS)
                item.externalMetadata = Self.metadata(for: playback)
                #endif
                player.replaceCurrentItem(with: item)
                // Full volume, unlike the quiet theme behind title pages.
                player.volume = 1
                player.play()
                #if !os(macOS)
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
                #endif
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

    #if !os(macOS)
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
    #endif
}

#if os(macOS)
/// Mac: the player takes the whole screen, as a video app's does, and gives
/// it back as it closes; a window already full screen stays so. Off in
/// Settings > Playback.
private struct FullScreenWhilePlaying: ViewModifier {
    @AppStorage(AppSettings.fullScreenPlaybackKey) private var enabled = true
    /// The window put into full screen for this video, to take back out.
    @State private var enteredWindow: NSWindow?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard enabled, let window = NSApp.keyWindow ?? NSApp.mainWindow,
                      !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
                enteredWindow = window
            }
            .onDisappear {
                guard let window = enteredWindow else { return }
                enteredWindow = nil
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
    }
}
#endif

#if os(macOS)
/// AVPlayerView hosted in SwiftUI: the Mac's own floating controls, which
/// show as the pointer moves, with chapters and a full-screen button.
struct SystemPlayer: NSViewRepresentable {
    let player: AVPlayer
    var showsPlaybackControls = true

    /// Hands the player over again once the view is in its window. Given it
    /// while still unsized and off-window, the view sometimes showed only
    /// black though the video played underneath.
    final class WindowedPlayerView: AVPlayerView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let current = player else { return }
            player = nil
            player = current
        }
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = WindowedPlayerView()
        view.player = player
        view.allowsPictureInPicturePlayback = false
        view.showsFullScreenToggleButton = true
        view.controlsStyle = showsPlaybackControls ? .floating : .none
        return view
    }

    /// Lets go of the player as this view goes away, as on the other platforms.
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        #if DEBUG
        let frame = view.frame
        let hidden = view.isHidden
        let window = view.window != nil
        Task { @MainActor [player] in
            try? await Task.sleep(for: .seconds(3))
            sidebarDebugLog.notice("player view frame=\(String(describing: frame), privacy: .public) hidden=\(hidden) inWindow=\(window) status=\(player.currentItem?.status.rawValue ?? -1) rate=\(player.rate) size=\(String(describing: player.currentItem?.presentationSize), privacy: .public) superviews=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public)")
        }
        #endif
        if view.player !== player {
            view.player = player
        }
        let style: AVPlayerViewControlsStyle = showsPlaybackControls ? .floating : .none
        if view.controlsStyle != style {
            view.controlsStyle = style
        }
    }
}
#else
/// AVPlayerViewController hosted in SwiftUI. The system UI supplies native
/// transport controls, info panel, chapters, audio options, and subtitles.
struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var contextualActions: [UIAction] = []
    var showsPlaybackControls = true
    /// A channel's timeline: no seeking or skipping in the system controls.
    var requiresLinearPlayback = false
    /// Extra tabs for the swipe-down info panel.
    var infoTabs: [UIViewController] = []
    /// A tap on the video, which shows or hides the system controls (iOS).
    var onTap: (() -> Void)?

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?

        private var lastReport = Date.distantPast

        /// A tap, or the pointer moving over the video; hover fires
        /// constantly, so this passes on at most a couple a second.
        @objc func tapped() {
            guard Date().timeIntervalSince(lastReport) > 0.5 else { return }
            lastReport = Date()
            onTap?()
        }

        /// Watches taps without taking them from the system player.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        #if os(tvOS)
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        #else
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        controller.view.addGestureRecognizer(tap)
        // With a pointer (iPad trackpad, Mac), the controls show on hover.
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        hover.delegate = context.coordinator
        controller.view.addGestureRecognizer(hover)
        #endif
        return controller
    }

    /// Lets go of the player as this view goes away, so playback that carries
    /// on elsewhere (the Live TV mini player) isn't still tied to a closed
    /// full-screen controller.
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player = nil
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        if controller.showsPlaybackControls != showsPlaybackControls {
            controller.showsPlaybackControls = showsPlaybackControls
        }
        if controller.requiresLinearPlayback != requiresLinearPlayback {
            controller.requiresLinearPlayback = requiresLinearPlayback
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
        #else
        context.coordinator.onTap = onTap
        #endif
    }
}
#endif

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

    #if canImport(UIKit)
    /// Hosts the tab for `AVPlayerViewController.customInfoViewControllers`.
    static func makeController(_ kind: Kind, for coordinator: PlaybackCoordinator) -> UIViewController {
        let host = UIHostingController(rootView: TracksTab(kind: kind, coordinator: coordinator))
        host.title = kind.title
        host.preferredContentSize = CGSize(width: 1920, height: 220)
        host.view.backgroundColor = .clear
        return host
    }
    #endif

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
                        trackButton(title: stream.title ?? stream.trackTitle, detail: Self.detail(for: stream), index: index)
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
    static func detail(for stream: MediaStream) -> String? {
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
