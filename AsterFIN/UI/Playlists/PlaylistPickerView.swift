//
//  PlaylistPickerView.swift
//  AsterFIN
//
//  "Add to Playlist": pick one of the user's playlists or make a new one.
//

import SwiftUI

/// What to add, handed to the picker as it opens. Presenting the picker with
/// this as its item, rather than ids kept beside a flag, means it opens with
/// the ids just chosen: with a flag, SwiftUI could build it from the ids as
/// they were before (none), and the add went through with nothing in it.
struct PlaylistRequest: Identifiable {
    let id = UUID()
    let itemIds: [String]
}

struct PlaylistPickerView: View {
    let itemIds: [String]
    /// "Audio" or "Video"; only playlists of this type are offered.
    let mediaType: String
    /// Called with the playlist's name once the items are in it.
    var onDone: (String) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.coverDismiss) private var dismiss
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

                HStack(spacing: Self.spacing) {
                    TextField("New playlist name", text: $newName)
                        .onboardingField()
                        .frame(maxWidth: 760)
                    ActionButton(title: "Create", systemImage: "plus", prominent: true) {
                        create()
                    }
                    .disabled(!canCreate)
                }
                .tvFocusSection()

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
                    .tvFocusSection()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, Self.topPadding)
            .padding(.bottom, Self.bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        #if !os(tvOS)
        // No remote Back button on iOS: give the picker a way to close.
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.white)
            .accessibilityLabel("Close")
            .padding(Lockup.screenPadding)
        }
        #endif
        .task { await load() }
    }

    #if os(tvOS)
    private static let spacing: CGFloat = 20
    private static let horizontalPadding: CGFloat = 120
    private static let topPadding: CGFloat = 80
    private static let bottomPadding: CGFloat = 80
    private static let artworkSize: CGFloat = 72
    private static let rowPadding = EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
    #else
    private static let spacing: CGFloat = 12
    private static let horizontalPadding: CGFloat = Lockup.screenPadding
    /// Clear of the close button.
    private static let topPadding: CGFloat = 64
    private static let bottomPadding: CGFloat = 16
    private static let artworkSize: CGFloat = 48
    private static let rowPadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 16)
    #endif

    private func row(_ playlist: BaseItem) -> some View {
        HStack(spacing: Self.spacing) {
            RemoteImage(url: session.jellyfin?.posterURL(for: playlist, width: 200), systemImage: "music.note.list")
                .frame(width: Self.artworkSize, height: Self.artworkSize)
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
        .padding(Self.rowPadding)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    private func load() async {
        guard let client = session.jellyfin else { return }
        playlists = (try? await client.playlists(mediaType: mediaType)) ?? []
        isLoading = false
    }

    private func add(to playlist: BaseItem) {
        guard let client = session.jellyfin else { return }
        guard !itemIds.isEmpty else {
            errorMessage = "There's nothing to add."
            return
        }
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
        guard let client = session.jellyfin else { return }
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