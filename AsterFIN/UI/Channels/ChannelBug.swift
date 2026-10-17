//
//  ChannelBug.swift
//  AsterFIN
//
//  A Channel's logo, faint in the bottom corner while it plays, as a TV
//  network's bug. Shown for a channel tagged asterfin:bug=on whose playlist
//  has a picture.
//

import SwiftUI

struct ChannelBug: View {
    /// The Channel playing; nil when it isn't one.
    let channelId: String?

    @Environment(AppSession.self) private var session

    #if os(tvOS)
    private static let width: CGFloat = 150
    private static let inset = EdgeInsets(top: 0, leading: 0, bottom: 70, trailing: 90)
    #else
    private static let width: CGFloat = 64
    private static let inset = EdgeInsets(top: 0, leading: 0, bottom: 24, trailing: 24)
    #endif

    private var imageURL: URL? {
        guard let channelId, let channel = ChannelTuner.channel(channelId), channel.showsBug,
              let tag = channel.playlist.imageTags?["Primary"], let client = session.client else { return nil }
        return client.imageURL(itemId: channel.playlist.id, kind: .primary, tag: tag, maxWidth: Int(Self.width * 2))
    }

    var body: some View {
        if let imageURL {
            RemoteImage(url: imageURL, contentMode: .fit) { EmptyView() }
                .frame(width: Self.width, height: Self.width)
                .opacity(0.45)
                .padding(Self.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
