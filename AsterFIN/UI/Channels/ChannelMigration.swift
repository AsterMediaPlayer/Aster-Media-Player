//
//  ChannelMigration.swift
//  AsterFIN
//
//  Channels used to be a list kept in AsterFIN's settings (on the device,
//  synced through the server). They're playlist tags now. The first time an
//  administrator opens this version, the old list is written as tags on
//  those playlists, keeping each channel's number, mode and logo, and the
//  old settings are no longer read.
//

import Foundation

enum ChannelMigration {
    private static let doneKey = "AsterFIN.channelsInTags"

    static func runIfNeeded(client: JellyfinClient) async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        // The old settings as the server last had them, else this device's.
        let server = (try? await client.appSettings()) ?? [:]
        func old(_ serverKey: String, _ localKey: String) -> String {
            server[serverKey] ?? defaults.string(forKey: localKey) ?? ""
        }
        let ids = PlaylistChannelList.ids(from: old("playlistChannels", AppSettings.playlistChannelsKey))
        guard !ids.isEmpty else {
            defaults.set(true, forKey: doneKey)
            return
        }
        // Only an administrator can write the tags; anyone else waits for one.
        guard let me = try? await client.me(), me.policy?.isAdministrator == true,
              let playlists = try? await client.playlists(mediaType: "Video") else { return }
        let modes = PlaylistChannelList.modes(from: old("playlistChannelModes", AppSettings.playlistChannelModesKey))
        let logos = Set(PlaylistChannelList.ids(from: old("playlistChannelLogos", AppSettings.playlistChannelLogosKey)))
        var allWritten = true
        for (index, id) in ids.enumerated() {
            guard let playlist = playlists.first(where: { $0.id == id }) else { continue }
            // Already tagged (another device got here first): leave it.
            guard !ChannelTags(tags: playlist.tags).isChannel else { continue }
            let tags = ChannelTags(isChannel: true, number: index + 1, mode: modes[id] ?? .rotation, showsLogo: logos.contains(id))
            do {
                try await client.setTags(tags.applied(to: playlist.tags), onItem: id)
            } catch {
                allWritten = false
                #if DEBUG
                print("DEBUG channels: couldn't tag \(playlist.displayTitle) as a channel: \(error)")
                #endif
            }
        }
        if allWritten {
            defaults.set(true, forKey: doneKey)
            #if DEBUG
            print("DEBUG channels: moved \(ids.count) channels to playlist tags")
            #endif
        }
    }
}
