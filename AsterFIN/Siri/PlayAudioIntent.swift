//
//  PlayAudioIntent.swift
//  AsterFIN
//
//  "Play OK Computer in Aster": plays what Siri found on the phone's music
//  player, shuffled or repeating if asked, or after the current song or at
//  the end of the queue. In the car, CarPlay's Now Playing shows it.
//

#if os(iOS)
import AppIntents

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays songs, albums, artists or playlists from your Jellyfin server.")

    var audioEntity: AudioEntity
    @Parameter(default: [])
    var playbackAttributes: Set<PlaybackAttributes>
    var queueLocation: QueueInsertionLocation?
    var warmupAudioQueueResult: WarmupAudioQueueResult?

    @MainActor
    func perform() async throws -> some IntentResult {
        let client = try SiriLibrary.client()
        let tracks = try await SiriLibrary.tracks(for: audioEntity)
        guard !tracks.isEmpty else { throw SiriMusicError.nothingToPlay }
        let music = AppSession.shared.music
        switch queueLocation {
        case .next?:
            music.enqueue(tracks, next: true, client: client)
        case .tail?:
            music.enqueue(tracks, next: false, client: client)
        case nil:
            music.play(tracks, shuffled: playbackAttributes.contains(.shuffle), client: client)
            if playbackAttributes.contains(.repeat), music.repeatMode == .off {
                music.cycleRepeat()
            }
        }
        return .result()
    }
}
#endif
