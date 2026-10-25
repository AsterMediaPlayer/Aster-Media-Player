//
//  PlexModels.swift
//  AsterFIN
//
//  Plex Media Server's JSON (asked for with `Accept: application/json`):
//  everything comes wrapped in a `MediaContainer`, with titles as
//  `Metadata`, libraries as `Directory` and Home rows and search results
//  as `Hub`s. Only what the app reads is here; Plex adds fields freely.
//

import Foundation

nonisolated struct PlexReply: Decodable, Sendable {
    var mediaContainer: PlexContainer

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

nonisolated struct PlexContainer: Decodable, Sendable {
    var size: Int?
    var totalSize: Int?
    var offset: Int?
    var metadata: [PlexMetadata]?
    var directory: [PlexDirectory]?
    var hub: [PlexHub]?

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset
        case metadata = "Metadata"
        case directory = "Directory"
        case hub = "Hub"
    }
}

/// A library section.
nonisolated struct PlexDirectory: Decodable, Sendable {
    var key: String
    var title: String
    /// movie, show, artist, photo
    var type: String
    var agent: String?
}

/// A row of titles: Continue Watching, or search results of one kind.
nonisolated struct PlexHub: Decodable, Sendable {
    var type: String?
    var hubIdentifier: String?
    var size: Int?
    var metadata: [PlexMetadata]?

    enum CodingKeys: String, CodingKey {
        case type, hubIdentifier, size
        case metadata = "Metadata"
    }
}

/// A tag on a title: a genre, or a person and their role.
nonisolated struct PlexTag: Decodable, Sendable {
    var id: Int?
    var tag: String
    var role: String?
    var thumb: String?
}

nonisolated struct PlexGuid: Decodable, Sendable {
    var id: String
}

nonisolated struct PlexImage: Decodable, Sendable {
    /// coverPoster, background, snapshot, clearLogo
    var type: String
    var url: String
}

nonisolated struct PlexChapter: Decodable, Sendable {
    var tag: String?
    var startTimeOffset: Int
    var endTimeOffset: Int?
}

/// Plex Pass's detected intro and credits.
nonisolated struct PlexMarker: Decodable, Sendable {
    /// intro, credits
    var type: String
    var startTimeOffset: Int
    var endTimeOffset: Int
}

nonisolated struct PlexStream: Decodable, Sendable {
    var id: Int
    /// 1 video, 2 audio, 3 subtitles
    var streamType: Int
    var index: Int?
    var codec: String?
    var languageCode: String?
    var language: String?
    var displayTitle: String?
    var title: String?
    var `default`: Bool?
    var forced: Bool?
    /// Set for a subtitle file beside the video, which can be fetched.
    var key: String?
    var width: Int?
    var height: Int?
    var channels: Int?
}

nonisolated struct PlexPart: Decodable, Sendable {
    var id: Int
    var key: String?
    var duration: Int?
    var container: String?
    var size: Int?
    var stream: [PlexStream]?

    enum CodingKeys: String, CodingKey {
        case id, key, duration, container, size
        case stream = "Stream"
    }
}

nonisolated struct PlexMedia: Decodable, Sendable {
    var id: Int
    var duration: Int?
    var bitrate: Int?
    var width: Int?
    var height: Int?
    var container: String?
    var videoCodec: String?
    var audioCodec: String?
    var videoResolution: String?
    var part: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, width, height, container, videoCodec, audioCodec, videoResolution
        case part = "Part"
    }
}

/// A title: a movie, show, season, episode, collection or extra.
nonisolated struct PlexMetadata: Decodable, Sendable {
    var ratingKey: String
    var key: String?
    /// movie, show, season, episode, collection, clip
    var type: String?
    var subtype: String?
    var title: String?
    var titleSort: String?
    var originalTitle: String?
    var summary: String?
    var tagline: String?
    var year: Int?
    /// Milliseconds.
    var duration: Int?
    /// Where it was left, in milliseconds.
    var viewOffset: Int?
    var viewCount: Int?
    var lastViewedAt: Int?
    /// A show's or season's episodes, and how many have been watched.
    var leafCount: Int?
    var viewedLeafCount: Int?
    var childCount: Int?
    var index: Int?
    var parentIndex: Int?
    var thumb: String?
    var art: String?
    var parentThumb: String?
    var grandparentThumb: String?
    var grandparentArt: String?
    var parentRatingKey: String?
    var grandparentRatingKey: String?
    var parentTitle: String?
    var grandparentTitle: String?
    var contentRating: String?
    var audienceRating: Double?
    var rating: Double?
    var studio: String?
    /// "2025-07-06"
    var originallyAvailableAt: String?
    /// Seconds since 1970.
    var addedAt: Int?
    var guid: String?
    var librarySectionID: Int?
    var genre: [PlexTag]?
    var role: [PlexTag]?
    var director: [PlexTag]?
    var writer: [PlexTag]?
    var guids: [PlexGuid]?
    var image: [PlexImage]?
    var chapter: [PlexChapter]?
    var marker: [PlexMarker]?
    var media: [PlexMedia]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, subtype, title, titleSort, originalTitle, summary, tagline, year, duration
        case viewOffset, viewCount, lastViewedAt, leafCount, viewedLeafCount, childCount, index, parentIndex
        case thumb, art, parentThumb, grandparentThumb, grandparentArt, parentRatingKey, grandparentRatingKey
        case parentTitle, grandparentTitle, contentRating, audienceRating, rating, studio, originallyAvailableAt, addedAt, guid, librarySectionID
        case genre = "Genre"
        case role = "Role"
        case director = "Director"
        case writer = "Writer"
        case guids = "Guid"
        case image = "Image"
        case chapter = "Chapter"
        case marker = "Marker"
        case media = "Media"
    }
}
