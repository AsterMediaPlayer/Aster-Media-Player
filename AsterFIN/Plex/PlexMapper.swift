//
//  PlexMapper.swift
//  AsterFIN
//
//  Plex's titles as the app's `BaseItem`s, so the screens built for
//  Jellyfin show them unchanged. Picture fields hold Plex's own paths
//  (a title's `thumb` and `art`), which `PlexClient.imageURL` sends through
//  the server's photo transcoder; times go from milliseconds to the app's
//  ticks (100 ns).
//

import Foundation

nonisolated enum PlexMapper {
    static let ticksPerMillisecond: Int64 = 10_000

    /// A library section as a library.
    static func library(_ directory: PlexDirectory) -> BaseItem {
        var item = BaseItem(id: directory.key)
        item.name = directory.title
        item.type = ItemKind.collectionFolder.rawValue
        item.collectionType = switch directory.type {
        case "movie": "movies"
        case "show": "tvshows"
        case "artist": "music"
        case "photo": "photos"
        default: directory.type ?? ""
        }
        return item
    }

    static func kind(_ type: String?) -> ItemKind {
        switch type {
        case "movie": .movie
        case "show": .series
        case "season": .season
        case "episode": .episode
        case "collection": .boxSet
        case "clip": .video
        default: .other
        }
    }

    static func item(_ metadata: PlexMetadata) -> BaseItem {
        let kind = kind(metadata.type)
        var item = BaseItem(id: metadata.ratingKey)
        item.type = kind.rawValue
        item.name = metadata.title
        item.originalTitle = metadata.originalTitle
        item.sortName = metadata.titleSort
        item.overview = metadata.summary
        item.taglines = metadata.tagline.map { [$0] }
        item.productionYear = metadata.year
        item.premiereDate = metadata.originallyAvailableAt.map { $0 + "T00:00:00Z" }
        item.dateCreated = metadata.addedAt.map { isoDate(TimeInterval($0)) }
        item.officialRating = metadata.contentRating
        item.communityRating = metadata.audienceRating ?? metadata.rating
        item.scores = scores(metadata.ratings)
        item.runTimeTicks = metadata.duration.map { Int64($0) * ticksPerMillisecond }
        item.indexNumber = metadata.index
        item.genres = metadata.genre?.map(\.tag)
        item.studios = metadata.studio.map { [NameGuidPair(name: $0)] }
        item.people = people(metadata)
        item.providerIds = providerIds(metadata)
        item.chapters = metadata.chapter?.map { chapter in
            ChapterInfo(startPositionTicks: Int64(chapter.startTimeOffset) * ticksPerMillisecond, name: chapter.tag, imageTag: chapter.thumb)
        }
        item.mediaStreams = metadata.media?.first?.part?.first?.stream?.map(stream)
        item.container = metadata.media?.first?.container
        item.isFolder = kind == .series || kind == .season || kind == .boxSet

        // Pictures: the poster, the backdrop and the logo; a season's and an
        // episode's fall back to their show's.
        var tags: [String: String] = [:]
        if let thumb = metadata.thumb { tags["Primary"] = thumb }
        if let logo = metadata.image?.first(where: { $0.type == "clearLogo" })?.url, kind != .episode, kind != .season {
            tags["Logo"] = logo
        }
        item.imageTags = tags.isEmpty ? nil : tags
        if let art = metadata.art, kind != .episode {
            item.backdropImageTags = [art]
        }

        switch kind {
        case .episode:
            item.seriesId = metadata.grandparentRatingKey
            item.seriesName = metadata.grandparentTitle
            item.seasonId = metadata.parentRatingKey
            item.seasonName = metadata.parentTitle
            item.parentId = metadata.parentRatingKey
            item.parentIndexNumber = metadata.parentIndex
            item.seriesPrimaryImageTag = metadata.grandparentThumb
            if let showArt = metadata.grandparentArt ?? metadata.art {
                item.parentBackdropItemId = metadata.grandparentRatingKey
                item.parentBackdropImageTags = [showArt]
            }
            if let logo = metadata.image?.first(where: { $0.type == "clearLogo" })?.url {
                item.parentLogoItemId = metadata.grandparentRatingKey
                item.parentLogoImageTag = logo
            }
        case .season:
            item.seriesId = metadata.parentRatingKey
            item.seriesName = metadata.parentTitle
            item.parentId = metadata.parentRatingKey
            item.seriesPrimaryImageTag = metadata.parentThumb
            if let art = metadata.art {
                item.parentBackdropItemId = metadata.parentRatingKey
                item.parentBackdropImageTags = [art]
            }
            item.childCount = metadata.leafCount
        case .series:
            item.childCount = metadata.childCount
            item.recursiveItemCount = metadata.leafCount
        default:
            break
        }

        item.userData = userData(metadata, kind: kind)
        return item
    }

    /// Where it was left, and whether it's been watched: a show or season
    /// by its episodes.
    static func userData(_ metadata: PlexMetadata, kind: ItemKind) -> UserItemData {
        var data = UserItemData()
        if let leaves = metadata.leafCount, kind == .series || kind == .season {
            let watched = metadata.viewedLeafCount ?? 0
            data.unplayedItemCount = max(0, leaves - watched)
            data.played = leaves > 0 && watched >= leaves
        } else {
            data.played = (metadata.viewCount ?? 0) > 0
            data.playCount = metadata.viewCount
        }
        if let offset = metadata.viewOffset, offset > 0 {
            data.playbackPositionTicks = Int64(offset) * ticksPerMillisecond
            if let duration = metadata.duration, duration > 0 {
                data.playedPercentage = Double(offset) / Double(duration) * 100
            }
        }
        data.lastPlayedDate = metadata.lastViewedAt.map { isoDate(TimeInterval($0)) }
        return data
    }

    /// The cast first, then who directed and wrote it.
    private static func people(_ metadata: PlexMetadata) -> [PersonInfo]? {
        func person(_ tag: PlexTag, type: String) -> PersonInfo {
            PersonInfo(id: tag.id.map(String.init) ?? tag.tag, name: tag.tag, role: tag.role, type: type, primaryImageTag: tag.thumb)
        }
        let all = (metadata.role ?? []).map { person($0, type: "Actor") }
            + (metadata.director ?? []).map { person($0, type: "Director") }
            + (metadata.writer ?? []).map { person($0, type: "Writer") }
        return all.isEmpty ? nil : all
    }

    /// The scores a title page carries, attributed by their pictures' names;
    /// nil when there are none (lists), leaving the plain rating.
    static func scores(_ ratings: [PlexRating]?) -> [TitleScore]? {
        guard let ratings, !ratings.isEmpty else { return nil }
        var found: [TitleScore.Source: TitleScore] = [:]
        for rating in ratings {
            let image = (rating.image ?? "").lowercased()
            let critic = rating.type?.lowercased() == "critic"
            let source: TitleScore.Source? = if image.hasPrefix("imdb://") {
                .imdb
            } else if image.hasPrefix("rottentomatoes://") {
                critic ? .tomatometer : .popcorn
            } else if image.hasPrefix("themoviedb://") || image.hasPrefix("tmdb://") {
                .tmdb
            } else {
                nil
            }
            // Plex writes every score out of ten.
            guard let source, found[source] == nil, let score = TitleScore(source, rating.value, outOf: 10) else { continue }
            found[source] = score
        }
        return found.isEmpty ? nil : TitleScore.ordered(Array(found.values))
    }

    /// "tmdb://5439847" as Tmdb, and so on, the anime sites as Jellyfin
    /// names them; Shoko's own id marks anime, and so does the AniDB entry
    /// the HAMA agent writes into the guid itself
    /// ("com.plexapp.agents.hama://anidb-1234?lang=en").
    private static func providerIds(_ metadata: PlexMetadata) -> [String: String]? {
        var ids: [String: String] = [:]
        for guid in metadata.guids ?? [] {
            let parts = guid.id.components(separatedBy: "://")
            guard parts.count == 2 else { continue }
            let name = switch parts[0] {
            case "tmdb": "Tmdb"
            case "imdb": "Imdb"
            case "tvdb": "Tvdb"
            case "anidb": "AniDB"
            case "anilist": "AniList"
            case "myanimelist": "MyAnimeList"
            default: parts[0].capitalized
            }
            ids[name] = parts[1]
        }
        if let guid = metadata.guid {
            if guid.contains(".shoko://") {
                ids["Shoko"] = guid.components(separatedBy: "/").last
            }
            if ids["AniDB"] == nil, let match = guid.firstMatch(of: /anidb\d?-(\d+)/) {
                ids["AniDB"] = String(match.1)
            }
        }
        return ids.isEmpty ? nil : ids
    }

    private static func stream(_ stream: PlexStream) -> MediaStream {
        var mapped = MediaStream()
        mapped.type = switch stream.streamType {
        case 1: "Video"
        case 2: "Audio"
        case 3: "Subtitle"
        default: nil
        }
        mapped.index = stream.index
        mapped.codec = stream.codec
        mapped.language = stream.languageCode
        mapped.displayTitle = stream.displayTitle
        mapped.title = stream.title
        mapped.isDefault = stream.default
        mapped.isForced = stream.forced
        mapped.isExternal = stream.key != nil
        mapped.width = stream.width
        mapped.height = stream.height
        mapped.channels = stream.channels
        return mapped
    }

    private static func isoDate(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }
}
