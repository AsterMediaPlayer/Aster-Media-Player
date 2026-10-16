//
//  AetherPlayback.swift
//  AsterFIN
//
//  Plays one video through AetherEngine, the app's main video player.
//  Usually the file streams from the server untouched, so every audio and
//  subtitle track is in hand and switches on the device. When the file is
//  too much (AV1 on Apple TV, which has no hardware for it, or a lower
//  quality chosen in the player) the server converts it and the engine
//  plays that stream instead: one audio track at a time, and the app draws
//  the subtitles. Progress goes to Jellyfin as it does for the system
//  player. What the engine can't play at all is handed to the system
//  player (`onFallback`). Music and audiobooks don't use this.
//

#if canImport(AetherEngine)
import AetherEngine
import AVFoundation
import Foundation
import Observation

@Observable
final class AetherPlayback {
    /// One engine for the app's life, as AetherEngine asks: each title is
    /// another `load` on it, not another engine.
    @ObservationIgnored static let sharedEngine: AetherEngine? = try? AetherEngine()

    let engine: AetherEngine
    private(set) var item: BaseItem?
    private(set) var errorMessage: String?
    /// Playing has begun, so the artwork cover can come off.
    private(set) var hasStarted = false
    /// The chosen ASS/SSA track drawn by libass, as the system player draws
    /// it (signs, vector drawings, the file's fonts); the engine's own cues
    /// for it are plain text and stay hidden meanwhile.
    private(set) var assTrack: AssSubtitleTrack?
    /// An ASS/SSA track is on its way to libass. Its plain-text cues would
    /// show drawings as coordinates and stack the signs, so nothing shows
    /// until it's ready; they're only the fallback if it fails.
    private(set) var isLoadingStyledSubtitles = false

    /// The episode after this one, once found.
    private(set) var upNext: BaseItem?
    /// The episode has ended and the Up Next card holds the screen.
    private(set) var endCardVisible = false
    /// Seconds before the next episode starts on its own (autoplay).
    private(set) var countdown: Int?
    /// Told each time an item starts, so the page behind can follow when
    /// the next episode plays on its own.
    @ObservationIgnored var onItemStarted: ((BaseItem) -> Void)?
    /// Told when the engine can't play the title, with a request for the
    /// same title from the same spot and on the same tracks, for the system
    /// player. Without it, a failure shows "Can't Play" instead.
    @ObservationIgnored var onFallback: ((PlaybackRequest) -> Void)?
    /// Whether a failure goes to the system player rather than an alert.
    var handsOverOnFailure: Bool { onFallback != nil }
    /// Playback keeps stalling, and the lower qualities are on offer.
    private(set) var qualityOfferVisible = false

    /// Playing a stream the server converts, rather than the file itself.
    private(set) var isConverted = false
    /// The converted stream's bitrate cap; nil for the streaming quality setting.
    private(set) var qualityCap: Int?
    /// The file can't be played as it is here (AV1 on Apple TV), so it's
    /// converted whatever quality is chosen.
    private(set) var mustConvert = false
    /// A converted stream's text subtitle under the playhead, drawn by the
    /// app; ASS tracks go to libass (`assTrack`) as usual.
    private(set) var subtitleText: String?

    /// The item's intro, credits and recap markers from the server, and the
    /// one the playhead is inside now, which Skip Intro / Skip Credits skips.
    private(set) var segments: [MediaSegment] = []
    private(set) var activeSegment: MediaSegment?
    /// Near the end of an episode with one after it: Play Next Episode.
    private(set) var showsUpNextAction = false
    /// A skip (or Play Next Episode) has just come up: it shows by itself
    /// for 5 seconds, and after that only with the controls.
    private(set) var skipOfferIsFresh = false

    private let client: JellyfinClient
    private var entry: PlaybackQueueItem
    private let preferences: PlaybackPreferences
    private var playSessionId: String?
    private var mediaSourceId: String?
    private var reportTask: Task<Void, Never>?
    private var stopped = false
    /// The file's subtitle streams as Jellyfin lists them, and its embedded
    /// files (an ASS track's fonts).
    private var subtitleStreams: [MediaStream] = []
    private var attachments: [MediaAttachment] = []
    private var assTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    /// Follows the playhead for the markers and Play Next Episode.
    private var timedTask: Task<Void, Never>?
    /// Intros already skipped by themselves, so seeking back into one plays it.
    private var autoSkipped: Set<String> = []
    private var skipOfferTask: Task<Void, Never>?
    /// The current item's end was already reported to the server.
    private var stopReported = false
    /// The title has gone to the system player.
    private var fellBack = false
    /// Watches for stalls that call for a lower quality.
    private var stallWatch = StallWatch()
    /// The file's audio streams as Jellyfin lists them, which a converted
    /// stream's menus offer (it carries only the one chosen).
    private var audioStreams: [MediaStream] = []
    /// A converted stream's tracks: its one audio track, and the subtitle
    /// the app draws (or the server burned in); -1 for none.
    private var convertedAudio: Int?
    private var convertedSubtitle = -1
    private var cueTask: Task<Void, Never>?
    private var playMethod = "DirectPlay"

    /// Video codecs Apple TV can only decode in software, too slowly to play.
    static let softwareOnlyCodecs: Set<String> = ["av1", "vp9", "vp8"]

    /// Whether this engine can take `request`: one whole title from the
    /// server, unless "Use the system player" is on. A queue, a clip, or a
    /// download keeps to the system player; so does a Live TV channel, once
    /// `start` sees what it is.
    static func canPlay(_ request: PlaybackRequest) -> Bool {
        guard AppSettings.useAetherEngine, sharedEngine != nil, request.items.count == 1, let entry = request.items.first, entry.endTicks == nil else { return false }
        #if os(iOS)
        if entry.channelId == nil, DownloadStore.shared.playable(entry.itemId) != nil { return false }
        #endif
        return true
    }

    init?(client: JellyfinClient, request: PlaybackRequest, preferences: PlaybackPreferences) {
        guard let engine = Self.sharedEngine, let entry = request.items.first else { return nil }
        self.engine = engine
        self.client = client
        self.entry = entry
        self.preferences = preferences
    }

    func start() async {
        do {
            let item = try await client.item(entry.itemId)
            self.item = item
            // A Live TV channel needs a live stream opened on the server,
            // which only the system player does for now.
            if item.kind == .tvChannel {
                fallBack("a Live TV channel")
                return
            }
            // Asked only for the session id and the file's id: the stream
            // below is the file itself, whatever the server would choose.
            let info = try await client.playbackInfo(
                itemId: entry.itemId,
                mediaSourceId: entry.mediaSourceId,
                startTicks: entry.startTicks,
                maxBitrate: AppSettings.maxBitrate,
                subtitleStreamIndex: -1
            )
            if let code = info.errorCode { throw JellyfinError.http(0, code) }
            guard let source = info.mediaSources.first else { throw JellyfinError.http(0, "No media source") }
            playSessionId = info.playSessionId
            mediaSourceId = source.id

            let streams = source.mediaStreams ?? []
            let audio = entry.audioStreamIndex ?? PlaybackCoordinator.preferredAudioTrack(in: streams, language: preferences.audioLanguage)
            let subtitles = streams.filter { $0.type == "Subtitle" }
            subtitleStreams = subtitles
            audioStreams = streams.filter { $0.type == "Audio" }
            attachments = source.mediaAttachments ?? item.mediaSources?.first { $0.id == source.id }?.mediaAttachments ?? []
            let subtitle = PlaybackCoordinator.resolveSubtitle(for: entry, source: source, among: subtitles, preferences: preferences)
            let start = entry.startTicks > 0 ? Double(entry.startTicks) / 10_000_000 : nil

            mustConvert = false
            #if os(tvOS)
            // Apple TV has no AV1 or VP9 hardware, and decoding them in
            // software can't keep up, so the server converts them.
            if let codec = streams.first(where: { $0.type == "Video" })?.codec?.lowercased(), Self.softwareOnlyCodecs.contains(codec) {
                mustConvert = true
            }
            #endif
            qualityCap = entry.maxBitrate
            isConverted = mustConvert || entry.maxBitrate != nil || entry.fallback != .none
            #if DEBUG
            let videoCodec = streams.first(where: { $0.type == "Video" })?.codec ?? "none"
            print("DEBUG playback: \(item.displayTitle) video=\(videoCodec) streams=\(streams.count) mustConvert=\(mustConvert) cap=\(String(describing: entry.maxBitrate)) fallback=\(entry.fallback) -> \(isConverted ? "converted" : "original file")")
            #endif

            if isConverted {
                try await loadConverted(audio: audio ?? source.defaultAudioStreamIndex, subtitle: subtitle, start: start)
            } else {
                playMethod = "DirectPlay"
                let url = client.directStreamURL(itemId: entry.itemId, mediaSourceId: source.id, playSessionId: info.playSessionId, container: source.container)
                try await engine.load(url: url, startPosition: start, audioSourceStreamIndex: audio.map { Int32($0) })
                guard !stopped else { return }
                // Jellyfin numbers a file's streams as the container does, so its
                // index is the engine's track id. An external file isn't in the
                // container and has no engine track yet.
                if subtitle >= 0, engine.subtitleTracks.contains(where: { $0.id == subtitle }) {
                    selectSubtitle(subtitle)
                }
            }
            guard !stopped else { return }
            engine.play()
            hasStarted = true
            stopReported = false
            if reportsPlayback {
                await client.reportStart(report(paused: false))
                startReporting()
            }
            onItemStarted?(item)
            startTimedState()
            // Markers and the next episode load once it plays, so they never
            // hold up the start.
            async let loadedSegments = (try? await client.mediaSegments(itemId: item.id)) ?? []
            // A channel goes on to what it's showing, never Up Next.
            let next = item.kind == .episode && entry.channelId == nil ? await PlaybackCoordinator.nextEpisode(after: item, client: client) : nil
            let markers = await loadedSegments
            guard self.item?.id == item.id, !stopped else { return }
            segments = markers
            upNext = next
        } catch is CancellationError {
            // A newer load took over, or the player closed.
        } catch {
            if !stopped { fallBack(error.localizedDescription) }
        }
    }

    /// Asks the server for a converted stream (at `qualityCap`, or the
    /// streaming quality setting) and loads it. The chosen audio track is the
    /// one the stream carries; a picture-based subtitle (PGS, VobSub) is
    /// burned in by the server, and a text one is drawn by the app.
    private func loadConverted(audio: Int?, subtitle: Int, start: Double?) async throws {
        let burnIn = subtitle >= 0 && !isTextSubtitle(subtitle) ? subtitle : nil
        let info = try await client.playbackInfo(
            itemId: entry.itemId,
            mediaSourceId: mediaSourceId,
            startTicks: entry.startTicks,
            maxBitrate: qualityCap ?? AppSettings.maxBitrate,
            audioStreamIndex: audio,
            subtitleStreamIndex: burnIn ?? -1,
            allowDirect: false,
            mostCompatible: entry.fallback == .mostCompatible
        )
        if let code = info.errorCode { throw JellyfinError.http(0, code) }
        guard let source = info.mediaSources.first, let path = source.transcodingUrl,
              let url = client.absoluteURL(serverRelative: path) else { throw JellyfinError.http(0, "The server didn't offer a converted stream") }
        playSessionId = info.playSessionId
        playMethod = "Transcode"
        convertedAudio = audio
        convertedSubtitle = subtitle
        #if DEBUG
        print("DEBUG playback: AetherEngine plays a converted stream (\(entry.fallback == .mostCompatible ? "H.264" : "HEVC/H.264"), cap \((qualityCap ?? AppSettings.maxBitrate) / 1_000_000) Mbps)")
        #endif
        try await engine.load(url: url, startPosition: start, audioSourceStreamIndex: nil)
        guard !stopped else { return }
        showConvertedSubtitle()
    }

    /// The load failed or the engine gave up partway. A converted stream
    /// is tried again as a plain H.264 encode first; after that, or for the
    /// file itself, the title goes to the system player, carrying on from
    /// where this got to, on the same tracks.
    func fallBack(_ reason: String) {
        guard !stopped, !fellBack else { return }
        if isConverted, entry.fallback != .mostCompatible {
            #if DEBUG
            print("DEBUG playback: converted stream failed (\(reason)); trying a plain H.264 encode")
            #endif
            restart { $0.fallback = .mostCompatible }
            return
        }
        guard let onFallback else {
            errorMessage = reason
            return
        }
        fellBack = true
        var resume = entry
        resume.mediaSourceId = mediaSourceId ?? entry.mediaSourceId
        if isConverted { resume.fallback = .mostCompatible }
        if hasStarted {
            resume.startTicks = currentTicks
            if let audio = currentAudio { resume.audioStreamIndex = audio }
            resume.subtitleStreamIndex = currentSubtitle
        }
        #if DEBUG
        print("DEBUG playback: AetherEngine can't play \(entry.itemId) (\(reason)); handing it to the system player")
        #endif
        stop()
        onFallback(PlaybackRequest(entry: resume))
    }

    /// Where playback has got to, for starting again from here.
    private var currentTicks: Int64 {
        let seconds = engine.clock.currentTime
        return seconds.isFinite && seconds > 0 ? Int64(seconds * 10_000_000) : entry.startTicks
    }

    /// Plays the same title again from here with `change` made to it:
    /// another quality, or another track on a converted stream.
    private func restart(_ change: (inout PlaybackQueueItem) -> Void) {
        var next = entry
        next.startTicks = currentTicks
        change(&next)
        endServerSession()
        guard let item else { return }
        play(item, entry: next)
    }

    /// Lets the server know this stream is done: the stop report, or for a
    /// converted stream nothing reports (a channel), ending its encode.
    private func endServerSession() {
        reportTask?.cancel()
        if hasStarted, !stopReported, reportsPlayback {
            stopReported = true
            let final = report(paused: true)
            let client = client
            Task { await client.reportStopped(final) }
        } else if isConverted, let playSessionId {
            let client = client
            Task { await client.stopTranscoding(playSessionId: playSessionId) }
        }
    }

    // MARK: Quality

    /// The qualities on offer: the original file (or, when it must be
    /// converted anyway, the best the setting allows) as 0, then the caps.
    var qualityChoices: [TrackChoice] {
        [TrackChoice(id: 0, title: mustConvert ? "Best" : "Original")] + StreamQuality.caps.map { TrackChoice(id: $0, title: StreamQuality.title($0)) }
    }

    /// The quality playing, as in `qualityChoices`.
    var currentQuality: Int { qualityCap ?? 0 }

    /// Plays on from here at another quality: a cap has the server convert
    /// the file down to it; 0 goes back to the original (or the best).
    func chooseQuality(_ cap: Int) {
        qualityOfferVisible = false
        guard cap != currentQuality else { return }
        restart { next in
            next.maxBitrate = cap > 0 ? cap : nil
            // A file that needed the plain encode still does.
            if next.fallback != .mostCompatible || cap == 0 && !mustConvert { next.fallback = .none }
        }
    }

    /// Stays as it is; the offer holds off for a while.
    func keepTrying() {
        qualityOfferVisible = false
        stallWatch.declined(at: Date())
    }

    /// Stops playback and tells the server where it ended. Safe to call twice.
    func stop() {
        guard !stopped else { return }
        stopped = true
        reportTask?.cancel()
        countdownTask?.cancel()
        timedTask?.cancel()
        clearStyledSubtitles()
        clearCues()
        let final = report(paused: true)
        engine.stop()
        if hasStarted, !stopReported, reportsPlayback {
            let client = client
            Task { await client.reportStopped(final) }
        } else if isConverted, let playSessionId {
            // Nothing reports a channel's stream, so its encode is ended here.
            let client = client
            Task { await client.stopTranscoding(playSessionId: playSessionId) }
        }
    }

    /// A channel's movie leaves its resume point and watched state alone.
    private var reportsPlayback: Bool { entry.channelId == nil }

    // MARK: Up Next

    /// The item played to its end: the server hears it finished, and when
    /// there's a next episode its card holds the screen, counting down to
    /// play it if autoplay is on. A channel goes on to whatever it's showing
    /// now. False when there's nothing next, and the player should close.
    func playbackEnded() -> Bool {
        reportTask?.cancel()
        timedTask?.cancel()
        activeSegment = nil
        showsUpNextAction = false
        if let channelId = entry.channelId {
            guard let live = ChannelTuner.live(channelId: channelId, after: entry.itemId) else { return false }
            play(live.item, entry: live.entry)
            return true
        }
        if hasStarted, !stopReported {
            stopReported = true
            var final = report(paused: true)
            // At the very end, so the server marks it watched.
            if engine.duration > 0 { final.positionTicks = Int64(engine.duration * 10_000_000) }
            let client = client
            Task { await client.reportStopped(final) }
        }
        guard upNext != nil else { return false }
        endCardVisible = true
        if AppSettings.autoplayNext { startCountdown() }
        return true
    }

    /// Plays the next episode in this same player.
    func playUpNextNow() {
        countdownTask?.cancel()
        countdown = nil
        guard let next = upNext else { return }
        // From Play Next Episode, before the end: this one stops here.
        if hasStarted, !stopReported {
            stopReported = true
            reportTask?.cancel()
            let final = report(paused: true)
            let client = client
            Task { await client.reportStopped(final) }
        }
        play(next, entry: PlaybackQueueItem(itemId: next.id, startTicks: next.userData?.playbackPositionTicks ?? 0))
    }

    /// Starts another item in this same player.
    private func play(_ next: BaseItem, entry: PlaybackQueueItem) {
        countdownTask?.cancel()
        countdown = nil
        timedTask?.cancel()
        segments = []
        activeSegment = nil
        showsUpNextAction = false
        autoSkipped = []
        endCardVisible = false
        upNext = nil
        clearStyledSubtitles()
        clearCues()
        hasStarted = false
        // Its artwork covers the screen until it starts.
        item = next
        self.entry = entry
        Task { await start() }
    }

    /// Closes the Up Next card without playing on; the player closes too.
    func dismissEndCard() {
        countdownTask?.cancel()
        countdown = nil
        endCardVisible = false
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 10
        countdownTask = Task { [weak self] in
            for remaining in stride(from: 9, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.countdown = remaining
            }
            guard !Task.isCancelled, let self else { return }
            self.playUpNextNow()
        }
    }

    // MARK: Skipping

    /// Jumps past the intro, credits or recap the playhead is in.
    func skipActiveSegment() {
        guard let segment = activeSegment else { return }
        activeSegment = nil
        let engine = engine
        Task { await engine.seek(to: Double(segment.endTicks) / 10_000_000) }
    }

    /// Four times a second: which marker the playhead is in (skipping an
    /// intro by itself when that's set), and whether it's time to offer the
    /// next episode, at the credits or in the last 30 seconds.
    private func startTimedState() {
        timedTask?.cancel()
        timedTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateTimedState()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func updateTimedState() {
        guard hasStarted, !endCardVisible else { return }
        let stalling = switch engine.playbackPhase {
        case .rebuffering, .stalled: true
        default: false
        }
        if !qualityOfferVisible, stallWatch.note(stalling: stalling, at: Date()) {
            qualityOfferVisible = true
        }
        let seconds = engine.clock.currentTime
        guard seconds.isFinite else { return }
        let ticks = Int64(seconds * 10_000_000)
        let inside = segments.first { $0.contains(ticks: ticks) }
        if inside?.id != activeSegment?.id {
            activeSegment = inside
            if inside != nil { freshenSkipOffer() }
        }
        if AppSettings.autoSkipIntro, let segment = inside, segment.type == "Intro", !autoSkipped.contains(segment.id) {
            autoSkipped.insert(segment.id)
            skipActiveSegment()
        }
        var offer = false
        let runTime = engine.duration > 0 ? Int64(engine.duration * 10_000_000) : (item?.runTimeTicks ?? 0)
        if upNext != nil, runTime > 0 {
            let creditsStart = segments.first { $0.type == "Outro" }?.startTicks
            let threshold = creditsStart ?? max(runTime - 30 * 10_000_000, Int64(Double(runTime) * 0.92))
            offer = ticks >= threshold
        }
        if offer != showsUpNextAction {
            showsUpNextAction = offer
            if offer, activeSegment == nil { freshenSkipOffer() }
        }
    }

    /// Shows the skip just offered for 5 seconds on its own.
    private func freshenSkipOffer() {
        skipOfferIsFresh = true
        skipOfferTask?.cancel()
        skipOfferTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.skipOfferIsFresh = false
        }
    }

    // MARK: Tracks

    /// A track to choose in the menus: an engine track id, or for a
    /// converted stream the file's stream index (the same numbers).
    struct TrackChoice: Identifiable, Hashable {
        let id: Int
        let title: String
    }

    var audioChoices: [TrackChoice] {
        if isConverted {
            return audioStreams.compactMap { stream in stream.index.map { TrackChoice(id: $0, title: stream.trackTitle) } }
        }
        return engine.audioTracks.map { TrackChoice(id: $0.id, title: AetherPlayerView.label(for: $0)) }
    }

    /// The subtitle tracks, not counting "Off".
    var subtitleChoices: [TrackChoice] {
        if isConverted {
            return subtitleStreams.compactMap { stream in stream.index.map { TrackChoice(id: $0, title: stream.trackTitle) } }
        }
        return engine.subtitleTracks.map { TrackChoice(id: $0.id, title: AetherPlayerView.label(for: $0)) }
    }

    var currentAudio: Int? { isConverted ? convertedAudio : engine.activeAudioTrackIndex }
    /// -1 for none.
    var currentSubtitle: Int { isConverted ? convertedSubtitle : (engine.activeSubtitleTrackIndex ?? -1) }

    /// A converted stream carries one audio track, so another one is a new
    /// stream from the server, from here.
    func selectAudio(_ id: Int) {
        if isConverted {
            guard id != convertedAudio else { return }
            restart { $0.audioStreamIndex = id; $0.subtitleStreamIndex = convertedSubtitle }
        } else {
            engine.selectAudioTrack(index: id)
        }
    }

    /// A subtitle track by id, or none for nil.
    func selectSubtitle(_ id: Int?) {
        if isConverted {
            let wanted = id ?? -1
            guard wanted != convertedSubtitle else { return }
            // A picture-based track is burned in by the server, so taking
            // one on or off needs a new stream; text ones the app draws.
            let burnedIn = convertedSubtitle >= 0 && !isTextSubtitle(convertedSubtitle)
            if burnedIn || (wanted >= 0 && !isTextSubtitle(wanted)) {
                restart { $0.subtitleStreamIndex = wanted; $0.audioStreamIndex = convertedAudio }
            } else {
                convertedSubtitle = wanted
                showConvertedSubtitle()
            }
            return
        }
        clearStyledSubtitles()
        if let id {
            engine.selectSubtitleTrack(index: id)
            loadStyledSubtitles(id)
        } else {
            engine.clearSubtitle()
        }
    }

    private func isTextSubtitle(_ index: Int) -> Bool {
        guard let stream = subtitleStreams.first(where: { $0.index == index }) else { return true }
        return PlaybackCoordinator.isTextTrack(stream)
    }

    // MARK: Converted stream subtitles

    /// Shows the converted stream's chosen text subtitle: ASS through
    /// libass, anything else as text cues from the server.
    private func showConvertedSubtitle() {
        clearStyledSubtitles()
        clearCues()
        let id = convertedSubtitle
        guard id >= 0, let stream = subtitleStreams.first(where: { $0.index == id }), PlaybackCoordinator.isTextTrack(stream) else { return }
        if AppSettings.styledSubtitles, AssSubtitleTrack.isAvailable, AssSubtitleTrack.handles(stream) {
            loadStyledSubtitles(id)
        } else {
            loadCues(id)
        }
    }

    private func loadCues(_ id: Int) {
        guard let mediaSourceId else { return }
        let client = client
        let itemId = entry.itemId
        cueTask = Task { [weak self] in
            do {
                let cues = try await client.subtitleCues(itemId: itemId, mediaSourceId: mediaSourceId, streamIndex: id)
                // Ten times a second, the cue under the playhead.
                while !Task.isCancelled {
                    guard let self, self.currentSubtitle == id else { return }
                    let text = SubtitleCue.text(at: self.precisePosition, in: cues)
                    if text != self.subtitleText { self.subtitleText = text }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                #if DEBUG
                print("DEBUG subtitles: track \(id) failed to load: \(error)")
                #endif
            }
        }
    }

    private func clearCues() {
        cueTask?.cancel()
        cueTask = nil
        subtitleText = nil
    }

    // MARK: Styled subtitles

    /// An ASS/SSA track goes to libass, the same as with the system player.
    /// Until it's loaded, or if it fails, the engine's text cues show.
    private func loadStyledSubtitles(_ id: Int) {
        guard AppSettings.styledSubtitles, AssSubtitleTrack.isAvailable, let mediaSourceId,
              let stream = subtitleStreams.first(where: { $0.index == id }), AssSubtitleTrack.handles(stream) else { return }
        let client = client
        let itemId = entry.itemId
        let attachments = attachments
        isLoadingStyledSubtitles = true
        assTask = Task { [weak self] in
            do {
                let loaded = try await AssSubtitleTrack.load(itemId: itemId, mediaSourceId: mediaSourceId, streamIndex: id, attachments: attachments, client: client)
                guard let self, !Task.isCancelled, self.currentSubtitle == id else {
                    loaded.unload()
                    return
                }
                self.isLoadingStyledSubtitles = false
                self.assTrack = loaded
                // 30 times a second: signs slide and fade, so 10 judders.
                while !Task.isCancelled {
                    loaded.update(seconds: self.precisePosition)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoadingStyledSubtitles = false
                #if DEBUG
                print("DEBUG subtitles: styled track \(id) failed (\(error)); showing it as text")
                #endif
                // A converted stream has no engine cues to fall back on.
                if let self, self.isConverted { self.loadCues(id) }
            }
        }
    }

    private func clearStyledSubtitles() {
        assTask?.cancel()
        assTask = nil
        isLoadingStyledSubtitles = false
        assTrack?.unload()
        assTrack = nil
    }

    /// Where the picture is now, on the source's clock, read from whichever
    /// pipeline is playing; the engine's own clock only ticks 10 times a second.
    private var precisePosition: Double {
        if let player = engine.currentAVPlayer {
            let item = player.currentTime().seconds
            if item.isFinite, let source = engine.presentationAxisMap.sourceSeconds(forItemSeconds: item) {
                return source
            }
        } else if let timebase = engine.softwarePresentationTimebase {
            let seconds = CMTimebaseGetTime(timebase).seconds
            if seconds.isFinite { return seconds }
        }
        return engine.clock.sourceTime
    }

    // MARK: Reporting

    /// Progress every ten seconds while the player is open.
    private func startReporting() {
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                await self.client.reportProgress(self.report(paused: self.engine.state == .paused))
            }
        }
    }

    private func report(paused: Bool) -> PlaybackReport {
        let seconds = engine.clock.currentTime
        return PlaybackReport(
            itemId: entry.itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: seconds.isFinite && seconds > 0 ? Int64(seconds * 10_000_000) : 0,
            isPaused: paused,
            canSeek: true,
            playMethod: playMethod,
            liveStreamId: nil,
            audioStreamIndex: currentAudio,
            subtitleStreamIndex: currentSubtitle >= 0 ? currentSubtitle : nil
        )
    }
}
#endif
