//
//  SettingsView.swift
//  AsterFIN
//

import SwiftUI

/// The Settings root: the categories under their headings, each opening its
/// own page. The pages go on the tab's navigation path, as browsing pages
/// do, so the tab knows a page is open (iPhone's More tab then hides its
/// own back button; see `MoreBarHider`).
struct SettingsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        SettingsPage(title: "Settings") {
            ForEach(SettingsCategory.Heading.allCases, id: \.self) { heading in
                let categories = SettingsCategory.topLevel(under: heading, isJellyfin: session.isJellyfin)
                if !categories.isEmpty {
                    Section {
                        ForEach(categories) { category in
                            row(category)
                        }
                    } header: {
                        if let title = heading.title { Text(title) }
                    }
                }
            }
        }
        // Every page's destination is here at the root, the pages within
        // pages too: registered further in, Apple TV froze opening them.
        .navigationDestination(for: SettingsCategory.self) { category in
            category.page
        }
        .navigationDestination(for: SettingsDestination.self) { destination in
            destination.page
        }
        .openSourceDestinations()
        // Settings that follow the user come from their server on opening.
        .task {
            if let client = session.jellyfin { await SettingsSync.pull(client: client) }
        }
    }

    @ViewBuilder
    private func row(_ category: SettingsCategory) -> some View {
        if category == .account {
            NavigationLink(value: category) {
                LabeledContent {
                    Text(session.userName ?? "")
                } label: {
                    Label(category.title, systemImage: category.systemImage)
                }
            }
        } else {
            category.link
        }
    }
}
