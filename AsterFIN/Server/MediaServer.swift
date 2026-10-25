//
//  MediaServer.swift
//  AsterFIN
//
//  What the app's browsing screens need from a server, whichever it is:
//  libraries, titles, the Home rows, a show's seasons and episodes, search,
//  watched and favourite, and pictures. Jellyfin and Emby answer through
//  `JellyfinClient`; Plex through its own client, which turns Plex's
//  answers into the same `BaseItem`s. What only Jellyfin has (music,
//  Live TV, channels, the plugins) is asked of `JellyfinClient` itself.
//

import Foundation

nonisolated protocol MediaServer: AnyObject, Sendable {
    var kind: ServerKind { get }
    var capabilities: ServerCapabilities { get }
    var baseURL: URL { get }
    var userId: String? { get }

    /// A picture's bytes; `fresh` skips any cached copy.
    func data(from url: URL, fresh: Bool) async throws -> Data
    /// The address of one of a title's pictures. `ref.tag` is whatever the
    /// server put in the item for it: Jellyfin's image tag, Plex's path.
    func imageURL(_ ref: ImageRef) -> URL

    func libraries() async throws -> [BaseItem]
    func item(_ id: String) async throws -> BaseItem
    func items(_ query: ItemQuery) async throws -> ItemsResult
    func latest(parentId: String?, limit: Int, kinds: [ItemKind]) async throws -> [BaseItem]
    func resume(limit: Int, parentId: String?) async throws -> [BaseItem]
    func nextUp(limit: Int, seriesId: String?, parentId: String?) async throws -> [BaseItem]
    func seasons(seriesId: String) async throws -> [BaseItem]
    func episodes(seriesId: String, seasonId: String?) async throws -> [BaseItem]
    func similar(to id: String, limit: Int) async throws -> [BaseItem]
    func specialFeatures(of id: String) async throws -> [BaseItem]
    func search(_ term: String, limit: Int) async throws -> [BaseItem]
    func setFavorite(_ id: String, _ favorite: Bool) async throws
    func setPlayed(_ id: String, _ played: Bool) async throws
}

/// One picture of a title, for `MediaServer.imageURL`.
nonisolated struct ImageRef: Sendable, Hashable {
    var itemId: String
    var kind: ImageKind
    var tag: String?
    var index: Int?
    var maxWidth: Int?
    var maxHeight: Int?
    /// JPEG/WebP quality, 0 to 100.
    var quality: Int = 90
}

/// What a server can do beyond browsing and playing, so the app shows only
/// what works there.
nonisolated struct ServerCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int

    static let quickConnect = ServerCapabilities(rawValue: 1 << 0)
    /// Aster's Jellyfin plugins: channels' groups, disc menus, OP/ED.
    static let plugins = ServerCapabilities(rawValue: 1 << 1)
    static let liveTV = ServerCapabilities(rawValue: 1 << 2)
    static let music = ServerCapabilities(rawValue: 1 << 3)
    static let audiobooks = ServerCapabilities(rawValue: 1 << 4)
    /// Channels made from tagged playlists.
    static let channels = ServerCapabilities(rawValue: 1 << 5)
    static let downloads = ServerCapabilities(rawValue: 1 << 6)
    static let upcoming = ServerCapabilities(rawValue: 1 << 7)
    static let playlists = ServerCapabilities(rawValue: 1 << 8)
    static let favorites = ServerCapabilities(rawValue: 1 << 9)
    static let trickplay = ServerCapabilities(rawValue: 1 << 10)
    /// Settings kept on the server, to follow the user between devices.
    static let settingsSync = ServerCapabilities(rawValue: 1 << 11)
    static let lyrics = ServerCapabilities(rawValue: 1 << 12)
}

// MARK: - Pictures

extension MediaServer {
    func imageURL(itemId: String, kind: ImageKind, tag: String? = nil, index: Int? = nil,
                  maxWidth: Int? = nil, maxHeight: Int? = nil, quality: Int = 90) -> URL {
        imageURL(ImageRef(itemId: itemId, kind: kind, tag: tag, index: index, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality))
    }

    /// Best landscape picture for a lockup: the item's own backdrop or thumb,
    /// then its parent's, then the primary image for episodes.
    func landscapeURL(for item: BaseItem, width: Int = 800) -> URL? {
        if item.kind == .episode, let tag = item.imageTags?["Primary"] {
            return imageURL(itemId: item.id, kind: .primary, tag: tag, maxWidth: width)
        }
        if let tag = item.imageTags?["Thumb"] {
            return imageURL(itemId: item.id, kind: .thumb, tag: tag, maxWidth: width)
        }
        if let tag = item.backdropImageTags?.first {
            return imageURL(itemId: item.id, kind: .backdrop, tag: tag, index: 0, maxWidth: width)
        }
        if let parent = item.parentThumbItemId, let tag = item.parentThumbImageTag {
            return imageURL(itemId: parent, kind: .thumb, tag: tag, maxWidth: width)
        }
        if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: parent, kind: .backdrop, tag: tag, index: 0, maxWidth: width)
        }
        if let series = item.seriesId, let tag = item.seriesThumbImageTag {
            return imageURL(itemId: series, kind: .thumb, tag: tag, maxWidth: width)
        }
        if let tag = item.imageTags?["Primary"] {
            return imageURL(itemId: item.id, kind: .primary, tag: tag, maxWidth: width)
        }
        return nil
    }

    func posterURL(for item: BaseItem, width: Int = 500, quality: Int = 90) -> URL? {
        if let tag = item.imageTags?["Primary"] {
            return imageURL(itemId: item.id, kind: .primary, tag: tag, maxWidth: width, quality: quality)
        }
        if let album = item.albumId, let tag = item.albumPrimaryImageTag {
            return imageURL(itemId: album, kind: .primary, tag: tag, maxWidth: width, quality: quality)
        }
        if let series = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(itemId: series, kind: .primary, tag: tag, maxWidth: width, quality: quality)
        }
        if let parent = item.parentPrimaryImageItemId, let tag = item.parentPrimaryImageTag {
            return imageURL(itemId: parent, kind: .primary, tag: tag, maxWidth: width, quality: quality)
        }
        return nil
    }

    func backdropURL(for item: BaseItem, width: Int = 1920) -> URL? {
        if let tag = item.backdropImageTags?.first {
            return imageURL(itemId: item.id, kind: .backdrop, tag: tag, index: 0, maxWidth: width)
        }
        if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: parent, kind: .backdrop, tag: tag, index: 0, maxWidth: width)
        }
        return landscapeURL(for: item, width: width)
    }

    func logoURL(for item: BaseItem, width: Int = 800) -> URL? {
        if let tag = item.imageTags?["Logo"] {
            return imageURL(itemId: item.id, kind: .logo, tag: tag, maxWidth: width)
        }
        if let parent = item.parentLogoItemId, let tag = item.parentLogoImageTag {
            return imageURL(itemId: parent, kind: .logo, tag: tag, maxWidth: width)
        }
        return nil
    }

    func personImageURL(_ person: PersonInfo, width: Int = 300) -> URL? {
        guard let tag = person.primaryImageTag else { return nil }
        return imageURL(itemId: person.id, kind: .primary, tag: tag, maxWidth: width)
    }
}
