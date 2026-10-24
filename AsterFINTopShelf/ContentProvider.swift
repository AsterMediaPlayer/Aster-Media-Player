//
//  ContentProvider.swift
//  AsterFINTopShelf
//
//  Fills the Apple TV home screen's top shelf with Continue Watching, Next
//  Up and recently played Live TV channels from the signed-in Jellyfin
//  server. Runs under tight memory and time limits, so it makes at most
//  three small requests, side by side, and decodes only what it shows.
//

import os
import TVServices

/// What the shelf found, in the system log (Console, or `log show` with
/// subsystem app.asterfin.topshelf), as the extension can't be watched otherwise.
nonisolated let shelfLog = Logger(subsystem: "app.asterfin.topshelf", category: "content")

final class ContentProvider: TVTopShelfContentProvider {

    nonisolated override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let session = TopShelfSession.load() else {
            shelfLog.error("No signed-in session in the shared Keychain item")
            return nil
        }
        shelfLog.notice("Loading for \(session.serverURL.absoluteString, privacy: .public)")
        let api = TopShelfAPI(session: session)

        async let resume = Self.logged("Resume") { try await api.items(session.resumePath, query: [
            "limit": "10",
            "mediaTypes": "Video",
            "enableImageTypes": "Primary",
            "imageTypeLimit": "1",
        ]) }
        async let nextUp = Self.logged("NextUp") { try await api.items("/Shows/NextUp", query: [
            "limit": "10",
            "enableResumable": "false",
            "enableImageTypes": "Primary",
            "imageTypeLimit": "1",
        ]) }
        // Channels the app last played, newest first (see RecentChannels in the app).
        let recentIds = UserDefaults(suiteName: "group.app.asterfin")?.stringArray(forKey: "AsterFIN.recentChannels") ?? []
        async let channels = recentIds.isEmpty ? [] : Self.logged("Channels") { try await api.items("/Items", query: [
            "ids": recentIds.joined(separator: ","),
            "enableImageTypes": "Primary",
            "imageTypeLimit": "1",
        ]) }
        let continueWatching = await resume
        let upNext = await nextUp
        let channelItems = await channels
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
        guard !sections.isEmpty else {
            shelfLog.notice("Nothing to show")
            return nil
        }
        return TVTopShelfSectionedContent(sections: sections)
    }

    /// A request's items, its count or failure noted in the log.
    nonisolated private static func logged(_ name: String, _ fetch: () async throws -> [TopShelfItem]) async -> [TopShelfItem] {
        do {
            let items = try await fetch()
            shelfLog.notice("\(name, privacy: .public): \(items.count) items")
            return items
        } catch {
            shelfLog.error("\(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
