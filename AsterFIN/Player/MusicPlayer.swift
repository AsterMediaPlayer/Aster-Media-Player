//
//  MusicPlayer.swift
//  AsterFIN
//
//  The app's one audio player: a queue of songs played through AVPlayer,
//  with shuffle and repeat, progress reported to Jellyfin, and the system's
//  Now Playing info and remote commands kept up to date.
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
    private let player: AVPlayer = {
        let player = AVPlayer()
        player.allowsExternalPlayback = false
        return player
    }()
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
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        #if os(iOS)
        if sonos != nil {
            let mode = sonosPlayMode
            sonosCommand { try await $0.setPlayMode(mode) }
        }
        #endif
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
        player.replaceCurrentItem(with: nil)
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
        let url = client.universalAudioURL(itemId: track.id, playSessionId: playSessionId, maxBitrate: AppSettings.maxBitrate)
        let item = AVPlayerItem(url: url)
        installObservers(for: item)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        publishNowPlaying(track)
        fetchLyrics(for: track, client: client)
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
    private func finishCurrent() {
        guard hasStarted, let track = current else { return }
        hasStarted = false
        let position = positionTicks
        let report = PlaybackReport(itemId: track.id, playSessionId: playSessionId, positionTicks: position, isPaused: true, playMethod: "DirectPlay")
        Task { await client?.reportStopped(report) }
    }

    private func stopAtEnd() {
        player.pause()
        isPlaying = false
        currentTime = 0
        updateNowPlayingPlayback()
    }

    private func trackEnded() {
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
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
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
                case .failed:
                    #if DEBUG
                    // Debug builds only: the error can include the stream URL and its token.
                    let underlying = (observed.error as NSError?)?.userInfo[NSUnderlyingErrorKey].map { String(describing: $0) } ?? ""
                    print("DEBUG music: failed \(observed.error?.localizedDescription ?? "unknown") \(String(describing: observed.error)) \(underlying)")
                    #endif
                    self.errorMessage = observed.error?.localizedDescription ?? "This song can't be played."
                    self.isPlaying = false
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.trackEnded()
            }
        }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
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
            player.replaceCurrentItem(with: nil)
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
        let tracks = slice.map { song in
            client.sonosTrack(for: song, art: client.posterURL(for: song, width: 600))
        }
        let number = index - start + 1
        let mode = sonosPlayMode
        sonosIds = slice.map(\.id)
        sonosStart = start
        isPlaying = playing
        sonosSettleUntil = Date().addingTimeInterval(30)
        startSonosSession()
        Task {
            do {
                try await room.clearQueue()
                try await room.enqueue(tracks)
                try await room.playFromQueue()
                try? await room.setPlayMode(mode)
                try await room.seek(track: number)
                if seconds > 1 { try? await room.seek(to: seconds) }
                if playing { try await room.play() }
                sonosSettleUntil = Date().addingTimeInterval(2)
            } catch {
                sonosLost(error)
            }
        }
    }

    /// To the queue's song at `newIndex`: within the room's queue a jump,
    /// else the queue sent again from there.
    private func sonosGo(to newIndex: Int) {
        guard let room = sonos, queue.indices.contains(newIndex) else { return }
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
