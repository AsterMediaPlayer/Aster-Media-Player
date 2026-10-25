//
//  ItemQuery.swift
//  AsterFIN
//
//  A request for titles in the app's own terms, which each server turns
//  into its own query: Jellyfin and Emby into `/Items` parameters (below),
//  Plex into a library section's filters. Views ask with this rather than
//  with one server's parameter names.
//

import Foundation

/// The order titles come in.
nonisolated enum ItemSort: Sendable, Hashable {
    case name, dateAdded, releaseDate, rating
}

nonisolated enum ItemFilter: Sendable, Hashable {
    case favorite
}

nonisolated struct ItemQuery: Sendable, Hashable {
    /// Within one library, collection or folder; nil for every library.
    var parentId: String?
    /// Only these kinds; empty for any.
    var kinds: [ItemKind] = []
    /// Through sub-folders too (a library's shows, not its folders). Nil
    /// leaves it to the server.
    var recursive: Bool?
    var sort: ItemSort?
    /// Nil leaves the order to the server.
    var descending: Bool?
    var filters: Set<ItemFilter> = []
    /// Titles this person is in.
    var personId: String?
    /// Exactly these titles.
    var ids: [String] = []
    var startIndex: Int?
    var limit: Int?
}

extension ItemQuery {
    /// The query as Jellyfin's (and Emby's) `/Items` parameters.
    var jellyfinParameters: [String: String?] {
        var query: [String: String?] = [:]
        if let parentId { query["parentId"] = parentId }
        if !kinds.isEmpty { query["includeItemTypes"] = kinds.map(\.rawValue).joined(separator: ",") }
        if let recursive { query["recursive"] = recursive ? "true" : "false" }
        if let sort {
            query["sortBy"] = switch sort {
            case .name: "SortName"
            case .dateAdded: "DateCreated,SortName"
            case .releaseDate: "PremiereDate,SortName"
            case .rating: "CommunityRating,SortName"
            }
        }
        if let descending { query["sortOrder"] = descending ? "Descending" : "Ascending" }
        if filters.contains(.favorite) { query["filters"] = "IsFavorite" }
        if let personId { query["personIds"] = personId }
        if !ids.isEmpty { query["ids"] = ids.joined(separator: ",") }
        if let startIndex { query["startIndex"] = String(startIndex) }
        if let limit { query["limit"] = String(limit) }
        return query
    }

    /// The same query, one page of it.
    func page(from start: Int, size: Int) -> ItemQuery {
        var paged = self
        paged.startIndex = start
        paged.limit = size
        return paged
    }
}
