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

    /// The sound is decoded here and sent to an AirPlay speaker, never
    /// fetched by the speaker itself: Listen Ahead serves the book from a
    /// scheme of the app's own, which a speaker can't reach (it connected
    /// and stayed silent).
    private let player: AVPlayer = {
        let player = AVPlayer()
        player.allowsExternalPlayback = false
        return player
    }()
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
    /// The part is playing through Listen Ahead's cache; and whether that
    /// failed this time, so the book streams as before instead.
    private var playsThroughCache = false
    private var cacheFailed = false
    private var artworkTask: Task<Void, Never>?
    /// The chapter the Now Playing info was last given for.
    private var nowPlayingChapterId: Int?

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
        cacheFailed = false
        rate = AudiobookRates.rate(for: book.id)
        installRemoteCommands()
        #if !os(macOS)
        observeInterruptions()
        #endif
        RemoteCommandLayout.useForAudiobooks()
        // Where listening stopped on this device, when nothing has played
        // the book since elsewhere: the server's copy can lag (a car
        // disconnecting) or be reset by its resume rules.
        let start = chapter.map { ($0.part, $0.start) } ?? AudiobookPositions.resumePoint(for: book) ?? book.resumePoint ?? (0, 0)
        load(part: start.0, at: start.1, playing: true)
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        guard book != nil else { return }
        #if os(iOS)
        if sonos != nil {
            isPlaying = false
            sonosCommand { try await $0.pause() }
            report(paused: true, saving: .now)
            updateNowPlayingPlayback()
            return
        }
        #endif
        player.pause()
        playWhenReady = false
        isPlaying = false
        currentTime = playerSeconds ?? currentTime
        // Saved on the server at once, not when next due: the app may be
        // put away (or the phone leave the car) before then.
        report(paused: true, saving: .now)
        updateNowPlayingPlayback()
    }

    func resume() {
        guard book != nil else { return }
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
        #if os(iOS)
        if sonos != nil {
            sonosCommand { try await $0.seek(to: clamped) }
            report(paused: !isPlaying)
            updateNowPlayingPlayback()
            return
        }
        #endif
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
        if sonos != nil {
            sonosCommand { try await $0.stop() }
            leaveSonos()
        }
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

        #if os(iOS)
        // On a Sonos room: it goes to this part and place in its queue,
        // which is the book's when it's this book.
        if let room = sonos {
            isPlaying = playing
            if sonosIds != book.parts.map(\.id) {
                sendBookToSonos(at: seconds, playing: playing)
            } else {
                hasStarted = true
                lastReport = Date()
                report(paused: !playing, start: true)
                // Until the room is there, what it says isn't the place.
                sonosSettleUntil = Date().addingTimeInterval(30)
                Task { [weak self] in
                    try? await room.start(track: part + 1, at: seconds, playing: playing)
                    self?.sonosSettleUntil = Date().addingTimeInterval(2)
                }
            }
            publishNowPlaying()
            return
        }
        #endif
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
        } else if !cacheFailed, let asset = ListenAhead.shared.asset(book: book, part: part, client: client) {
            cachedItem = AVPlayerItem(asset: asset)
            // The stretch ahead starts from where this part will play.
            ListenAhead.shared.update(bookId: book.id, part: part, seconds: seconds, force: true)
        }
        #endif
        playsThroughCache = cachedItem != nil
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
        let ticks = positionTicks
        let report = PlaybackReport(itemId: book.parts[partIndex].id, playSessionId: playSessionId, positionTicks: ticks, isPaused: true, playMethod: "DirectPlay")
        noteLocally(ticks)
        Task { [client] in
            await client?.reportStopped(report)
            // Jellyfin's audiobook rules drop a position in a file's first
            // (or last) minutes when playback stops; the place is set again
            // straight after, leaving its played state alone.
            if ticks > 0 { _ = try? await client?.saveResumePosition(itemId: report.itemId, ticks: ticks) }
        }
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
            AudiobookPositions.clear(bookId: book.id)
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
        guard let book, book.parts.indices.contains(partIndex) else { return }
        if ticks > 0, !played {
            AudiobookPositions.note(bookId: book.id, part: partIndex, seconds: Double(ticks) / 10_000_000)
        }
        #if os(iOS)
        AudiobookDownloads.shared.noteProgress(bookId: book.id, partId: book.parts[partIndex].id, ticks: ticks, played: played)
        #endif
    }

    private var playerSeconds: TimeInterval? {
        #if os(iOS)
        if sonos != nil { return currentTime }
        #endif
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : nil
    }

    private var positionTicks: Int64 {
        guard let seconds = playerSeconds, seconds > 0 else { return 0 }
        return Int64(seconds * 10_000_000)
    }

    /// As in `MusicPlayer`: off the main thread, since it can block, and
    /// set up as long-form audio first, for AirPlay 2 speakers.
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
                    // Through the cache, it tries again streaming as before.
                    if self.playsThroughCache {
                        self.cacheFailed = true
                        self.load(part: self.partIndex, at: self.currentTime, playing: self.playWhenReady)
                        return
                    }
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
                // A new chapter: its own bar from zero on the Lock Screen.
                if self.currentChapter?.id != self.nowPlayingChapterId { self.updateNowPlayingPlayback() }
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

    private func report(paused: Bool, start: Bool = false, saving: ResumePoints.Saving = .whenDue) {
        guard hasStarted, let book, let client, book.parts.indices.contains(partIndex) else { return }
        let report = PlaybackReport(itemId: book.parts[partIndex].id, playSessionId: playSessionId, positionTicks: positionTicks, isPaused: paused, playMethod: "DirectPlay")
        noteLocally(positionTicks)
        Task {
            if start {
                await client.reportStart(report)
            } else {
                await client.reportProgress(report, savingResumePoint: saving)
            }
        }
    }

    // MARK: Sonos

    #if os(iOS)
    /// The Sonos room playing the book, nil while it plays on this device.
    private(set) var sonosRoom: SonosGroup?
    @ObservationIgnored private var sonos: SonosClient?
    /// The parts in the room's queue: the book's, once sent.
    @ObservationIgnored private var sonosIds: [String] = []
    @ObservationIgnored private var sonosPoll: Task<Void, Never>?
    @ObservationIgnored private var sonosSettleUntil = Date.distantPast
    @ObservationIgnored private var sonosFailures = 0

    /// Plays on `group`, or back on this device with nil, from where it is.
    /// A Sonos plays at normal speed whatever the speed chosen here.
    func play(on group: SonosGroup?) {
        guard book != nil else { return }
        let at = currentTime
        let playing = isPlaying
        if let group {
            guard group.id != sonosRoom?.id else { return }
            if let previous = sonos { Task { try? await previous.stop() } }
            finishCurrent()
            ListenAhead.shared.pause()
            player.pause()
            removeObservers()
            player.replaceCurrentItem(with: nil)
            sonosRoom = group
            sonos = SonosClient(speaker: group.coordinator)
            sendBookToSonos(at: at, playing: true)
            startSonosPolling()
        } else {
            guard let room = sonos else { return }
            Task { try? await room.pause() }
            finishCurrent()
            leaveSonos()
            load(part: partIndex, at: at, playing: playing)
        }
    }

    /// The book's parts as the room's queue, played from this part and place.
    private func sendBookToSonos(at seconds: TimeInterval, playing: Bool) {
        guard let room = sonos, let client, let book else { return }
        let art = client.posterURL(for: book.cover, width: 600)
        let tracks = book.parts.enumerated().map { number, part in
            client.sonosTrack(for: part, title: book.parts.count > 1 ? "\(book.title), Part \(number + 1)" : book.title,
                              artist: book.author, album: book.title, art: art)
        }
        let number = partIndex + 1
        sonosIds = book.parts.map(\.id)
        isPlaying = playing
        playSessionId = UUID().uuidString
        hasStarted = true
        lastReport = Date()
        report(paused: !playing, start: true)
        publishNowPlaying()
        sonosSettleUntil = Date().addingTimeInterval(30)
        Task {
            do {
                try await room.clearQueue()
                try await room.enqueue(tracks)
                try await room.playFromQueue()
                try? await room.setPlayMode(.normal)
                try await room.start(track: number, at: seconds, playing: playing)
                sonosSettleUntil = Date().addingTimeInterval(2)
            } catch {
                sonosLost(error)
            }
        }
    }

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

    /// Where the room has got to in the book: the screen, the server and
    /// this device's own note of the place follow it.
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
        guard sonos != nil, let book, Date() >= sonosSettleUntil else { return }
        if !position.uri.isEmpty, JellyfinClient.sonosItemId(in: position.uri) == nil {
            // Something else took the room over.
            isPlaying = false
            report(paused: true, saving: .now)
            leaveSonos()
            updateNowPlayingPlayback()
            return
        }
        // Stopped, a room goes back to its first track at zero, which isn't
        // where listening got to; at the end of the last part, the book's done.
        if state == .stopped || state == .noMedia {
            if isPlaying {
                isPlaying = false
                if partIndex == book.parts.count - 1, duration - currentTime < 20 {
                    AudiobookPositions.clear(bookId: book.id)
                    currentTime = duration
                    finishCurrent()
                } else {
                    report(paused: true, saving: .now)
                }
                updateNowPlayingPlayback()
            }
            return
        }
        let id = JellyfinClient.sonosItemId(in: position.uri)
        let part = id.flatMap { sonosIds.firstIndex(of: $0) } ?? (position.track - 1)
        if book.parts.indices.contains(part), part != partIndex {
            finishCurrent()
            partIndex = part
            duration = book.partDurations[part]
            playSessionId = UUID().uuidString
            hasStarted = true
            lastReport = Date()
            report(paused: false, start: true)
        }
        currentTime = position.elapsed
        if position.duration > 0 { duration = position.duration }
        let playing = state == .playing || state == .transitioning
        if playing != isPlaying {
            isPlaying = playing
            report(paused: !playing, saving: playing ? .whenDue : .now)
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

    /// The Lock Screen's and headphones' controls. `MusicPlayer` adds its
    /// own to the same commands; each does nothing while it has nothing
    /// loaded, and only one of the two has something at a time.
    #if !os(macOS)
    /// A call or Siri paused the audio, so it plays on when they're done.
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var interruptionObservers: [NSObjectProtocol] = []

    /// The system pauses the player itself for a call or Siri (it makes the
    /// audio session inactive): this follows it, so it says paused
    /// meanwhile, and carries on afterwards when the system recommends it.
    private func observeInterruptions() {
        guard interruptionObservers.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        interruptionObservers = [
            // Headphones unplugged, or the car's Bluetooth or CarPlay gone:
            // the system pauses the player by itself, so this pauses too,
            // which saves where it got to at once.
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                guard reason == .oldDeviceUnavailable else { return }
                MainActor.assumeIsolated {
                    guard let self, self.isPlaying else { return }
                    self.pause()
                }
            },
            // Put away (or the screen locked): where it is, saved now, in
            // case the system ends the app before the next save is due.
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.report(paused: !self.isPlaying, saving: .now)
                }
            },
        ] + observeAudioInterruptions { [weak self] began, shouldResume in
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
                // The Lock Screen's and headphones' bar is the chapter's.
                self.seek(to: self.chapterBounds.start + seconds)
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if let author = book.author { info[MPMediaItemPropertyArtist] = author }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateNowPlayingPlayback()

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

    /// The Lock Screen, Control Center, headphones and car stereos show the
    /// chapter's progress, as the app's own bar does, not the whole file's.
    private func updateNowPlayingPlayback() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        let bounds = chapterBounds
        nowPlayingChapterId = currentChapter?.id
        info[MPMediaItemPropertyPlaybackDuration] = bounds.end - bounds.start
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = min(max(currentTime - bounds.start, 0), bounds.end - bounds.start)
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

/// Where each book was last listened to on this device, downloaded or not.
/// The server's copy can trail it (saved every 30 seconds, and nothing when a
/// car or headphones disconnect and the app is then ended) or be reset by
/// Jellyfin's audiobook resume rules, so starting a book again prefers this,
/// unless the book has been played elsewhere since.
nonisolated enum AudiobookPositions {
    private struct Position: Codable {
        var part: Int
        var seconds: Double
        var updated: Date
    }

    private static let key = "AsterFIN.audiobookPositions"
    /// How much later than this device the server's last play has to be to
    /// count as listening elsewhere, rather than this device's own reports.
    static let elsewhereMargin: TimeInterval = 120

    private static func load() -> [String: Position] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Position].self, from: data)) ?? [:]
    }

    private static func save(_ positions: [String: Position]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(positions), forKey: key)
    }

    static func note(bookId: String, part: Int, seconds: Double) {
        var positions = load()
        positions[bookId] = Position(part: part, seconds: seconds, updated: Date())
        save(positions)
    }

    /// The book was listened to the end.
    static func clear(bookId: String) {
        var positions = load()
        guard positions.removeValue(forKey: bookId) != nil else { return }
        save(positions)
    }

    /// This device's place in `book`, unless the server has heard of it
    /// being played since (on another device).
    static func resumePoint(for book: Audiobook) -> (part: Int, seconds: TimeInterval)? {
        guard let position = load()[book.id], book.parts.indices.contains(position.part) else { return nil }
        let lastPlayedElsewhere = book.parts.compactMap { JellyfinDate.parse($0.userData?.lastPlayedDate) }.max()
        if let lastPlayedElsewhere, lastPlayedElsewhere > position.updated.addingTimeInterval(elsewhereMargin) {
            return nil
        }
        return (position.part, position.seconds)
    }
}
