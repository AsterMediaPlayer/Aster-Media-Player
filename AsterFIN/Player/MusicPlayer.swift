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

    private let player = AVPlayer()
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

    // MARK: Starting

    /// Plays a list of songs from one of them, optionally shuffled (the chosen
    /// song still goes first).
    func play(_ tracks: [BaseItem], startingAt start: Int = 0, shuffled: Bool = false, client: JellyfinClient) {
        let songs = tracks.filter { $0.kind == .audio }
        guard !songs.isEmpty else { return }
        finishCurrent()
        self.client = client
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
        player.pause()
        isPlaying = false
        report(paused: true)
        updateNowPlayingPlayback()
    }

    func resume() {
        guard current != nil else { return }
        Self.activateAudioSession()
        player.play()
        isPlaying = true
        report(paused: false)
        updateNowPlayingPlayback()
    }

    func next() {
        guard current != nil else { return }
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
        finishCurrent()
        index -= 1
        load()
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 10_000_000)
        currentTime = target.seconds
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
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
    }

    /// Stops and clears the queue, for example on sign-out.
    func stop() {
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
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(seconds * 10_000_000)
    }

    /// Activating the session can block, so it is done off the main thread;
    /// AVPlayer activates it implicitly anyway, this just makes it explicit.
    private static func activateAudioSession() {
        #if !os(macOS)
        Task.detached(priority: .userInitiated) {
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

    // MARK: System integration

    #if !os(macOS)
    /// A call or Siri paused the audio, so it plays on when they're done.
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    /// The system pauses the player itself for a call or Siri: this follows
    /// it, so it says paused meanwhile, and carries on afterwards when the
    /// system says it may.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let began = (info[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                self?.interrupted(began: began, shouldResume: options.contains(.shouldResume))
            }
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
