//
//  SettingsCategory.swift
//  AsterFIN
//
//  Settings' pages, grouped under headings: one list for the Settings tab
//  on iPhone, iPad and Apple TV, and the sidebar of the Mac's Settings
//  window. A page can sit within another (Audio & Subtitles under Video):
//  it opens from that page, and on the Mac shows under it in the sidebar.
//

import SwiftUI

enum SettingsCategory: Hashable, CaseIterable, Identifiable {
    case streaming, video, audioSubtitles, discMenus, music, audiobooks
    case anime, titlePages, channels
    case downloads, general, tabBar
    case tracking, serverPlugins
    case account, about

    var id: Self { self }

    enum Heading: CaseIterable {
        case playback, library, device, services, account

        var title: String? {
            switch self {
            case .playback: "Playback"
            case .library: "Library"
            case .device: "This Device"
            case .services: "Services"
            case .account: nil
            }
        }
    }

    var title: String {
        switch self {
        case .streaming: "Streaming & Data"
        case .video: "Video"
        case .audioSubtitles: "Audio & Subtitles"
        case .discMenus: "Disc Menus"
        case .music: "Music"
        case .audiobooks: "Audiobooks"
        case .anime: "Anime"
        case .titlePages: "Title Pages"
        case .channels: "Channels"
        case .downloads: "Downloads"
        case .general: "General"
        case .tabBar: "Tab Bar"
        case .tracking: "Tracking"
        case .serverPlugins: "Server Plugins"
        case .account: "Account"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .streaming: "antenna.radiowaves.left.and.right"
        case .video: "play.rectangle"
        case .audioSubtitles: "captions.bubble"
        case .discMenus: "opticaldisc"
        case .music: "music.note"
        case .audiobooks: "books.vertical"
        case .anime: "sparkles"
        case .titlePages: "music.note.tv"
        case .channels: "tv.and.mediabox"
        case .downloads: "arrow.down.circle"
        case .general: "gearshape"
        case .tabBar: "rectangle.bottomhalf.inset.filled"
        case .tracking: "checklist"
        case .serverPlugins: "puzzlepiece.extension"
        case .account: "person.crop.circle"
        case .about: "info.circle"
        }
    }

    var heading: Heading {
        switch self {
        case .streaming, .video, .audioSubtitles, .discMenus, .music, .audiobooks: .playback
        case .anime, .titlePages, .channels: .library
        case .downloads, .general, .tabBar: .device
        case .tracking, .serverPlugins: .services
        case .account, .about: .account
        }
    }

    /// The page this one opens from, for a page within another.
    var parent: SettingsCategory? {
        switch self {
        case .audioSubtitles, .discMenus: .video
        case .tabBar: .general
        default: nil
        }
    }

    /// Whether the page is offered here, with this server.
    func isAvailable(isJellyfin: Bool) -> Bool {
        switch self {
        // Disc menus come from a Jellyfin plugin, and Channels from playlist
        // tags in Jellyfin's shape: neither on Emby or Plex yet.
        case .discMenus, .channels, .serverPlugins:
            return isJellyfin
        // Only once Aster has the services' app ids (see TrackerKeys).
        case .tracking:
            return TrackerAccounts.isAvailable || AsterTracking.shared.isPresent
        case .downloads, .tabBar, .audiobooks:
            #if os(iOS)
            return true
            #else
            return false
            #endif
        default:
            return true
        }
    }

    /// The pages offered at the top level, under `heading`, in order.
    static func topLevel(under heading: Heading, isJellyfin: Bool) -> [SettingsCategory] {
        allCases.filter { $0.heading == heading && $0.parent == nil && $0.isAvailable(isJellyfin: isJellyfin) }
    }

    /// The pages within this one, in order.
    func children(isJellyfin: Bool) -> [SettingsCategory] {
        Self.allCases.filter { $0.parent == self && $0.isAvailable(isJellyfin: isJellyfin) }
    }

    /// A row opening this page, on the Settings stack.
    var link: some View {
        NavigationLink(value: self) {
            Label(title, systemImage: systemImage)
        }
    }

    @MainActor @ViewBuilder
    var page: some View {
        switch self {
        case .streaming: StreamingSettingsView()
        case .video: VideoSettingsView()
        case .audioSubtitles: AudioSubtitleSettingsView()
        case .discMenus: DiscMenuSettingsView()
        case .music: MusicSettingsView()
        case .audiobooks:
            #if os(iOS)
            AudiobookSettingsView()
            #else
            EmptyView()
            #endif
        case .anime: AnimeSettingsView()
        case .titlePages: TitlePageSettingsView()
        case .channels: ChannelSettingsView()
        case .downloads:
            #if os(iOS)
            DownloadSettingsView()
            #else
            EmptyView()
            #endif
        case .general: GeneralSettingsView()
        case .tabBar:
            #if os(iOS)
            TabBarSettingsView()
            #else
            EmptyView()
            #endif
        case .tracking: TrackingSettingsView()
        case .serverPlugins: ServerPluginsSettingsView()
        case .account: AccountSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

/// Pages under Account: a saved server's page, and its Lock After choices,
/// by the server's id. Registered at the stack's root with the categories:
/// pages registered further in froze Apple TV when they opened one more.
enum SettingsDestination: Hashable {
    case savedServer(String), lockAfter(String)

    @MainActor @ViewBuilder
    var page: some View {
        switch self {
        case .savedServer(let id): SavedServerPage(serverID: id)
        case .lockAfter(let id): LockAfterPage(serverID: id)
        }
    }
}
