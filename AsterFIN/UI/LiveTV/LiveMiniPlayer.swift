//
//  LiveMiniPlayer.swift
//  AsterFIN
//
//  The channel that keeps playing in the Live TV header after Back, like
//  the Channels and YouTube TV apps. Selecting it goes full screen again.
//

import AVFoundation
import SwiftUI

struct LiveMiniPlayer: View {
    let coordinator: PlaybackCoordinator
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
                PlayerLayerView(player: coordinator.player)
                if coordinator.errorMessage != nil {
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
        guard let item = coordinator.currentItem else { return "Live TV" }
        return [item.channelNumber, item.name].compactMap { $0 }.joined(separator: " ")
    }
}

/// Shows an AVPlayer's picture with no controls.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer?.videoGravity = .resizeAspect
        view.playerLayer?.player = player
        #if !os(tvOS)
        Self.restorePicture(in: view, from: player)
        #endif
        return view
    }

    #if !os(tvOS)
    /// After the full-screen player closes, iOS leaves the player's video
    /// bound to the view that went away: this layer is attached and the sound
    /// plays, but no frame arrives. Re-attaching the layer or toggling the
    /// video track doesn't bring it back; a seek to where playback already is
    /// does, since it flushes playback and draws to the layers attached now.
    /// Waits a moment first so a hand-over that works on its own isn't
    /// interrupted, and tries again once if the first seek isn't enough.
    private static func restorePicture(in view: LayerView, from player: AVPlayer) {
        Task { @MainActor [weak view, player] in
            for _ in 1...3 {
                try? await Task.sleep(for: .milliseconds(700))
                guard let view, let layer = view.playerLayer, !layer.isReadyForDisplay else { return }
                // Still loading a channel: nothing to show yet, so wait.
                guard player.timeControlStatus == .playing else { continue }
                await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }
    #endif

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer?.player !== player {
            view.playerLayer?.player = player
        }
    }
}
