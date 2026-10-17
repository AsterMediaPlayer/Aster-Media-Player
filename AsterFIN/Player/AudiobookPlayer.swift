//
//  AudiobookPlayer.swift
//  AsterFIN
//
//  Plays one audiobook at a time through AVPlayer: picks up where Jellyfin
//  says listening left off, moves between chapters and parts, plays at the
//  speed chosen for the book, and skips back 15 seconds or ahead 30 from the
//  app, the Lock Screen and headphones. Progress goes back to Jellyfin so
//  another device carries on from the same place.
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

@Observable
final class AudiobookPlayer {
    private(set) var book: Audiobook?
    /// The part (file) playing.
    private(set) var partIndex = 0
    private(set) var isPlaying = false
    /// Seconds into the part playing, and the part's length.
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1
    private(set) var errorMessage: String?
    /// Whether the full-screen player is up.
    var isNowPlayingPresented = false
    /// Called when a book starts, so music and page theme music step aside.
    var onStart: (() -> Void)?

    static let skipBackSeconds: TimeInterval = 15
    static let skipForwardSeconds: TimeInterval = 30

    /// The chapter the playhead is in.
    var currentChapter: AudiobookChapter? {
        guard let book else { return nil }
        return book.chapters.last { $0.part < partIndex || ($0.part == partIndex && $0.start <= currentTime + 0.5) }
    }

    /// How far into the whole book, and its whole length.
    var bookElapsed: TimeInterval { (book?.offset(ofPart: partIndex) ?? 0) + currentTime }
    var bookDuration: TimeInterval { book?.duration ?? 0 }

    /// Where the current chapter starts and ends in the part playing, for
    /// its progress bar; the whole part when there are no chapters.
    var chapterBounds: (start: TimeInterval, end: TimeInterval) {
        guard let book, let chapter = currentChapter, chapter.part == partIndex else { return (0, duration) }
        let next = book.chapters.first { $0.id == chapter.id + 1 }
        let end = next.map { $0.part == partIndex ? $0.start : duration } ?? duration
        return (chapter.start, max(end, chapter.start))
    }

    private let player = AVPlayer()
    private var client: JellyfinClient?
    private var playSessionId = UUID().uuidString
    /// Where to start once the part is ready.
    private var pendingStart: TimeInterval = 0
    /// Whether to play once the part is ready (else it waits, paused).
    private var playWhenReady = true
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var lastReport = Date.distantPast
    private var hasStarted = false
    private var commandsInstalled = false
    private var artworkTask: Task<Void, Never>?

    // MARK: Starting

    /// Plays `book`: from `chapter` when given, else from where listening
    /// left off. The book already playing just carries on.
    func play(_ book: Audiobook, from chapter: AudiobookChapter? = nil, client: JellyfinClient) {
        isNowPlayingPresented = true
        if self.book?.id == book.id, chapter == nil {
            if !isPlaying { resume() }
            return
        }
        if self.book?.id == book.id, let chapter {
            jump(to: chapter)
            if !isPlaying { resume() }
            return
        }
        onStart?()
        finishCurrent()
        self.client = client
        self.book = book
        rate = AudiobookRates.rate(for: book.id)
        installRemoteCommands()
        RemoteCommandLayout.useForAudiobooks()
        let start = chapter.map { ($0.part, $0.start) } ?? book.resumePoint ?? (0, 0)
        load(part: start.0, at: start.1, playing: true)
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        guard book != nil else { return }
        player.pause()
        playWhenReady = false
        isPlaying = false
        currentTime = playerSeconds ?? currentTime
        report(paused: true)
        updateNowPlayingPlayback()
    }

    func resume() {
        guard book != nil else { return }
        Self.activateAudioSession()
        playWhenReady = true
        if hasStarted {
            player.rate = rate
        }
        isPlaying = true
        report(paused: false)
        updateNowPlayingPlayback()
    }

    /// Back or ahead by `seconds`, into the part before or after when it
    /// runs past this one's start or end.
    func skip(by seconds: TimeInterval) {
        guard let book else { return }
        let target = currentTime + seconds
        if target < 0, partIndex > 0 {
            let previous = partIndex - 1
            load(part: previous, at: max(book.partDurations[previous] + target, 0), playing: isPlaying)
        } else if target > duration, duration > 0, partIndex + 1 < book.parts.count {
            load(part: partIndex + 1, at: target - duration, playing: isPlaying)
        } else {
            seek(to: target)
        }
    }

    /// Moves within the part playing.
    func seek(to seconds: TimeInterval) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = clamped
        guard hasStarted else {
            pendingStart = clamped
            return
        }
        let target = CMTime(seconds: clamped, preferredTimescale: 10_000_000)
        Task {
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            report(paused: !isPlaying)
            updateNowPlayingPlayback()
        }
    }

    func jump(to chapter: AudiobookChapter) {
        if chapter.part == partIndex {
            seek(to: chapter.start)
        } else {
            load(part: chapter.part, at: chapter.start, playing: isPlaying)
        }
        updateNowPlayingPlayback()
    }

    func nextChapter() {
        guard let book, let current = currentChapter,
              let next = book.chapters.first(where: { $0.id == current.id + 1 }) else { return }
        jump(to: next)
    }

    /// The start of this chapter, or the one before when just into it.
    func previousChapter() {
        guard let book, let current = currentChapter else {
            seek(to: 0)
            return
        }
        let intoChapter = current.part == partIndex ? currentTime - current.start : currentTime
        if intoChapter > 3 || current.id == 0 {
            jump(to: current)
        } else if let previous = book.chapters.first(where: { $0.id == current.id - 1 }) {
            jump(to: previous)
        }
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if let book { AudiobookRates.setRate(newRate, for: book.id) }
        player.defaultRate = newRate
        if isPlaying, hasStarted { player.rate = newRate }
        updateNowPlayingPlayback()
    }

    /// Stops and lets go of the book, reporting where it got to.
    func stop() {
        guard book != nil else { return }
        #if os(iOS)
        ListenAhead.shared.pause()
        #endif
        finishCurrent()
        removeObservers()
        player.replaceCurrentItem(with: nil)
        book = nil
        partIndex = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        errorMessage = nil
        isNowPlayingPresented = false
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Loading

    private func load(part: Int, at seconds: TimeInterval, playing: Bool) {
        guard let client, let book, book.parts.indices.contains(part) else { return }
        finishCurrent()
        removeObservers()
        partIndex = part
        let item = book.parts[part]
        playSessionId = UUID().uuidString
        hasStarted = false
        currentTime = seconds
        pendingStart = seconds
        playWhenReady = playing
        duration = book.partDurations[part]
        errorMessage = nil

        Self.activateAudioSession()
        // The universal URL always starts at the beginning, so the resume
        // point is sought once the file is ready.
        var url = client.universalAudioURL(itemId: item.id, playSessionId: playSessionId, maxBitrate: AppSettings.maxBitrate)
        var cachedItem: AVPlayerItem?
        #if os(iOS)
        // A downloaded book plays from the device; else, with Listen Ahead
        // on, through its cache of what's coming up.
        if let saved = AudiobookDownloads.shared.fileURL(forPart: item.id) {
            url = saved
        } else if let asset = ListenAhead.shared.asset(book: book, part: part, client: client) {
            cachedItem = AVPlayerItem(asset: asset)
            // The stretch ahead starts from where this part will play.
            ListenAhead.shared.update(bookId: book.id, part: part, seconds: seconds, force: true)
        }
        #endif
        let playerItem = cachedItem ?? AVPlayerItem(url: url)
        // Keeps voices natural when sped up or slowed down.
        playerItem.audioTimePitchAlgorithm = .timeDomain
        installObservers(for: playerItem)
        player.defaultRate = rate
        player.replaceCurrentItem(with: playerItem)
        isPlaying = playing
        publishNowPlaying()
    }

    /// Seeks to the start point and plays, once the file is ready.
    private func startWhenReady(_ item: AVPlayerItem) async {
        let length = item.duration.seconds
        if length.isFinite, length > 0 { duration = length }
        if pendingStart > 0 {
            let target = CMTime(seconds: min(pendingStart, max(duration - 1, 0)), preferredTimescale: 10_000_000)
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        guard player.currentItem === item else { return }
        hasStarted = true
        if playWhenReady {
            player.rate = rate
        }
        isPlaying = playWhenReady
        currentTime = playerSeconds ?? currentTime
        lastReport = Date()
        report(paused: !playWhenReady, start: true)
        updateNowPlayingPlayback()
    }

    /// Reports the part that's ending, so the server keeps its position.
    private func finishCurrent() {
        guard hasStarted, let book, book.parts.indices.contains(partIndex) else { return }
        hasStarted = false
        let report = PlaybackReport(itemId: book.parts[partIndex].id, playSessionId: playSessionId, positionTicks: positionTicks, isPaused: true, playMethod: "DirectPlay")
        noteLocally(positionTicks)
        Task { [client] in await client?.reportStopped(report) }
    }

    private func partEnded() {
        guard let book else { return }
        noteLocally(positionTicks, played: true)
        if partIndex + 1 < book.parts.count {
            load(part: partIndex + 1, at: 0, playing: true)
        } else {
            // The end of the book: report it finished and stop there.
            #if os(iOS)
            ListenAhead.shared.finished(bookId: book.id)
            #endif
            finishCurrent()
            player.pause()
            isPlaying = false
            playWhenReady = false
            currentTime = duration
            updateNowPlayingPlayback()
        }
    }

    /// For a downloaded book, keeps where listening got to on the device,
    /// for when the server can't be reached; handed over later.
    private func noteLocally(_ ticks: Int64, played: Bool = false) {
        #if os(iOS)
        guard let book, book.parts.indices.contains(partIndex) else { return }
        AudiobookDownloads.shared.noteProgress(bookId: book.id, partId: book.parts[partIndex].id, ticks: ticks, played: played)
        #endif
    }

    private var playerSeconds: TimeInterval? {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }

    private var positionTicks: Int64 {
        guard let seconds = playerSeconds, seconds > 0 else { return 0 }
        return Int64(seconds * 10_000_000)
    }

    /// As in `MusicPlayer`: off the main thread, since it can block.
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
                guard let self, self.player.currentItem === observed else { return }
                switch observed.status {
                case .readyToPlay:
                    if !self.hasStarted {
                        await self.startWhenReady(observed)
                    }
                case .failed:
                    #if DEBUG
                    // Debug builds only: the error can include the stream URL and its token.
                    print("DEBUG audiobook: failed \(String(describing: observed.error))")
                    #endif
                    self.errorMessage = observed.error?.localizedDescription ?? "This book can't be played."
                    self.isPlaying = false
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.partEnded()
            }
        }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.hasStarted else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
                #if os(iOS)
                if let book = self.book {
                    ListenAhead.shared.update(bookId: book.id, part: self.partIndex, seconds: self.currentTime)
                }
                #endif
                if Date().timeIntervalSince(self.lastReport) >= 10 {
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
        guard hasStarted, let book, let client, book.parts.indices.contains(partIndex) else { return }
        let report = PlaybackReport(itemId: book.parts[partIndex].id, playSessionId: playSessionId, positionTicks: positionTicks, isPaused: paused, playMethod: "DirectPlay")
        noteLocally(positionTicks)
        Task {
            if start {
                await client.reportStart(report)
            } else {
                await client.reportProgress(report)
            }
        }
    }

    // MARK: System integration

    /// The Lock Screen's and headphones' controls. `MusicPlayer` adds its
    /// own to the same commands; each does nothing while it has nothing
    /// loaded, and only one of the two has something at a time.
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
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(by: -Self.skipBackSeconds) }
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(by: Self.skipForwardSeconds) }
            return .success
        }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            Task { @MainActor [weak self] in self?.setRate(rate) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor [weak self] in
                guard let self, self.book != nil else { return }
                self.seek(to: seconds)
            }
            return .success
        }
    }

    private func publishNowPlaying() {
        guard let book else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyAlbumTitle: book.series ?? book.title,
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if let author = book.author { info[MPMediaItemPropertyArtist] = author }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        artworkTask?.cancel()
        guard let client, let url = client.posterURL(for: book.cover, width: 600) else { return }
        let bookId = book.id
        artworkTask = Task { [weak self] in
            guard let image = await ImageStore.shared.image(for: url, client: client), !Task.isCancelled else { return }
            guard let self, self.book?.id == bookId else { return }
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)
        if let chapter = currentChapter {
            info[MPNowPlayingInfoPropertyChapterNumber] = chapter.id
            info[MPNowPlayingInfoPropertyChapterCount] = book?.chapters.count ?? 0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// Which buttons the Lock Screen, Control Center and headphones offer: next
/// and previous for music, 15 and 30 second skips and speed for a book.
enum RemoteCommandLayout {
    static func useForMusic() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
    }

    static func useForAudiobooks() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: AudiobookPlayer.skipBackSeconds)]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: AudiobookPlayer.skipForwardSeconds)]
        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.supportedPlaybackRates = AudiobookRates.choices.map { NSNumber(value: $0) }
    }
}
