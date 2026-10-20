//
//  ChannelRemote.swift
//  AsterFIN
//
//  An iPhone held upright while a channel plays: the picture at the top
//  and, below it, every channel with what's on, like a remote in the hand.
//  Tap one to change to it. Sideways, the picture fills the screen and the
//  dial changes channel instead (`ChannelDialOverlay`).
//

#if os(iOS) && canImport(AetherEngine)
import SwiftUI

struct ChannelRemoteList: View {
    let playback: AetherPlayback
    let model: ChannelFlickModel

    @Environment(AppSession.self) private var session
    /// Bumped at each tune, for the thunk.
    @State private var tunes = 0

    /// The channel playing (or being tuned to).
    private var playingId: String { model.currentId }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(model.channels) { channel in
                        row(channel)
                            .id(channel.id)
                            .listRowBackground(channel.id == playingId ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.04))
                    }
                } header: {
                    Text("Channels")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { proxy.scrollTo(playingId, anchor: .center) }
        }
        .background(Color.black)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: tunes)
        .task {
            // What's on changes as programmes end.
            guard let client = session.client else { return }
            while !Task.isCancelled {
                await model.refresh(client: client)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func row(_ channel: FlickChannel) -> some View {
        Button {
            tune(channel)
        } label: {
            HStack(spacing: 14) {
                Text(channel.number ?? "")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .frame(minWidth: 40, alignment: .trailing)
                ZStack {
                    if let logo = channel.logoURL ?? channel.bugURL {
                        RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                    } else {
                        Image(systemName: "tv")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 52, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(channel.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if channel.id == playingId {
                            Text("Watching")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    if let program = channel.now {
                        ChannelProgramLines(program: program)
                    }
                }
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let program = channel.now, let itemId = program.itemId {
                Button(program.isMovie ? "Go to Movie" : "Go to Episode", systemImage: "arrow.up.right") {
                    playback.goTo(itemId)
                }
            }
        }
    }

    private func tune(_ channel: FlickChannel) {
        model.select(channel.id)
        guard channel.id != playingId else { return }
        playback.switchChannel(to: channel.id)
        model.playing(channel.id)
        tunes += 1
        DialSounds.shared.clunk()
    }
}
#endif
