//
//  ChannelBug.swift
//  AsterFIN
//
//  A Channel's logo, faint in a corner while it plays, as a TV network's
//  bug. Shown for a channel tagged aster:bug=on with a logo (its one
//  series' clear logo, or the playlist's picture), in the corner and at the
//  size its bug-location= and bug-size=
//  tags ask for. It sits in the corner of the picture itself, so a 4:3
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
    /// What's playing: a new programme brings back a bug that hides itself.
    var playingId: String?

    @Environment(AppSession.self) private var session
    /// Faded out, `bug-hide=` seconds after tuning in or a programme starting.
    @State private var faded = false

    #if os(tvOS)
    private static let width: CGFloat = 300
    #else
    private static let width: CGFloat = 128
    #endif
    /// From the picture's right and bottom edges, as fractions of its size,
    /// so the bug keeps clear of the edge on any screen.
    private static let insetX: CGFloat = 0.094
    private static let insetY: CGFloat = 0.12

    private var channel: PlaylistChannel? {
        guard let channelId, let channel = ChannelTuner.channel(channelId), channel.showsBug else { return nil }
        return channel
    }

    var body: some View {
        if let channel, let client = session.client,
           let url = channel.logoURL(client: client, maxWidth: Int(Self.width * CGFloat(channel.bugSize) / 100 * 2)) {
            let corner = channel.bugCorner
            let width = Self.width * CGFloat(channel.bugSize) / 100
            GeometryReader { proxy in
                let picture = Self.pictureRect(in: proxy.size, aspect: videoAspect)
                let insetX = picture.width * Self.insetX + width / 2
                let insetY = picture.height * Self.insetY + width / 2
                RemoteImage(url: url, contentMode: .fit) { EmptyView() }
                    .frame(width: width, height: width, alignment: Self.alignment(for: corner))
                    .opacity(faded ? 0 : 0.45)
                    .position(
                        x: corner.isLeft ? picture.minX + insetX : picture.maxX - insetX,
                        y: corner.isTop ? picture.minY + insetY : picture.maxY - insetY
                    )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: "\(channel.id)|\(playingId ?? "")") {
                faded = false
                guard channel.bugHideAfter > 0 else { return }
                try? await Task.sleep(for: .seconds(channel.bugHideAfter))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 1)) { faded = true }
            }
        }
    }

    /// The logo hugs the corner it's in, whatever its shape.
    private static func alignment(for corner: BugCorner) -> Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
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
