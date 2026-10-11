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

    static let width: CGFloat = 352
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
        .buttonStyle(.card)
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
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer?.player !== player {
            view.playerLayer?.player = player
        }
    }
}
