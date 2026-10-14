//
//  AetherPlayback.swift
//  AsterFIN
//
//  Plays one video through AetherEngine instead of AVPlayer, a test of the
//  engine behind the "Player engine" setting. The file streams from the
//  server untouched (no transcode, no HLS), so every audio and subtitle
//  track is in hand and switches on the device. Progress goes to Jellyfin
//  as it does for the system player. Music and audiobooks don't use this.
//

#if canImport(AetherEngine)
import AetherEngine
import AVFoundation
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

    private let client: JellyfinClient
    private let entry: PlaybackQueueItem
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

    /// Whether this engine can take `request`: one whole title from the
    /// server. A queue, a clip, or a download keeps to the system player.
    static func canPlay(_ request: PlaybackRequest) -> Bool {
        guard AppSettings.useAetherEngine, sharedEngine != nil, request.items.count == 1, let entry = request.items.first, entry.endTicks == nil else { return false }
        #if os(iOS)
        if DownloadStore.shared.playable(entry.itemId) != nil { return false }
        #endif
        return true
    }

    init?(client: JellyfinClient, request: PlaybackRequest, preferences: PlaybackPreferences) {
        guard let engine = Self.sharedEngine, let entry = request.items.first else { return nil }
        self.engine = engine
        self.client = client
        self.entry = entry
        self.preferences = preferences
    }

    func start() async {
        do {
            let item = try await client.item(entry.itemId)
            self.item = item
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
            attachments = source.mediaAttachments ?? item.mediaSources?.first { $0.id == source.id }?.mediaAttachments ?? []
            let subtitle = PlaybackCoordinator.resolveSubtitle(for: entry, source: source, among: subtitles, preferences: preferences)

            let url = client.directStreamURL(itemId: entry.itemId, mediaSourceId: source.id, playSessionId: info.playSessionId, container: source.container)
            let start = entry.startTicks > 0 ? Double(entry.startTicks) / 10_000_000 : nil
            try await engine.load(url: url, startPosition: start, audioSourceStreamIndex: audio.map { Int32($0) })
            guard !stopped else { return }
            // Jellyfin numbers a file's streams as the container does, so its
            // index is the engine's track id. An external file isn't in the
            // container and has no engine track yet.
            if subtitle >= 0, engine.subtitleTracks.contains(where: { $0.id == subtitle }) {
                selectSubtitle(subtitle)
            }
            engine.play()
            hasStarted = true
            await client.reportStart(report(paused: false))
            startReporting()
        } catch is CancellationError {
            // A newer load took over, or the player closed.
        } catch {
            if !stopped { errorMessage = error.localizedDescription }
        }
    }

    /// Stops playback and tells the server where it ended. Safe to call twice.
    func stop() {
        guard !stopped else { return }
        stopped = true
        reportTask?.cancel()
        clearStyledSubtitles()
        let final = report(paused: true)
        engine.stop()
        if hasStarted {
            let client = client
            Task { await client.reportStopped(final) }
        }
    }

    // MARK: Tracks

    func selectAudio(_ id: Int) {
        engine.selectAudioTrack(index: id)
    }

    /// A subtitle track by id, or none for nil.
    func selectSubtitle(_ id: Int?) {
        clearStyledSubtitles()
        if let id {
            engine.selectSubtitleTrack(index: id)
            loadStyledSubtitles(id)
        } else {
            engine.clearSubtitle()
        }
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
                guard let self, !Task.isCancelled, self.engine.activeSubtitleTrackIndex == id else {
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
            canSeek: true,
            playMethod: "DirectPlay",
            liveStreamId: nil,
            audioStreamIndex: engine.activeAudioTrackIndex,
            subtitleStreamIndex: engine.activeSubtitleTrackIndex
        )
    }
}
#endif
