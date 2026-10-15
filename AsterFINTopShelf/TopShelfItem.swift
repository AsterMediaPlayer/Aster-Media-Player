//
//  TopShelfItem.swift
//  AsterFINTopShelf
//
//  Just enough of a Jellyfin item to draw a top shelf entry, and the small
//  client that fetches them. Entries are posters; episodes show their series art.
//

import Foundation
import os
import TVServices

nonisolated struct TopShelfItem: Decodable, Sendable {
    struct UserData: Decodable, Sendable {
        var playedPercentage: Double?

        enum CodingKeys: String, CodingKey {
            case playedPercentage = "PlayedPercentage"
        }
    }

    var id: String
    var name: String?
    var type: String?
    var seriesId: String?
    var seriesName: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var imageTags: [String: String]?
    var seriesPrimaryImageTag: String?
    var parentPrimaryImageItemId: String?
    var parentPrimaryImageTag: String?
    var userData: UserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case imageTags = "ImageTags"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case parentPrimaryImageItemId = "ParentPrimaryImageItemId"
        case parentPrimaryImageTag = "ParentPrimaryImageTag"
        case userData = "UserData"
    }

    /// "Series — S1, E4" for episodes, else the title.
    var title: String {
        let fallback = name ?? "Untitled"
        guard type == "Episode" else { return fallback }
        let code = indexNumber.map { episode in
            parentIndexNumber.map { "S\($0), E\(episode)" } ?? "Episode \(episode)"
        }
        let label = [seriesName, code].compactMap { $0 }.joined(separator: " — ")
        return label.isEmpty ? fallback : label
    }

    /// Where the poster lives: item id, image type and tag. Episodes use the
    /// show's cover art rather than their own still, falling back to the
    /// season poster, then the episode's own image.
    var posterImage: (itemId: String, kind: String, tag: String)? {
        if type == "Episode" {
            if let series = seriesId, let tag = seriesPrimaryImageTag { return (series, "Primary", tag) }
            if let parent = parentPrimaryImageItemId, let tag = parentPrimaryImageTag { return (parent, "Primary", tag) }
        }
        if let tag = imageTags?["Primary"] { return (id, "Primary", tag) }
        return nil
    }
}

nonisolated struct TopShelfItemsResult: Decodable, Sendable {
    var items: [TopShelfItem]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

/// A tiny Jellyfin client for the extension: one header, one decoder.
nonisolated struct TopShelfAPI: Sendable {
    let session: TopShelfSession

    private var authorization: String {
        "MediaBrowser Client=\"AsterFIN\", Device=\"Apple TV\", DeviceId=\"\(session.deviceId)\", Version=\"1.0\", Token=\"\(session.accessToken)\""
    }

    func items(_ path: String, query: [String: String]) async throws -> [TopShelfItem] {
        var merged = query
        merged["userId"] = session.userId
        var request = URLRequest(url: url(path, query: merged))
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            shelfLog.error("\(path, privacy: .public): HTTP \(status)")
            throw URLError(.badServerResponse)
        }
        do {
            return try JSONDecoder().decode(TopShelfItemsResult.self, from: data).items
        } catch {
            shelfLog.error("\(path, privacy: .public): couldn't decode: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func shelfItem(for item: TopShelfItem) -> TVTopShelfSectionedItem {
        let shelf = TVTopShelfSectionedItem(identifier: item.id)
        shelf.title = item.title
        // Channel logos are square-ish; titles use posters.
        let isChannel = item.type == "TvChannel"
        shelf.imageShape = isChannel ? .square : .poster
        if let picture = item.posterImage {
            shelf.setImageURL(imageURL(picture, width: 400), for: .screenScale1x)
            shelf.setImageURL(imageURL(picture, width: 800), for: .screenScale2x)
        }
        if let percent = item.userData?.playedPercentage, percent > 0 {
            shelf.playbackProgress = min(max(percent / 100, 0), 1)
        }
        if let play = URL(string: "asterfin://play/\(item.id)") {
            shelf.playAction = TVTopShelfAction(url: play)
        }
        // A channel has no page of its own, so selecting it tunes in too.
        if let open = URL(string: isChannel ? "asterfin://play/\(item.id)" : "asterfin://item/\(item.id)") {
            shelf.displayAction = TVTopShelfAction(url: open)
        }
        return shelf
    }

    /// Images are fetched by the system without headers, so the token rides
    /// along as a query parameter.
    private func imageURL(_ picture: (itemId: String, kind: String, tag: String), width: Int) -> URL {
        let path = "/Items/\(picture.itemId)/Images/\(picture.kind)"
        return url(path, query: ["tag": picture.tag, "maxWidth": String(width), "ApiKey": session.accessToken, "api_key": session.accessToken])
    }

    private func url(_ path: String, query: [String: String]) -> URL {
        var components = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        return components.url ?? session.serverURL
    }
}
