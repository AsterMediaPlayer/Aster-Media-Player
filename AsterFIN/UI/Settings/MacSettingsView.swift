//
//  MacSettingsView.swift
//  AsterFIN
//

#if os(macOS)
import SwiftUI

/// The Mac's Settings window (Aster › Settings…, ⌘,): the categories in a
/// sidebar under their headings, as System Settings has them, with pages
/// within pages (Audio & Subtitles under Video) indented beneath, and the
/// page chosen beside it. It took over from a tab per page once there were
/// more than the window's width could hold.
struct MacSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var selection: SettingsCategory? = .streaming

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsCategory.Heading.allCases, id: \.self) { heading in
                    let categories = SettingsCategory.topLevel(under: heading, isJellyfin: session.isJellyfin)
                    if !categories.isEmpty {
                        Section {
                            ForEach(categories) { category in
                                sidebarRow(category)
                                ForEach(category.children(isJellyfin: session.isJellyfin)) { child in
                                    sidebarRow(child)
                                        .padding(.leading, 16)
                                }
                            }
                        } header: {
                            if let title = heading.title { Text(title) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            // The sidebar stays, as System Settings' does.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            if let selection {
                // A stack of its own for each page, for the pages it opens (a
                // saved server's, Open Source & Licenses). Account starts
                // afresh after a server switch, back at the list of servers
                // rather than on the page of the one switched from.
                NavigationStack {
                    selection.page
                        .navigationDestination(for: SettingsCategory.self) { category in
                            category.page
                        }
                        .navigationDestination(for: SettingsDestination.self) { destination in
                            destination.page
                        }
                        .openSourceDestinations()
                }
                .id(selection == .account ? "account-\(session.serverGeneration)" : "\(selection)")
            }
        }
        .frame(width: 880, height: 620)
        .task {
            if let client = session.jellyfin { await SettingsSync.pull(client: client) }
        }
        // Switched to a server without the page that was open (Server
        // Plugins, Channels, Disc Menus on Emby or Plex): Account, where the
        // switch was made.
        .onChange(of: session.serverGeneration) {
            if let selection, !selection.isAvailable(isJellyfin: session.isJellyfin) {
                self.selection = .account
            }
        }
    }

    private func sidebarRow(_ category: SettingsCategory) -> some View {
        Label(category.title, systemImage: category.systemImage)
            .tag(category)
    }
}
#endif
