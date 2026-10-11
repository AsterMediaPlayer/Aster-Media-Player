//
//  PlaybackCoordinator.swift
//  AsterFIN
//
//  Drives an AVPlayer through a queue of Jellyfin items: resolves how to
//  stream each one, seeks to the start position, exposes chapters to the
//  system player and reports progress back to the server.
//

import AVFoundation
import AVKit
import Foundation
import Observation
import UIKit

/// One thing to play: an item, from an offset, optionally with chosen tracks.
/// A subtitle index of -1 means none, even if the server would default one.
nonisolated struct PlaybackQueueItem: Hashable, Sendable {
    var itemId: String
    var startTicks: Int64 = 0
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    /// How far this entry has stepped back after failing to play.
    var fallback: StreamFallback = .none
    /// Reloads in a row after the stream stalled mid-playback.
    var stallRetries = 0
    /// Whether this entry has played at its current fallback level, proving
    /// that stream works. Later failures are then stalls, even ones that
    /// land while a track change or reload is still starting up.
    var hasPlayed = false
    /// Set for a clip (an opening or ending): playback stops here, and the
    /// episode's resume point and watched state are left alone.
    var endTicks: Int64?
    /// Where the clip began, kept while `startTicks` moves on reloads.
    var clipStartTicks: Int64?
    /// The music video card shown over a clip.
    var themeInfo: ThemeInfo?
}

/// The streams tried in turn when a title won't play, each asking the server
/// for something safer. Kept per queue entry, so a track change keeps it and
/// the next episode starts afresh.
nonisolated enum StreamFallback: Int, Hashable, Sendable, Comparable {
    /// Direct play when the profile allows it, else what the server picks.
    case none
    /// Direct play and direct stream off; the server may still copy streams.
    case serverTranscode
    /// A fresh 8-bit H.264 + AAC encode, copying nothing from the file.
    case mostCompatible

    static func < (lhs: StreamFallback, rhs: StreamFallback) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the player is asked to play. A single item or a sequence (extras in order).
nonisolated struct PlaybackRequest: Identifiable, Hashable, Sendable {
    var id = UUID()
    var items: [PlaybackQueueItem]

    init(itemId: String, startTicks: Int64 = 0, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil) {
        items = [PlaybackQueueItem(itemId: itemId, startTicks: startTicks, audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex)]
    }

    init(itemIds: [String]) {
        items = itemIds.map { PlaybackQueueItem(itemId: $0) }
    }

    /// Just part of an item, e.g. an episode's opening, without touching its
    /// resume point or watched state. `info` fills the music video card.
    init(clipOf itemId: String, fromTicks startTicks: Int64, toTicks endTicks: Int64, info: ThemeInfo? = nil) {
        items = [PlaybackQueueItem(itemId: itemId, startTicks: startTicks, endTicks: endTicks, clipStartTicks: startTicks, themeInfo: info)]
    }
}

@Observable
final class PlaybackCoordinator {
    let player = AVPlayer()
    private(set) var currentItem: BaseItem?
    private(set) var errorMessage: String?
    private(set) var isFinished = false

    /// Intro and credits markers for the current item, and the one the
    /// playhead is inside right now.
    private(set) var segments: [MediaSegment] = []
    private(set) var activeSegment: MediaSegment?
    /// The episode after this one, when playing the last item of the queue.
    private(set) var upNext: BaseItem?
    /// True near the end of an episode, when "Play Next Episode" is offered.
    private(set) var showsUpNextAction = false
    /// True once an episode has ended and the Up Next card is holding the screen.
    private(set) var endCardVisible = false
    /// Seconds left before the next episode starts on its own.
    private(set) var countdown: Int?

    /// The current title's audio and subtitle tracks as the server lists them,
    /// which includes ones the stream does not carry yet.
    private(set) var audioTracks: [MediaStream] = []
    private(set) var subtitleTracks: [MediaStream] = []
    /// Server stream indexes now in use; -1 means subtitles are off.
    private(set) var selectedAudioIndex: Int?
    private(set) var selectedSubtitleIndex = -1

    /// The music video card for the clip playing, if it has one.
    var themeInfo: ThemeInfo? {
        index < queue.count ? queue[index].themeInfo : nil
    }

    /// The clip's stretch of the episode, in seconds, for timing that card.
    var clipRange: ClosedRange<Double>? {
        guard index < queue.count, let start = queue[index].clipStartTicks, let end = queue[index].endTicks, end > start else { return nil }
        return Double(start) / 10_000_000 ... Double(end) / 10_000_000
    }

    private let autoplayNext: Bool
    private let autoSkipIntro: Bool
    private let preferences: PlaybackPreferences
    private var autoSkipped: Set<String> = []
    private var countdownTask: Task<Void, Never>?

    private let client: JellyfinClient
    private var queue: [PlaybackQueueItem]
    private var index = 0

    private var playSessionId: String?
    private var mediaSourceId: String?
    private var liveStreamId: String?
    private var isLive = false
    private var playMethod = "DirectPlay"
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var mediaSelectionObserver: NSObjectProtocol?
    private var subtitleObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    /// Watches play and pause for the whole session, across items.
    private var pauseObservation: NSKeyValueObservation?
    /// When playback last paused; nil while it plays.
    private var pausedSince: Date?

    /// The subtitle line(s) under the playhead, drawn over the video by
    /// `SubtitleOverlayView`; nil when nothing is showing.
    private(set) var subtitleText: String?
    /// True while the chosen track is being fetched from the server.
    private(set) var isLoadingSubtitles = false
    private var subtitleCues: [SubtitleCue] = []
    private var subtitleTask: Task<Void, Never>?
    /// The audio language to pick when the stream offers several tracks.
    private var preferredAudioLanguage: String?
    private var lastReport = Date.distantPast
    /// The current item is ready and playing.
    private(set) var hasStarted = false
    private var stopped = false

    init(client: JellyfinClient, request: PlaybackRequest, autoplayNext: Bool = true, autoSkipIntro: Bool = false, preferences: PlaybackPreferences = PlaybackPreferences()) {
        self.client = client
        self.queue = request.items
        self.autoplayNext = autoplayNext
        self.autoSkipIntro = autoSkipIntro
        self.preferences = preferences
    }

    // MARK: Lifecycle

    func start() {
        guard !queue.isEmpty else {
            errorMessage = "There is nothing to play."
            return
        }
        player.allowsExternalPlayback = true
        pauseObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.player.timeControlStatus == .paused {
                    if self.pausedSince == nil { self.pausedSince = Date() }
                } else {
                    self.pausedSince = nil
                }
            }
        }
        Task { await play(index: 0) }
    }

    /// Whether the viewer had paused before the full-screen player began to
    /// close. AVKit can pause on its own while the player closes, so a pause
    /// in the last moment doesn't count: only one that had already lasted a
    /// second, longer than the close takes.
    var wasPausedByViewer: Bool {
        guard let pausedSince else { return false }
        return Date().timeIntervalSince(pausedSince) > 1
    }

    /// Stops playback and reports the final position. Safe to call more than once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        countdownTask?.cancel()
        let position = currentPositionTicks
        pauseObservation = nil
        player.pause()
        removeObservers()
        if hasStarted, reportsPlayback, let item = currentItem {
            let report = makeReport(itemId: item.id, position: position, paused: true)
            Task { await client.reportStopped(report) }
        }
        if let liveStreamId {
            let id = liveStreamId
            Task { await client.closeLiveStream(id) }
        }
        stopUnreportedTranscode()
        subtitleTask?.cancel()
        player.replaceCurrentItem(with: nil)
    }

    /// A clip sends no playback reports, so the server never hears that its
    /// stream stopped; its transcode is ended here instead.
    private func stopUnreportedTranscode() {
        guard !reportsPlayback, let playSessionId else { return }
        let client = client
        Task { await client.stopTranscoding(playSessionId: playSessionId) }
    }

    private var currentPositionTicks: Int64 {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(seconds * 10_000_000)
    }

    // MARK: Queue

    private func play(index: Int) async {
        guard index < queue.count else {
            isFinished = true
            return
        }
        self.index = index
        let entry = queue[index]
        hasStarted = false
        removeObservers()

        segments = []
        activeSegment = nil
        upNext = nil
        showsUpNextAction = false
        autoSkipped = []

        do {
            let item = try await client.item(entry.itemId)
            currentItem = item
            // A clip (an OP or ED) plays without subtitles or other audio
            // tracks: pulling ASS tracks out of an MKV can take the server
            // longer than the player waits, and a song doesn't need them.
            let isClip = entry.endTicks != nil
            var info = try await client.playbackInfo(
                itemId: entry.itemId,
                startTicks: entry.startTicks,
                maxBitrate: AppSettings.maxBitrate,
                audioStreamIndex: entry.audioStreamIndex,
                subtitleStreamIndex: isClip ? -1 : entry.subtitleStreamIndex,
                allowDirect: entry.fallback == .none,
                mostCompatible: entry.fallback == .mostCompatible
            )
            if let code = info.errorCode {
                throw JellyfinError.http(0, code)
            }
            guard var source = info.mediaSources.first else {
                throw JellyfinError.http(0, "No media source")
            }

            // Decide live-ness for this title before anything reads it.
            isLive = source.isInfiniteStream == true || item.kind == .tvChannel
            let streams = isLive || isClip ? [] : (source.mediaStreams ?? [])
            audioTracks = streams.filter { $0.type == "Audio" }
            subtitleTracks = streams.filter { $0.type == "Subtitle" }
            selectedAudioIndex = entry.audioStreamIndex ?? source.defaultAudioStreamIndex ?? audioTracks.first?.index
            preferredAudioLanguage = audioTracks.first { $0.index == entry.audioStreamIndex }?.language ?? preferences.audioLanguage

            // The subtitle track to show: an explicit choice, else the user's
            // preferences applied to this title's tracks, else the server's
            // default. Text tracks are fetched and drawn by the app, so the
            // server only needs telling when a picture-based track (PGS,
            // VobSub) must be burned in, or when it burned one in unasked.
            let chosenSubtitle = isClip ? -1 : Self.resolveSubtitle(for: entry, source: source, among: subtitleTracks, preferences: preferences)
            let wantBurnedIn = Self.isBurnedIn(chosenSubtitle, among: subtitleTracks) ? chosenSubtitle : nil
            if wantBurnedIn != Self.burnedInSubtitle(in: source) {
                let corrected = try await client.playbackInfo(
                    itemId: entry.itemId,
                    startTicks: entry.startTicks,
                    maxBitrate: AppSettings.maxBitrate,
                    audioStreamIndex: entry.audioStreamIndex,
                    subtitleStreamIndex: wantBurnedIn ?? -1,
                    allowDirect: entry.fallback == .none,
                    mostCompatible: entry.fallback == .mostCompatible
                )
                if corrected.errorCode == nil, let correctedSource = corrected.mediaSources.first {
                    info = corrected
                    source = correctedSource
                }
            }
            selectedSubtitleIndex = chosenSubtitle
            playSessionId = info.playSessionId
            mediaSourceId = source.id
            liveStreamId = source.liveStreamId
            isLive = source.isInfiniteStream == true || item.kind == .tvChannel

            let url: URL
            let asset: AVURLAsset
            let container = (source.container ?? "").lowercased()
            let directContainers = ["mp4", "m4v", "mov"]
            let canDirectPlay = source.supportsDirectPlay == true
                && entry.fallback == .none
                && directContainers.contains(where: { container.contains($0) })

            if isLive {
                // Live channels: the server's HLS stream, or a tuner that already speaks HLS.
                if let transcoding = source.transcodingUrl, let absolute = client.absoluteURL(serverRelative: transcoding) {
                    url = absolute
                    playMethod = "Transcode"
                } else if let path = source.path, path.lowercased().contains("m3u8"), let direct = URL(string: path), direct.scheme?.hasPrefix("http") == true {
                    url = direct
                    playMethod = "DirectPlay"
                } else {
                    throw JellyfinError.http(0, "This channel's stream format isn't supported on Apple TV.")
                }
                asset = AVURLAsset(url: url)
            } else if canDirectPlay {
                url = client.directStreamURL(itemId: entry.itemId, mediaSourceId: source.id, playSessionId: info.playSessionId, container: source.container)
                playMethod = "DirectPlay"
                asset = AVURLAsset(url: url)
            } else if let transcoding = source.transcodingUrl, let absolute = client.absoluteURL(serverRelative: transcoding) {
                url = absolute
                playMethod = "Transcode"
                asset = AVURLAsset(url: url)
            } else if entry.fallback == .none, source.supportsDirectStream == true || source.supportsDirectPlay == true {
                url = client.directStreamURL(itemId: entry.itemId, mediaSourceId: source.id, playSessionId: info.playSessionId, container: source.container)
                playMethod = "DirectStream"
                asset = AVURLAsset(url: url)
            } else {
                throw JellyfinError.http(0, "This video cannot be played on Apple TV.")
            }
            let playerItem = AVPlayerItem(asset: asset)
            if let endTicks = entry.endTicks {
                // A clip: the player stops here and reports reaching the end.
                playerItem.forwardPlaybackEndTime = CMTime(value: endTicks, timescale: 10_000_000)
            }
            // AVKit's info panel reads the asset's own metadata and expects it
            // loaded ("caller's responsibility"); load it alongside the artwork.
            async let assetMetadata = asset.load(.commonMetadata, .metadata)
            playerItem.externalMetadata = await Self.metadata(for: item, client: client)
            _ = try? await assetMetadata
            #if os(tvOS)
            playerItem.navigationMarkerGroups = Self.chapterMarkers(for: item)
            #endif
            player.appliesMediaSelectionCriteriaAutomatically = true
            installObservers(for: playerItem, startTicks: isLive ? 0 : entry.startTicks)
            player.replaceCurrentItem(with: playerItem)
            player.play()
            // The subtitle fetch runs alongside; cues appear once it lands.
            loadSubtitles()

            // Markers and the following episode load after playback starts so
            // they never delay it; results are dropped if the item changed.
            let client = client
            #if os(tvOS)
            async let artwork = Self.chapterArtwork(for: item, client: client)
            #endif
            // A clip gets no skip markers (Skip Intro would skip the very
            // opening asked for) and no Up Next.
            let loadedSegments = isLive || isClip ? [] : ((try? await client.mediaSegments(itemId: entry.itemId)) ?? [])
            let next = item.kind == .episode && !isClip && index + 1 >= queue.count ? await resolveNextEpisode(after: item) : nil
            guard currentItem?.id == item.id else { return }
            segments = loadedSegments
            upNext = next
            #if os(tvOS)
            // Chapter names show at once; their frames replace them when ready.
            let frames = await artwork
            if !frames.isEmpty, currentItem?.id == item.id {
                playerItem.navigationMarkerGroups = Self.chapterMarkers(for: item, artwork: frames)
            }
            #endif
        } catch {
            handlePlaybackFailure(error.localizedDescription)
        }
    }

    // MARK: Track selection

    /// The subtitle track for a title: the entry's explicit choice (-1 for
    /// none) wins, then the user's preferences, then the server's default.
    private static func resolveSubtitle(for entry: PlaybackQueueItem, source: MediaSourceInfo, among tracks: [MediaStream], preferences: PlaybackPreferences) -> Int {
        if let explicit = entry.subtitleStreamIndex { return explicit }
        let serverDefault = source.defaultSubtitleStreamIndex ?? -1
        let language = preferences.subtitleLanguage
        /// The first track in the preferred language, else the first at all.
        func first(in candidates: [MediaStream]) -> Int? {
            let inLanguage = candidates.first { LanguageTag.sameLanguage($0.language, language) }
            return (inLanguage ?? candidates.first)?.index
        }
        switch preferences.subtitleMode {
        case .none:
            return -1
        case .always:
            let full = tracks.filter { $0.isForced != true }
            if let match = full.first(where: { LanguageTag.sameLanguage($0.language, language) }) {
                return match.index ?? -1
            }
            return serverDefault >= 0 ? serverDefault : (first(in: full) ?? first(in: tracks) ?? -1)
        case .onlyForced:
            return first(in: tracks.filter { $0.isForced == true }) ?? -1
        case .default, .smart:
            return serverDefault
        }
    }

    /// Text tracks are fetched and drawn by the app; the rest (PGS, VobSub)
    /// are pictures the server has to burn into the video.
    private static func isTextTrack(_ track: MediaStream) -> Bool {
        track.isTextSubtitleStream ?? (track.deliveryMethod != "Encode")
    }

    /// Whether choosing `streamIndex` means a burned-in stream.
    private static func isBurnedIn(_ streamIndex: Int, among tracks: [MediaStream]) -> Bool {
        guard let track = tracks.first(where: { $0.index == streamIndex }) else { return false }
        return !isTextTrack(track)
    }

    /// The track the server burned into its stream, read from the stream's
    /// URL; nil for none (and always for direct play).
    private static func burnedInSubtitle(in source: MediaSourceInfo) -> Int? {
        guard let transcoding = source.transcodingUrl,
              let items = URLComponents(string: transcoding)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }
        guard value("subtitlemethod")?.lowercased() == "encode" else { return nil }
        return value("subtitlestreamindex").flatMap { Int($0) }
    }

    /// Picks the audio track once the item can play. Direct play exposes the
    /// file's own tracks in the file's order; otherwise they are matched by
    /// language. Any subtitle track inside the stream is turned off, since
    /// the app draws the chosen one itself.
    private func applyTrackSelection(to item: AVPlayerItem) async {
        guard !isLive else { return }
        let asset = item.asset
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            if playMethod == "DirectPlay", let wanted = selectedAudioIndex,
               group.options.count == audioTracks.count,
               let position = audioTracks.firstIndex(where: { $0.index == wanted }) {
                item.select(group.options[position], in: group)
            } else if let language = preferredAudioLanguage,
                      let option = Self.option(in: group.options, language: language) {
                item.select(option, in: group)
            }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            item.select(nil, in: group)
        }
    }

    // MARK: Subtitles

    /// Fetches the chosen text track and starts showing its cues. Nothing
    /// to fetch for none, or for a track burned into the picture.
    private func loadSubtitles() {
        subtitleTask?.cancel()
        subtitleCues = []
        subtitleText = nil
        isLoadingSubtitles = false
        guard index < queue.count, let mediaSourceId,
              let track = subtitleTracks.first(where: { $0.index == selectedSubtitleIndex }),
              Self.isTextTrack(track), let streamIndex = track.index else { return }
        let itemId = queue[index].itemId
        let client = client
        isLoadingSubtitles = true
        subtitleTask = Task { [weak self] in
            do {
                let cues = try await client.subtitleCues(itemId: itemId, mediaSourceId: mediaSourceId, streamIndex: streamIndex)
                guard !Task.isCancelled, let self else { return }
                self.isLoadingSubtitles = false
                guard self.selectedSubtitleIndex == streamIndex else { return }
                self.subtitleCues = cues
                self.updateSubtitleText()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoadingSubtitles = false
                #if DEBUG
                print("DEBUG subtitles: track \(streamIndex) failed to load: \(error)")
                #endif
            }
        }
    }

    /// Called ten times a second: shows the cue under the playhead.
    private func updateSubtitleText() {
        let time = player.currentTime().seconds
        let text = time.isFinite ? SubtitleCue.text(at: time, in: subtitleCues) : nil
        if text != subtitleText {
            subtitleText = text
        }
    }

    /// Drops the app's cues, e.g. when a track inside the stream takes over.
    private func clearSubtitles() {
        subtitleTask?.cancel()
        subtitleCues = []
        subtitleText = nil
        isLoadingSubtitles = false
    }

    // MARK: Changing tracks during playback

    /// Switches audio in place when the file's own tracks are playing,
    /// otherwise asks the server for a stream with the chosen track and
    /// carries on from the current position (a transcode has one track).
    func selectAudio(_ streamIndex: Int) {
        guard streamIndex != selectedAudioIndex, !isLive, let item = player.currentItem else { return }
        Task {
            // Direct play exposes every audio track, in the file's order.
            if playMethod == "DirectPlay",
               let position = audioTracks.firstIndex(where: { $0.index == streamIndex }),
               let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
               group.options.count == audioTracks.count {
                item.select(group.options[position], in: group)
                selectedAudioIndex = streamIndex
                queue[index].audioStreamIndex = streamIndex
                return
            }
            restart(audio: streamIndex, subtitle: selectedSubtitleIndex)
        }
    }

    /// Shows another subtitle track, or none. Text tracks swap in place; a
    /// burned-in track, coming or going, needs a new stream from the server.
    func selectSubtitle(_ streamIndex: Int) {
        guard streamIndex != selectedSubtitleIndex, !isLive, index < queue.count else { return }
        if Self.isBurnedIn(selectedSubtitleIndex, among: subtitleTracks) || Self.isBurnedIn(streamIndex, among: subtitleTracks) {
            restart(audio: selectedAudioIndex, subtitle: streamIndex)
            return
        }
        selectedSubtitleIndex = streamIndex
        queue[index].subtitleStreamIndex = streamIndex
        loadSubtitles()
        // A track turned on from the system menu plays inside the stream
        // and would double up with the app's cues.
        if let item = player.currentItem {
            Task {
                if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                    item.select(nil, in: group)
                }
            }
        }
    }

    /// Plays the current title again from where it is, with new tracks.
    private func restart(audio: Int?, subtitle: Int) {
        guard index < queue.count else { return }
        queue[index].audioStreamIndex = audio
        queue[index].subtitleStreamIndex = subtitle
        queue[index].startTicks = currentPositionTicks
        reportStoppedIfStarted()
        Task { await play(index: index) }
    }

    /// The stream's option in a language, however either side spells it.
    private static func option(in options: [AVMediaSelectionOption], language: String) -> AVMediaSelectionOption? {
        let wanted = language.lowercased()
        let wantedBcp = LanguageTag.bcp47(from: wanted)
        return options.first { option in
            if let code = option.locale?.language.languageCode {
                if code.identifier(.alpha3)?.lowercased() == wanted ||
                    code.identifier(.alpha2)?.lowercased() == wanted ||
                    code.identifier(.alpha2)?.lowercased() == wantedBcp {
                    return true
                }
            }
            if let tag = option.extendedLanguageTag?.lowercased() {
                if tag == wanted || tag == wantedBcp || tag.hasPrefix(wanted + "-") || tag.hasPrefix(wantedBcp + "-") {
                    return true
                }
            }
            return false
        }
    }

    /// The episode after this one in its series, skipping missing ones and
    /// specials (unless the current episode is itself a special).
    private func resolveNextEpisode(after episode: BaseItem) async -> BaseItem? {
        guard let seriesId = episode.seriesId,
              let all = try? await client.episodes(seriesId: seriesId, seasonId: nil),
              let position = all.firstIndex(where: { $0.id == episode.id }) else { return nil }
        let inSpecials = (episode.parentIndexNumber ?? 1) == 0
        return all.dropFirst(position + 1).first { candidate in
            candidate.locationType != "Virtual" && (inSpecials || (candidate.parentIndexNumber ?? 1) != 0)
        }
    }

    private func advance() {
        reportStoppedIfStarted()
        if let liveStreamId {
            let id = liveStreamId
            Task { await client.closeLiveStream(id) }
            self.liveStreamId = nil
        }
        showsUpNextAction = false
        activeSegment = nil
        if index + 1 >= queue.count, upNext != nil {
            // Hold on the Up Next card instead of closing the player.
            player.pause()
            endCardVisible = true
            if autoplayNext { startCountdown() }
            return
        }
        Task { await play(index: index + 1) }
    }

    /// False while playing a clip, which must leave the episode's resume
    /// point and watched state as they were.
    private var reportsPlayback: Bool {
        !(index < queue.count && queue[index].endTicks != nil)
    }

    /// Before replacing the stream: ends the old one on the server.
    private func reportStoppedIfStarted() {
        stopUnreportedTranscode()
        guard hasStarted, let item = currentItem else { return }
        hasStarted = false
        guard reportsPlayback else { return }
        let report = makeReport(itemId: item.id, position: currentPositionTicks, paused: true)
        Task { await client.reportStopped(report) }
    }

    // MARK: Falling back

    /// Called when a title won't play. A title that was already playing has
    /// shown its format works, so the failure is a stall (the server or the
    /// network falling behind, e.g. CoreMedia -12889): the same stream is
    /// reloaded from where it stopped, twice at most, without asking the
    /// server for a heavier encode. A title that never started tries a safer
    /// stream instead: a server transcode, then a fresh H.264 + AAC encode.
    /// Only when nothing works does the "Can't Play" alert appear.
    private func handlePlaybackFailure(_ message: String) {
        guard !stopped, index < queue.count else { return }
        let entry = queue[index]

        if hasStarted || entry.hasPlayed, entry.stallRetries < 2 {
            #if DEBUG
            print("DEBUG playback: stalled while playing (\(message)); reloading the same stream (\(entry.stallRetries + 1) of 2)")
            #endif
            let position = isLive ? 0 : currentPositionTicks
            reportStoppedIfStarted()
            if let liveStreamId {
                let id = liveStreamId
                Task { await client.closeLiveStream(id) }
                self.liveStreamId = nil
            }
            queue[index].stallRetries += 1
            queue[index].startTicks = position
            Task { await play(index: index) }
            return
        }

        // A transcode that failed gains nothing from another transcode that
        // may copy the same streams, so it goes straight to a fresh encode.
        let alreadyTranscoding = playMethod == "Transcode" || isLive
        let next: StreamFallback? = switch entry.fallback {
        case .none: alreadyTranscoding ? .mostCompatible : .serverTranscode
        case .serverTranscode: .mostCompatible
        case .mostCompatible: nil
        }
        guard let next else {
            #if DEBUG
            print("DEBUG playback: giving up at \(entry.fallback) (\(message)); started \(hasStarted), played before \(entry.hasPlayed), reloads \(entry.stallRetries)")
            #endif
            errorMessage = message
            return
        }
        #if DEBUG
        print("DEBUG playback: \(playMethod) failed (\(message)); retrying as \(next)")
        #endif
        let position = hasStarted && !isLive ? currentPositionTicks : entry.startTicks
        reportStoppedIfStarted()
        if let liveStreamId {
            let id = liveStreamId
            Task { await client.closeLiveStream(id) }
            self.liveStreamId = nil
        }
        queue[index].fallback = next
        // A new kind of stream has yet to prove itself.
        queue[index].hasPlayed = false
        queue[index].stallRetries = 0
        queue[index].startTicks = position
        Task { await play(index: index) }
    }

    // MARK: Tuning

    /// Carries on playing, e.g. in the mini player after the full-screen
    /// player closes; AVKit may pause as it goes.
    func resume() {
        guard !stopped else { return }
        player.play()
    }

    /// Plays another item in place of the current one, keeping this player:
    /// how the Live TV mini player changes channel without being rebuilt.
    func tune(_ itemId: String) {
        guard !stopped, index < queue.count, currentItem?.id != itemId else { return }
        reportStoppedIfStarted()
        if let liveStreamId {
            let id = liveStreamId
            Task { await client.closeLiveStream(id) }
            self.liveStreamId = nil
        }
        errorMessage = nil
        queue[index] = PlaybackQueueItem(itemId: itemId)
        Task { await play(index: index) }
    }

    // MARK: Skipping and Up Next

    /// Jumps past the intro or credits the playhead is inside.
    func skipActiveSegment() {
        guard let segment = activeSegment else { return }
        activeSegment = nil
        let target = CMTime(value: segment.endTicks, timescale: 10_000_000)
        Task { await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .positiveInfinity) }
    }

    /// Starts the next episode now, from the Up Next card or the in-player action.
    func playUpNextNow() {
        guard let next = upNext else { return }
        cancelCountdown()
        endCardVisible = false
        reportStoppedIfStarted()
        queue.append(PlaybackQueueItem(itemId: next.id, startTicks: next.userData?.playbackPositionTicks ?? 0))
        upNext = nil
        Task { await play(index: index + 1) }
    }

    /// Closes the Up Next card and ends playback.
    func dismissEndCard() {
        cancelCountdown()
        endCardVisible = false
        isFinished = true
    }

    private func startCountdown() {
        cancelCountdown()
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

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    /// Called twice a second: tracks which marker the playhead is in, skips
    /// intros when asked, and decides when to offer the next episode.
    private func updateTimedState() {
        guard hasStarted, !isLive else { return }
        let ticks = currentPositionTicks
        let inside = segments.first { $0.contains(ticks: ticks) }
        if inside?.id != activeSegment?.id {
            activeSegment = inside
        }
        if autoSkipIntro, let segment = inside, segment.type == "Intro", !autoSkipped.contains(segment.id) {
            autoSkipped.insert(segment.id)
            skipActiveSegment()
        }
        let runTime = currentItem?.runTimeTicks ?? 0
        var offer = false
        if upNext != nil, runTime > 0 {
            let creditsStart = segments.first { $0.type == "Outro" }?.startTicks
            let threshold = creditsStart ?? max(runTime - 30 * 10_000_000, Int64(Double(runTime) * 0.92))
            offer = ticks >= threshold
        }
        if offer != showsUpNextAction {
            showsUpNextAction = offer
        }
    }

    // MARK: Observation and reporting

    private func installObservers(for item: AVPlayerItem, startTicks: Int64) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch observed.status {
                case .readyToPlay:
                    if startTicks > 0, !self.hasStarted {
                        let time = CMTime(value: startTicks, timescale: 10_000_000)
                        await self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
                    }
                    if !self.hasStarted {
                        await self.applyTrackSelection(to: observed)
                        self.hasStarted = true
                        if self.index < self.queue.count {
                            self.queue[self.index].hasPlayed = true
                        }
                        if let current = self.currentItem, current.kind == .tvChannel {
                            RecentChannels.record(current.id)
                        }
                        if self.reportsPlayback, let current = self.currentItem {
                            let report = self.makeReport(itemId: current.id, position: startTicks, paused: false)
                            await self.client.reportStart(report)
                        }
                    }
                case .failed:
                    // Ignore a failure from an item already replaced by a retry.
                    guard self.player.currentItem === observed else { return }
                    self.handlePlaybackFailure(observed.error?.localizedDescription ?? "Playback failed.")
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advance()
            }
        }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }

        subtitleObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 10), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSubtitleText()
            }
        }

        mediaSelectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.mediaSelectionDidChange()
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let subtitleObserver {
            player.removeTimeObserver(subtitleObserver)
            self.subtitleObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(mediaSelectionObserver)
            self.mediaSelectionObserver = nil
        }
        statusObservation = nil
    }

    /// Responds to native Apple TV Subtitles and Audio menu selections.
    private func mediaSelectionDidChange() {
        guard let item = player.currentItem else { return }
        Task {
            // A track picked from the system Subtitles menu plays inside the
            // stream (a file's own text track, or closed captions), so the
            // app's cues step aside for it.
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
               item.currentMediaSelection.selectedMediaOption(in: group) != nil,
               !subtitleCues.isEmpty || isLoadingSubtitles {
                clearSubtitles()
            }
            // Only direct play offers more than one audio option (the file's
            // own tracks); they carry no server index, so match by name or language.
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
                let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                if let selected {
                    let tag = (selected.extendedLanguageTag ?? selected.locale?.language.languageCode?.identifier)?.lowercased()
                    let bcpTag = tag.flatMap { LanguageTag.bcp47(from: $0) }
                    if let matched = audioTracks.first(where: { track in
                        let trackBcp = LanguageTag.bcp47(from: track.language)
                        return track.trackTitle == selected.displayName ||
                            track.displayTitle == selected.displayName ||
                            track.title == selected.displayName ||
                            (bcpTag != nil && bcpTag == trackBcp)
                    }) {
                        selectedAudioIndex = matched.index
                    }
                }
            }
            if hasStarted, reportsPlayback, let current = currentItem {
                let report = makeReport(itemId: current.id, position: currentPositionTicks, paused: player.timeControlStatus != .playing)
                await client.reportProgress(report)
            }
        }
    }

    private func tick() {
        updateTimedState()
        // A minute of smooth playback after a reload ends the stall streak.
        if hasStarted, index < queue.count, queue[index].stallRetries > 0,
           currentPositionTicks - queue[index].startTicks > 60 * 10_000_000 {
            queue[index].stallRetries = 0
        }
        guard hasStarted, reportsPlayback, let item = currentItem, Date().timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = Date()
        let report = makeReport(itemId: item.id, position: currentPositionTicks, paused: player.timeControlStatus != .playing)
        Task { await client.reportProgress(report) }
    }

    private func makeReport(itemId: String, position: Int64, paused: Bool) -> PlaybackReport {
        PlaybackReport(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: position,
            isPaused: paused,
            canSeek: !isLive,
            playMethod: playMethod,
            liveStreamId: liveStreamId,
            audioStreamIndex: selectedAudioIndex,
            subtitleStreamIndex: selectedSubtitleIndex >= 0 ? selectedSubtitleIndex : nil
        )
    }

    // MARK: System player metadata

    private static func metadata(for item: BaseItem, client: JellyfinClient) async -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        var title = item.displayTitle
        var overview = item.overview
        if item.kind == .episode, let series = item.seriesName {
            title = series
            items.append(metadataItem(.iTunesMetadataTrackSubTitle, value: [item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · ")))
        }
        if item.kind == .tvChannel {
            title = [item.channelNumber, item.name].compactMap { $0 }.joined(separator: " ")
            if let program = item.currentProgram {
                items.append(metadataItem(.iTunesMetadataTrackSubTitle, value: [program.name, program.episodeTitle].compactMap { $0 }.joined(separator: " · ")))
                overview = program.overview
            }
        }
        items.append(metadataItem(.commonIdentifierTitle, value: title))
        if let overview {
            items.append(metadataItem(.commonIdentifierDescription, value: overview))
        }
        if let url = client.landscapeURL(for: item, width: 1200) ?? client.posterURL(for: item),
           let data = try? await client.data(from: url) {
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = data as NSData
            artwork.dataType = kCMMetadataBaseDataType_JPEG as String
            artwork.extendedLanguageTag = "und"
            items.append(artwork)
        }
        return items
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    #if os(tvOS)
    /// The Chapters panel's markers: names, plus each chapter's frame from
    /// `artwork` (keyed by chapter index) once it has loaded. tvOS only: the
    /// iOS player has no chapters panel.
    private static func chapterMarkers(for item: BaseItem, artwork: [Int: Data] = [:]) -> [AVNavigationMarkersGroup] {
        guard let chapters = item.chapters, chapters.count > 1 else { return [] }
        let total = item.runTimeTicks ?? 0
        var groups: [AVTimedMetadataGroup] = []
        for (index, chapter) in chapters.enumerated() {
            let start = CMTime(value: chapter.startPositionTicks, timescale: 10_000_000)
            let endTicks = index + 1 < chapters.count ? chapters[index + 1].startPositionTicks : total
            let end = CMTime(value: max(endTicks, chapter.startPositionTicks + 10_000_000), timescale: 10_000_000)
            var items = [metadataItem(.commonIdentifierTitle, value: chapter.name ?? "Chapter \(index + 1)")]
            if let data = artwork[index] {
                let image = AVMutableMetadataItem()
                image.identifier = .commonIdentifierArtwork
                image.value = data as NSData
                image.dataType = kCMMetadataBaseDataType_JPEG as String
                image.extendedLanguageTag = "und"
                items.append(image)
            }
            groups.append(AVTimedMetadataGroup(items: items, timeRange: CMTimeRange(start: start, end: end)))
        }
        return [AVNavigationMarkersGroup(title: "Chapters", timedNavigationMarkers: groups)]
    }
    #endif

    /// Downloads the frames Jellyfin extracted for each chapter, side by side.
    /// Chapters without a frame, or whose download fails, are left out.
    private static func chapterArtwork(for item: BaseItem, client: JellyfinClient) async -> [Int: Data] {
        guard let chapters = item.chapters, chapters.count > 1 else { return [:] }
        return await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, chapter) in chapters.enumerated() {
                guard let tag = chapter.imageTag else { continue }
                let url = client.chapterImageURL(itemId: item.id, index: index, tag: tag)
                group.addTask { (index, try? await client.data(from: url)) }
            }
            var artwork: [Int: Data] = [:]
            for await (index, data) in group {
                if let data { artwork[index] = data }
            }
            return artwork
        }
    }
}
