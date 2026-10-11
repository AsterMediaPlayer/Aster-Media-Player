//
//  VideoPlaylistView.swift
//  AsterFIN
//
//  A playlist of movies and episodes: Play All, Shuffle, and a grid whose
//  entries can be reordered or removed with a long press.
//

import SwiftUI

struct VideoPlaylistView: View {
    let playlist: BaseItem

    @Environment(AppSession.self) private var session
    @State private var items: [BaseItem] = []
    @State private var isLoading = true
    @State private var playback: PlaybackRequest?
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: Lockup.landscapeWidth, maximum: Lockup.landscapeWidth), spacing: Lockup.gridSpacing, alignment: .top)]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    Text(playlist.displayTitle)
                        .font(.largeTitle.weight(.bold))
                    Spacer()
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Lockup.screenPadding)
                .padding(.top, 40)

                HStack(spacing: 20) {
                    ActionButton(title: "Play All", systemImage: "play.fill", prominent: true) {
                        playback = PlaybackRequest(itemIds: items.map(\.id))
                    }
                    ActionButton(title: "Shuffle", systemImage: "shuffle") {
                        playback = PlaybackRequest(itemIds: items.shuffled().map(\.id))
                    }
                }
                .disabled(items.isEmpty)
                .padding(.horizontal, Lockup.screenPadding)
                .tvFocusSection()

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, Lockup.screenPadding)
                }

                if items.isEmpty, !isLoading {
                    MessageView(systemImage: "list.and.film", title: "This playlist is empty", detail: "Use Add to Playlist on a movie or episode to fill it.")
                        .frame(height: 400)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Lockup.gridRowSpacing) {
                        ForEach(Array(items.enumerated()), id: \.element.playlistRowID) { position, item in
                            PlaylistVideoLockup(item: item) {
                                if position > 0 {
                                    Button("Move Up", systemImage: "arrow.up") { move(item, to: position - 1) }
                                }
                                if position < items.count - 1 {
                                    Button("Move Down", systemImage: "arrow.down") { move(item, to: position + 1) }
                                }
                                Button("Remove from Playlist", systemImage: "trash", role: .destructive) { remove(item) }
                            }
                        }
                    }
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.vertical, 40)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .task(id: playlist.id) { await load() }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request) { playback = nil }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        do {
            items = try await client.playlistItems(playlistId: playlist.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func remove(_ item: BaseItem) {
        guard let client = session.client, let entry = item.playlistItemId else { return }
        let previous = items
        items.removeAll { $0.playlistRowID == item.playlistRowID }
        Task {
            do {
                try await client.removeFromPlaylist(playlist.id, entryIds: [entry])
            } catch {
                items = previous
                errorMessage = error.localizedDescription
            }
        }
    }

    private func move(_ item: BaseItem, to newIndex: Int) {
        guard let client = session.client, let entry = item.playlistItemId,
              let from = items.firstIndex(where: { $0.playlistRowID == item.playlistRowID }) else { return }
        let previous = items
        let moved = items.remove(at: from)
        items.insert(moved, at: newIndex)
        Task {
            do {
                try await client.movePlaylistItem(playlist.id, entryId: entry, to: newIndex)
            } catch {
                items = previous
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A landscape lockup that opens the item and offers playlist actions on a
/// long press of the clickpad.
private struct PlaylistVideoLockup<Actions: View>: View {
    let item: BaseItem
    @ViewBuilder var actions: () -> Actions

    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: item) {
                RemoteImage(url: session.client?.landscapeURL(for: item, width: 800), systemImage: item.kind == .episode ? "tv" : "film")
                    .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
            }
            .cardButtonStyle()
            .contextMenu(menuItems: actions)
            .accessibilityLabel(item.displayTitle)

            Text(item.kind == .episode ? (item.seriesName ?? item.displayTitle) : item.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: Lockup.landscapeWidth, alignment: .leading)
            if item.kind == .episode {
                Text([item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Lockup.landscapeWidth, alignment: .leading)
            } else if let year = item.yearText {
                Text(year)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}