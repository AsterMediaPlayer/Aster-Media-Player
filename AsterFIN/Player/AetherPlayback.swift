//
//  AetherPlayback.swift
//  AsterFIN
//
//  Plays one video through AetherEngine, the app's main video player. The
//  file streams from the server untouched (no transcode, no HLS), so every
//  audio and subtitle track is in hand and switches on the device. Progress
//  goes to Jellyfin as it does for the system player. What the engine can't
//  play is handed to the system player, which can ask for a transcode
//  (`onFallback`). Music and audiobooks don't use this.
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
            attachments = source.mediaAttachments ?? item.mediaSources?.first { $0.id == source.id }?.mediaAttachments ?? []
            let subtitle = PlaybackCoordinator.resolveSubtitle(for: entry, source: source, among: subtitles, preferences: preferences)

            let url = client.directStreamURL(itemId: entry.itemId, mediaSourceId: source.id, playSessionId: info.playSessionId, container: source.container)
            let start = entry.startTicks > 0 ? Double(entry.startTicks) / 10_000_000 : nil
            try await engine.load(url: url, startPosition: start, audioSourceStreamIndex: audio.map { Int32($0) })
            guard !stopped else { return }
            // Jellyfin numbers a file's streams as the container does, so its
            // index is the engine's track id. An external file isn't in the
            // container and has no engine track yet.
            if subtitle >= 0, engine.subtitleTracks.contains(where: { $0.id == subtitle }) {
                selectSubtitle(subtitle)
            }
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

    /// Hands the title to the system player: the load failed, the engine
    /// gave up partway, or it's something the engine doesn't take. It
    /// carries on from where this got to, on the same tracks.
    func fallBack(_ reason: String) {
        guard !stopped, !fellBack else { return }
        guard let onFallback else {
            errorMessage = reason
            return
        }
        fellBack = true
        var resume = entry
        resume.mediaSourceId = mediaSourceId ?? entry.mediaSourceId
        if hasStarted {
            let seconds = engine.clock.currentTime
            if seconds.isFinite, seconds > 0 { resume.startTicks = Int64(seconds * 10_000_000) }
            if let audio = engine.activeAudioTrackIndex { resume.audioStreamIndex = audio }
            resume.subtitleStreamIndex = engine.activeSubtitleTrackIndex ?? -1
        }
        #if DEBUG
        print("DEBUG playback: AetherEngine can't play \(entry.itemId) (\(reason)); handing it to the system player")
        #endif
        stop()
        onFallback(PlaybackRequest(entry: resume))
    }

    /// Stops playback and tells the server where it ended. Safe to call twice.
    func stop() {
        guard !stopped else { return }
        stopped = true
        reportTask?.cancel()
        countdownTask?.cancel()
        timedTask?.cancel()
        clearStyledSubtitles()
        let final = report(paused: true)
        engine.stop()
        if hasStarted, !stopReported, reportsPlayback {
            let client = client
            Task { await client.reportStopped(final) }
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

    func selectAudio(_ id: Int) {
        engine.selectAudioTrack(index: id)
    }

    /// A subtitle track by id, or none for nil.
    func selectSubtitle(_ id: Int?) {
        clearStyledSubtitles()
        if let id {
            engine.selectSubtitleTrack(index: id)
            loadStyledSubtitles(id)
        } else {
            engine.clearSubtitle()
        }
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
                guard let self, !Task.isCancelled, self.engine.activeSubtitleTrackIndex == id else {
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
            playMethod: "DirectPlay",
            liveStreamId: nil,
            audioStreamIndex: engine.activeAudioTrackIndex,
            subtitleStreamIndex: engine.activeSubtitleTrackIndex
        )
    }
}
#endif
