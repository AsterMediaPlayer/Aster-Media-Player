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
    @AppStorage(AppSettings.playlistChannelsKey) private var stored = ""
    @AppStorage(AppSettings.playlistChannelModesKey) private var storedModes = ""
    @AppStorage(AppSettings.playlistChannelLogosKey) private var storedLogos = ""
    @State private var model = ChannelsModel()
    @State private var guide: ChannelGuideSource?

    private var ids: [String] { PlaylistChannelList.ids(from: stored) }

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
                    emptyDetail: "Pick video playlists with movies or episodes in Edit Channels."
                )
                // A new guide (other channels, or the next day) starts afresh.
                .id(ObjectIdentifier(guide))
            }
        }
        .task(id: [stored, storedModes, storedLogos]) {
            guard let client = session.client else { return }
            await model.load(
                ids: ids,
                modes: PlaylistChannelList.modes(from: storedModes),
                logos: Set(PlaylistChannelList.ids(from: storedLogos)),
                client: client
            )
            rebuildGuide()
        }
        .onAppear {
            // The guide covers a day from when it was made; move it on once
            // it's an hour behind.
            if let guide, Date().timeIntervalSince(guide.guideStart) > 3600 { rebuildGuide() }
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
