//
//  WidgetAPI.swift
//  AsterFINWidgets
//
//  Just enough of Jellyfin for the widgets: Continue Watching and Next Up,
//  with small artwork fetched up front, as a widget can't load images later.
//

import Foundation

nonisolated struct WidgetTitle: Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var progress: Double?
    var image: Data?
}

nonisolated struct WidgetAPI: Sendable {
    let session: WidgetSession

    private struct Item: Decodable, Sendable {
        struct UserData: Decodable, Sendable {
            var playedPercentage: Double?
            enum CodingKeys: String, CodingKey { case playedPercentage = "PlayedPercentage" }
        }
        var id: String
        var name: String?
        var type: String?
        var seriesId: String?
        var seriesName: String?
        var indexNumber: Int?
        var parentIndexNumber: Int?
        var imageTags: [String: String]?
        var parentBackdropItemId: String?
        var parentBackdropImageTags: [String]?
        var backdropImageTags: [String]?
        var userData: UserData?
        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", type = "Type", seriesId = "SeriesId", seriesName = "SeriesName"
            case indexNumber = "IndexNumber", parentIndexNumber = "ParentIndexNumber", imageTags = "ImageTags"
            case parentBackdropItemId = "ParentBackdropItemId", parentBackdropImageTags = "ParentBackdropImageTags"
            case backdropImageTags = "BackdropImageTags", userData = "UserData"
        }
    }
    private struct Result: Decodable, Sendable {
        var items: [Item]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    /// Continue Watching, then Next Up, without repeats.
    func continueWatching(limit: Int) async -> [WidgetTitle] {
        async let resume = items("/UserItems/Resume", ["limit": "\(limit)", "mediaTypes": "Video", "fields": "ParentId"])
        async let nextUp = items("/Shows/NextUp", ["limit": "\(limit)", "enableResumable": "false"])
        var seen = Set<String>()
        let found = ((try? await resume) ?? []) + ((try? await nextUp) ?? [])
        let unique = found.filter { seen.insert($0.id).inserted }.prefix(limit)
        return await withTaskGroup(of: (Int, WidgetTitle).self) { group in
            for (index, item) in unique.enumerated() {
                group.addTask { (index, await self.title(for: item)) }
            }
            var titles: [(Int, WidgetTitle)] = []
            for await titled in group { titles.append(titled) }
            return titles.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func title(for item: Item) async -> WidgetTitle {
        let isEpisode = item.type == "Episode"
        let code = isEpisode ? item.indexNumber.map { e in item.parentIndexNumber.map { "S\($0), E\(e)" } ?? "E\(e)" } : nil
        let percent = item.userData?.playedPercentage.map { $0 / 100 }
        return WidgetTitle(
            id: item.id,
            title: isEpisode ? (item.seriesName ?? item.name ?? "") : (item.name ?? ""),
            subtitle: isEpisode ? [code, item.name].compactMap { $0 }.joined(separator: " · ") : nil,
            progress: percent.flatMap { $0 > 0 ? min($0, 1) : nil },
            image: await image(for: item)
        )
    }

    /// A landscape picture, small: widgets have a tight memory limit.
    private func image(for item: Item) async -> Data? {
        let picture: (String, String, String)?
        if let tag = item.backdropImageTags?.first {
            picture = (item.id, "Backdrop", tag)
        } else if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            picture = (parent, "Backdrop", tag)
        } else if let tag = item.imageTags?["Primary"] {
            picture = (item.id, "Primary", tag)
        } else {
            picture = nil
        }
        guard let (id, kind, tag) = picture else { return nil }
        let url = url("/Items/\(id)/Images/\(kind)", ["tag": tag, "maxWidth": "480", "quality": "70", "api_key": session.accessToken])
        return try? await URLSession(configuration: .ephemeral).data(from: url).0
    }

    private func items(_ path: String, _ query: [String: String]) async throws -> [Item] {
        var merged = query
        merged["userId"] = session.userId
        merged["enableImageTypes"] = "Primary,Backdrop"
        merged["imageTypeLimit"] = "1"
        var request = URLRequest(url: url(path, merged))
        request.setValue("MediaBrowser Client=\"Aster\", Device=\"iPhone\", DeviceId=\"\(session.deviceId)\", Version=\"1.0\", Token=\"\(session.accessToken)\"", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Result.self, from: data).items
    }

    private func url(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(url: session.serverURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
        return components.url ?? session.serverURL
    }
}
