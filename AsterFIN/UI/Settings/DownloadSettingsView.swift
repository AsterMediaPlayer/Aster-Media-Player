//
//  DownloadSettingsView.swift
//  AsterFIN
//
//  Settings ▸ Downloads (iPhone and iPad).
//

import SwiftUI

// MARK: - Downloads

#if os(iOS)
/// Downloads on or off, then where and how they're saved.
struct DownloadSettingsView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.downloadsEnabledKey) private var enabled = true
    @State private var confirmRemoveAll = false

    private let store = DownloadStore.shared

    var body: some View {
        SettingsPage(title: "Downloads") {
            Section {
                Toggle("Allow downloads", isOn: $enabled)
                SettingsNote(enabled
                    ? "Download movies and episodes from the ⋯ button on their page to watch without a connection. They're in the Downloads tab."
                    : "Download is hidden and the Downloads tab is gone. Titles already downloaded stay until you remove them.")
            }
            if enabled, !session.canDownload {
                Section {
                    SettingsNote("Your Jellyfin account isn't allowed to download media. The server's administrator can allow it in the user's settings, under Allow media downloading.")
                }
            }
            if enabled {
                DownloadOptionsSections()
            }
            if !store.records.isEmpty || !AudiobookDownloads.shared.records.isEmpty {
                Section {
                    Button("Remove All Downloads", role: .destructive) { confirmRemoveAll = true }
                }
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                store.removeAll()
                AudiobookDownloads.shared.removeAll()
            }
        } message: {
            Text("This frees \(DownloadStore.format(store.usedBytes + AudiobookDownloads.shared.usedBytes)) and stops any downloads in progress.")
        }
    }
}
#endif
