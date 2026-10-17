//
//  AetherPlayerView.swift
//  AsterFIN
//
//  The full-screen player for AetherEngine playback. The engine only draws
//  the picture, so the controls are the app's own: on Apple TV laid out and
//  driven like the system player's (see `AetherTVControls`), on iPhone, iPad
//  and the Mac a tap or click away. Subtitles, text and picture-based (PGS,
//  DVD), are drawn over the video from the engine's cues.
//

#if canImport(AetherEngine)
import AetherEngine
import AVKit
import SwiftUI

struct AetherPlayerView: View {
    let playback: AetherPlayback
    var onFinished: () -> Void

    @ObservedObject private var engine: AetherEngine
    #if !os(tvOS)
    /// When the controls were last called up; nil while they're hidden.
    @State private var controlsShownAt: Date? = Date()
    /// The picture fills the screen, cropping the edges, rather than fitting.
    @State private var fills = false
    /// A double-tap skip just made: which way, shown briefly over its side.
    @State private var skipFlash: SkipFlash?
    #endif

    init(playback: AetherPlayback, onFinished: @escaping () -> Void) {
        self.playback = playback
        self.onFinished = onFinished
        _engine = ObservedObject(wrappedValue: playback.engine)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AetherPlayerSurface(engine: engine)
                .ignoresSafeArea()
            if let track = playback.assTrack {
                AssSubtitleOverlay(track: track, videoSize: CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight)))
            } else if playback.isConverted {
                // A converted stream carries no subtitles; the app draws them.
                SubtitleOverlayView(text: playback.subtitleText)
                    .allowsHitTesting(false)
            } else if !playback.isLoadingStyledSubtitles {
                AetherSubtitleLayer(engine: engine, clock: engine.clock)
                    .allowsHitTesting(false)
            }
            // Under the controls, so they draw over it.
            if playback.hasStarted, !playback.endCardVisible {
                ChannelBug(channelId: playback.channelId, videoAspect: videoAspect, playingId: playback.item?.id)
            }
            // An anime episode's opening or ending gets its song card, as it
            // does in the system player.
            if playback.hasStarted, !playback.endCardVisible {
                ForEach(playback.themeMoments) { moment in
                    ThemeInfoOverlay(currentTime: { engine.clock.currentTime }, range: moment.range, info: moment.info)
                }
            }
            // The Up Next card takes the screen (and the remote) on its own.
            if !playback.endCardVisible {
                #if os(tvOS)
                AetherTVControls(playback: playback, engine: engine, isSuspended: errorMessage != nil || playback.qualityOfferVisible, onFinished: onFinished)
                #else
                touchControls
                skipButton
                #endif
            }

            // Changing channel: the one playing carries on until the next is
            // ready, and says so; or says the next one couldn't be tuned.
            if let note = playback.tuningName.map({ "Tuning \($0)…" }) ?? playback.tuneMessage {
                HStack(spacing: 12) {
                    if playback.tuningName != nil { ProgressView() }
                    Text(note)
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.white)
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if playback.qualityOfferVisible, !playback.endCardVisible {
                StallQualityCard(playback: playback)
                    .transition(.opacity)
            }

            if !playback.hasStarted, playback.errorMessage == nil {
                PlaybackLoadingView(item: playback.item)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if playback.endCardVisible, let next = playback.upNext {
                UpNextCard(episode: next, countdown: playback.countdown) {
                    playback.playUpNextNow()
                } dismiss: {
                    playback.dismissEndCard()
                    onFinished()
                }
                .transition(.opacity)
            }
        }
        #if !os(tvOS)
        // The engine is shared between videos: each one starts fitted.
        .onAppear { engine.videoGravity = .resizeAspect }
        #endif
        .animation(.easeInOut(duration: 0.6), value: playback.hasStarted)
        .animation(.easeInOut(duration: 0.3), value: playback.endCardVisible)
        .animation(.easeInOut(duration: 0.3), value: playback.qualityOfferVisible)
        .animation(.easeInOut(duration: 0.25), value: playback.tuningName ?? playback.tuneMessage)
        .onChange(of: engine.state) { _, state in
            // The end of an episode with one after it holds on Up Next;
            // anything else closes the player.
            if state == .ended, !playback.playbackEnded() { onFinished() }
            // Paused on a Live TV channel: what's on it now, for the pause screen.
            if state == .paused { playback.refreshLiveProgram() }
            // Given up partway: the system player carries on from here.
            if case .error(let message) = state { playback.fallBack(message) }
        }
        .alert("Can't Play", isPresented: Binding(get: { errorMessage != nil }, set: { _ in })) {
            Button("OK", action: onFinished)
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// The picture's shape as shown: its size, with any non-square pixels
    /// (a DVD's) accounted for; nil until it's known.
    private var videoAspect: CGFloat? {
        guard engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 else { return nil }
        return CGFloat(engine.sourceVideoWidth) * CGFloat(engine.sourceVideoPixelAspectRatio) / CGFloat(engine.sourceVideoHeight)
    }

    /// The load failing, or the engine giving up partway, when there's no
    /// system player to hand over to.
    private var errorMessage: String? {
        if let message = playback.errorMessage { return message }
        if case .error(let message) = engine.state, !playback.handsOverOnFailure { return message }
        return nil
    }

    /// "English · DTS 5.1", "Japanese · PGS (Forced)".
    static func label(for track: TrackInfo) -> String {
        let language = track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        var parts = [track.name.isEmpty ? (language ?? "Track \(track.id)") : track.name]
        if !track.name.isEmpty, let language, !track.name.localizedCaseInsensitiveContains(language) {
            parts.append(language)
        }
        var format = track.isAtmos ? "Atmos" : track.codec.uppercased()
        switch track.channels {
        case 6: format += " 5.1"
        case 8: format += " 7.1"
        case 2: format += " Stereo"
        default: break
        }
        parts.append(format)
        var text = parts.joined(separator: " · ")
        if track.isForced { text += " (Forced)" }
        if track.isHearingImpaired { text += " (SDH)" }
        return text
    }

    /// Jumps from where the last jump was headed, so presses in a row add up.
    static func skip(_ seconds: Double, on engine: AetherEngine) {
        let from = engine.seekTarget ?? engine.clock.currentTime
        let to = min(max(from + seconds, 0), max(engine.duration - 1, 0))
        Task { await engine.seek(to: to) }
    }

    // MARK: iPhone, iPad and Mac

    #if !os(tvOS)
    private var isPlaying: Bool { engine.state == .playing }

    /// The controls stay up while paused, as the system player's do.
    private var controlsShown: Bool {
        controlsShownAt != nil || engine.state == .paused
    }

    private var touchControls: some View {
        ZStack {
            // A tap or click on the picture shows or hides the controls. On
            // iPhone and iPad a double-tap on either side skips 10 seconds,
            // and a pinch fills the screen or fits the picture again.
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    #if os(iOS)
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in
                                // A live channel has nothing to skip through.
                                guard !playback.isLive else { return }
                                let forward = value.location.x > proxy.size.width / 2
                                Self.skip(forward ? 10 : -10, on: engine)
                                skipFlash = SkipFlash(forward: forward)
                            }
                            .exclusively(before: TapGesture().onEnded { toggleControls() })
                    )
                    .simultaneousGesture(
                        MagnifyGesture().onEnded { value in
                            if value.magnification > 1.1 { setFills(true) }
                            if value.magnification < 0.9 { setFills(false) }
                        }
                    )
                    #else
                    .onTapGesture { toggleControls() }
                    #endif
            }
            .ignoresSafeArea()
            #if os(iOS)
            if let skipFlash {
                SkipFlashView(flash: skipFlash)
                    .id(skipFlash.id)
                    .allowsHitTesting(false)
                    .task(id: skipFlash.id) {
                        try? await Task.sleep(for: .milliseconds(700))
                        if self.skipFlash?.id == skipFlash.id { self.skipFlash = nil }
                    }
            }
            #endif
            controlsLayout
                .opacity(controlsShown ? 1 : 0)
                .disabled(!controlsShown)
                .animation(.easeInOut(duration: 0.25), value: controlsShown)
        }
        .task(id: controlsShownAt) {
            // The controls fade a few seconds after the last touch.
            guard controlsShownAt != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, isPlaying { controlsShownAt = nil }
        }
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { skip(-10); return .handled }
        .onKeyPress(.rightArrow) { skip(10); return .handled }
        .onKeyPress(.escape) { onFinished(); return .handled }
        #endif
    }

    private var controlsLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Button(action: onFinished) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
                if showsPauseInfo, let item = playback.item {
                    AetherPauseLogo(item: item)
                        .padding(.leading, 8)
                        .transition(.opacity)
                } else {
                    titleBlock
                }
                Spacer()
            }
            Spacer()
            centerButtons
                .frame(maxWidth: .infinity)
            Spacer()
            if showsPauseInfo, let item = playback.item {
                AetherPauseDetails(item: item, engine: engine, program: playback.liveProgram)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if playback.isLive {
                LiveBadge()
            } else {
                AetherTimeline(engine: engine, clock: engine.clock, onScrub: reveal, preview: playback.scrubPreview(at:))
            }
            HStack(spacing: 20) {
                RoutePicker()
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("AirPlay")
                #if os(iOS)
                Button { setFills(!fills); reveal() } label: {
                    Label(fills ? "Fit to Screen" : "Fill Screen", systemImage: fills ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                #endif
                Spacer()
                if !playback.isLive {
                    chapterMenu
                    speedMenu
                }
                trackMenus
            }
            #if os(iOS)
            // Icons only: an upright iPhone has no room for the words.
            .labelStyle(.iconOnly)
            .font(.title3)
            #endif
            .buttonStyle(.plain)
            .padding(.top, 16)
            #if os(iOS)
            if engine.airPlayPictureStaysLocal {
                Text("AirPlay is playing the sound only; this video's picture stays on this device.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 8)
            }
            #endif
        }
        .padding(edgePadding)
        .animation(.easeInOut(duration: 0.35), value: showsPauseInfo)
        .background {
            // Darkens the edges so white text reads over a bright picture,
            // more so while paused, under the logo and the details.
            LinearGradient(colors: [.black.opacity(showsPauseInfo ? 0.7 : 0.6), .clear, .clear, .black.opacity(showsPauseInfo ? 0.85 : 0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.35), value: showsPauseInfo)
        }
        .foregroundStyle(.white)
    }

    /// Mac: paused, the title's logo and details show, as on Apple TV.
    private var showsPauseInfo: Bool {
        #if os(macOS)
        engine.state == .paused
        #else
        false
        #endif
    }

    private var edgePadding: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 24, leading: 32, bottom: 24, trailing: 32)
        #else
        EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        #endif
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let item = playback.item {
            VStack(alignment: .leading, spacing: 4) {
                if item.kind == .episode, let series = item.seriesName {
                    Text(series)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(item.displayTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
            }
        }
    }

    private var centerButtons: some View {
        HStack(spacing: 48) {
            Button { skip(-10) } label: {
                Image(systemName: "gobackward.10")
            }
            .accessibilityLabel("Back 10 seconds")
            .opacity(playback.isLive ? 0 : 1)
            .disabled(playback.isLive)
            Button(action: togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Button { skip(10) } label: {
                Image(systemName: "goforward.10")
            }
            .accessibilityLabel("Forward 10 seconds")
            .opacity(playback.isLive ? 0 : 1)
            .disabled(playback.isLive)
        }
        .font(.system(size: 30))
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trackMenus: some View {
        if playback.audioChoices.count > 1 {
            Menu {
                Picker("Audio", selection: Binding(
                    get: { playback.currentAudio ?? -1 },
                    set: { playback.selectAudio($0); reveal() }
                )) {
                    ForEach(playback.audioChoices) { track in
                        Text(track.title).tag(track.id)
                    }
                }
            } label: {
                Label("Audio", systemImage: "speaker.wave.2")
            }
        }
        if !playback.subtitleChoices.isEmpty {
            Menu {
                Picker("Subtitles", selection: Binding(
                    get: { playback.currentSubtitle },
                    set: { playback.selectSubtitle($0 >= 0 ? $0 : nil); reveal() }
                )) {
                    Text("Off").tag(-1)
                    ForEach(playback.subtitleChoices) { track in
                        Text(track.title).tag(track.id)
                    }
                }
            } label: {
                Label("Subtitles", systemImage: "captions.bubble")
            }
        }
        if !playback.isLive {
        Menu {
            // A cap has the server convert the file down to it; AetherEngine
            // plays on from the same spot.
            Picker("Quality", selection: Binding(
                get: { playback.currentQuality },
                set: { playback.chooseQuality($0); reveal() }
            )) {
                ForEach(playback.qualityChoices) { choice in
                    Text(choice.title).tag(choice.id)
                }
            }
        } label: {
            Label("Quality", systemImage: "dial.medium")
        }
        }
    }

    /// Skip Intro / Skip Credits, or Play Next Episode near the end, in the
    /// lower right while one applies: for 5 seconds as it comes up, and
    /// again whenever the controls do.
    @ViewBuilder
    private var skipButton: some View {
        Group {
            // For its first 5 seconds, then again whenever the controls are up.
            if !(playback.skipOfferIsFresh || controlsShown) {
                EmptyView()
            } else if let segment = playback.activeSegment {
                Button {
                    playback.skipActiveSegment()
                } label: {
                    Label(segment.skipTitle, systemImage: "forward.fill")
                }
            } else if playback.showsUpNextAction {
                Button {
                    playback.playUpNextNow()
                } label: {
                    Label("Play Next Episode", systemImage: "forward.end.fill")
                }
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        // Clear of the timeline and track menus while they show.
        .padding(.trailing, edgePadding.trailing)
        .padding(.bottom, controlsShown ? 130 : edgePadding.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.25), value: playback.activeSegment?.id)
        .animation(.easeInOut(duration: 0.25), value: playback.showsUpNextAction)
        .animation(.easeInOut(duration: 0.25), value: controlsShown)
        .animation(.easeInOut(duration: 0.25), value: playback.skipOfferIsFresh)
    }

    private func reveal() {
        controlsShownAt = Date()
    }

    private func toggleControls() {
        controlsShownAt = controlsShownAt == nil ? Date() : nil
    }

    private func setFills(_ fill: Bool) {
        fills = fill
        engine.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    @ViewBuilder
    private var chapterMenu: some View {
        if !playback.chapters.isEmpty {
            Menu {
                ForEach(Array(playback.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        playback.play(chapter: chapter)
                        reveal()
                    } label: {
                        Text(chapter.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(index + 1)")
                        Text(AetherTimeline.time(Double(chapter.startPositionTicks) / 10_000_000))
                    }
                }
            } label: {
                Label("Chapters", systemImage: "list.bullet")
            }
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(
                get: { playback.speed },
                set: { playback.setSpeed($0); reveal() }
            )) {
                ForEach(AetherPlayback.speeds, id: \.self) { speed in
                    Text(Self.speedTitle(speed)).tag(speed)
                }
            }
        } label: {
            Label("Speed", systemImage: playback.speed == 1 ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.67percent")
        }
    }

    /// "1×", "1.25×".
    static func speedTitle(_ speed: Float) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func togglePlayPause() {
        engine.togglePlayPause()
        reveal()
    }

    private func skip(_ seconds: Double) {
        Self.skip(seconds, on: engine)
        reveal()
    }
    #endif
}

// MARK: - Timeline

/// The playhead and the times either side. Watches the engine's clock, which
/// ticks ten times a second, so only this redraws as the video plays.
struct AetherTimeline: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    /// Apple TV: where a swipe has moved the playhead to, not yet played from.
    var scrubTarget: Double? = nil
    var onScrub: () -> Void = {}
    /// The picture for a point on the timeline, shown above the playhead
    /// while scrubbing.
    var preview: ((Double) async -> CGImage?)? = nil

    /// Where a drag on the bar has got to, before it's let go.
    @State private var scrubPosition: Double?

    private var highlighted: Bool { scrubTarget != nil }
    private var duration: Double { max(engine.duration, 0) }
    private var position: Double { scrubTarget ?? scrubPosition ?? engine.seekTarget ?? clock.currentTime }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
                let buffered = duration > 0 ? min(max(clock.bufferedPosition / duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.35))
                        .frame(width: proxy.size.width * buffered)
                    Capsule().fill(.white)
                        .frame(width: proxy.size.width * fraction)
                }
                .frame(height: barHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .overlay(alignment: .bottomLeading) {
                    if let scrubbing = scrubTarget ?? scrubPosition {
                        let x = proxy.size.width * fraction - ScrubBubble.width / 2
                        ScrubBubble(seconds: scrubbing, preview: preview)
                            .frame(width: ScrubBubble.width)
                            .fixedSize(horizontal: false, vertical: true)
                            .alignmentGuide(.bottom) { _ in -16 }
                            .offset(x: min(max(x, 0), max(proxy.size.width - ScrubBubble.width, 0)))
                            .allowsHitTesting(false)
                    }
                }
                #if !os(tvOS)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            scrubPosition = min(max(value.location.x / proxy.size.width, 0), 1) * duration
                            onScrub()
                        }
                        .onEnded { _ in
                            guard let target = scrubPosition else { return }
                            Task {
                                await engine.seek(to: target)
                                scrubPosition = nil
                            }
                        }
                )
                #endif
            }
            .frame(height: touchHeight)
            .animation(.easeOut(duration: 0.15), value: highlighted)

            HStack {
                Text(Self.time(position))
                Spacer()
                Text("-" + Self.time(max(duration - position, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(Self.time(position)) of \(Self.time(duration))")
    }

    private var barHeight: CGFloat {
        #if os(tvOS)
        highlighted ? 14 : 8
        #else
        6
        #endif
    }

    private var touchHeight: CGFloat {
        #if os(tvOS)
        20
        #else
        24
        #endif
    }

    /// "4:05", or "1:04:05" past an hour.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: pattern))
    }
}

// MARK: - Subtitles

/// The cues under the playhead: text in the app's caption style, pictures
/// (PGS, DVB, DVD) placed where the disc put them on the frame.
private struct AetherSubtitleLayer: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        // Cues are timed on the source's clock, which is what sourceTime reads.
        let now = clock.sourceTime
        let showing = engine.subtitleCues.filter { $0.startTime <= now && now < $0.endTime }
        let text = showing.compactMap(\.text).joined(separator: "\n")
        ZStack {
            GeometryReader { proxy in
                let frame = videoFrame(in: proxy.size)
                ForEach(showing) { cue in
                    if case .image(let picture) = cue.body {
                        Image(decorative: picture.cgImage, scale: 1)
                            .resizable()
                            .frame(width: picture.position.width * frame.width, height: picture.position.height * frame.height)
                            .position(x: frame.minX + picture.position.midX * frame.width, y: frame.minY + picture.position.midY * frame.height)
                    }
                }
            }
            .ignoresSafeArea()
            SubtitleOverlayView(text: text.isEmpty ? nil : text)
        }
    }

    /// Where the picture sits on screen: the video's shape fitted inside.
    private func videoFrame(in size: CGSize) -> CGRect {
        let width = CGFloat(engine.sourceVideoWidth)
        let height = CGFloat(engine.sourceVideoHeight)
        guard width > 0, height > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / width, size.height / height)
        let fitted = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}
// MARK: - Stalling

/// Comes up when the original file keeps stalling: carry on, or play at a
/// lower quality, which the server converts down to fit the connection.
struct StallQualityCard: View {
    let playback: AetherPlayback

    #if os(tvOS)
    @FocusState private var focused: Int?
    #endif

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Playback Keeps Stopping")
                    .font(.title2.weight(.semibold))
                Text("The connection can't keep up with the original file. A lower quality has the server convert it to fit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            choices
        }
        .padding(40)
        .frame(maxWidth: 900)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(40)
        #if os(tvOS)
        .onAppear { focused = 0 }
        // Back is "Keep Trying".
        .onExitCommand { playback.keepTrying() }
        #endif
    }

    private var choices: some View {
        HStack(spacing: 16) {
            Button("Keep Trying") { playback.keepTrying() }
                .buttonStyle(.bordered)
                #if os(tvOS)
                .focused($focused, equals: 0)
                #endif
            ForEach(StreamQuality.caps, id: \.self) { cap in
                Button(StreamQuality.title(cap)) { playback.chooseQuality(cap) }
                    .buttonStyle(.borderedProminent)
                    #if os(tvOS)
                    .focused($focused, equals: cap)
                    #endif
            }
        }
    }
}

// MARK: - Touch extras

#if !os(tvOS)
/// A double-tap skip, for the flash over its side of the screen.
struct SkipFlash: Equatable {
    var forward: Bool
    var id = UUID()
}

/// "10" with arrows, briefly, over the side that was double-tapped.
private struct SkipFlashView: View {
    let flash: SkipFlash

    var body: some View {
        Image(systemName: flash.forward ? "goforward.10" : "gobackward.10")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(.white)
            .padding(28)
            .background(.black.opacity(0.35), in: Circle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: flash.forward ? .trailing : .leading)
            .padding(.horizontal, 60)
            .transition(.opacity)
    }
}

/// The system's AirPlay button.
#if os(iOS)
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#elseif os(macOS)
private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
#endif

// MARK: - Live

/// In place of the timeline for a Live TV channel.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text("LIVE")
                .font(.callout.weight(.bold))
                .tracking(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Live")
    }
}

// MARK: - Scrub preview

/// The frame and time above the playhead while scrubbing.
struct ScrubBubble: View {
    let seconds: Double
    var preview: ((Double) async -> CGImage?)?

    @State private var image: CGImage?

    #if os(tvOS)
    static let width: CGFloat = 400
    #else
    static let width: CGFloat = 200
    #endif

    var body: some View {
        VStack(spacing: 6) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: Self.width, height: Self.width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 8)
            }
            Text(AetherTimeline.time(seconds))
                .font(.callout.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
        }
        .foregroundStyle(.white)
        // A new frame every two seconds of timeline, not every pixel dragged.
        .task(id: Int(seconds / 2)) {
            guard let preview else { return }
            if let frame = await preview(seconds), !Task.isCancelled { image = frame }
        }
    }
}

#endif
