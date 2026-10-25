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
    /// A second engine, for changing Channels-tab channel without a gap: the
    /// next channel loads on it, silent and out of sight, while the first
    /// plays on; once its picture is up the two change places. Made the
    /// first time it's needed.
    @ObservationIgnored static let spareEngine: AetherEngine? = try? AetherEngine()

    /// The engine on screen; another after a channel change (`crossOver`).
    private(set) var engine: AetherEngine
    /// The engine loading the next channel behind the one playing, while it
    /// does; the player view gives it a place to draw so its first frame
    /// can be seen to be ready.
    private(set) var standbyEngine: AetherEngine?
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
    /// A channel came to an end of its own accord (its schedule lost), so
    /// the player should close.
    private(set) var wantsToClose = false
    /// The cut-short break clip playing has reached its cut.
    @ObservationIgnored private var reachedCut = false
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

    private let client: any MediaServer
    /// The current episode's song card details, being looked up.
    private var themeLookup: Task<(plugin: [OpEdTheme]?, known: [KnownTheme]), Never>?
    /// The server as Jellyfin, for what only it has: Live TV's streams,
    /// openings and endings, and styled subtitles' fonts.
    private var jellyfin: JellyfinClient? { client as? JellyfinClient }
    private var entry: PlaybackQueueItem
    /// The Channel this is playing, if it's playing one.
    var channelId: String? { entry.channelId }
    /// The Live TV channel playing, if it's one.
    var liveChannelId: String? { isLive ? entry.itemId : nil }
    /// Playing on a timeline the viewer can't move: a Live TV channel, or a
    /// Channels-tab channel, whose schedule it keeps to. No skipping,
    /// scrubbing or chapters; Go to Episode is the way to watch freely.
    var followsTimeline: Bool { isLive || entry.channelId != nil }
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
    @ObservationIgnored private var nowPlaying: AetherNowPlaying
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
    #if os(iOS)
    /// The floating window the video moves into when the app leaves the
    /// screen while it plays.
    @ObservationIgnored private var pip: AetherPictureInPicture?
    #endif
    /// A Channels-tab channel's next title, fetched while the one before it
    /// played on, so its start doesn't ask the server again.
    private struct PreparedTitle {
        let item: BaseItem
        let info: PlaybackInfoResponse
    }
    @ObservationIgnored private var prepared: PreparedTitle?
    #if DEBUG
    /// When the current channel change began, for timing where it goes.
    @ObservationIgnored private var tuneClock: ContinuousClock.Instant?
    private func tuneLog(_ step: String) {
        guard let tuneClock else { return }
        let ms = (ContinuousClock.now - tuneClock).components.attoseconds / 1_000_000_000_000_000 + (ContinuousClock.now - tuneClock).components.seconds * 1000
        print("DEBUG tune: +\(ms) ms \(step)")
    }
    #endif
    /// Bytes warmed of the next channel's file: enough for its headers, not
    /// the engine's 8 MB, since a channel starts partway in.
    private static let channelPrewarmBytes = 2 * 1024 * 1024

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

    init?(client: any MediaServer, request: PlaybackRequest, preferences: PlaybackPreferences) {
        guard let engine = Self.sharedEngine, let entry = request.items.first else { return nil }
        self.engine = engine
        self.client = client
        self.entry = entry
        self.preferences = preferences
        self.nowPlaying = AetherNowPlaying(engine: engine, client: client)
    }

    func start() async {
        do {
            let ready = prepared?.item.id == entry.itemId ? prepared : nil
            prepared = nil
            let item: BaseItem
            if let ready { item = ready.item } else { item = try await client.item(entry.itemId) }
            self.item = item
            isLive = item.kind == .tvChannel
            // The song cards' details, looked up while the stream starts.
            let client = client
            themeLookup = isLive ? nil : Task { await PlaybackCoordinator.themeSources(for: item, client: client) }
            nowPlaying.prepare()
            if isLive {
                try await loadLive()
            } else {
                try await loadTitle(item, info: ready?.info)
            }
            guard !stopped else { return }
            #if DEBUG
            tuneLog("engine load returned")
            #endif
            await begin(item)
            if isLive { return }
            await loadExtras(for: item)
        } catch is CancellationError {
            // A newer load took over, or the player closed.
        } catch {
            if !stopped { fallBack(error.localizedDescription) }
        }
    }

    /// Markers, the next episode and song cards, once it plays, so they never
    /// hold up the start. A channel gets no markers: skipping an intro, by
    /// hand or on its own, would leave the schedule behind.
    private func loadExtras(for item: BaseItem) async {
        let onChannel = entry.channelId != nil
        // The episode's OP/ED chapters give the cards at once, since a card
        // shows only in a theme's first seconds and an opening can start
        // the episode; the song's details fill them in when they come.
        if AppSettings.themeCards, item.kind == .episode {
            themeMoments = PlaybackCoordinator.themeMoments(for: item, segments: [], pluginThemes: [], knownThemes: [])
        }
        async let loadedSegments = onChannel ? [] : (try? await client.mediaSegments(itemId: item.id)) ?? []
        let markers = await loadedSegments
        guard self.item?.id == item.id, !stopped else { return }
        segments = markers
        if AppSettings.themeCards, item.kind == .episode {
            let (themes, known) = await themeLookup?.value ?? (nil, [])
            guard self.item?.id == item.id, !stopped else { return }
            themeMoments = PlaybackCoordinator.themeMoments(for: item, segments: markers, pluginThemes: themes ?? [], knownThemes: known)
            #if DEBUG
            print("DEBUG theme cards: ready at \(Int(engine.clock.currentTime))s; \(themeMoments.map { "\($0.info.kicker) at \(Int($0.range.lowerBound))s" }.joined(separator: ", "))")
            #endif
        }
        // A channel goes on to what it's showing, never Up Next.
        let next = item.kind == .episode && entry.channelId == nil ? await PlaybackCoordinator.nextEpisode(after: item, client: client) : nil
        guard self.item?.id == item.id, !stopped else { return }
        upNext = next
        if AppSettings.themeCards, item.kind == .musicVideo, let jellyfin {
            let moments = await PlaybackCoordinator.musicVideoMoments(for: item, client: jellyfin)
            guard self.item?.id == item.id, !stopped else { return }
            themeMoments = moments
        }
    }

    /// Playing from here on, once the engine has the stream.
    private func begin(_ item: BaseItem) async {
        if speed != 1 { engine.setRate(speed) }
        engine.play()
        hasStarted = true
        stopReported = false
        nowPlaying.seekable = !followsTimeline
        nowPlaying.show(item)
        trickplay = isLive ? nil : ScrubPreviewSource(client: client, item: item, mediaSourceId: mediaSourceId)
        if reportsPlayback {
            await client.reportStart(report(paused: false))
            startReporting()
        }
        onItemStarted?(item)
        #if os(iOS)
        updatePictureInPicture()
        // A channel's schedule on the Lock Screen; Go to Episode leaves it.
        if let channelId = entry.channelId { ChannelActivity.show(channelId: channelId) } else { ChannelActivity.end() }
        #endif
        startTimedState()
        if isLive {
            // For the Top Shelf's recent channels.
            RecentChannels.record(item.id)
        }
    }

    #if os(iOS)
    /// The floating window on the engine playing now (another after a
    /// channel change crosses over), with skipping as this title allows: Go
    /// to Episode turns a channel into a plain title.
    private func updatePictureInPicture() {
        if pip?.engine !== engine {
            pip?.stop()
            pip = AetherPictureInPicture(engine: engine, followsTimeline: followsTimeline)
        }
        pip?.followsTimeline = followsTimeline
    }
    #endif

    /// A movie, episode or other video: the file itself, or a stream the
    /// server converts.
    private func loadTitle(_ item: BaseItem, info prefetched: PlaybackInfoResponse? = nil) async throws {
        // Asked only for the session id and the file's id: the stream
        // below is the file itself, whatever the server would choose. A
        // channel change asks ahead (`switchChannel`), and the same answer
        // is used, so the warmed file's address matches.
        let info: PlaybackInfoResponse
        if let prefetched {
            info = prefetched
        } else {
            info = try await client.playbackInfo(
                itemId: entry.itemId,
                mediaSourceId: entry.mediaSourceId,
                startTicks: entry.startTicks,
                maxBitrate: AppSettings.maxBitrate,
                subtitleStreamIndex: -1
            )
        }
        let setup = try setUpTitle(item, info: info)
        if isConverted {
            try await loadConverted(audio: setup.audio ?? setup.source.defaultAudioStreamIndex, subtitle: setup.subtitle, start: setup.start)
        } else {
            playMethod = "DirectPlay"
            let url = client.directStreamURL(itemId: entry.itemId, mediaSourceId: setup.source.id, playSessionId: info.playSessionId, container: setup.source.container)
            try await engine.load(url: url, startPosition: setup.start, audioSourceStreamIndex: setup.audio.map { Int32($0) })
            guard !stopped else { return }
            selectFileSubtitle(setup.subtitle)
        }
    }

    /// What `loadTitle` works out before it loads: the file, its tracks,
    /// whether it's converted, where it starts.
    private struct TitleSetup {
        let source: MediaSourceInfo
        let audio: Int?
        let subtitle: Int
        let start: Double?
    }

    /// The title's session, tracks and conversion, from the server's answer.
    private func setUpTitle(_ item: BaseItem, info: PlaybackInfoResponse) throws -> TitleSetup {
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

        mustConvert = Self.needsConversion(source)
        qualityCap = entry.maxBitrate
        if qualityCap == nil, Self.overQualityLimit(source) {
            qualityCap = AppSettings.maxBitrate
        }
        isConverted = mustConvert || qualityCap != nil || entry.fallback != .none
        #if DEBUG
        let videoCodec = streams.first(where: { $0.type == "Video" })?.codec ?? "none"
        print("DEBUG playback: \(item.displayTitle) video=\(videoCodec) streams=\(streams.count) mustConvert=\(mustConvert) cap=\(String(describing: qualityCap)) fallback=\(entry.fallback) -> \(isConverted ? "converted" : "original file")")
        #endif
        return TitleSetup(source: source, audio: audio, subtitle: subtitle, start: start)
    }

    /// Jellyfin numbers a file's streams as the container does, so its index
    /// is the engine's track id. An external file isn't in the container and
    /// has no engine track yet.
    private func selectFileSubtitle(_ subtitle: Int) {
        if subtitle >= 0, engine.subtitleTracks.contains(where: { $0.id == subtitle }) {
            selectSubtitle(subtitle)
        }
    }

    /// Apple TV has no AV1 or VP9 hardware, and decoding them in software
    /// can't keep up, so the server converts them.
    private static func needsConversion(_ source: MediaSourceInfo) -> Bool {
        #if os(tvOS)
        let codec = (source.mediaStreams ?? []).first { $0.type == "Video" }?.codec?.lowercased()
        return codec.map { softwareOnlyCodecs.contains($0) } ?? false
        #else
        return false
        #endif
    }

    /// Over the quality limit (lower on cellular data), the file is converted
    /// down to it: played as it is, a big one takes a minute to start on a
    /// slow connection, and stalls.
    private static func overQualityLimit(_ source: MediaSourceInfo) -> Bool {
        guard AppSettings.limitsQuality, let bitrate = source.bitrate else { return false }
        return bitrate > AppSettings.maxBitrate
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
            let client = jellyfin
            Task { await client?.closeLiveStream(liveStreamId) }
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
            if let text = try? await (client as? JellyfinClient)?.playlistText(at: playlist) {
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
                    let client = self.jellyfin
                    Task { await client?.closeLiveStream(liveStreamId) }
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
            let programs = (try? await (client as? JellyfinClient)?.programs(channelId: channelId, from: now, to: now.addingTimeInterval(60))) ?? []
            guard let self, self.liveChannelId == channelId else { return }
            self.liveProgram = programs.first { $0.isAiringNow } ?? programs.first
        }
    }

    /// Changes channel in this same player: another Live TV channel, or
    /// whatever another of the Channels tab's channels is showing now.
    ///
    /// A Channels-tab channel plays on while the next one's title is asked
    /// for and its file warmed, and gives way only then, as Live TV's `tune`
    /// does, the next one then loading in its place.
    func switchChannel(to channelId: String) {
        if isLive {
            tune(channelId)
            return
        }
        guard !stopped, let current = entry.channelId else { return }
        guard current != channelId else {
            // Back to the channel playing: whatever was being tuned is dropped.
            tuneTask?.cancel()
            tuningName = nil
            return
        }
        guard let first = ChannelTuner.live(channelId: channelId) else { return }
        let name = ChannelTuner.channel(channelId)?.name ?? "the channel"
        guard hasStarted else {
            // Nothing on screen to hold yet.
            tuneTask?.cancel()
            tuningName = nil
            endServerSession()
            play(first.item, entry: first.entry)
            return
        }
        tuneTask?.cancel()
        tuningName = name
        #if DEBUG
        tuneClock = .now
        tuneLog("flick to \(name)")
        #endif
        tuneTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.tuningName = nil } }
            do {
                let item = try await self.client.item(first.item.id)
                try Task.checkCancellation()
                #if DEBUG
                self.tuneLog("item fetched")
                #endif
                let info = try await self.client.playbackInfo(
                    itemId: item.id,
                    startTicks: first.entry.startTicks,
                    maxBitrate: AppSettings.maxBitrate,
                    subtitleStreamIndex: -1
                )
                try Task.checkCancellation()
                #if DEBUG
                let codec = info.mediaSources.first?.mediaStreams?.first { $0.type == "Video" }?.codec ?? "?"
                self.tuneLog("playback info (\(codec), \(info.mediaSources.first.map { Self.playsOriginal($0) ? "original file" : "converted" } ?? "?"))")
                #endif
                if info.errorCode == nil, let source = info.mediaSources.first, Self.playsOriginal(source) {
                    let url = self.client.directStreamURL(itemId: item.id, mediaSourceId: source.id, playSessionId: info.playSessionId, container: source.container)
                    let report = await AetherEngine.prewarm(url: url, byteBudget: Self.channelPrewarmBytes)
                    try Task.checkCancellation()
                    #if DEBUG
                    self.tuneLog("prewarm: \(report)")
                    #endif
                }
                guard !self.stopped, self.entry.channelId == current else { return }
                // Where the channel has got to now, not when the change began.
                guard let scheduled = ChannelTuner.live(channelId: channelId) else { return }
                // The file itself, the same title still on: it loads on the
                // spare engine while this one plays, and they change places
                // once its picture is up. Otherwise (a converted stream, the
                // programme changed meanwhile) it loads in place.
                var now = scheduled
                if now.item.id == item.id, info.errorCode == nil, let source = info.mediaSources.first,
                   Self.playsOriginal(source), Self.canLoadBeside(source, language: self.preferences.audioLanguage), let spare = self.otherEngine {
                    #if DEBUG
                    self.tuneLog("next channel loading on the spare engine")
                    #endif
                    do {
                        try await self.crossOver(to: item, entry: now.entry, info: info, source: source, on: spare, leaving: current)
                        return
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // It wouldn't start beside this one: the plain way instead.
                        #if DEBUG
                        self.tuneLog("spare engine failed (\(error.localizedDescription)); loading in place")
                        #endif
                        guard !self.stopped, self.entry.channelId == current,
                              let later = ChannelTuner.live(channelId: channelId) else { return }
                        now = later
                    }
                }
                #if DEBUG
                if let source = info.mediaSources.first, Self.playsOriginal(source), !Self.canLoadBeside(source, language: self.preferences.audioLanguage) {
                    self.tuneLog("loading in place, so the TV can switch (\(Self.isHDR(source) ? "HDR" : "more audio channels than the TV is outputting"))")
                }
                #endif
                self.prepared = now.item.id == item.id ? PreparedTitle(item: item, info: info) : nil
                self.tuningName = nil
                self.endServerSession()
                #if DEBUG
                self.tuneLog("cut over: engine load starts")
                #endif
                // In place, as Live TV changes: no artwork cover, the
                // picture playing until the engine takes the next.
                self.play(now.item, entry: now.entry, inPlace: true)
            } catch {
                guard !(error is CancellationError), !self.stopped else { return }
                #if DEBUG
                print("DEBUG playback: couldn't prepare \(name) (\(error.localizedDescription)); staying on this channel")
                #endif
                self.showTuneMessage("Couldn't tune \(name)")
            }
        }
    }

    #if DEBUG
    func logFirstFrame() {
        tuneLog("first frame on screen")
        tuneClock = nil
    }
    #endif

    /// Whether the next channel can load on the second engine without
    /// disturbing the TV: in SDR, since a second engine can't switch the TV
    /// into HDR (and the TV turns an HDR picture down); and with no more
    /// sound channels than the TV is putting out now, since more would make
    /// it renegotiate the HDMI audio while this channel still plays (a
    /// click and a gap). Fewer is fine: the TV stays as it is.
    private static func canLoadBeside(_ source: MediaSourceInfo, language: String?) -> Bool {
        guard !isHDR(source) else { return false }
        #if os(macOS)
        return true
        #else
        let streams = source.mediaStreams ?? []
        let index = PlaybackCoordinator.preferredAudioTrack(in: streams, language: language)
        let track = streams.first { $0.type == "Audio" && $0.index == index } ?? streams.first { $0.type == "Audio" }
        guard let channels = track?.channels, channels > 0 else { return true }
        let session = AVAudioSession.sharedInstance()
        return min(channels, session.maximumOutputNumberOfChannels) <= session.outputNumberOfChannels
        #endif
    }

    /// A video stream in HDR or Dolby Vision, as the server reads the file.
    private static func isHDR(_ source: MediaSourceInfo) -> Bool {
        guard let range = (source.mediaStreams ?? []).first(where: { $0.type == "Video" })?.videoRangeType?.uppercased() else { return false }
        return !range.isEmpty && range != "SDR" && range != "UNKNOWN"
    }

    /// The engine not on screen, to load the next channel on.
    private var otherEngine: AetherEngine? {
        let other = engine === Self.sharedEngine ? Self.spareEngine : Self.sharedEngine
        return other === engine ? nil : other
    }

    /// Plays `next` on `spare`, muted and out of sight, at the channel's
    /// place in it, until its first picture is ready; then the two change
    /// places in one go: its sound comes up, this engine stops, and it's
    /// the player's from then on. As a second engine it leaves the TV's
    /// frame rate and HDR mode as they were, until the channel's next
    /// programme loads in place.
    private func crossOver(to next: BaseItem, entry nextEntry: PlaybackQueueItem, info: PlaybackInfoResponse, source: MediaSourceInfo, on spare: AetherEngine, leaving channel: String) async throws {
        standbyEngine = spare
        spare.volume = 0
        let streams = source.mediaStreams ?? []
        let audio = PlaybackCoordinator.preferredAudioTrack(in: streams, language: preferences.audioLanguage)
        let start = nextEntry.startTicks > 0 ? Double(nextEntry.startTicks) / 10_000_000 : nil
        let url = client.directStreamURL(itemId: next.id, mediaSourceId: source.id, playSessionId: info.playSessionId, container: source.container)
        do {
            try await spare.load(url: url, startPosition: start, options: LoadOptions(sharedOutputRole: .secondary), audioSourceStreamIndex: audio.map { Int32($0) })
            #if DEBUG
            tuneLog("spare engine loaded")
            #endif
            try await Self.waitForFirstFrame(on: spare)
            try Task.checkCancellation()
            guard !stopped, entry.channelId == channel else { throw CancellationError() }
        } catch {
            spare.stop()
            if standbyEngine === spare { standbyEngine = nil }
            throw error
        }
        #if DEBUG
        tuneLog("spare engine's picture is up: changing places")
        #endif
        tuningName = nil
        endServerSession()
        nowPlaying.end()
        let old = engine
        resetForNextTitle(next, entry: nextEntry, inPlace: true)
        engine = spare
        standbyEngine = nil
        nowPlaying = AetherNowPlaying(engine: spare, client: client)
        spare.volume = 1
        old.stop()
        isLive = false
        let setup = try setUpTitle(next, info: info)
        playMethod = "DirectPlay"
        selectFileSubtitle(setup.subtitle)
        nowPlaying.prepare()
        await begin(next)
        #if DEBUG
        logFirstFrame()
        #endif
        await loadExtras(for: next)
    }

    /// Until `engine` has a picture to show; throws if it fails first, or
    /// takes too long.
    private static func waitForFirstFrame(on engine: AetherEngine, timeout: Duration = .seconds(6)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !engine.hasFirstFrameReadyForDisplay {
            try Task.checkCancellation()
            if case .error(let message) = engine.state { throw JellyfinError.http(0, message) }
            guard ContinuousClock.now < deadline else { throw JellyfinError.http(0, "The channel took too long to start") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Whether `source` plays as the file itself, as `loadTitle` decides
    /// for a channel's entry (no quality picked, no fallback).
    private static func playsOriginal(_ source: MediaSourceInfo) -> Bool {
        !needsConversion(source) && !overQualityLimit(source)
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
        let client = jellyfin
        closingLiveStream = Task { await client?.closeLiveStream(liveStreamId) }
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
            // On Plex, the server's reason when it has one.
            if let plex = client as? PlexClient {
                let session = playSessionId
                let converting = isConverted
                Task {
                    guard let trouble = await plex.playbackTrouble(wasConverting: converting, playSessionId: session),
                          errorMessage == reason else { return }
                    errorMessage = trouble.localizedDescription
                }
            }
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
        #if os(iOS)
        pip?.stop()
        pip = nil
        ChannelActivity.end()
        if reportsPlayback { WidgetRefresh.continueWatching() }
        #endif
        reportTask?.cancel()
        tuneTask?.cancel()
        tuneMessageTask?.cancel()
        prepared = nil
        standbyEngine?.stop()
        standbyEngine = nil
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
    /// `inPlace`: a channel change, like Live TV's, with no artwork cover
    /// while the next title loads.
    private func play(_ next: BaseItem, entry: PlaybackQueueItem, inPlace: Bool = false) {
        resetForNextTitle(next, entry: entry, inPlace: inPlace)
        Task { await start() }
    }

    /// Clears what belonged to the title playing, for `next`.
    private func resetForNextTitle(_ next: BaseItem, entry: PlaybackQueueItem, inPlace: Bool) {
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
        if !inPlace { hasStarted = false }
        reachedCut = false
        liveProgram = nil
        // Its artwork covers the screen until it starts (unless in place).
        item = next
        self.entry = entry
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
        // A break clip cut short to land on the half hour ends at its cut,
        // as if it had played out.
        if let cut = entry.channelCutTicks, ticks >= cut, !reachedCut {
            reachedCut = true
            if !playbackEnded() { wantsToClose = true }
            return
        }
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
                guard let jellyfin = client as? JellyfinClient else { throw PlexError.notBuilt }
                let loaded = try await AssSubtitleTrack.load(itemId: itemId, mediaSourceId: mediaSourceId, streamIndex: id, attachments: attachments, client: jellyfin)
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

    /// Back in the foreground after the engine let the video go (on Apple TV
    /// whenever the app leaves the screen; on iPhone once a paused video has
    /// sat in the background past the engine's grace window). Rebuilt before
    /// anything plays: a title where it was, paused; a channel where its
    /// schedule has got to; Live TV with a fresh stream.
    func restoreAfterBackground() {
        guard !stopped, hasStarted, engine.needsForegroundVideoRestore else { return }
        #if DEBUG
        print("DEBUG playback: restoring \(item?.displayTitle ?? entry.itemId) after the background")
        #endif
        if isLive, let item {
            // The server's stream has likely been closed meanwhile.
            endServerSession()
            closeLiveStream()
            play(item, entry: entry)
        } else if let channelId = entry.channelId {
            guard let live = ChannelTuner.live(channelId: channelId) else {
                wantsToClose = true
                return
            }
            endServerSession()
            play(live.item, entry: live.entry)
        } else if isConverted {
            // The server's encode has likely ended while the app was away:
            // a fresh one from here.
            restart { _ in }
        } else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.engine.reloadAtCurrentPosition { $0.autoplay = false }
                } catch is CancellationError {
                } catch {
                    if !self.stopped { self.fallBack(error.localizedDescription) }
                }
            }
        }
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
