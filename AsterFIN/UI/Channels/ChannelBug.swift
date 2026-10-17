//
//  ChannelBug.swift
//  AsterFIN
//
//  A Channel's logo, faint in the bottom corner while it plays, as a TV
//  network's bug. Shown for a channel tagged asterfin:bug=on whose playlist
//  has a picture. It sits in the corner of the picture itself, so a 4:3
//  show between black bars (or a wide film between bars above and below)
//  keeps it on the picture rather than out in the bars.
//

import SwiftUI

struct ChannelBug: View {
    /// The Channel playing; nil when it isn't one.
    let channelId: String?
    /// The picture's shape as shown, width over height; nil while unknown,
    /// when the picture is taken to fill the screen.
    var videoAspect: CGFloat?

    @Environment(AppSession.self) private var session

    #if os(tvOS)
    private static let width: CGFloat = 300
    #else
    private static let width: CGFloat = 128
    #endif
    /// From the picture's right and bottom edges, as fractions of its size,
    /// so the bug keeps clear of the edge on any screen.
    private static let insetX: CGFloat = 0.094
    private static let insetY: CGFloat = 0.12

    private var imageURL: URL? {
        guard let channelId, let channel = ChannelTuner.channel(channelId), channel.showsBug,
              let tag = channel.playlist.imageTags?["Primary"], let client = session.client else { return nil }
        return client.imageURL(itemId: channel.playlist.id, kind: .primary, tag: tag, maxWidth: Int(Self.width * 2))
    }

    var body: some View {
        if let imageURL {
            GeometryReader { proxy in
                let picture = Self.pictureRect(in: proxy.size, aspect: videoAspect)
                RemoteImage(url: imageURL, contentMode: .fit) { EmptyView() }
                    .frame(width: Self.width, height: Self.width, alignment: .bottomTrailing)
                    .opacity(0.45)
                    .position(
                        x: picture.maxX - picture.width * Self.insetX - Self.width / 2,
                        y: picture.maxY - picture.height * Self.insetY - Self.width / 2
                    )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Where a picture of `aspect` sits when fitted into `size`: the whole of
    /// it for a matching shape, between bars otherwise.
    static func pictureRect(in size: CGSize, aspect: CGFloat?) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        guard let aspect, aspect.isFinite, aspect > 0, size.width > 0, size.height > 0 else { return full }
        if size.width / size.height > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        } else {
            let height = size.width / aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
    }
}
