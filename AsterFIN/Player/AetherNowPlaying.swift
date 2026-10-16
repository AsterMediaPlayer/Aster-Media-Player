//
//  AetherNowPlaying.swift
//  AsterFIN
//
//  The system's Now Playing for AetherEngine video: the lock screen and
//  Control Center, the Apple TV's Now Playing, and headphone and remote
//  buttons. On iPhone, iPad and Apple TV the engine owns a Now Playing
//  session for its native path and fills in the elapsed time, duration and
//  rate itself; this gives it the title and artwork and answers its
//  commands. (Video the engine decodes in software has no such session.)
//  The Mac has no sessions, so the shared Now Playing center is written
//  here, elapsed time included.
//
//  The system only lists an app whose audio session is active. Apple's
//  player view activates it; the engine's bare video layer doesn't, so it's
//  activated here as each item starts (per playback, as the engine asks, so
//  the HDMI audio route is negotiated for this video).
//

#if canImport(AetherEngine)
import AetherEngine
import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

final class AetherNowPlaying {
    static let skipSeconds: Double = 10

    private let engine: AetherEngine
    private let client: JellyfinClient
    /// The title, series and artwork for the item playing.
    private var info: [String: Any] = [:]
    /// The item shown, so artwork arriving late for another is dropped.
    private var itemId: String?
    private var artworkTask: Task<Void, Never>?
    #if os(macOS)
    /// The shared command center's handlers, removed when playback ends.
    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    #else
    /// The session the commands were added to; a new one needs them again.
    private var commandSession: ObjectIdentifier?
    #endif

    init(engine: AetherEngine, client: JellyfinClient) {
        self.engine = engine
        self.client = client
    }

    /// Before each load: the engine only makes its session for a load that
    /// asked for one.
    func prepare() {
        #if !os(macOS)
        engine.ownsVideoNowPlayingSession = true
        #endif
    }

    /// The item has started: its title and artwork, and the buttons.
    func show(_ item: BaseItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name ?? item.displayTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if item.kind == .episode {
            // "Sakamoto Days" over "S1, E2".
            if let series = item.seriesName { info[MPMediaItemPropertyArtist] = series }
            if let episode = item.indexNumber {
                info[MPMediaItemPropertyAlbumTitle] = item.parentIndexNumber.map { "S\($0), E\(episode)" } ?? "Episode \(episode)"
            }
        } else if let year = item.productionYear {
            info[MPMediaItemPropertyArtist] = String(year)
        }
        self.info = info
        itemId = item.id
        publish()
        installCommands()
        #if !os(macOS)
        activate()
        #endif

        artworkTask?.cancel()
        // A video's own wide still reads best on the lock screen; else the poster.
        guard let url = client.landscapeURL(for: item, width: 800) ?? client.posterURL(for: item, width: 600) else { return }
        let client = client
        let itemId = item.id
        artworkTask = Task { [weak self] in
            guard let image = await ImageStore.shared.image(for: url, client: client), !Task.isCancelled else { return }
            guard let self, self.itemId == itemId else { return }
            self.info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.publish()
        }
    }

    /// Keeps the Mac's elapsed time and rate current; elsewhere the engine's
    /// session does this itself.
    func tick() {
        #if os(macOS)
        guard !info.isEmpty else { return }
        publish()
        #endif
    }

    /// Playback has ended: nothing is playing any more.
    func end() {
        artworkTask?.cancel()
        info = [:]
        itemId = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        for target in targets { target.command.removeTarget(target.token) }
        targets = []
        #else
        engine.setVideoNowPlayingInfo([:])
        commandSession = nil
        #endif
    }

    private func publish() {
        #if os(macOS)
        var current = info
        let seconds = engine.clock.currentTime
        current[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds.isFinite ? seconds : 0
        current[MPMediaItemPropertyPlaybackDuration] = engine.duration
        let playing = engine.state == .playing
        current[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = current
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        #else
        engine.setVideoNowPlayingInfo(info)
        #endif
    }

    #if !os(macOS)
    /// Activates the audio session (off the main thread: it can take a
    /// moment while the route is negotiated), then has the engine's session
    /// claim Now Playing, which it couldn't while the audio was inactive.
    private func activate() {
        Task { [weak self] in
            await Task.detached {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    #if DEBUG
                    print("DEBUG now playing: audio session didn't activate: \(error)")
                    #endif
                }
            }.value
            guard let self, let session = self.engine.videoNowPlayingSession else {
                #if DEBUG
                print("DEBUG now playing: no session (the engine's software path has none)")
                #endif
                return
            }
            let active = await session.becomeActiveIfPossible()
            #if DEBUG
            print("DEBUG now playing: session active \(active)")
            #endif
        }
    }
    #endif

    // MARK: Commands

    private func installCommands() {
        #if os(macOS)
        guard targets.isEmpty else { return }
        add(to: MPRemoteCommandCenter.shared())
        #else
        // The session comes with the engine's native path; on the software
        // path there's none to add them to.
        guard let session = engine.videoNowPlayingSession else { return }
        let id = ObjectIdentifier(session)
        guard id != commandSession else { return }
        commandSession = id
        add(to: session.remoteCommandCenter)
        #endif
    }

    private func add(to center: MPRemoteCommandCenter) {
        let engine = engine
        func on(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            let token = command.addTarget(handler: handler)
            #if os(macOS)
            targets.append((command, token))
            #else
            _ = token
            #endif
        }
        on(center.playCommand) { _ in
            Task { @MainActor in engine.play() }
            return .success
        }
        on(center.pauseCommand) { _ in
            Task { @MainActor in engine.pause() }
            return .success
        }
        on(center.togglePlayPauseCommand) { _ in
            Task { @MainActor in engine.togglePlayPause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        on(center.skipForwardCommand) { _ in
            Task { @MainActor in await Self.skip(engine, by: Self.skipSeconds) }
            return .success
        }
        on(center.skipBackwardCommand) { _ in
            Task { @MainActor in await Self.skip(engine, by: -Self.skipSeconds) }
            return .success
        }
        on(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in await engine.seek(to: seconds) }
            return .success
        }
        // Videos have no tracks to step through.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private static func skip(_ engine: AetherEngine, by seconds: Double) async {
        let now = engine.clock.currentTime
        guard now.isFinite else { return }
        let end = engine.duration > 0 ? engine.duration : .greatestFiniteMagnitude
        await engine.seek(to: min(max(0, now + seconds), end))
    }
}
#endif
