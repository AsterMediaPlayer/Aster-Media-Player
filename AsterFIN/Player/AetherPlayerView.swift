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
import SwiftUI

struct AetherPlayerView: View {
    let playback: AetherPlayback
    var onFinished: () -> Void

    @ObservedObject private var engine: AetherEngine
    #if !os(tvOS)
    /// When the controls were last called up; nil while they're hidden.
    @State private var controlsShownAt: Date? = Date()
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
            } else if !playback.isLoadingStyledSubtitles {
                AetherSubtitleLayer(engine: engine, clock: engine.clock)
                    .allowsHitTesting(false)
            }
            // The Up Next card takes the screen (and the remote) on its own.
            if !playback.endCardVisible {
                #if os(tvOS)
                AetherTVControls(playback: playback, engine: engine, isSuspended: errorMessage != nil, onFinished: onFinished)
                #else
                touchControls
                skipButton
                #endif
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
        .animation(.easeInOut(duration: 0.6), value: playback.hasStarted)
        .animation(.easeInOut(duration: 0.3), value: playback.endCardVisible)
        .onChange(of: engine.state) { _, state in
            // The end of an episode with one after it holds on Up Next;
            // anything else closes the player.
            if state == .ended, !playback.playbackEnded() { onFinished() }
        }
        .alert("Can't Play", isPresented: Binding(get: { errorMessage != nil }, set: { _ in })) {
            Button("OK", action: onFinished)
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// The load failing, or the engine giving up partway.
    private var errorMessage: String? {
        if let message = playback.errorMessage { return message }
        if case .error(let message) = engine.state { return message }
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
            // A tap or click on the picture shows or hides the controls.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { controlsShownAt = controlsShownAt == nil ? Date() : nil }
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
                AetherPauseDetails(item: item, engine: engine)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            AetherTimeline(engine: engine, clock: engine.clock, onScrub: reveal)
            HStack(spacing: 20) {
                Spacer()
                trackMenus
            }
            .padding(.top, 16)
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
        }
        .font(.system(size: 30))
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trackMenus: some View {
        if engine.audioTracks.count > 1 {
            Menu {
                Picker("Audio", selection: Binding(
                    get: { engine.activeAudioTrackIndex ?? -1 },
                    set: { playback.selectAudio($0); reveal() }
                )) {
                    ForEach(engine.audioTracks) { track in
                        Text(Self.label(for: track)).tag(track.id)
                    }
                }
            } label: {
                Label("Audio", systemImage: "speaker.wave.2")
            }
        }
        if !engine.subtitleTracks.isEmpty {
            Menu {
                Picker("Subtitles", selection: Binding(
                    get: { engine.activeSubtitleTrackIndex ?? -1 },
                    set: { playback.selectSubtitle($0 >= 0 ? $0 : nil); reveal() }
                )) {
                    Text("Off").tag(-1)
                    ForEach(engine.subtitleTracks) { track in
                        Text(Self.label(for: track)).tag(track.id)
                    }
                }
            } label: {
                Label("Subtitles", systemImage: "captions.bubble")
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
#endif
