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
//  player. A Live TV channel plays the server's live stream, opened and
//  closed through Jellyfin. What the engine can't play at all is handed to
//  the system player (`onFallback`). Music and audiobooks don't use this.
//

#if canImport(AetherEngine)
import AetherEngine
import AVFoundation
import Combine
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
    /// The playback speed chosen in the player. The engine forgets it on
    /// each load, so it's put back after one.
    private(set) var speed: Float = 1
    /// An anime episode's openings and endings, for the song card, when the
    /// card is on (the same as the system player's).
    private(set) var themeMoments: [PlaybackCoordinator.ThemeMoment] = []
    /// A Live TV channel: no timeline, no skipping.
    private(set) var isLive = false
    /// Whether playback is paused right now.
    var isPaused: Bool { engine.state == .paused }

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
    /// The Channel this is playing, if it's playing one.
    var channelId: String? { entry.channelId }
    /// The Live TV channel playing, if it's one.
    var liveChannelId: String? { isLive ? entry.itemId : nil }
    /// What's on that channel, from the guide, fetched as playback pauses.
    private(set) var liveProgram: BaseItem?
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
    /// The lock screen, Control Center and remote buttons.
    @ObservationIgnored private let nowPlaying: AetherNowPlaying
    /// The item's trickplay frames, when the server has made them.
    @ObservationIgnored private var trickplay: ScrubPreviewSource?
    /// The server's live stream for a channel, closed when it's done.
    private var liveStreamId: String?
    @ObservationIgnored private var liveResetTask: Task<Void, Never>?
    /// When the live source was last reopened, to give up on a channel that
    /// keeps dropping rather than retry for ever.
    private var liveRetunes: [Date] = []
    /// The last channel's stream, still being closed. The tuner has only so
    /// many streams, so the next one opens once it's gone.
    @ObservationIgnored private var closingLiveStream: Task<Void, Never>?
    /// This channel failed to start once and was given a second go before
    /// going to the system player.
    private var liveStartRetried = false
    /// The channel being tuned while the current one plays on, and the
    /// work of tuning it.
    private(set) var tuningName: String?
    @ObservationIgnored private var tuneTask: Task<Void, Never>?
    /// A channel couldn't be tuned, so the one playing stayed; shown briefly.
    private(set) var tuneMessage: String?
    /// Until when a channel isn't opened beside the playing one: the tuner
    /// source turned a second stream away (some give only one at a time,
    /// whatever Jellyfin counts), so for a while each change goes straight
    /// to letting this channel go first, rather than failing first.
    @ObservationIgnored private static var holdingUnavailableUntil = Date.distantPast
    @ObservationIgnored private var tuneMessageTask: Task<Void, Never>?

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
        self.nowPlaying = AetherNowPlaying(engine: engine, client: client)
    }

    func start() async {
        do {
            let item = try await client.item(entry.itemId)
            self.item = item
            isLive = item.kind == .tvChannel
            nowPlaying.prepare()
            if isLive {
                try await loadLive()
            } else {
                try await loadTitle(item)
            }
            guard !stopped else { return }
            await begin(item)
            if isLive { return }
            // Markers and the next episode load once it plays, so they never
            // hold up the start.
            async let loadedSegments = (try? await client.mediaSegments(itemId: item.id)) ?? []
            // A channel goes on to what it's showing, never Up Next.
            let next = item.kind == .episode && entry.channelId == nil ? await PlaybackCoordinator.nextEpisode(after: item, client: client) : nil
            let markers = await loadedSegments
            guard self.item?.id == item.id, !stopped else { return }
            segments = markers
            upNext = next
            if AppSettings.themeCards, item.kind == .episode {
                let themes = await client.opEdThemes(for: item.id) ?? []
                guard self.item?.id == item.id, !stopped else { return }
                themeMoments = PlaybackCoordinator.themeMoments(for: item, segments: markers, pluginThemes: themes)
            }
        } catch is CancellationError {
            // A newer load took over, or the player closed.
        } catch {
            if !stopped { fallBack(error.localizedDescription) }
        }
    }

    /// Playing from here on, once the engine has the stream.
    private func begin(_ item: BaseItem) async {
        if speed != 1 { engine.setRate(speed) }
        engine.play()
        hasStarted = true
        stopReported = false
        nowPlaying.show(item)
        trickplay = isLive ? nil : ScrubPreviewSource(client: client, item: item, mediaSourceId: mediaSourceId)
        if reportsPlayback {
            await client.reportStart(report(paused: false))
            startReporting()
        }
        onItemStarted?(item)
        startTimedState()
        if isLive {
            // For the Top Shelf's recent channels.
            RecentChannels.record(item.id)
        }
    }

    /// A movie, episode or other video: the file itself, or a stream the
    /// server converts.
    private func loadTitle(_ item: BaseItem) async throws {
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
    }

    // MARK: Live TV

    /// Opens the channel's live stream on the server, the way the system
    /// player does, and plays its HLS stream through the engine as live.
    private func loadLive() async throws {
        await closingLiveStream?.value
        closingLiveStream = nil
        try await load(try await openLive(entry.itemId))
    }

    /// A channel's stream, opened on the server and ready for the engine.
    private struct OpenedLive {
        let playSessionId: String?
        let mediaSourceId: String?
        let liveStreamId: String?
        let url: URL
        let playMethod: String
    }

    /// Opens the channel's live stream on the server, without touching
    /// what's playing.
    private func openLive(_ channelId: String) async throws -> OpenedLive {
        let info = try await client.playbackInfo(
            itemId: channelId,
            startTicks: 0,
            maxBitrate: AppSettings.maxBitrate,
            subtitleStreamIndex: -1
        )
        if let code = info.errorCode { throw JellyfinError.http(0, code) }
        guard let source = info.mediaSources.first else { throw JellyfinError.http(0, "No media source") }
        if let path = source.transcodingUrl, let absolute = client.absoluteURL(serverRelative: path) {
            return OpenedLive(playSessionId: info.playSessionId, mediaSourceId: source.id, liveStreamId: source.liveStreamId, url: absolute, playMethod: "Transcode")
        } else if let path = source.path, path.lowercased().contains("m3u8"), let direct = URL(string: path), direct.scheme?.hasPrefix("http") == true {
            // A tuner that already speaks HLS.
            return OpenedLive(playSessionId: info.playSessionId, mediaSourceId: source.id, liveStreamId: source.liveStreamId, url: direct, playMethod: "DirectPlay")
        }
        if let liveStreamId = source.liveStreamId {
            let client = client
            Task { await client.closeLiveStream(liveStreamId) }
        }
        throw JellyfinError.http(0, "This channel's stream format isn't supported.")
    }

    /// Plays an opened stream: it becomes this player's.
    private func load(_ opened: OpenedLive) async throws {
        playSessionId = opened.playSessionId
        mediaSourceId = opened.mediaSourceId
        liveStreamId = opened.liveStreamId
        playMethod = opened.playMethod
        #if DEBUG
        print("DEBUG playback: AetherEngine plays live channel \(item?.displayTitle ?? entry.itemId) (\(playMethod))")
        #endif
        try await engine.load(url: opened.url, options: LoadOptions(isLive: true, nativeRemoteHLS: true))
        watchForLiveReset()
    }

    /// Waits until an opened stream lists video, following a master
    /// playlist to its first variant; throws if it doesn't within 20 seconds.
    private func waitUntilServing(_ opened: OpenedLive) async throws {
        let deadline = Date().addingTimeInterval(20)
        var playlist = opened.url
        while true {
            try Task.checkCancellation()
            if let text = try? await client.playlistText(at: playlist) {
                if text.contains("#EXTINF") { return }
                let variant = text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && !$0.hasPrefix("#") }
                if let variant, let next = URL(string: variant, relativeTo: playlist)?.absoluteURL, next != playlist {
                    playlist = next
                    continue
                }
            }
            guard Date() < deadline else { throw JellyfinError.http(0, "The channel didn't start.") }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Changes channel in this same player, as the Live TV mini player does.
    /// The channel playing carries on while the new one is tuned (the
    /// server opening its stream and starting the video), and gives way
    /// only once it's ready. A channel that can't be tuned leaves the
    /// current one playing, with a note; if it couldn't even open (both
    /// tuners busy, with this channel holding one), it's tried the plain
    /// way, this channel first let go.
    func tune(_ channelId: String) {
        guard isLive, !stopped else { return }
        guard entry.itemId != channelId else {
            // Back to the channel playing: whatever was being tuned is dropped.
            tuneTask?.cancel()
            tuningName = nil
            return
        }
        guard hasStarted, Date() >= Self.holdingUnavailableUntil else {
            cutOver(to: channelId)
            return
        }
        tuneTask?.cancel()
        tuneTask = Task { [weak self] in
            guard let self else { return }
            let channel = try? await self.client.item(channelId)
            guard !Task.isCancelled, !self.stopped else { return }
            self.tuningName = channel?.displayTitle ?? "the channel"
            defer { if !Task.isCancelled { self.tuningName = nil } }
            let opened: OpenedLive
            do {
                opened = try await self.openLive(channelId)
            } catch {
                guard !Task.isCancelled, !self.stopped else { return }
                #if DEBUG
                print("DEBUG playback: couldn't open \(channelId) beside the playing channel (\(error.localizedDescription)); tuning the plain way for 10 minutes")
                #endif
                Self.holdingUnavailableUntil = Date().addingTimeInterval(600)
                self.tuningName = nil
                self.cutOver(to: channelId)
                return
            }
            do {
                try await self.waitUntilServing(opened)
                guard !Task.isCancelled, !self.stopped, let channel else { throw CancellationError() }
                await self.switchLive(to: channel, opened: opened)
            } catch {
                if let liveStreamId = opened.liveStreamId {
                    let client = self.client
                    Task { await client.closeLiveStream(liveStreamId) }
                }
                guard !(error is CancellationError), !self.stopped else { return }
                #if DEBUG
                print("DEBUG playback: \(channel?.displayTitle ?? channelId) didn't start (\(error.localizedDescription)); staying on this channel")
                #endif
                self.showTuneMessage("Couldn't tune \(channel?.displayTitle ?? "that channel")")
            }
        }
    }

    /// Changes channel by letting this one go first, then opening the next.
    private func cutOver(to channelId: String) {
        tuneTask?.cancel()
        endServerSession()
        closeLiveStream()
        liveRetunes = []
        liveStartRetried = false
        play(item ?? BaseItem(id: channelId, name: nil, type: ItemKind.tvChannel.rawValue), entry: PlaybackQueueItem(itemId: channelId))
    }

    /// The new channel is ready: the old one stops, and the engine takes
    /// the new stream.
    private func switchLive(to channel: BaseItem, opened: OpenedLive) async {
        endServerSession()
        closeLiveStream()
        liveRetunes = []
        liveStartRetried = false
        timedTask?.cancel()
        liveProgram = nil
        item = channel
        entry = PlaybackQueueItem(itemId: channel.id)
        tuningName = nil
        do {
            try await load(opened)
            guard !stopped else { return }
            await begin(channel)
        } catch is CancellationError {
        } catch {
            if !stopped { fallBack(error.localizedDescription) }
        }
    }

    private func showTuneMessage(_ message: String) {
        tuneMessage = message
        tuneMessageTask?.cancel()
        tuneMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.tuneMessage = nil
        }
    }

    /// Fetches what's on the Live TV channel now, for the pause screen.
    func refreshLiveProgram() {
        guard let channelId = liveChannelId else { return }
        let client = client
        Task { [weak self] in
            let now = Date()
            let programs = (try? await client.programs(channelId: channelId, from: now, to: now.addingTimeInterval(60))) ?? []
            guard let self, self.liveChannelId == channelId else { return }
            self.liveProgram = programs.first { $0.isAiringNow } ?? programs.first
        }
    }

    /// Changes channel in this same player: another Live TV channel, or
    /// whatever another of the Channels tab's channels is showing now.
    func switchChannel(to channelId: String) {
        if isLive {
            tune(channelId)
            return
        }
        guard !stopped, let current = entry.channelId, current != channelId,
              let live = ChannelTuner.live(channelId: channelId) else { return }
        endServerSession()
        play(live.item, entry: live.entry)
    }

    /// Leaves the channel for `itemId` played on its own, as if picked from
    /// its show or the library: from where it was left off, with progress
    /// saved, its markers, and Up Next after it. The channel plays on until
    /// the title is found.
    func goTo(_ itemId: String) {
        guard !stopped, entry.channelId != nil else { return }
        let client = client
        Task { [weak self] in
            let found = try? await client.item(itemId)
            guard let self, !self.stopped, self.entry.channelId != nil else { return }
            guard let found else {
                self.showTuneMessage("Couldn't open that title")
                return
            }
            self.endServerSession()
            self.play(found, entry: PlaybackQueueItem(itemId: found.id, startTicks: found.userData?.playbackPositionTicks ?? 0))
        }
    }

    /// The engine says the live source can't go on (the server restarted
    /// its stream, or it stopped arriving): a fresh stream from the server,
    /// a few times at most before giving the channel to the system player.
    private func watchForLiveReset() {
        liveResetTask?.cancel()
        let resets = engine.liveSourceReset.values
        liveResetTask = Task { [weak self] in
            for await _ in resets {
                guard let self, !Task.isCancelled else { return }
                self.reopenLive()
                return
            }
        }
    }

    private func reopenLive() {
        guard isLive, !stopped, let item else { return }
        let now = Date()
        liveRetunes.removeAll { now.timeIntervalSince($0) > 120 }
        guard liveRetunes.count < 3 else {
            fallBack("the channel keeps dropping")
            return
        }
        liveRetunes.append(now)
        #if DEBUG
        print("DEBUG playback: live source reset; reopening \(item.displayTitle) (\(liveRetunes.count) of 3)")
        #endif
        endServerSession()
        closeLiveStream()
        play(item, entry: entry)
    }

    private func closeLiveStream() {
        liveResetTask?.cancel()
        liveResetTask = nil
        guard let liveStreamId else { return }
        self.liveStreamId = nil
        let client = client
        closingLiveStream = Task { await client.closeLiveStream(liveStreamId) }
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
        // A live channel's stream can be briefly missing on the server (a
        // tuner still being let go, an encode not ready): one fresh try in
        // this player before handing it over.
        if isLive, !liveStartRetried, let item {
            liveStartRetried = true
            #if DEBUG
            print("DEBUG playback: live channel failed (\(reason)); trying a fresh stream once")
            #endif
            endServerSession()
            closeLiveStream()
            play(item, entry: entry)
            return
        }
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
        tuneTask?.cancel()
        tuneMessageTask?.cancel()
        countdownTask?.cancel()
        timedTask?.cancel()
        clearStyledSubtitles()
        clearCues()
        nowPlaying.end()
        let final = report(paused: true)
        engine.stop()
        closeLiveStream()
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
        themeMoments = []
        clearStyledSubtitles()
        clearCues()
        hasStarted = false
        liveProgram = nil
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
        nowPlaying.tick()
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

    // MARK: Speed, chapters and scrubbing

    /// The speeds offered; the engine plays video at up to 2×.
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    func setSpeed(_ speed: Float) {
        self.speed = speed
        engine.setRate(speed)
    }

    /// The item's chapters, when there are enough to be worth choosing from.
    var chapters: [ChapterInfo] {
        let all = item?.chapters ?? []
        return all.count > 1 ? all.sorted { $0.startPositionTicks < $1.startPositionTicks } : []
    }

    func play(chapter: ChapterInfo) {
        let engine = engine
        Task {
            await engine.seek(to: Double(chapter.startPositionTicks) / 10_000_000)
            engine.play()
        }
    }

    /// The picture for a point on the timeline while scrubbing: a trickplay
    /// frame, else a still from what the engine has downloaded, else nil
    /// (the preview shows just the time).
    func scrubPreview(at seconds: Double) async -> CGImage? {
        if let trickplay, let frame = await trickplay.frame(at: seconds) { return frame }
        guard engine.supportsCacheBackedStills else { return nil }
        return await engine.scrubThumbnail(atSeconds: seconds, maxWidth: ScrubPreviewSource.previewWidth)
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

    /// Sends where playback is and saves it as the resume point now, for when
    /// the app is leaving the screen and may not get to say it stopped.
    func saveProgressNow() {
        guard hasStarted, !stopped, !stopReported, reportsPlayback, !isLive else { return }
        let report = report(paused: engine.state == .paused)
        let client = client
        Task { await client.reportProgress(report, savingResumePoint: .now) }
    }

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
            canSeek: !isLive,
            playMethod: playMethod,
            liveStreamId: liveStreamId,
            audioStreamIndex: currentAudio,
            subtitleStreamIndex: currentSubtitle >= 0 ? currentSubtitle : nil,
            runTimeTicks: item?.runTimeTicks ?? (engine.duration > 0 ? Int64(engine.duration * 10_000_000) : nil)
        )
    }
}
#endif
