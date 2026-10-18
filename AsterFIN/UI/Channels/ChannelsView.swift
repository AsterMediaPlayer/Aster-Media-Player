//
//  ChannelsView.swift
//  AsterFIN
//
//  The Channels tab: playlists made into TV-style channels, laid out in the
//  same guide as Live TV.
//

import SwiftUI

struct ChannelsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openItem) private var openItem
    @State private var model = ChannelsModel()
    @State private var guide: ChannelGuideSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Channels (Beta)")
                    .font(.largeTitle.weight(.bold))
                Spacer()
                NavigationLink {
                    ChannelSettingsView()
                } label: {
                    Label("Edit Channels", systemImage: "slider.horizontal.3")
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
            #if os(tvOS)
            .padding(.top, 40)
            #else
            .padding(.top, 8)
            #endif
            .padding(.bottom, 10)
            .tvFocusSection()

            if let error = model.errorMessage, model.channels.isEmpty {
                MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let guide {
                GuideView(
                    model: guide,
                    channels: guide.channels,
                    select: select,
                    playChannel: tuneIn(channelId:),
                    emptyDetail: "Make a video playlist into a channel in Edit Channels, or tag it aster:channel in Jellyfin."
                )
                // A new guide (other channels, or the next day) starts afresh.
                .id(ObjectIdentifier(guide))
            }
        }
        // On showing, and again on coming back (from Edit Channels, say):
        // the channels are whatever the server's playlists are tagged as now.
        // Only playlists whose contents changed are fetched again.
        .onAppear {
            Task {
                guard let client = session.client else { return }
                let before = model.channels
                await model.load(client: client)
                // The guide covers a week from when it was made: it's made
                // again when the channels changed, or once it's an hour behind.
                if guide == nil || model.channels != before || guide.map({ Date().timeIntervalSince($0.guideStart) > 3600 }) == true {
                    rebuildGuide()
                }
            }
        }
    }

    private func rebuildGuide() {
        guide = ChannelGuideSource(channels: model.channels)
    }

    /// What's on now tunes in; anything later opens its page.
    private func select(_ program: BaseItem) {
        guard let scheduled = guide?.scheduledProgram(withId: program.id) else { return }
        if scheduled.contains(Date()) {
            tuneIn(channelId: scheduled.channelId)
        } else {
            openItem?(scheduled.item)
        }
    }

    /// Plays what's on the channel now, from as far in as it's got.
    private func tuneIn(channelId: String) {
        guard let live = ChannelTuner.live(channelId: channelId) else { return }
        session.router.play(PlaybackRequest(entry: live.entry))
    }
}
