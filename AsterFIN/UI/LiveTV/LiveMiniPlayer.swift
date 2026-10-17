//
//  LiveMiniPlayer.swift
//  AsterFIN
//
//  The channel that keeps playing in the Live TV header after Back, like
//  the Channels and YouTube TV apps. Selecting it goes full screen again.
//

#if canImport(AetherEngine)
import AetherEngine
#endif
import AVFoundation
import SwiftUI

struct LiveMiniPlayer: View {
    var coordinator: PlaybackCoordinator?
    #if canImport(AetherEngine)
    /// The channel when it's playing through AetherEngine.
    var aether: AetherPlayback?
    #endif
    var expand: () -> Void

    #if os(tvOS)
    static let width: CGFloat = 352
    #else
    /// Sits beside the "Live TV" title on a phone.
    static let width: CGFloat = 160
    #endif
    private static let height: CGFloat = width * 9 / 16

    var body: some View {
        Button(action: expand) {
            ZStack {
                Color.black
                #if canImport(AetherEngine)
                if let aether {
                    AetherPlayerSurface(engine: aether.engine)
                }
                #endif
                if let coordinator {
                    PlayerLayerView(player: coordinator.player)
                }
                if coordinator?.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.width, height: Self.height)
        }
        .cardButtonStyle()
        // The picture speaks for itself; VoiceOver still hears the channel.
        .accessibilityLabel("Now playing: \(channelTitle). Select to watch full screen.")
    }

    private var channelTitle: String {
        #if canImport(AetherEngine)
        let current = aether?.item ?? coordinator?.currentItem
        #else
        let current = coordinator?.currentItem
        #endif
        guard let item = current else { return "Live TV" }
        return [item.channelNumber, item.name].compactMap { $0 }.joined(separator: " ")
    }
}

/// Shows an AVPlayer's picture with no controls.
private struct PlayerLayerView: View {
    let player: AVPlayer

    var body: some View {
        VideoLayerView(player: player, gravity: .resizeAspect) { view in
            #if os(iOS)
            Self.restorePicture(in: view, from: player)
            #endif
        }
    }

    #if os(iOS)
    /// After the full-screen player closes, iOS leaves the player's video
    /// bound to the view that went away: this layer is attached and the sound
    /// plays, but no frame arrives. Re-attaching the layer or toggling the
    /// video track doesn't bring it back; a seek to where playback already is
    /// does, since it flushes playback and draws to the layers attached now.
    /// Waits a moment first so a hand-over that works on its own isn't
    /// interrupted, and tries again once if the first seek isn't enough.
    private static func restorePicture(in view: PlayerLayerHostView, from player: AVPlayer) {
        Task { @MainActor [weak view, player] in
            for _ in 1...3 {
                try? await Task.sleep(for: .milliseconds(700))
                guard let view, !view.playerLayer.isReadyForDisplay else { return }
                // Still loading a channel: nothing to show yet, so wait.
                guard player.timeControlStatus == .playing else { continue }
                await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }
    #endif
}
