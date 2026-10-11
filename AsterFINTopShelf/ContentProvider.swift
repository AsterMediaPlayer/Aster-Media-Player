//
//  ContentProvider.swift
//  AsterFINTopShelf
//
//  Fills the Apple TV home screen's top shelf with Continue Watching, Next
//  Up and recently played Live TV channels from the signed-in Jellyfin
//  server. Runs under tight memory and time limits, so it makes at most
//  three small requests, side by side, and decodes only what it shows.
//

import TVServices

final class ContentProvider: TVTopShelfContentProvider {

    nonisolated override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let session = TopShelfSession.load() else { return nil }
        let api = TopShelfAPI(session: session)

        async let resume = api.items("/UserItems/Resume", query: [
            "limit": "10",
            "mediaTypes": "Video",
            "enableImageTypes": "Primary",
            "imageTypeLimit": "1",
        ])
        async let nextUp = api.items("/Shows/NextUp", query: [
            "limit": "10",
            "enableResumable": "false",
            "enableImageTypes": "Primary",
            "imageTypeLimit": "1",
        ])
        // Channels the app last played, newest first (see RecentChannels in the app).
        let recentIds = UserDefaults(suiteName: "group.app.asterfin")?.stringArray(forKey: "AsterFIN.recentChannels") ?? []
        async let channels = recentIds.isEmpty ? [] : api.items("/Items", query: [
            "ids": recentIds.joined(separator: ","),
            "enableImageTypes": "Primary",
            "imageTypeLimit": "1",
        ])
        let continueWatching = (try? await resume) ?? []
        let upNext = (try? await nextUp) ?? []
        let channelItems = (try? await channels) ?? []
        // The server doesn't keep the order of `ids`.
        let recentChannels = recentIds.compactMap { id in channelItems.first { $0.id == id } }

        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        if !continueWatching.isEmpty {
            let collection = TVTopShelfItemCollection(items: continueWatching.map { api.shelfItem(for: $0) })
            collection.title = "Continue Watching"
            sections.append(collection)
        }
        if !upNext.isEmpty {
            let collection = TVTopShelfItemCollection(items: upNext.map { api.shelfItem(for: $0) })
            collection.title = "Next Up"
            sections.append(collection)
        }
        if !recentChannels.isEmpty {
            let collection = TVTopShelfItemCollection(items: recentChannels.map { api.shelfItem(for: $0) })
            collection.title = "Recent Channels"
            sections.append(collection)
        }
        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }
}
