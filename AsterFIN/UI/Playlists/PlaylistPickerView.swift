//
//  PlaylistPickerView.swift
//  AsterFIN
//
//  "Add to Playlist": pick one of the user's playlists or make a new one.
//

import SwiftUI

struct PlaylistPickerView: View {
    let itemIds: [String]
    /// "Audio" or "Video"; only playlists of this type are offered.
    let mediaType: String
    /// Called with the playlist's name once the items are in it.
    var onDone: (String) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [BaseItem] = []
    @State private var isLoading = true
    @State private var newName = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canCreate: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking
    }

    var body: some View {
        ZStack {
            Color(white: 0.06).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add to Playlist")
                        .font(.largeTitle.weight(.bold))
                    Text("\(itemIds.count) item\(itemIds.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 20) {
                    TextField("New playlist name", text: $newName)
                        .frame(width: 760)
                    ActionButton(title: "Create", systemImage: "plus", prominent: true) {
                        create()
                    }
                    .disabled(!canCreate)
                }
                .focusSection()

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else if playlists.isEmpty {
                    Text("No \(mediaType == "Audio" ? "music" : "video") playlists yet. Name one above to create it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Your Playlists")
                        .font(.title3.weight(.semibold))
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 8) {
                            ForEach(playlists) { playlist in
                                Button {
                                    add(to: playlist)
                                } label: {
                                    row(playlist)
                                }
                                .buttonStyle(.plain)
                                .disabled(isWorking)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .focusSection()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await load() }
    }

    private func row(_ playlist: BaseItem) -> some View {
        HStack(spacing: 20) {
            RemoteImage(url: session.client?.posterURL(for: playlist, width: 200), systemImage: "music.note.list")
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let count = playlist.childCount {
                    Text("\(count) item\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "plus.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    private func load() async {
        guard let client = session.client else { return }
        playlists = (try? await client.playlists(mediaType: mediaType)) ?? []
        isLoading = false
    }

    private func add(to playlist: BaseItem) {
        guard let client = session.client else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await client.addToPlaylist(playlist.id, itemIds: itemIds)
                onDone(playlist.displayTitle)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func create() {
        guard let client = session.client else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await client.createPlaylist(name: name, itemIds: itemIds, mediaType: mediaType)
                onDone(name)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}