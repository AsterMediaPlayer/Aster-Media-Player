//
//  MusicPlayer.swift
//  AsterFIN
//
//  The app's one audio player: a queue of songs played through AVPlayer,
//  with shuffle and repeat, progress reported to Jellyfin, and the system's
//  Now Playing info and remote commands kept up to date. With gapless on
//  (Settings ▸ Playback ▸ Music), the next song waits in the player behind
//  the one playing, so it follows without a gap; and the songs coming up
//  are saved ahead on a good connection (`MusicAhead`).
//

import AVFoundation
import Foundation
import MediaPlayer
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum RepeatMode {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var systemImage: String {
        self == .one ? "repeat.1" : "repeat"
    }
}

@Observable
final class MusicPlayer {
    private(set) var queue: [BaseItem] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isShuffled = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var errorMessage: String?
    /// Lyrics for the current song, once fetched; nil when the server has none.
    private(set) var lyrics: Lyrics?
    /// Set when playback starts so the Music screen can present Now Playing.
    var isNowPlayingPresented = false
    /// Called when a new queue starts, so page theme music can step aside.
    var onStart: (() -> Void)?

    /// The lyric line the playhead is on, for synced lyrics.
    var currentLyricIndex: Int? {
        guard let lyrics, lyrics.isSynced else { return nil }
        let ticks = Int64(currentTime * 10_000_000) + (lyrics.metadata?.offset ?? 0)
        return lyrics.lyrics.lastIndex { ($0.start ?? 0) <= ticks }
    }

    var current: BaseItem? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var upNext: [BaseItem] {
        Array(queue.dropFirst(index + 1).prefix(50))
    }

    var hasNext: Bool { index + 1 < queue.count || repeatMode == .all }
    var hasPrevious: Bool { index > 0 || currentTime > 3 }

    /// The sound is decoded here and sent to an AirPlay speaker, never
    /// fetched by the speaker itself (a speaker reaching the server for the
    /// song, with its token, isn't wanted; see `AudiobookPlayer` too).
    private let player: AVQueuePlayer = {
        let player = AVQueuePlayer()
        player.allowsExternalPlayback = false
        // As a plain AVPlayer: a song stops at its end unless one is lined up.
        player.actionAtItemEnd = .pause
        return player
    }()
    /// The next song, already in the player behind the one playing, so it
    /// follows without a gap. Nil with gapless off, on a Sonos room, while
    /// repeating one song, and after the last.
    private struct LinedUp {
        var index: Int
        let id: String
        let item: AVPlayerItem
        let playSessionId: String
    }
    @ObservationIgnored private var linedUp: LinedUp?
    @ObservationIgnored private var linedUpObservation: NSKeyValueObservation?
    @ObservationIgnored private var currentItemObservation: NSKeyValueObservation?
    /// The song tried once more after failing, so a failure isn't retried
    /// for good.
    @ObservationIgnored private var retriedTrackId: String?
    /// How long before a song's end the next is lined up: late enough that
    /// a conversion the server starts for it isn't dropped as idle while
    /// it waits, early enough to be ready in time.
    private static let lineUpLead: TimeInterval = 30
    /// Watches for a song that says it's playing but doesn't move.
    @ObservationIgnored private var stallWatch: Task<Void, Never>?
    /// A song's audio as the server probed it. Songs follow each other without
    /// a gap only when these match: moving on into a different sample rate
    /// (44.1 kHz into 48 kHz, say) left the player counting with no sound.
    private struct AudioShape: Equatable {
        let codec: String?
        let sampleRate: Int?
        let channels: Int?
    }
    @ObservationIgnored private var shapes: [String: AudioShape] = [:]
    /// Whether the songs coming up may be saved yet: only once the song
    /// playing has a minute loaded (or all of it), so a download doesn't
    /// hold up the song just started.
    @ObservationIgnored private var mayFetchAhead = false
    @ObservationIgnored private var shapeLookups: Set<String> = []
    /// Containers the server sends as they are (see `universalAudioURL`).
    private static let playsAsIs: Set<String> = ["mp3", "aac", "m4a", "m4b", "mp4", "flac", "alac", "wav", "aiff"]
    private var client: JellyfinClient?
    /// The order songs were handed to us, kept so shuffle can be undone.
    private var originalOrder: [BaseItem] = []
    private var playSessionId = UUID().uuidString
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var lastReport = Date.distantPast
    private var hasStarted = false
    private var commandsInstalled = false
    private var artworkTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    /// Where to go once the song is ready (back from a Sonos room, say).
    @ObservationIgnored private var pendingSeek: TimeInterval?

    // MARK: Starting

    /// Plays a list of songs from one of them, optionally shuffled (the chosen
    /// song still goes first).
    func play(_ tracks: [BaseItem], startingAt start: Int = 0, shuffled: Bool = false, client: JellyfinClient) {
        let songs = tracks.filter { $0.kind == .audio }
        guard !songs.isEmpty else { return }
        finishCurrent()
        self.client = client
        #if os(iOS)
        sonosIds = []
        #endif
        originalOrder = songs
        let startIndex = min(max(start, 0), songs.count - 1)
        if shuffled {
            var rest = songs
            let first = rest.remove(at: startIndex)
            queue = [first] + rest.shuffled()
            index = 0
            isShuffled = true
        } else {
            queue = songs
            index = startIndex
            isShuffled = false
        }
        isNowPlayingPresented = true
        installRemoteCommands()
        #if !os(macOS)
        observeInterruptions()
        #endif
        RemoteCommandLayout.useForMusic()
        onStart?()
        load()
    }

    /// Adds songs right after the one playing, or at the end of the queue,
    /// without interrupting it; with nothing playing, plays them.
    func enqueue(_ tracks: [BaseItem], next: Bool, client: JellyfinClient) {
        let songs = tracks.filter { $0.kind == .audio }
        guard !songs.isEmpty else { return }
        guard let now = current else {
            play(songs, client: client)
            return
        }
        queue.insert(contentsOf: songs, at: next ? index + 1 : queue.count)
        let original = next ? (originalOrder.firstIndex { $0.id == now.id }.map { $0 + 1 } ?? originalOrder.count) : originalOrder.count
        originalOrder.insert(contentsOf: songs, at: original)
        #if os(iOS)
        if sonos != nil { sendQueueToSonos(at: currentTime, playing: isPlaying) }
        #endif
        queueChanged()
    }

    /// Jumps to a song already in the queue.
    func skip(to track: BaseItem) {
        guard let position = queue.firstIndex(where: { $0.id == track.id }) else { return }
        finishCurrent()
        index = position
        load()
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        guard current != nil else { return }
        #if os(iOS)
        if sonos != nil {
            isPlaying = false
            sonosCommand { try await $0.pause() }
            report(paused: true)
            updateNowPlayingPlayback()
            return
        }
        #endif
        player.pause()
        isPlaying = false
        report(paused: true)
        updateNowPlayingPlayback()
    }

    func resume() {
        guard current != nil else { return }
        #if os(iOS)
        if sonos != nil {
            isPlaying = true
            sonosCommand { try await $0.play() }
            report(paused: false)
            updateNowPlayingPlayback()
            return
        }
        #endif
        Self.activateAudioSession()
        player.play()
        isPlaying = true
        report(paused: false)
        updateNowPlayingPlayback()
    }

    func next() {
        guard current != nil else { return }
        #if DEBUG
        print("DEBUG music: Next pressed")
        #endif
        #if os(iOS)
        if sonos != nil {
            if index + 1 < queue.count {
                sonosGo(to: index + 1)
            } else if repeatMode == .all {
                sonosGo(to: 0)
            } else {
                isPlaying = false
                sonosCommand { try await $0.stop() }
            }
            return
        }
        #endif
        finishCurrent()
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            stopAtEnd()
            return
        }
        load()
    }

    func previous() {
        guard current != nil else { return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
            return
        }
        #if os(iOS)
        if sonos != nil {
            sonosGo(to: index - 1)
            return
        }
        #endif
        finishCurrent()
        index -= 1
        load()
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 10_000_000)
        currentTime = target.seconds
        #if os(iOS)
        if sonos != nil {
            let seconds = target.seconds
            sonosCommand { try await $0.seek(to: seconds) }
            report(paused: !isPlaying)
            updateNowPlayingPlayback()
            return
        }
        #endif
        Task {
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            report(paused: !isPlaying)
            updateNowPlayingPlayback()
        }
    }

    func toggleShuffle() {
        guard let now = current else { return }
        if isShuffled {
            queue = originalOrder
            index = originalOrder.firstIndex(where: { $0.id == now.id }) ?? 0
            isShuffled = false
        } else {
            var rest = queue
            rest.remove(at: index)
            queue = [now] + rest.shuffled()
            index = 0
            isShuffled = true
        }
        #if os(iOS)
        // The room's queue follows the new order, from where it's got to.
        if sonos != nil { sendQueueToSonos(at: currentTime, playing: isPlaying) }
        #endif
        queueChanged()
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        #if os(iOS)
        if sonos != nil {
            let mode = sonosPlayMode
            sonosCommand { try await $0.setPlayMode(mode) }
        }
        #endif
        queueChanged()
    }

    /// Stops and clears the queue, for example on sign-out.
    func stop() {
        #if os(iOS)
        if sonos != nil {
            sonosCommand { try await $0.stop() }
            leaveSonos()
        }
        #endif
        finishCurrent()
        removeObservers()
        stallWatch?.cancel()
        dropLinedUp()
        player.removeAllItems()
        MusicAhead.shared.clear()
        queue = []
        originalOrder = []
        index = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        lyricsTask?.cancel()
        lyrics = nil
        isNowPlayingPresented = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Loading

    private func load() {
        removeObservers()
        dropLinedUp()
        guard let client, let track = current else {
            isPlaying = false
            return
        }
        playSessionId = UUID().uuidString
        hasStarted = false
        currentTime = 0
        duration = TimeInterval(track.runTimeTicks ?? 0) / 10_000_000
        errorMessage = nil

        #if os(iOS)
        // On a Sonos room: it plays this one, from its queue when it's there.
        if sonos != nil {
            if let position = sonosIds.firstIndex(of: track.id), sonosStart + position == index {
                sonosGo(to: index)
            } else {
                sendQueueToSonos(at: 0, playing: true)
            }
            return
        }
        #endif
        Self.activateAudioSession()
        let item = makeItem(for: track, playSessionId: playSessionId, client: client)
        installObservers(for: item)
        watchForAdvance()
        player.removeAllItems()
        player.insert(item, after: nil)
        player.play()
        isPlaying = true
        watchForStalls()
        publishNowPlaying(track)
        fetchLyrics(for: track, client: client)
        songStarted()
    }

    /// A song has started: downloads wait until it's well loaded, and the
    /// formats the next line-up compares are looked up.
    private func songStarted() {
        mayFetchAhead = false
        MusicAhead.shared.hold()
        if let playing = current { _ = shape(of: playing) }
        if let next = followingIndex, queue.indices.contains(next) { _ = shape(of: queue[next]) }
    }

    /// A song's player item: its saved file when `MusicAhead` has it, else
    /// the stream.
    private func makeItem(for track: BaseItem, playSessionId: String, client: JellyfinClient) -> AVPlayerItem {
        if let file = MusicAhead.shared.savedFile(for: track.id) {
            #if DEBUG
            print("DEBUG music: \(track.name ?? track.id) from its saved .\(file.pathExtension)")
            #endif
            return AVPlayerItem(url: file)
        }
        #if DEBUG
        print("DEBUG music: \(track.name ?? track.id) streamed (container \(track.container ?? "?"))")
        #endif
        return AVPlayerItem(url: client.universalAudioURL(itemId: track.id, playSessionId: playSessionId, maxBitrate: AppSettings.musicMaxBitrate))
    }

    // MARK: Gapless and saving ahead

    /// The place in the queue of the song after this one, as it'll play.
    private var followingIndex: Int? {
        guard repeatMode != .one, !queue.isEmpty else { return nil }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode == .all ? 0 : nil
    }

    /// Puts the song after this one in the player behind it, so it follows
    /// without a gap, or takes it out when gapless is off or nothing follows.
    private func lineUpNext() {
        #if os(iOS)
        guard sonos == nil else { return dropLinedUp() }
        #endif
        // Moved on to the lined-up song already: `advanced(to:)` lines up the next.
        if let linedUp, player.currentItem === linedUp.item { return }
        guard AppSettings.gaplessMusic, let client, let playing = player.currentItem,
              let next = followingIndex else { return dropLinedUp() }
        let track = queue[next]
        // Only a song that will play as it is: a saved file, or one the server
        // sends unconverted. A conversion lined up early can be dropped by the
        // server before its turn, leaving the player silent; one not lined up
        // loads when its turn comes, with a short gap.
        guard MusicAhead.shared.savedFile(for: track.id) != nil || Self.streamsAsIs(track) else {
            return dropLinedUp()
        }
        if linedUp?.id == track.id {
            linedUp?.index = next
            return
        }
        // Both songs' formats, looked up once; until they're in, it's tried
        // again on the next tick.
        guard let playingTrack = current, let now = shape(of: playingTrack), let following = shape(of: track) else {
            return dropLinedUp()
        }
        guard now.sampleRate != nil, now == following else {
            #if DEBUG
            print("DEBUG music: not lining up \(track.name ?? track.id): \(String(describing: now)) into \(String(describing: following))")
            #endif
            return dropLinedUp()
        }
        dropLinedUp()
        let session = UUID().uuidString
        let item = makeItem(for: track, playSessionId: session, client: client)
        guard player.canInsert(item, after: playing) else { return }
        player.insert(item, after: playing)
        linedUp = LinedUp(index: next, id: track.id, item: item, playSessionId: session)
        player.actionAtItemEnd = .advance
        // One that fails while it waits is let go, and loads as usual when
        // its turn comes.
        linedUpObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let reason = observed.error?.localizedDescription ?? "unknown"
            Task { @MainActor [weak self] in
                self?.linedUpFailed(observed, reason: reason)
            }
        }
        #if DEBUG
        print("DEBUG music: lined up \(track.name ?? track.id)\(MusicAhead.shared.savedFile(for: track.id) != nil ? " (saved)" : "")")
        #endif
    }

    private func dropLinedUp() {
        if let linedUp, player.currentItem !== linedUp.item {
            player.remove(linedUp.item)
        }
        linedUp = nil
        linedUpObservation = nil
        player.actionAtItemEnd = .pause
    }

    private func linedUpFailed(_ item: AVPlayerItem, reason: String) {
        guard let failed = linedUp, failed.item === item, player.currentItem !== item else { return }
        DebugLog.note("music", "The next song couldn't be lined up (\(reason)); it loads when its turn comes")
        #if DEBUG
        print("DEBUG music: lined-up \(failed.id) failed: \(reason)")
        #endif
        MusicAhead.shared.forget(failed.id)
        dropLinedUp()
    }

    /// A song's format, once looked up (nil until then; the lookup starts on
    /// the first ask).
    private func shape(of track: BaseItem) -> AudioShape? {
        if let known = shapes[track.id] { return known }
        guard let client, shapeLookups.insert(track.id).inserted else { return nil }
        let id = track.id
        Task { [weak self] in
            let item = try? await client.item(id)
            let streams = item?.mediaStreams ?? item?.mediaSources?.first?.mediaStreams ?? []
            let audio = streams.first { $0.type == "Audio" }
            self?.shapes[id] = AudioShape(codec: audio?.codec?.lowercased(), sampleRate: audio?.sampleRate, channels: audio?.channels)
        }
        return nil
    }

    /// Whether the server will send this song as it is: a format played here,
    /// with no lower streaming limit to convert it down to. A song whose
    /// format the list didn't say counts as converted.
    private static func streamsAsIs(_ track: BaseItem) -> Bool {
        guard !AppSettings.musicLimitsQuality, let container = track.container?.lowercased() else { return false }
        return container.split(separator: ",").contains { playsAsIs.contains(String($0)) }
    }

    /// A song that says it's playing but hasn't moved for 15 seconds is
    /// loaded again from where it was, once: a stream the server let go of
    /// stalls without failing.
    private func watchForStalls() {
        stallWatch?.cancel()
        stallWatch = Task { [weak self] in
            var stalledFor: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                #if os(iOS)
                if self.sonos != nil { stalledFor = 0; continue }
                #endif
                #if DEBUG
                let item = self.player.currentItem
                let buffered = item?.loadedTimeRanges.last.map { Int(CMTimeRangeGetEnd($0.timeRangeValue).seconds) } ?? -1
                print("DEBUG music tick: \(self.current?.name ?? "-") playing=\(self.isPlaying) status=\(item?.status.rawValue ?? -1) control=\(self.player.timeControlStatus.rawValue) waiting=\(self.player.reasonForWaitingToPlay?.rawValue ?? "-") rate=\(self.player.rate) t=\(Int(self.player.currentTime().seconds)) buffered=\(buffered) file=\((item?.asset as? AVURLAsset)?.url.isFileURL ?? false) items=\(self.player.items().count) error=\(item?.error?.localizedDescription ?? "-")")
                #endif
                // The song playing is well loaded: the ones coming up may be saved.
                if !self.mayFetchAhead, let item = self.player.currentItem, item.status == .readyToPlay {
                    let isFile = (item.asset as? AVURLAsset)?.url.isFileURL ?? false
                    let loadedTo = item.loadedTimeRanges.last.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds } ?? 0
                    let enough = min(self.currentTime + 60, max(self.duration - 1, 0))
                    if isFile || (loadedTo.isFinite && loadedTo >= enough) {
                        self.mayFetchAhead = true
                        self.saveAhead()
                    }
                }
                if self.isPlaying, self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    stalledFor += 3
                } else {
                    stalledFor = 0
                }
                guard stalledFor >= 15, let track = self.current, self.retriedTrackId != track.id else { continue }
                stalledFor = 0
                self.retriedTrackId = track.id
                DebugLog.note("music", "A song stalled; loading it again from \(Int(self.currentTime)) s")
                #if DEBUG
                print("DEBUG music: \(track.name ?? track.id) stalled, reloading at \(Int(self.currentTime)) s")
                #endif
                MusicAhead.shared.forget(track.id)
                self.pendingSeek = self.currentTime > 1 ? self.currentTime : nil
                self.load()
                return
            }
        }
    }

    /// In the last stretch of the song, when the next one is lined up.
    private var isNearEnd: Bool {
        duration > 0 && duration - currentTime <= Self.lineUpLead
    }

    /// Lines up the next song once near the end, or updates (or drops) the
    /// one lined up already.
    private func refreshLineUp() {
        if linedUp != nil || isNearEnd { lineUpNext() }
    }

    /// Saves the songs coming up, on a good connection.
    private func saveAhead() {
        guard let client, mayFetchAhead else { return }
        #if os(iOS)
        if sonos != nil { return }
        #endif
        let upcoming = Array(queue.dropFirst(index + 1).prefix(MusicAhead.songsAhead))
        MusicAhead.shared.prepare(upcoming: upcoming, playing: current, client: client)
    }

    /// The queue's order or repeat changed: the song lined up, and those
    /// saved ahead, follow it.
    private func queueChanged() {
        guard current != nil else { return }
        refreshLineUp()
        saveAhead()
    }

    /// Settings ▸ Playback ▸ Music changed.
    func musicSettingsChanged() {
        if !AppSettings.musicAhead { MusicAhead.shared.clear() }
        queueChanged()
    }

    /// Follows the player as it moves on to the lined-up song by itself.
    private func watchForAdvance() {
        guard currentItemObservation == nil else { return }
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor [weak self] in
                self?.advanced(to: item)
            }
        }
    }

    /// The song before ended and the lined-up one took over without a gap:
    /// the queue, reports, Now Playing and lyrics catch up with it.
    private func advanced(to item: AVPlayerItem?) {
        guard let next = linedUp, let item, item === next.item else { return }
        #if DEBUG
        print("DEBUG music: moved on to the lined-up song without a gap")
        #endif
        finishCurrent(endedAt: duration)
        removeObservers()
        linedUp = nil
        linedUpObservation = nil
        player.actionAtItemEnd = .pause
        index = next.index
        guard let client, let track = current else { return }
        playSessionId = next.playSessionId
        hasStarted = false
        currentTime = 0
        duration = TimeInterval(track.runTimeTicks ?? 0) / 10_000_000
        errorMessage = nil
        installObservers(for: item)
        isPlaying = true
        watchForStalls()
        publishNowPlaying(track)
        fetchLyrics(for: track, client: client)
        songStarted()
    }

    private func fetchLyrics(for track: BaseItem, client: JellyfinClient) {
        lyricsTask?.cancel()
        lyrics = nil
        lyricsTask = Task { [weak self] in
            let fetched = try? await client.lyrics(itemId: track.id)
            guard !Task.isCancelled, let self, self.current?.id == track.id else { return }
            self.lyrics = fetched
        }
    }

    /// Reports the song that is ending so the server records it, without
    /// touching the queue.
    private func finishCurrent(endedAt end: TimeInterval? = nil) {
        guard hasStarted, let track = current else { return }
        hasStarted = false
        // Past its end the player is on the next song, so its own length.
        let position = end.map { Int64($0 * 10_000_000) } ?? positionTicks
        let report = PlaybackReport(itemId: track.id, playSessionId: playSessionId, positionTicks: position, isPaused: true, playMethod: "DirectPlay")
        Task { await client?.reportStopped(report) }
    }

    private func stopAtEnd() {
        player.pause()
        isPlaying = false
        currentTime = 0
        updateNowPlayingPlayback()
    }

    private func trackEnded(_ ended: AVPlayerItem?) {
        // A lined-up song follows by itself (see `advanced(to:)`), and the
        // end of one the player has already moved on from is old news.
        guard linedUp == nil, let ended, ended === player.currentItem else { return }
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            return
        }
        next()
    }

    private var positionTicks: Int64 {
        #if os(iOS)
        if sonos != nil { return Int64(max(currentTime, 0) * 10_000_000) }
        #endif
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(seconds * 10_000_000)
    }

    /// Activating the session can block, so it is done off the main thread;
    /// AVPlayer activates it implicitly anyway, this just makes it explicit.
    /// Set up as long-form audio first, so AirPlay 2 speakers and groups
    /// are offered and the song is handed to them (see `AudioSessionUse`).
    private static func activateAudioSession() {
        #if !os(macOS)
        Task.detached(priority: .userInitiated) {
            AudioSessionUse.prepare(.longFormAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
    }

    // MARK: Observing

    private func installObservers(for item: AVPlayerItem) {
        // Initial too: a lined-up song is often ready before it takes over.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch observed.status {
                case .readyToPlay:
                    let length = observed.duration.seconds
                    if length.isFinite, length > 0 { self.duration = length }
                    if let resumeAt = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seek(to: resumeAt)
                    }
                    if !self.hasStarted {
                        self.hasStarted = true
                        self.lastReport = Date()
                        self.report(paused: false, start: true)
                        self.updateNowPlayingPlayback()
                    }
                    if self.retriedTrackId == self.current?.id { self.retriedTrackId = nil }
                case .failed:
                    #if DEBUG
                    // Debug builds only: the error can include the stream URL and its token.
                    let underlying = (observed.error as NSError?)?.userInfo[NSUnderlyingErrorKey].map { String(describing: $0) } ?? ""
                    print("DEBUG music: failed \(observed.error?.localizedDescription ?? "unknown") \(String(describing: observed.error)) \(underlying)")
                    #endif
                    let reason = observed.error?.localizedDescription ?? "unknown"
                    // Once more, from a fresh stream: a saved file that won't
                    // open, or a stream the server let go of while it waited.
                    if let track = self.current, self.retriedTrackId != track.id {
                        self.retriedTrackId = track.id
                        DebugLog.note("music", "A song failed (\(reason)); trying a fresh stream")
                        #if DEBUG
                        print("DEBUG music: \(track.name ?? track.id) failed (\(reason)), retrying from a fresh stream")
                        #endif
                        MusicAhead.shared.forget(track.id)
                        self.load()
                        return
                    }
                    DebugLog.note("music", "A song failed again (\(reason))")
                    self.errorMessage = observed.error?.localizedDescription ?? "This song can't be played."
                    self.isPlaying = false
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let ended = note.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                self?.trackEnded(ended)
            }
        }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
                if self.linedUp == nil, self.isNearEnd { self.lineUpNext() }
                if self.hasStarted, Date().timeIntervalSince(self.lastReport) >= 10 {
                    self.lastReport = Date()
                    self.report(paused: !self.isPlaying)
                }
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation = nil
    }

    private func report(paused: Bool, start: Bool = false) {
        guard hasStarted, let track = current, let client else { return }
        let report = PlaybackReport(itemId: track.id, playSessionId: playSessionId, positionTicks: positionTicks, isPaused: paused, playMethod: "DirectPlay")
        Task {
            if start {
                await client.reportStart(report)
            } else {
                await client.reportProgress(report, savingResumePoint: .never)
            }
        }
    }

    // MARK: Sonos

    #if os(iOS)
    /// The Sonos room playing the queue, nil while it plays on this device.
    private(set) var sonosRoom: SonosGroup?
    @ObservationIgnored private var sonos: SonosClient?
    /// The songs in the room's queue, in order, and the place in `queue` of
    /// its first.
    @ObservationIgnored private var sonosIds: [String] = []
    @ObservationIgnored private var sonosStart = 0
    @ObservationIgnored private var sonosPoll: Task<Void, Never>?
    /// Until then, what the room says is left alone: a command is on its way.
    @ObservationIgnored private var sonosSettleUntil = Date.distantPast
    @ObservationIgnored private var sonosFailures = 0

    private var sonosPlayMode: SonosPlayMode {
        switch repeatMode {
        case .off: .normal
        case .all: .repeatAll
        case .one: .repeatOne
        }
    }

    /// Plays on `group`, or back on this device with nil, from where it is.
    func play(on group: SonosGroup?) {
        guard current != nil else { return }
        let at = currentTime
        let playing = isPlaying
        if let group {
            guard group.id != sonosRoom?.id else { return }
            // From one room to another: the first stops.
            if let previous = sonos { Task { try? await previous.stop() } }
            // Quiet here; the room takes over from the same place.
            finishCurrent()
            player.pause()
            removeObservers()
            dropLinedUp()
            player.removeAllItems()
            sonosRoom = group
            sonos = SonosClient(speaker: group.coordinator)
            sendQueueToSonos(at: at, playing: true)
            startSonosPolling()
        } else {
            guard let room = sonos else { return }
            Task { try? await room.pause() }
            finishCurrent()
            leaveSonos()
            pendingSeek = at > 1 ? at : nil
            load()
            if !playing { pause() }
        }
    }

    /// Fills the room's queue from the songs around this one and plays it
    /// from `seconds` in: up to fifty before, so Previous works there, and
    /// five hundred in all.
    private func sendQueueToSonos(at seconds: TimeInterval, playing: Bool) {
        guard let room = sonos, let client else { return }
        let start = max(0, index - 50)
        let slice = Array(queue[start ..< min(queue.count, start + 500)])
        let number = index - start + 1
        let mode = sonosPlayMode
        sonosIds = slice.map(\.id)
        sonosStart = start
        isPlaying = playing
        sonosSettleUntil = Date().addingTimeInterval(30)
        startSonosSession()
        Task {
            do {
                // The files as they are, where a speaker plays them.
                let known = await client.withContainers(slice)
                let tracks = known.map { song in
                    client.sonosTrack(for: song, art: client.posterURL(for: song, width: 600))
                }
                try await room.clearQueue()
                try await room.enqueue(tracks)
                try await room.playFromQueue()
                try? await room.setPlayMode(mode)
                try await room.start(track: number, at: seconds, playing: playing)
                sonosSettleUntil = Date().addingTimeInterval(2)
            } catch {
                sonosLost(error)
            }
        }
    }

    /// To the queue's song at `newIndex`: within the room's queue a jump,
    /// else the queue sent again from there.
    private func sonosGo(to newIndex: Int) {
        guard sonos != nil, queue.indices.contains(newIndex) else { return }
        let position = newIndex - sonosStart
        guard sonosIds.indices.contains(position), sonosIds[position] == queue[newIndex].id else {
            finishCurrent()
            index = newIndex
            sendQueueToSonos(at: 0, playing: true)
            return
        }
        finishCurrent()
        index = newIndex
        currentTime = 0
        duration = TimeInterval(queue[newIndex].runTimeTicks ?? 0) / 10_000_000
        isPlaying = true
        startSonosSession()
        sonosCommand { room in
            try await room.seek(track: position + 1)
            try await room.play()
        }
    }

    /// A command for the room, with the room's word on things put off a
    /// moment while it goes.
    private func sonosCommand(_ command: @escaping @Sendable (SonosClient) async throws -> Void) {
        guard let room = sonos else { return }
        sonosSettleUntil = Date().addingTimeInterval(2)
        Task {
            do {
                try await command(room)
            } catch {
                #if DEBUG
                print("DEBUG sonos: command failed: \(error)")
                #endif
            }
        }
    }

    /// The song playing on the room, as a session of its own on the server.
    private func startSonosSession() {
        playSessionId = UUID().uuidString
        hasStarted = true
        lastReport = Date()
        report(paused: !isPlaying, start: true)
        publishNowPlayingAndLyrics()
    }

    private func publishNowPlayingAndLyrics() {
        guard let track = current else { return }
        publishNowPlaying(track)
        if let client { fetchLyrics(for: track, client: client) }
    }

    private func startSonosPolling() {
        sonosPoll?.cancel()
        sonosFailures = 0
        sonosPoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.followSonos()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// What the room is playing, where, and whether: the screen and the
    /// server follow it.
    private func followSonos() async {
        guard let room = sonos else { return }
        let position: SonosPosition
        let state: SonosTransportState
        do {
            position = try await room.position()
            state = try await room.transportState()
            sonosFailures = 0
        } catch {
            sonosFailures += 1
            if sonosFailures >= 8 { sonosLost(error) }
            return
        }
        guard sonos != nil, Date() >= sonosSettleUntil else { return }
        // Something else took the room over (its own app, a radio station).
        if !position.uri.isEmpty, JellyfinClient.sonosItemId(in: position.uri) == nil {
            isPlaying = false
            leaveSonos()
            updateNowPlayingPlayback()
            return
        }
        // Stopped (at the queue's end, say), a room goes back to its first
        // track at zero, which isn't where listening got to.
        if state == .stopped || state == .noMedia {
            if isPlaying {
                isPlaying = false
                report(paused: true)
                updateNowPlayingPlayback()
            }
            return
        }
        let id = JellyfinClient.sonosItemId(in: position.uri)
        let place = id.flatMap { sonosIds.firstIndex(of: $0) } ?? (position.track - 1)
        if sonosIds.indices.contains(place), sonosStart + place != index {
            finishCurrent()
            index = sonosStart + place
            duration = TimeInterval(queue[index].runTimeTicks ?? 0) / 10_000_000
            startSonosSession()
        }
        currentTime = position.elapsed
        if position.duration > 0 { duration = position.duration }
        let playing = state == .playing || state == .transitioning
        if playing != isPlaying {
            isPlaying = playing
            report(paused: !playing)
        } else if Date().timeIntervalSince(lastReport) >= 10 {
            lastReport = Date()
            report(paused: !isPlaying)
        }
        updateNowPlayingPlayback()
    }

    private func sonosLost(_ error: Error) {
        let name = sonosRoom?.name ?? "The Sonos room"
        #if DEBUG
        print("DEBUG sonos: lost \(name): \(error)")
        #endif
        isPlaying = false
        errorMessage = "\(name) stopped answering."
        leaveSonos()
    }

    private func leaveSonos() {
        sonosPoll?.cancel()
        sonosPoll = nil
        sonos = nil
        sonosRoom = nil
        sonosIds = []
    }
    #endif

    // MARK: System integration

    #if !os(macOS)
    /// A call or Siri paused the audio, so it plays on when they're done.
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var interruptionObservers: [NSObjectProtocol] = []

    /// The system pauses the player itself for a call or Siri (it makes the
    /// audio session inactive): this follows it, so it says paused
    /// meanwhile, and carries on afterwards when the system recommends it.
    private func observeInterruptions() {
        guard interruptionObservers.isEmpty else { return }
        interruptionObservers = observeAudioInterruptions { [weak self] began, shouldResume in
            self?.interrupted(began: began, shouldResume: shouldResume)
        }
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        if began {
            resumeAfterInterruption = isPlaying
            if isPlaying { pause() }
        } else {
            let resume = resumeAfterInterruption && shouldResume
            resumeAfterInterruption = false
            if resume { self.resume() }
        }
    }
    #endif

    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor [weak self] in self?.seek(to: seconds) }
            return .success
        }
    }

    private func publishNowPlaying(_ track: BaseItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPNowPlayingInfoPropertyPlaybackRate: 1,
        ]
        if let artist = track.artistText { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let number = track.indexNumber { info[MPMediaItemPropertyAlbumTrackNumber] = number }
        #if os(iOS)
        // So "I like this song" or "add this to my playlist" means this one.
        if #available(iOS 27.0, *) {
            info[MPNowPlayingInfoPropertyAppEntityIdentifiers] = SiriNowPlaying.identifiers(for: track)
        }
        #endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        artworkTask?.cancel()
        guard let client, let url = client.posterURL(for: track, width: 600) else { return }
        let trackId = track.id
        artworkTask = Task { [weak self] in
            guard let image = await ImageStore.shared.image(for: url, client: client), !Task.isCancelled else { return }
            guard let self, self.current?.id == trackId else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            current[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = current
        }
    }

    private func updateNowPlayingPlayback() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

#if !os(macOS)
/// Observers for the system pausing the audio for a call or Siri, and for
/// its say afterwards on playing on: `handler` gets whether the
/// interruption began, and whether to play on. On iOS and tvOS 27 the
/// system tells it by the session going inactive and a later
/// recommendation; before, by one interruption notice for each end.
func observeAudioInterruptions(_ handler: @escaping @MainActor (_ began: Bool, _ shouldResume: Bool) -> Void) -> [NSObjectProtocol] {
    let session = AVAudioSession.sharedInstance()
    let center = NotificationCenter.default
    if #available(iOS 27, tvOS 27, *) {
        return [
            center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main) { note in
                let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                // Only the system's doing: the app letting the session go
                // itself isn't an interruption.
                guard context?.source == .system else { return }
                MainActor.assumeIsolated { handler(true, false) }
            },
            center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main) { note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                let shouldResume = context?.recommendation == .shouldResume
                MainActor.assumeIsolated { handler(false, shouldResume) }
            },
        ]
    }
    return [
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { note in
            guard let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { handler(type == .began, options.contains(.shouldResume)) }
        },
    ]
}
#endif
