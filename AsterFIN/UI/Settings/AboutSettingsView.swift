//
//  AboutSettingsView.swift
//  AsterFIN
//
//  Settings ▸ About.
//

import SwiftUI

// MARK: - About

struct AboutSettingsView: View {
    @State private var sendingReport = false

    var body: some View {
        SettingsPage(title: "About") {
            // Focusable rows give the page somewhere for focus to land; with
            // nothing focused, tvOS never delivers the Back press to pop it.
            Section {
                LabeledContent("Aster Media Player", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .focusable()
                SettingsNote("A Jellyfin, Emby and Plex client for Apple TV, iPhone, iPad and Mac, with DVD and Blu-ray style menus on Jellyfin from the Aster Disc plugin.")
                    .focusable()
            }
            Section {
                AboutLink(title: "Help & Support", systemImage: "questionmark.circle", address: AboutLink.support)
                AboutLink(title: "Privacy Policy", systemImage: "hand.raised", address: AboutLink.privacy)
                NavigationLink(value: OpenSourceRoute.list) {
                    Label("Open Source & Licenses", systemImage: "doc.text")
                }
                Button {
                    sendingReport = true
                } label: {
                    Label("Send Debug Report", systemImage: "ladybug")
                }
            }
        }
        .sheet(isPresented: $sendingReport) {
            DebugReportView()
        }
    }
}

/// One of Aster's web pages: a link where there's a browser, and the address
/// to type in on Apple TV, which has none.
private struct AboutLink: View {
    static let support = "https://astermediaplayer.com/support.html"
    static let privacy = "https://astermediaplayer.com/privacy.html"

    let title: String
    let systemImage: String
    let address: String

    var body: some View {
        #if os(tvOS)
        LabeledContent {
            Text(address.replacingOccurrences(of: "https://", with: ""))
        } label: {
            Label(title, systemImage: systemImage)
        }
        .focusable()
        #else
        if let url = URL(string: address) {
            Link(destination: url) {
                Label(title, systemImage: systemImage)
            }
        }
        #endif
    }
}
