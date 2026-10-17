//
//  AetherTVControls.swift
//  AsterFIN
//
//  The Apple TV controls for AetherEngine playback, worked like the system
//  player's:
//  - Click (or Play/Pause) pauses and plays; the timeline shows while paused
//    and for a few seconds after any press.
//  - Paused, a swipe across the touch surface moves the playhead freely and a
//    click plays from there; Menu puts it back. Left and right clicks jump
//    10 seconds.
//  - Paused, the title's logo shows in the top left and its details above
//    the timeline.
//  - A swipe or click down opens the panel: Chapters, Audio, Subtitles and
//    Quality, the choices below them. It closes on Menu, or after a while left alone.
//  - On a Live TV channel or a Channels-tab channel, Up opens the channel
//    row (`ChannelFlickBar`): left and right go round the channels, a click
//    changes to the one picked, Down or Menu closes it.
//  - Menu always backs out one step: scrub, panel, controls, then the player.
//
//  Focus never goes missing: one invisible view holds it while the panel is
//  closed and the panel's buttons hold it while it's open, all in one focus
//  state, and if it ever ends up on nothing it's put back. Back steps back
//  through the controls, from the remote or a keyboard's Esc.
//

#if canImport(AetherEngine) && os(tvOS)
import AetherEngine
import SwiftUI
import UIKit

struct AetherTVControls: View {
    let playback: AetherPlayback
    @ObservedObject var engine: AetherEngine
    /// True while an alert is up, which takes focus on purpose.
    var isSuspended: Bool
    var onFinished: () -> Void

    @Environment(AppSession.self) private var session

    private enum Mode: Hashable {
        case hidden, transport, panel, channels
    }

    private enum Tab: Hashable {
        case chapters, audio, subtitles, quality

        var title: String {
            switch self {
            case .chapters: "Chapters"
            case .audio: "Audio"
            case .subtitles: "Subtitles"
            case .quality: "Quality"
            }
        }
    }

    private enum Focus: Hashable {
        /// The invisible view that takes the remote while the panel is closed.
        case surface
        case tab(Tab)
        case chapter(Int)
        case option(Tab, Int)
    }

    /// What restarts the fade: any press, and the state that holds it off.
    private struct FadeKey: Equatable {
        var mode: Mode
        var activity: Int
        var scrubbing: Bool
        var playing: Bool
    }

    /// The screen, in points, for turning a swipe into a fraction of it.
    private static let screen = CGSize(width: 1920, height: 1080)

    @State private var mode: Mode = .transport
    @State private var tab: Tab = .audio
    /// Where a swipe has moved the playhead, before a click plays from there.
    @State private var scrubTarget: Double?
    /// The position the current swipe started from; nil between swipes.
    @State private var scrubFrom: Double?
    /// Counts presses and moves, so each one restarts the fade.
    @State private var activity = 0
    /// The channel row, while it's open (or last open).
    @State private var flick: ChannelFlickModel?
    @FocusState private var focus: Focus?

    private var tabs: [Tab] {
        var tabs: [Tab] = []
        if !chapters.isEmpty { tabs.append(.chapters) }
        if !playback.audioChoices.isEmpty { tabs.append(.audio) }
        if !playback.subtitleChoices.isEmpty { tabs.append(.subtitles) }
        tabs.append(.quality)
        return tabs
    }

    var body: some View {
        ZStack {
            RemoteSwipeCatcher(isEnabled: mode != .panel && mode != .channels) { moved, ended in swiped(moved, ended: ended) }
                .allowsHitTesting(false)
            surface
            layout
                .opacity(mode == .hidden || mode == .channels ? 0 : 1)
            if mode == .channels, let flick {
                ChannelFlickBar(model: flick)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            if showsSkip, let action = skipAction {
                // A click takes it, as with the system player's Skip Intro;
                // Play/Pause still pauses.
                PanelPill(title: action.title, systemImage: action.systemImage, focused: true, current: false)
                    .padding(.trailing, 90)
                    .padding(.bottom, 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsSkip ? skipAction?.title : nil)
        .animation(.easeInOut(duration: 0.25), value: mode)
        .defaultFocus($focus, .surface)
        .onAppear { focus = .surface }
        .task(id: FadeKey(mode: mode, activity: activity, scrubbing: scrubTarget != nil, playing: engine.state == .playing)) {
            await fadeWhenIdle()
        }
        .onChange(of: focus) { _, now in
            #if DEBUG
            print("DEBUG tv controls: focus \(String(describing: now)) mode \(mode)")
            #endif
            if case .tab(let focused) = now { tab = focused }
            if now == nil {
                restoreFocusSoon()
            } else if mode == .panel {
                activity += 1
            }
        }
        .onPlayPauseCommand { playPause() }
        .onExitCommand { back() }
        .onKeyPress(.escape) {
            // A keyboard's Esc (the Mac's, in the Simulator) is Back too. Not
            // taken here, it goes to the full-screen cover's own Esc shortcut,
            // which closes the player without asking.
            back()
            return .handled
        }
    }

    // MARK: Remote

    /// Holds focus while the panel is closed and takes every press and swipe.
    private var surface: some View {
        Color.black.opacity(0.001)
            .ignoresSafeArea()
            .focusable(mode != .panel)
            .focused($focus, equals: .surface)
            .focusEffectDisabled()
            .onTapGesture { select() }
            .onMoveCommand { direction in
                if mode == .channels {
                    switch direction {
                    case .left: flickMove(-1)
                    case .right: flickMove(1)
                    case .down: closeChannels()
                    default: activity += 1
                    }
                    return
                }
                switch direction {
                case .left: jump(-10)
                case .right: jump(10)
                case .up: if playsChannels { openChannels() } else { show() }
                case .down: openPanel()
                @unknown default: show()
                }
            }
    }

    /// Skip Intro / Skip Credits, or Play Next Episode near the end, while one
    /// applies.
    private var skipAction: (title: String, systemImage: String, perform: () -> Void)? {
        if let segment = playback.activeSegment {
            return (segment.skipTitle, "forward.fill", { playback.skipActiveSegment() })
        }
        if playback.showsUpNextAction {
            return ("Play Next Episode", "forward.end.fill", { playback.playUpNextNow() })
        }
        return nil
    }

    /// The skip shows for its first 5 seconds, then again whenever the
    /// controls are up; never over the panel.
    private var showsSkip: Bool {
        skipAction != nil && mode != .panel && mode != .channels && (playback.skipOfferIsFresh || mode == .transport)
    }

    /// A click: changes channel in the channel row, plays from a scrub,
    /// takes the skip on screen, or pauses.
    private func select() {
        if mode == .channels {
            changeChannel()
            return
        }
        if scrubTarget == nil, showsSkip, let action = skipAction {
            action.perform()
            return
        }
        playPause()
    }

    private func playPause() {
        if let target = scrubTarget {
            play(from: target)
        } else {
            engine.togglePlayPause()
            show()
        }
    }

    /// Menu: one step back at a time.
    private func back() {
        if mode == .channels {
            closeChannels()
        } else if mode == .panel {
            closePanel()
        } else if scrubTarget != nil {
            scrubTarget = nil
            show()
        } else if mode == .transport {
            mode = .hidden
        } else {
            onFinished()
        }
    }

    private func swiped(_ moved: CGSize, ended: Bool) {
        guard mode != .panel, mode != .channels else { return }
        let x = moved.width / Self.screen.width
        let y = moved.height / Self.screen.height
        if scrubFrom == nil {
            scrubFrom = scrubTarget ?? engine.clock.currentTime
            show()
        }
        // Scrubbing is for a paused picture, as in the system player; while
        // playing a swipe only shows the timeline.
        if !playback.isLive, engine.state == .paused, abs(x) > abs(y), engine.duration > 0, let from = scrubFrom {
            // A swipe across the whole surface covers a quarter of the video,
            // kept between 2 and 15 minutes.
            let span = min(max(engine.duration / 4, 120), 900)
            scrubTarget = clamped(from + x * span)
        }
        if ended {
            scrubFrom = nil
            if y > 0.12, y > abs(x) * 1.5 { openPanel() }
        }
    }

    private func jump(_ seconds: Double) {
        // A live channel has nothing to skip through.
        guard !playback.isLive else {
            show()
            return
        }
        if let target = scrubTarget {
            scrubTarget = clamped(target + seconds)
        } else {
            AetherPlayerView.skip(seconds, on: engine)
        }
        show()
    }

    private func play(from target: Double) {
        show()
        Task {
            await engine.seek(to: target)
            engine.play()
            // Held until the seek lands, so the playhead doesn't jump back.
            scrubTarget = nil
        }
    }

    private func clamped(_ seconds: Double) -> Double {
        min(max(seconds, 0), max(engine.duration - 1, 0))
    }

    private func show() {
        if mode == .hidden { mode = .transport }
        activity += 1
    }

    private func openPanel() {
        scrubTarget = nil
        scrubFrom = nil
        guard let first = tabs.first else { return }
        if !tabs.contains(tab) { tab = first }
        mode = .panel
        focus = .tab(tab)
    }

    private func closePanel() {
        mode = .transport
        activity += 1
        refocusSurface()
    }

    /// The surface can only take focus once it's focusable again, after
    /// this change has gone through.
    private func refocusSurface() {
        Task {
            await Task.yield()
            focus = .surface
        }
    }

    /// The timeline fades 5 seconds after the last press while playing; the
    /// panel closes after 8 seconds left alone. A paused picture keeps its
    /// timeline, as the system player does.
    private func fadeWhenIdle() async {
        switch mode {
        case .hidden:
            return
        case .transport:
            guard scrubTarget == nil, engine.state == .playing else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { mode = .hidden }
        case .panel:
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            mode = engine.state == .playing ? .hidden : .transport
            refocusSurface()
        case .channels:
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { closeChannels() }
        }
    }

    // MARK: Channels

    /// Playing a Live TV channel or one of the Channels tab's, which Up
    /// flicks through.
    private var playsChannels: Bool {
        playback.liveChannelId != nil || playback.channelId != nil
    }

    private func openChannels() {
        guard let client = session.client,
              let model = ChannelFlickModel(currentLiveChannel: playback.liveChannelId, currentChannel: playback.channelId, client: client) else {
            show()
            return
        }
        scrubTarget = nil
        scrubFrom = nil
        flick = model
        mode = .channels
        activity += 1
        Task { await model.refresh(client: client) }
    }

    private func flickMove(_ step: Int) {
        flick?.move(by: step)
        activity += 1
    }

    /// Changes to the picked channel, or just closes on the one playing.
    private func changeChannel() {
        if let flick, let picked = flick.selectedChannel, picked.id != flick.currentId {
            playback.switchChannel(to: picked.id)
        }
        closeChannels()
    }

    private func closeChannels() {
        guard mode == .channels else { return }
        mode = .hidden
    }

    /// Focus on nothing (a view it was on went away): put it back where the
    /// controls expect it, once the change has settled.
    private func restoreFocusSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard focus == nil, !isSuspended else { return }
            if mode == .panel, let first = tabs.first {
                focus = .tab(tabs.contains(tab) ? tab : first)
            } else {
                focus = .surface
            }
        }
    }

    // MARK: Layout

    /// Paused, the picture gets the title's logo and its details, as a
    /// streaming service's player does; the panel takes the room when open.
    private var showsPauseInfo: Bool {
        engine.state == .paused && mode != .panel
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 28) {
            if showsPauseInfo {
                logo
                    .transition(.opacity)
            }
            Spacer()
            if mode == .panel {
                // As in the system player: the tabs above their choices, the
                // timeline away while they're up.
                tabRow
                panelCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                if showsPauseInfo {
                    pauseInfo
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    titleBlock
                }
                if playback.isLive {
                    LiveBadge()
                } else {
                    AetherTimeline(engine: engine, clock: engine.clock, scrubTarget: scrubTarget, preview: playback.scrubPreview(at:))
                }
                tabRow
            }
        }
        .padding(EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .animation(.easeInOut(duration: 0.35), value: showsPauseInfo)
        .background {
            ZStack {
                // Darkens the foot of the picture so white text reads over it,
                // further up while paused or in the panel.
                LinearGradient(colors: [.clear, .black.opacity(mode == .panel || showsPauseInfo ? 0.9 : 0.65)], startPoint: mode == .panel || showsPauseInfo ? UnitPoint(x: 0.5, y: 0.25) : .center, endPoint: .bottom)
                if showsPauseInfo {
                    // And the top, behind the logo.
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: showsPauseInfo)
        }
        .foregroundStyle(.white)
    }

    /// The title's clear logo in the top left (see `AetherPauseLogo`).
    @ViewBuilder
    private var logo: some View {
        if let item = playback.item {
            AetherPauseLogo(item: item)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The paused title's details (see `AetherPauseDetails`).
    @ViewBuilder
    private var pauseInfo: some View {
        if let item = playback.item {
            AetherPauseDetails(item: item, engine: engine)
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let item = playback.item {
            VStack(alignment: .leading, spacing: 6) {
                if let line = episodeLine(for: item) {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Text(item.kind == .episode ? (item.seriesName ?? item.displayTitle) : item.displayTitle)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
            }
        }
    }

    /// "S1, E2 · The Academy's Top Dogs" for an episode.
    private func episodeLine(for item: BaseItem) -> String? {
        guard item.kind == .episode else { return nil }
        var parts: [String] = []
        if let season = item.parentIndexNumber, let episode = item.indexNumber {
            parts.append("S\(season), E\(episode)")
        }
        parts.append(item.displayTitle)
        return parts.joined(separator: " · ")
    }

    /// The tabs. Labels until the panel opens; only then buttons, so they
    /// never take focus from the surface.
    private var tabRow: some View {
        HStack(spacing: 16) {
            ForEach(tabs, id: \.self) { item in
                if mode == .panel {
                    Button {
                        // Click a tab to go down into it.
                        if let first = firstOption(in: item) { focus = first }
                    } label: {
                        PanelPill(title: item.title, focused: focus == .tab(item), current: tab == item)
                    }
                    .buttonStyle(PanelPillStyle())
                    .focused($focus, equals: .tab(item))
                } else {
                    PanelPill(title: item.title, focused: false, current: false)
                }
            }
        }
        // The full width, so up from anywhere below finds the tabs, not only
        // from right under one.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// The tab's content under the tabs, straight on the darkened picture
    /// like the pills; one height for every tab so moving between them
    /// doesn't jolt the layout.
    private var panelCard: some View {
        Group {
            switch tab {
            case .chapters:
                chapterRow
            case .audio:
                optionRow(.audio, options: playback.audioChoices.map { ($0.id, $0.title) }, selected: playback.currentAudio) { id in
                    playback.selectAudio(id)
                }
            case .subtitles:
                optionRow(.subtitles, options: [(-1, "Off")] + playback.subtitleChoices.map { ($0.id, $0.title) }, selected: playback.currentSubtitle) { id in
                    playback.selectSubtitle(id >= 0 ? id : nil)
                }
            case .quality:
                // A cap has the server convert the file down to it; the
                // engine plays on from the same spot.
                optionRow(.quality, options: playback.qualityChoices.map { ($0.id, $0.title) }, selected: playback.currentQuality) { cap in
                    playback.chooseQuality(cap)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.cardContentHeight, maxHeight: Self.cardContentHeight, alignment: .topLeading)
        // Down from any tab lands in here, wherever its buttons sit: From
        // Beginning is far to the right of the Info tab.
        .focusSection()
    }

    private static let cardContentHeight: CGFloat = 250

    // MARK: Chapters

    /// The item's chapters, when there are enough to be worth choosing from.
    private var chapters: [ChapterInfo] {
        let all = playback.item?.chapters ?? []
        return all.count > 1 ? all.sorted { $0.startPositionTicks < $1.startPositionTicks } : []
    }

    /// The chapter the playhead is in.
    private var currentChapter: Int {
        let now = engine.clock.currentTime
        return chapters.lastIndex { Double($0.startPositionTicks) / 10_000_000 <= now } ?? 0
    }

    private var chapterRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 28) {
                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        play(chapter)
                    } label: {
                        ChapterCard(
                            title: chapter.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(index + 1)",
                            time: AetherTimeline.time(Double(chapter.startPositionTicks) / 10_000_000),
                            image: chapterImage(chapter, index: index),
                            focused: focus == .chapter(index),
                            current: index == currentChapter
                        )
                    }
                    .buttonStyle(PanelPillStyle())
                    .focused($focus, equals: .chapter(index))
                    .onMoveCommand(perform: upToTabs)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func chapterImage(_ chapter: ChapterInfo, index: Int) -> URL? {
        guard let item = playback.item, let tag = chapter.imageTag else { return nil }
        return session.client?.chapterImageURL(itemId: item.id, index: index, tag: tag)
    }

    private func play(_ chapter: ChapterInfo) {
        closePanel()
        Task {
            await engine.seek(to: Double(chapter.startPositionTicks) / 10_000_000)
            engine.play()
        }
    }

    // MARK: Tracks

    /// The choices for a tab in a row; picking one leaves the panel open.
    private func optionRow(_ tab: Tab, options: [(id: Int, title: String)], selected: Int?, choose: @escaping (Int) -> Void) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(options, id: \.id) { option in
                    Button {
                        choose(option.id)
                        activity += 1
                    } label: {
                        PanelPill(title: option.title, focused: focus == .option(tab, option.id), current: false, checked: selected == option.id)
                    }
                    .buttonStyle(PanelPillStyle())
                    .focused($focus, equals: .option(tab, option.id))
                    .onMoveCommand(perform: upToTabs)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    /// Up from a tab's content goes back to its tab, wherever the content
    /// sits: the focus engine looks only straight up, and From Beginning is
    /// far to the right of the Info tab.
    private func upToTabs(_ direction: MoveCommandDirection) {
        if direction == .up { focus = .tab(tab) }
    }

    private func firstOption(in tab: Tab) -> Focus? {
        switch tab {
        case .chapters: chapters.isEmpty ? nil : .chapter(currentChapter)
        case .audio: playback.currentAudio.map { .option(.audio, $0) } ?? playback.audioChoices.first.map { .option(.audio, $0.id) }
        case .subtitles: .option(.subtitles, playback.currentSubtitle)
        case .quality: .option(.quality, playback.currentQuality)
        }
    }
}

// MARK: - Chapter cards

/// A chapter's frame, name and start time.
private struct ChapterCard: View {
    let title: String
    let time: String
    let image: URL?
    let focused: Bool
    /// The chapter playing now.
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: image, systemImage: "film")
                .frame(width: 304, height: 171)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(focused ? 0.9 : current ? 0.35 : 0), lineWidth: 4)
                }
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: 304, alignment: .leading)
        .scaleEffect(focused ? 1.05 : 1, anchor: .bottom)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - Pills

/// A tab or a choice in the panel: frosted glass, lit up softly when in
/// focus so the picture still shows through.
private struct PanelPill: View {
    let title: String
    var systemImage: String? = nil
    let focused: Bool
    /// The tab whose choices are showing, while focus is up among them.
    var current: Bool
    var checked = false

    var body: some View {
        HStack(spacing: 10) {
            if checked {
                Image(systemName: "checkmark")
                    .font(.callout.weight(.bold))
            }
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .foregroundStyle(focused ? .black : .white)
        .background {
            if focused {
                Capsule().fill(.white.opacity(0.8))
            } else {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(.white.opacity(current ? 0.18 : 0)))
            }
        }
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - Swipes

/// Swipes on the remote's touch surface, which SwiftUI can't see on tvOS.
/// The recognizer goes on the window, so it hears every swipe whichever view
/// has focus; this view itself never takes focus, which stays with SwiftUI.
/// Off while `isEnabled` is false, so the panel's buttons swipe as usual.
private struct RemoteSwipeCatcher: UIViewRepresentable {
    var isEnabled: Bool
    /// How far the swipe has moved, and whether it has ended.
    var onSwipe: (CGSize, Bool) -> Void

    func makeUIView(context: Context) -> SwipeCatcherView {
        let view = SwipeCatcherView()
        view.isUserInteractionEnabled = false
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: SwipeCatcherView, context: Context) {
        view.onSwipe = onSwipe
        view.pan.isEnabled = isEnabled
    }

    static func dismantleUIView(_ view: SwipeCatcherView, coordinator: ()) {
        view.pan.view?.removeGestureRecognizer(view.pan)
    }
}

private final class SwipeCatcherView: UIView {
    let pan = UIPanGestureRecognizer()
    var onSwipe: ((CGSize, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.cancelsTouchesInView = false
        pan.addTarget(self, action: #selector(panned(_:)))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        pan.view?.removeGestureRecognizer(pan)
        window?.addGestureRecognizer(pan)
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let moved = recognizer.translation(in: recognizer.view)
        let size = CGSize(width: moved.x, height: moved.y)
        switch recognizer.state {
        case .began, .changed: onSwipe?(size, false)
        case .ended, .cancelled: onSwipe?(size, true)
        default: break
        }
    }
}

/// No system focus effect: the pill draws its own.
private struct PanelPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
#endif
