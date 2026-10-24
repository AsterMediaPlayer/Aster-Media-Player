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
                Button {
                    openItem?.push(ChannelSettingsPage())
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
                    // On Apple TV, an administrator's Select on a channel
                    // opens its settings; everyone else's (and a tap on a
                    // touch screen) tunes in, as before.
                    openChannel: Self.selectOpensSettings && session.canEditChannels ? { openItem?.push(ChannelSettingsPage(only: $0)) } : nil,
                    grouping: model.grouping,
                    emptyDetail: "Make a video playlist into a channel in Edit Channels, or tag it aster:channel in Jellyfin."
                )
                // A new guide (other channels, or the next day) starts afresh.
                .id(ObjectIdentifier(guide))
            }
        }
        // Pushed onto the tab's own path, so Back comes straight back to the
        // guide, and under iPhone's More tab its bar steps aside for the
        // page's (one back arrow). A push of the page's own, or a second
        // copy of that bar-hiding, once crashed opening Channels under More.
        .navigationDestination(for: ChannelSettingsPage.self) { page in
            ChannelSettingsView(only: page.only)
        }
        // On showing, and again on coming back (from Edit Channels, say):
        // the channels are whatever the server's playlists are tagged as now.
        // Only playlists whose contents changed are fetched again.
        .onAppear {
            Task {
                guard let client = session.client else { return }
                let before = model.channels
                await model.load(client: client, userName: session.userName)
                // The guide covers a week from when it was made: it's made
                // again when the channels changed, or once it's an hour behind.
                if guide == nil || model.channels != before || guide.map({ Date().timeIntervalSince($0.guideStart) > 3600 }) == true {
                    rebuildGuide()
                }
            }
        }
    }

    #if os(tvOS)
    private static let selectOpensSettings = true
    #else
    private static let selectOpensSettings = false
    #endif

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

/// Edit Channels, or one channel's settings, as a page on the tab's path.
struct ChannelSettingsPage: Hashable {
    var only: String? = nil
}
