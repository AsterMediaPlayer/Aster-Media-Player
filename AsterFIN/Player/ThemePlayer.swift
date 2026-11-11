//
//  ThemePlayer.swift
//  AsterFIN
//
//  Theme music and theme videos on title pages: a quiet looping song and a
//  muted looping backdrop video, faded in and out as the viewer moves between
//  pages. Episodes and seasons share their series' theme without a restart.
//

import AVFoundation
import Foundation
import Observation

@Observable
final class ThemePlayer {
    /// The item (or series) whose theme is loaded, so a page can tell whether
    /// the current video belongs to it.
    private(set) var key: String?
    /// The looping theme video, once one has proven playable.
    private(set) var videoPlayer: DiscTrailerPlayer?

    private var music: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var volume: Float = 0.35
    private var suspended = false
    private var loadTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// The server transcode behind an opening used as the theme video.
    private var clipTranscode: (client: any MediaServer, playSessionId: String)?
    /// Which opening is standing in as the theme video. Nil while the
    /// title's own theme video plays (or none does), which is never swapped.
    private var fallbackId: String?
    /// The music playing is an opening's song standing in, not the title's
    /// theme song.
    private var musicIsOpening = false

    /// Starts the theme for a title. Pages pass their own toggles; music that
    /// the viewer is already listening to always wins.
    func show(item: BaseItem, client: any MediaServer, music wantsMusic: Bool, video wantsVideo: Bool, musicPlaying: Bool) {
        guard wantsMusic || wantsVideo, !musicPlaying else {
            hide()
            return
        }
        let themeKey = item.seriesId ?? item.id
        hideTask?.cancel()
        hideTask = nil
        if themeKey == key {
            resume()
            return
        }
        release()
        key = themeKey
        // Theme songs and videos are Jellyfin's and Emby's; on Plex only an
        // opening can stand in (see `showOpeningIfNoVideo`), for this page.
        guard let client = client as? JellyfinClient else { return }
        loadTask = Task { [weak self] in
            let song = wantsMusic ? (try? await client.themeSongs(itemId: item.id))?.first : nil
            let video = wantsVideo ? (try? await client.themeVideos(itemId: item.id))?.first : nil
            guard let self, !Task.isCancelled, self.key == themeKey else { return }
            if let song {
                self.startMusic(url: client.universalAudioURL(itemId: song.id, playSessionId: UUID().uuidString, maxBitrate: AppSettings.musicMaxBitrate))
            }
            if let video {
                await self.startVideo(id: video.id, url: client.videoStreamURL(itemId: video.id), themeKey: themeKey)
            }
        }
    }

    /// For a series with no theme video of its own: loops one of its openings
    /// (found in the episodes' chapters) behind the page instead. Waits for
    /// the server's theme video first, which always wins. With `sound`, the
    /// opening plays at theme-music volume and replaces any theme song.
    func showOpeningIfNoVideo(_ clip: ThemeClip, for item: BaseItem, client: any MediaServer, sound: Bool = false) {
        let range = CMTimeRange(
            start: CMTime(value: clip.startTicks, timescale: 10_000_000),
            end: CMTime(value: clip.endTicks, timescale: 10_000_000)
        )
        showFallbackVideo(id: clip.id, for: item, sound: sound, timeRange: range) {
            guard let stream = await Self.stream(for: clip, client: client) else { return nil }
            // A server stream needs ending by hand: theme playback reports nothing.
            return (stream.url, stream.playSessionId.map { (client, $0) })
        }
    }

    /// The same for an opening from the OP/ED plugin: a ready MP4 the
    /// player opens directly, so no server transcode is involved.
    func showOpeningIfNoVideo(_ theme: OpEdTheme, url: URL, for item: BaseItem, sound: Bool = false) {
        showFallbackVideo(id: theme.id, for: item, sound: sound, timeRange: .invalid) { (url, nil) }
    }

    /// An opening from the OP/ED plugin that only has audio: plays the song
    /// as the page's theme music, replacing any theme song and any opening
    /// video standing in. The title's own theme video still wins.
    func showOpeningSongIfNoVideo(_ theme: OpEdTheme, url: URL, for item: BaseItem) {
        let themeKey = item.seriesId ?? item.id
        Task { [weak self] in
            await self?.loadTask?.value
            guard let self, self.key == themeKey, self.canShowFallback(theme.id) else { return }
            if self.videoPlayer != nil {
                // An opening video was standing in; the song replaces it.
                self.videoPlayer?.stop()
                self.videoPlayer = nil
                self.endClipTranscode()
            }
            if let music = self.music {
                self.music = nil
                self.looper = nil
                self.fade(music, to: 0, over: 0.6) {
                    music.pause()
                    music.removeAllItems()
                }
            }
            self.fallbackId = theme.id
            self.startMusic(url: url)
            self.musicIsOpening = true
        }
    }

    /// Waits for the title's own theme video (which always wins), then loops
    /// `resolve`'s stream behind the page. Another opening already standing
    /// in is swapped out (e.g. when a different season is picked); the
    /// title's own theme video never is.
    private func showFallbackVideo(
        id: String,
        for item: BaseItem,
        sound: Bool,
        timeRange: CMTimeRange,
        resolve: @escaping () async -> (url: URL, transcode: (any MediaServer, String)?)?
    ) {
        let themeKey = item.seriesId ?? item.id
        Task { [weak self] in
            await self?.loadTask?.value
            guard let self, self.key == themeKey, self.canShowFallback(id) else {
                #if DEBUG
                print("DEBUG theme: opening \(id) not shown: key=\(self?.key ?? "nil") wanted=\(themeKey) canShow=\(self?.canShowFallback(id) ?? false)")
                #endif
                return
            }
            guard let stream = await resolve() else {
                #if DEBUG
                print("DEBUG theme: no stream for opening \(id)")
                #endif
                return
            }
            #if DEBUG
            print("DEBUG theme: opening \(id) stream \(stream.url.absoluteString.prefix(120))")
            #endif
            guard self.key == themeKey, self.canShowFallback(id) else { return }
            if self.videoPlayer != nil {
                // Swapping one opening for another.
                self.videoPlayer?.stop()
                self.videoPlayer = nil
                self.endClipTranscode()
            }
            if let transcode = stream.transcode {
                self.clipTranscode = (transcode.0, transcode.1)
            }
            self.fallbackId = id
            // The opening is the song now (two at once would clash), and a
            // previous opening's song always gives way to the new opening.
            if sound || self.musicIsOpening, let music = self.music {
                self.music = nil
                self.looper = nil
                self.musicIsOpening = false
                self.fade(music, to: 0, over: 0.6) {
                    music.pause()
                    music.removeAllItems()
                }
            }
            await self.startVideo(id: id, url: stream.url, themeKey: themeKey, timeRange: timeRange, muted: !sound)
        }
    }

    /// An anime opening (video or song) is standing in as the theme.
    var isShowingOpening: Bool { fallbackId != nil }

    /// Whether the opening with this id is the video looping behind the page.
    func isShowingOpeningVideo(_ id: String) -> Bool {
        fallbackId == id && videoPlayer != nil
    }

    /// The opening behind the page is being watched on its own.
    private(set) var isWatchingOpening = false

    /// Watch OP on the page itself: the opening already looping behind it
    /// starts over at full volume and any theme song goes quiet. Nothing
    /// reloads.
    func watchOpening() {
        guard let videoPlayer else { return }
        isWatchingOpening = true
        if let music {
            fade(music, to: 0, over: 0.4) { music.pause() }
        }
        videoPlayer.player.isMuted = false
        videoPlayer.player.volume = 0
        videoPlayer.restart()
        fade(videoPlayer.player, to: 1, over: 0.6)
    }

    /// Back to the page: the opening drops to its theme volume (or silence)
    /// and the theme song, if any, comes back.
    func stopWatchingOpening() {
        guard isWatchingOpening else { return }
        isWatchingOpening = false
        if let videoPlayer {
            let player = videoPlayer.player
            if videoPlayer.isMuted {
                fade(player, to: 0, over: 0.6) {
                    player.isMuted = true
                    player.volume = 1
                }
            } else {
                fade(player, to: volume, over: 0.6)
            }
        }
        if let music, !suspended {
            music.play()
            fade(music, to: volume, over: 0.8)
        }
    }

    /// Nothing standing in yet, or another opening (video or song) that may
    /// be swapped for this one; never the title's own theme video.
    private func canShowFallback(_ id: String) -> Bool {
        if fallbackId == id { return false }
        return videoPlayer == nil || fallbackId != nil
    }

    private func endClipTranscode() {
        if let (client, session) = clipTranscode {
            Task { await client.stopTranscoding(playSessionId: session) }
        }
        clipTranscode = nil
    }

    /// Episodes are mostly MKV, which Apple TV can't open, so the server's
    /// stream (usually a cheap remux) is used unless the file plays as is.
    static func stream(for clip: ThemeClip, client: any MediaServer) async -> (url: URL, playSessionId: String?)? {
        guard let info = try? await client.playbackInfo(
            itemId: clip.episode.id,
            // Jellyfin's stream keeps the episode's own clock when started
            // partway; Plex's starts its clock over, so it's started at the
            // beginning and the player seeks to the clip.
            startTicks: client.kind == .plex ? 0 : clip.startTicks,
            maxBitrate: AppSettings.maxBitrate,
            subtitleStreamIndex: -1
        ), let source = info.mediaSources.first else {
            #if DEBUG
            print("DEBUG theme: no playback info for clip \(clip.id)")
            #endif
            return nil
        }
        let container = (source.container ?? "").lowercased()
        if source.supportsDirectPlay == true, ["mp4", "m4v", "mov"].contains(where: { container.contains($0) }) {
            return (client.directStreamURL(itemId: clip.episode.id, mediaSourceId: source.id, playSessionId: info.playSessionId, container: source.container), nil)
        }
        guard let path = source.transcodingUrl, let url = client.absoluteURL(serverRelative: path) else {
            #if DEBUG
            print("DEBUG theme: clip \(clip.id) is \(container) with no transcode offered")
            #endif
            return nil
        }
        return (url, info.playSessionId)
    }

    #if DEBUG
    /// Says how a player item fares: ready, or failed and why, and any
    /// error the stream logs. Debug builds only.
    static func watch(_ item: AVPlayerItem, label: String) {
        Task {
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.newErrorLogEntryNotification, object: item) {
                if let event = item.errorLog()?.events.last {
                    print("DEBUG theme: \(label) stream error \(event.errorStatusCode) \(event.errorComment ?? "") at \(event.uri ?? "")")
                }
            }
        }
        Task {
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.failedToPlayToEndTimeNotification, object: item) {
                print("DEBUG theme: \(label) failed to play to the end: \(item.error?.localizedDescription ?? "unknown")")
            }
        }
        Task {
            while item.status == .unknown {
                try? await Task.sleep(for: .milliseconds(250))
            }
            switch item.status {
            case .readyToPlay: print("DEBUG theme: \(label) ready, \(item.duration.seconds.isFinite ? "\(Int(item.duration.seconds)) s" : "no duration")")
            case .failed: print("DEBUG theme: \(label) failed: \(item.error?.localizedDescription ?? "unknown") \(item.error.map { String(describing: $0) } ?? "")")
            default: break
            }
        }
    }
    #endif

    /// Title pages showing each theme (by series or item id). The Mac can
    /// build a page twice and drop the spare at once; counting means that
    /// spare going away doesn't stop the theme the real page started.
    private var pagesShowing: [String: Int] = [:]

    /// A title page for `item` is on screen.
    func pageAppeared(for item: BaseItem) {
        pagesShowing[item.seriesId ?? item.id, default: 0] += 1
        hideTask?.cancel()
        hideTask = nil
    }

    /// A title page for `item` went away; the theme fades once none is left.
    func pageDisappeared(for item: BaseItem) {
        let themeKey = item.seriesId ?? item.id
        let left = (pagesShowing[themeKey] ?? 1) - 1
        pagesShowing[themeKey] = left > 0 ? left : nil
        if left <= 0 { hide() }
    }

    /// Fades the theme out. Delayed slightly so pushing from a series to one of
    /// its episodes keeps the music going instead of restarting it. With
    /// `evenIfShowing` (music starting elsewhere) it goes regardless of pages.
    func hide(evenIfShowing: Bool = false) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            // A page for this theme came (back) in the meantime.
            if !evenIfShowing, let key = self.key, self.pagesShowing[key] != nil { return }
            self.release()
        }
    }

    /// Quiets the theme while a video or disc menu is up.
    func suspend() {
        suspended = true
        if let music {
            fade(music, to: 0, over: 0.4) { music.pause() }
        }
        videoPlayer?.pause()
    }

    func resume() {
        suspended = false
        if let music {
            music.play()
            fade(music, to: volume, over: 0.8)
        }
        videoPlayer?.play()
    }

    // MARK: Internals

    private func release() {
        loadTask?.cancel()
        loadTask = nil
        if let music {
            let fading = music
            fade(fading, to: 0, over: 0.6) {
                fading.pause()
                fading.removeAllItems()
            }
        }
        music = nil
        looper = nil
        videoPlayer?.stop()
        videoPlayer = nil
        endClipTranscode()
        fallbackId = nil
        musicIsOpening = false
        isWatchingOpening = false
        key = nil
    }

    private func startMusic(url: URL) {
        let player = AVQueuePlayer()
        player.volume = 0
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        music = player
        if !suspended {
            player.play()
            fade(player, to: volume, over: 0.8)
        }
    }

    /// Only videos Apple TV can decode are used; an MKV theme simply leaves the
    /// still backdrop in place.
    private func startVideo(id: String, url: URL, themeKey: String, timeRange: CMTimeRange = .invalid, muted: Bool = true) async {
        let asset = AVURLAsset(url: url)
        let playable: Bool
        do {
            playable = try await asset.load(.isPlayable)
        } catch {
            #if DEBUG
            print("DEBUG theme: video \(id) failed to load: \(error.localizedDescription)")
            #endif
            return
        }
        guard playable, key == themeKey else {
            #if DEBUG
            if !playable { print("DEBUG theme: video \(id) isn't playable on Apple TV") }
            #endif
            return
        }
        let player = DiscTrailerPlayer(trailerId: id, url: url, muted: muted, timeRange: timeRange)
        // With sound, as quiet as theme music.
        if !muted { player.player.volume = volume }
        videoPlayer = player
        if !suspended { player.play() }
        #if DEBUG
        print("DEBUG theme: video \(id) started\(suspended ? " (suspended)" : "")")
        if let item = player.player.currentItem { Self.watch(item, label: "opening \(id)") }
        #endif
    }

    private func fade(_ player: AVQueuePlayer, to target: Float, over seconds: Double, completion: (() -> Void)? = nil) {
        let start = player.volume
        let steps = max(1, Int(seconds * 30))
        Task { @MainActor in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000) / steps))
                player.volume = start + (target - start) * Float(step) / Float(steps)
            }
            player.volume = target
            completion?()
        }
    }
}
