//
//  JellyfinModels.swift
//  AsterFIN
//
//  Codable views of the Jellyfin REST API. Property names on the wire are
//  PascalCase; GUIDs arrive as 32 hex digits without hyphens.
//

import Foundation
import Synchronization

// MARK: - Server and users

nonisolated struct PublicSystemInfo: Codable, Sendable, Equatable {
    var serverName: String?
    var version: String?
    var id: String?
    var localAddress: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
        case localAddress = "LocalAddress"
    }
}

nonisolated struct JellyfinUser: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var primaryImageTag: String?
    var hasPassword: Bool?
    var hasConfiguredPassword: Bool?
    var configuration: UserConfiguration?
    var policy: UserPolicy?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case primaryImageTag = "PrimaryImageTag"
        case hasPassword = "HasPassword"
        case hasConfiguredPassword = "HasConfiguredPassword"
        case configuration = "Configuration"
        case policy = "Policy"
    }
}

/// What the server's administrator allows this user. Only what the app uses.
nonisolated struct UserPolicy: Codable, Sendable, Hashable {
    /// "Allow media downloading" in the user's settings on the server.
    var enableContentDownloading: Bool?
    /// An administrator can edit any item's metadata, a playlist's tags included.
    var isAdministrator: Bool?

    enum CodingKeys: String, CodingKey {
        case enableContentDownloading = "EnableContentDownloading"
        case isAdministrator = "IsAdministrator"
    }
}

nonisolated struct AuthenticationResult: Codable, Sendable {
    var user: JellyfinUser
    var accessToken: String
    var serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

nonisolated struct QuickConnectResult: Codable, Sendable, Equatable {
    var authenticated: Bool
    var secret: String
    var code: String

    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated"
        case secret = "Secret"
        case code = "Code"
    }
}

// MARK: - Items

nonisolated struct ItemsResult: Codable, Sendable {
    var items: [BaseItem]
    var totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

nonisolated struct UserItemData: Codable, Sendable, Hashable {
    var playbackPositionTicks: Int64?
    var playCount: Int?
    var isFavorite: Bool?
    var played: Bool?
    var playedPercentage: Double?
    var unplayedItemCount: Int?
    /// ISO 8601, so these sort as text.
    var lastPlayedDate: String?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case playedPercentage = "PlayedPercentage"
        case unplayedItemCount = "UnplayedItemCount"
        case lastPlayedDate = "LastPlayedDate"
    }
}

nonisolated extension BaseItem {
    /// Matched by Shoko, which also records the AniDB id: how the app tells
    /// anime apart from other shows and films. Series and movies carry these.
    var isAnime: Bool {
        guard let ids = providerIds else { return false }
        return ids.keys.contains { $0 == "AniDB" || $0.hasPrefix("Shoko") }
    }
}

nonisolated struct PersonInfo: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
    var role: String?
    var type: String?
    var primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

nonisolated struct NameGuidPair: Codable, Sendable, Hashable {
    var name: String?
    var id: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
    }
}

nonisolated struct ChapterInfo: Codable, Sendable, Hashable {
    var startPositionTicks: Int64
    var name: String?
    var imageTag: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case imageTag = "ImageTag"
    }
}

nonisolated struct MediaStream: Codable, Sendable, Hashable {
    var codec: String?
    var type: String?
    var index: Int?
    var language: String?
    var displayTitle: String?
    var isDefault: Bool?
    var isExternal: Bool?
    var isForced: Bool?
    var title: String?
    var deliveryMethod: String?
    var deliveryUrl: String?
    var isTextSubtitleStream: Bool?
    var width: Int?
    var height: Int?
    var channels: Int?
    var videoRangeType: String?

    enum CodingKeys: String, CodingKey {
        case codec = "Codec"
        case type = "Type"
        case index = "Index"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case isDefault = "IsDefault"
        case isExternal = "IsExternal"
        case isForced = "IsForced"
        case title = "Title"
        case deliveryMethod = "DeliveryMethod"
        case deliveryUrl = "DeliveryUrl"
        case isTextSubtitleStream = "IsTextSubtitleStream"
        case width = "Width"
        case height = "Height"
        case channels = "Channels"
        case videoRangeType = "VideoRangeType"
    }

    /// How a track is named in menus: the server's display title, else
    /// language, codec and whether it is a separate file.
    var trackTitle: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        var parts: [String] = []
        if let language { parts.append(language.uppercased()) }
        if let codec { parts.append(codec.uppercased()) }
        if isExternal == true { parts.append("External") }
        return parts.isEmpty ? "Track \(index ?? 0)" : parts.joined(separator: " · ")
    }
}

/// How subtitles are chosen when nothing is picked for a title. Mirrors the
/// server's user setting so the web app and Apple TV agree.
nonisolated enum SubtitleMode: String, CaseIterable, Sendable, Identifiable {
    case `default` = "Default"
    case always = "Always"
    case onlyForced = "OnlyForced"
    case none = "None"
    case smart = "Smart"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .always: return "Always on"
        case .onlyForced: return "Only forced"
        case .none: return "Off"
        case .smart: return "Smart"
        }
    }
}

/// The user's server-side settings. Every field is carried so a change to one
/// can be posted back without clearing the others.
nonisolated struct UserConfiguration: Codable, Sendable, Hashable {
    var audioLanguagePreference: String?
    var playDefaultAudioTrack: Bool?
    var subtitleLanguagePreference: String?
    var displayMissingEpisodes: Bool?
    var groupedFolders: [String]?
    var subtitleMode: String?
    var displayCollectionsView: Bool?
    var enableLocalPassword: Bool?
    var orderedViews: [String]?
    var latestItemsExcludes: [String]?
    var myMediaExcludes: [String]?
    var hidePlayedInLatest: Bool?
    var rememberAudioSelections: Bool?
    var rememberSubtitleSelections: Bool?
    var enableNextEpisodeAutoPlay: Bool?
    var castReceiverId: String?

    enum CodingKeys: String, CodingKey {
        case audioLanguagePreference = "AudioLanguagePreference"
        case playDefaultAudioTrack = "PlayDefaultAudioTrack"
        case subtitleLanguagePreference = "SubtitleLanguagePreference"
        case displayMissingEpisodes = "DisplayMissingEpisodes"
        case groupedFolders = "GroupedFolders"
        case subtitleMode = "SubtitleMode"
        case displayCollectionsView = "DisplayCollectionsView"
        case enableLocalPassword = "EnableLocalPassword"
        case orderedViews = "OrderedViews"
        case latestItemsExcludes = "LatestItemsExcludes"
        case myMediaExcludes = "MyMediaExcludes"
        case hidePlayedInLatest = "HidePlayedInLatest"
        case rememberAudioSelections = "RememberAudioSelections"
        case rememberSubtitleSelections = "RememberSubtitleSelections"
        case enableNextEpisodeAutoPlay = "EnableNextEpisodeAutoPlay"
        case castReceiverId = "CastReceiverId"
    }
}

/// What the player should choose when a title has several tracks.
nonisolated struct PlaybackPreferences: Sendable, Equatable {
    var audioLanguage: String?
    var subtitleLanguage: String?
    var subtitleMode: SubtitleMode = .default
}

nonisolated struct MediaSourceInfo: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String?
    var container: String?
    var runTimeTicks: Int64?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var transcodingUrl: String?
    var transcodingContainer: String?
    var transcodingSubProtocol: String?
    var mediaStreams: [MediaStream]?
    var bitrate: Int?
    var `protocol`: String?
    var path: String?
    var isInfiniteStream: Bool?
    var liveStreamId: String?
    var requiresOpening: Bool?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    /// Files embedded in the container, such as the fonts an ASS track uses.
    var mediaAttachments: [MediaAttachment]?
    /// The file's size in bytes.
    var size: Int64?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case runTimeTicks = "RunTimeTicks"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingUrl = "TranscodingUrl"
        case transcodingContainer = "TranscodingContainer"
        case transcodingSubProtocol = "TranscodingSubProtocol"
        case mediaStreams = "MediaStreams"
        case bitrate = "Bitrate"
        case `protocol` = "Protocol"
        case path = "Path"
        case isInfiniteStream = "IsInfiniteStream"
        case liveStreamId = "LiveStreamId"
        case size = "Size"
        case requiresOpening = "RequiresOpening"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
        case mediaAttachments = "MediaAttachments"
    }
}

/// A file inside a video's container, e.g. an MKV's fonts.
nonisolated struct MediaAttachment: Codable, Sendable, Hashable {
    var index: Int
    var fileName: String?
    var mimeType: String?

    /// Whether this is a font a subtitle track can use.
    var isFont: Bool {
        if let mimeType, mimeType.lowercased().contains("font") { return true }
        let name = (fileName ?? "").lowercased()
        return [".ttf", ".otf", ".ttc"].contains { name.hasSuffix($0) }
    }

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case fileName = "FileName"
        case mimeType = "MimeType"
    }
}

nonisolated struct PlaybackInfoResponse: Codable, Sendable {
    var mediaSources: [MediaSourceInfo]
    var playSessionId: String?
    var errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}

nonisolated struct RemoteTrailer: Codable, Sendable, Hashable {
    var url: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case url = "Url"
        case name = "Name"
    }
}

/// The subset of Jellyfin's BaseItemDto the app renders.
nonisolated struct BaseItem: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String?
    var originalTitle: String?
    var type: String?
    var mediaType: String?
    var collectionType: String?
    var overview: String?
    var taglines: [String]?
    var genres: [String]?
    var studios: [NameGuidPair]?
    var people: [PersonInfo]?
    var productionYear: Int?
    var premiereDate: String?
    var endDate: String?
    var status: String?
    var officialRating: String?
    var communityRating: Double?
    var criticRating: Double?
    var runTimeTicks: Int64?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var childCount: Int?
    var recursiveItemCount: Int?
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonName: String?
    var parentId: String?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var parentLogoItemId: String?
    var parentLogoImageTag: String?
    /// The file's container, as the server probed it ("mp3", "flac",
    /// "mov,mp4,m4a,…"); not given for every kind of item.
    var container: String?
    var parentPrimaryImageItemId: String?
    var parentPrimaryImageTag: String?
    var seriesPrimaryImageTag: String?
    var seriesThumbImageTag: String?
    var primaryImageAspectRatio: Double?
    var userData: UserItemData?
    var chapters: [ChapterInfo]?
    /// Trickplay images for scrubbing, by file (media source) id and then
    /// by width; only on a title the server has made them for.
    var trickplay: [String: [String: TrickplayInfo]]?
    /// The item's tags in Jellyfin; a playlist's say whether it's a channel
    /// (see `ChannelTags`).
    var tags: [String]?
    var mediaSources: [MediaSourceInfo]?
    var mediaStreams: [MediaStream]?
    var providerIds: [String: String]?
    var remoteTrailers: [RemoteTrailer]?
    var locationType: String?
    var isFolder: Bool?
    var dateCreated: String?

    // Live TV: channels, programs, recordings.
    var channelId: String?
    var channelName: String?
    var channelNumber: String?
    var channelType: String?
    var channelPrimaryImageTag: String?
    var startDate: String?
    var episodeTitle: String?
    var isSeries: Bool?
    var isMovie: Bool?
    var isSports: Bool?
    var isNews: Bool?
    var isKids: Bool?
    var isLive: Bool?
    var isPremiere: Bool?
    var isRepeat: Bool?
    var timerId: String?
    var seriesTimerId: String?
    var currentProgram: ChannelProgram?

    // Music: albums, artists and songs.
    var album: String?
    var albumId: String?
    var albumArtist: String?
    var albumArtists: [NameGuidPair]?
    var artists: [String]?
    var artistItems: [NameGuidPair]?
    var albumPrimaryImageTag: String?
    var albumCount: Int?
    var songCount: Int?
    /// This entry's id inside a playlist, needed to remove or move it.
    var playlistItemId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case originalTitle = "OriginalTitle"
        case type = "Type"
        case mediaType = "MediaType"
        case collectionType = "CollectionType"
        case overview = "Overview"
        case taglines = "Taglines"
        case genres = "Genres"
        case studios = "Studios"
        case people = "People"
        case productionYear = "ProductionYear"
        case premiereDate = "PremiereDate"
        case endDate = "EndDate"
        case status = "Status"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case runTimeTicks = "RunTimeTicks"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case seasonId = "SeasonId"
        case seasonName = "SeasonName"
        case parentId = "ParentId"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentThumbItemId = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentLogoItemId = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case container = "Container"
        case parentPrimaryImageItemId = "ParentPrimaryImageItemId"
        case parentPrimaryImageTag = "ParentPrimaryImageTag"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case seriesThumbImageTag = "SeriesThumbImageTag"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case userData = "UserData"
        case chapters = "Chapters"
        case trickplay = "Trickplay"
        case tags = "Tags"
        case mediaSources = "MediaSources"
        case mediaStreams = "MediaStreams"
        case providerIds = "ProviderIds"
        case remoteTrailers = "RemoteTrailers"
        case locationType = "LocationType"
        case isFolder = "IsFolder"
        case dateCreated = "DateCreated"
        case channelId = "ChannelId"
        case channelName = "ChannelName"
        case channelNumber = "ChannelNumber"
        case channelType = "ChannelType"
        case channelPrimaryImageTag = "ChannelPrimaryImageTag"
        case startDate = "StartDate"
        case episodeTitle = "EpisodeTitle"
        case isSeries = "IsSeries"
        case isMovie = "IsMovie"
        case isSports = "IsSports"
        case isNews = "IsNews"
        case isKids = "IsKids"
        case isLive = "IsLive"
        case isPremiere = "IsPremiere"
        case isRepeat = "IsRepeat"
        case timerId = "TimerId"
        case seriesTimerId = "SeriesTimerId"
        case currentProgram = "CurrentProgram"
        case album = "Album"
        case albumId = "AlbumId"
        case albumArtist = "AlbumArtist"
        case albumArtists = "AlbumArtists"
        case artists = "Artists"
        case artistItems = "ArtistItems"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case albumCount = "AlbumCount"
        case songCount = "SongCount"
        case playlistItemId = "PlaylistItemId"
    }

    /// Identity for a row in a playlist, where the same song may appear twice.
    var playlistRowID: String { playlistItemId ?? id }
}

nonisolated struct PlaylistCreationResult: Codable, Sendable {
    var id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

extension BaseItem {
    /// Who performs a song or album, for display.
    var artistText: String? {
        if let artists, !artists.isEmpty { return artists.joined(separator: ", ") }
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        return albumArtists?.compactMap(\.name).first
    }

    /// The album artist's id, for linking from an album to its artist page.
    var primaryArtist: NameGuidPair? {
        albumArtists?.first ?? artistItems?.first
    }

    /// "3:42" for a song.
    var trackDurationText: String? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        return MusicFormat.clock(TimeInterval(ticks) / 10_000_000)
    }
}

nonisolated enum MusicFormat {
    /// "m:ss", or "h:mm:ss" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "1 hr 12 min" or "42 min" for an album or playlist.
    static func length(ticks: Int64) -> String? {
        guard ticks > 0 else { return nil }
        let minutes = Int(ticks / 600_000_000)
        if minutes >= 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
        return "\(max(minutes, 1)) min"
    }
}

/// The program a channel is airing now, as embedded in a channel item.
nonisolated struct ChannelProgram: Codable, Sendable, Hashable {
    var id: String
    var name: String?
    var episodeTitle: String?
    var startDate: String?
    var endDate: String?
    var overview: String?
    var imageTags: [String: String]?
    var isMovie: Bool?
    var isSports: Bool?
    var isNews: Bool?
    var isKids: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case episodeTitle = "EpisodeTitle"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case overview = "Overview"
        case imageTags = "ImageTags"
        case isMovie = "IsMovie"
        case isSports = "IsSports"
        case isNews = "IsNews"
        case isKids = "IsKids"
    }
}

// MARK: - Live TV

nonisolated struct LiveTVInfo: Codable, Sendable {
    var isEnabled: Bool?
    var enabledUsers: [String]?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "IsEnabled"
        case enabledUsers = "EnabledUsers"
    }
}

/// A scheduled or in-progress recording of one program.
nonisolated struct TimerInfo: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var channelId: String?
    var channelName: String?
    var programId: String?
    var name: String?
    var overview: String?
    var startDate: String?
    var endDate: String?
    var status: String?
    var seriesTimerId: String?
    var programInfo: BaseItem?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case channelId = "ChannelId"
        case channelName = "ChannelName"
        case programId = "ProgramId"
        case name = "Name"
        case overview = "Overview"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case status = "Status"
        case seriesTimerId = "SeriesTimerId"
        case programInfo = "ProgramInfo"
    }
}

/// A recurring recording rule.
/// A series recording rule. Carries every field the server reads on update so
/// changing one option never resets the others.
nonisolated struct SeriesTimerInfo: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String?
    var overview: String?
    var channelId: String?
    var channelName: String?
    var channelPrimaryImageTag: String?
    var programId: String?
    var externalId: String?
    var externalChannelId: String?
    var externalProgramId: String?
    var serviceName: String?
    var startDate: String?
    var endDate: String?
    var recordAnyChannel: Bool?
    var recordAnyTime: Bool?
    var recordNewOnly: Bool?
    var skipEpisodesInLibrary: Bool?
    var keepUpTo: Int?
    var keepUntil: String?
    var priority: Int?
    var prePaddingSeconds: Int?
    var postPaddingSeconds: Int?
    var isPrePaddingRequired: Bool?
    var isPostPaddingRequired: Bool?
    var dayPattern: String?
    var days: [String]?
    var imageTags: [String: String]?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var parentPrimaryImageItemId: String?
    var parentPrimaryImageTag: String?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case overview = "Overview"
        case channelId = "ChannelId"
        case channelName = "ChannelName"
        case channelPrimaryImageTag = "ChannelPrimaryImageTag"
        case programId = "ProgramId"
        case externalId = "ExternalId"
        case externalChannelId = "ExternalChannelId"
        case externalProgramId = "ExternalProgramId"
        case serviceName = "ServiceName"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case recordAnyChannel = "RecordAnyChannel"
        case recordAnyTime = "RecordAnyTime"
        case recordNewOnly = "RecordNewOnly"
        case skipEpisodesInLibrary = "SkipEpisodesInLibrary"
        case keepUpTo = "KeepUpTo"
        case keepUntil = "KeepUntil"
        case priority = "Priority"
        case prePaddingSeconds = "PrePaddingSeconds"
        case postPaddingSeconds = "PostPaddingSeconds"
        case isPrePaddingRequired = "IsPrePaddingRequired"
        case isPostPaddingRequired = "IsPostPaddingRequired"
        case dayPattern = "DayPattern"
        case days = "Days"
        case imageTags = "ImageTags"
        case parentThumbItemId = "ParentThumbItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentPrimaryImageItemId = "ParentPrimaryImageItemId"
        case parentPrimaryImageTag = "ParentPrimaryImageTag"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
    }
}

/// Jellyfin writes dates as ISO 8601 with seven fractional digits, which the
/// standard formatters reject. Trim the fraction, then parse.
nonisolated enum JellyfinDate {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Dates already parsed. The guide reads every programme's start and end
    /// on each move of the remote, and parsing is far slower than a lookup.
    private static let parsed = Mutex<[String: Date]>([:])
    private static let parsedLimit = 50_000

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = parsed.withLock({ $0[text] }) { return date }
        guard let date = parseUncached(text) else { return nil }
        parsed.withLock { cache in
            if cache.count >= parsedLimit { cache.removeAll(keepingCapacity: true) }
            cache[text] = date
        }
        return date
    }

    private static func parseUncached(_ original: String) -> Date? {
        var text = original
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<zone]
            let trimmed = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text = String(text[..<dot]) + "." + trimmed + String(text[zone...])
            if let date = withFraction.date(from: text) { return date }
        }
        return plain.date(from: text) ?? withFraction.date(from: text)
    }

    static func string(_ date: Date) -> String {
        plain.string(from: date)
    }
}

nonisolated extension BaseItem {
    var start: Date? { JellyfinDate.parse(startDate) }
    var end: Date? { JellyfinDate.parse(endDate) }

    var isAiringNow: Bool {
        guard let start, let end else { return false }
        let now = Date()
        return start <= now && now < end
    }

    /// Fraction of a program that has already aired.
    var airedFraction: Double? {
        guard let start, let end, end > start, isAiringNow else { return nil }
        return Date().timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    var isProgram: Bool { type == "Program" }
    var isChannel: Bool { type == "TvChannel" }
    var isRecording: Bool { type == "Recording" }
}

nonisolated extension ChannelProgram {
    var start: Date? { JellyfinDate.parse(startDate) }
    var end: Date? { JellyfinDate.parse(endDate) }

    var airedFraction: Double? {
        guard let start, let end, end > start else { return nil }
        let now = Date()
        guard start <= now, now < end else { return nil }
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}

// MARK: - Derived presentation helpers

nonisolated extension BaseItem {
    var kind: ItemKind { ItemKind(rawValue: type ?? "") ?? .other }

    var displayTitle: String { name ?? "Untitled" }

    /// "S1, E4" for episodes, nil otherwise.
    var episodeCode: String? {
        guard kind == .episode, let episode = indexNumber else { return nil }
        if let season = parentIndexNumber {
            return "S\(season), E\(episode)"
        }
        return "Episode \(episode)"
    }

    var runtimeMinutes: Int? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        return Int(ticks / 600_000_000)
    }

    var runtimeText: String? {
        guard let minutes = runtimeMinutes else { return nil }
        if minutes >= 60 {
            return "\(minutes / 60) hr \(minutes % 60) min"
        }
        return "\(minutes) min"
    }

    var remainingText: String? {
        guard let ticks = runTimeTicks, ticks > 0,
              let position = userData?.playbackPositionTicks, position > 0 else { return nil }
        let left = max(0, Int((ticks - position) / 600_000_000))
        return left >= 60 ? "\(left / 60) hr \(left % 60) min left" : "\(left) min left"
    }

    var progressFraction: Double? {
        guard let ticks = runTimeTicks, ticks > 0,
              let position = userData?.playbackPositionTicks, position > 0 else { return nil }
        return min(1, max(0, Double(position) / Double(ticks)))
    }

    var canResume: Bool {
        (userData?.playbackPositionTicks ?? 0) > 0
    }

    var isPlayable: Bool {
        switch kind {
        case .movie, .episode, .video, .musicVideo, .trailer, .tvChannel, .recording: return true
        default: return mediaType == "Video"
        }
    }

    var yearText: String? {
        if kind == .series, let year = productionYear {
            if status == "Continuing" { return "\(year)–" }
            if let end = endDate, end.count >= 4, let endYear = Int(end.prefix(4)), endYear != year {
                return "\(year)–\(endYear)"
            }
        }
        return productionYear.map(String.init)
    }

    /// The one-line metadata the Apple TV app shows under a title.
    var metadataLine: [String] {
        var parts: [String] = []
        if let year = yearText { parts.append(year) }
        if let rating = officialRating { parts.append(rating) }
        if let runtime = runtimeText, kind != .series { parts.append(runtime) }
        if let genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        return parts
    }

    var isHD: Bool {
        guard let stream = (mediaStreams ?? mediaSources?.first?.mediaStreams)?.first(where: { $0.type == "Video" }) else {
            return false
        }
        return (stream.width ?? 0) >= 1280
    }

    var is4K: Bool {
        guard let stream = (mediaStreams ?? mediaSources?.first?.mediaStreams)?.first(where: { $0.type == "Video" }) else {
            return false
        }
        return (stream.width ?? 0) >= 3800
    }

    var directors: [String] {
        (people ?? []).filter { $0.type == "Director" }.compactMap(\.name)
    }

    var writers: [String] {
        (people ?? []).filter { $0.type == "Writer" }.compactMap(\.name)
    }

    var cast: [PersonInfo] {
        (people ?? []).filter { $0.type == "Actor" || $0.type == "GuestStar" }
    }
}

/// An intro, credits or similar span inside an item, from the server's media
/// segment providers (Intro Skipper, chapter markers, EDL files).
nonisolated struct MediaSegment: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var itemId: String?
    var type: String
    var startTicks: Int64
    var endTicks: Int64

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case itemId = "ItemId"
        case type = "Type"
        case startTicks = "StartTicks"
        case endTicks = "EndTicks"
    }

    var skipTitle: String {
        switch type {
        case "Intro": return "Skip Intro"
        case "Outro": return "Skip Credits"
        case "Recap": return "Skip Recap"
        case "Preview": return "Skip Preview"
        case "Commercial": return "Skip Ad"
        default: return "Skip"
        }
    }

    func contains(ticks: Int64) -> Bool {
        ticks >= startTicks && ticks < endTicks
    }
}

/// A song's lyrics from the server: timed lines when a synced file exists,
/// plain lines otherwise.
nonisolated struct Lyrics: Codable, Sendable, Hashable {
    var metadata: LyricMetadata?
    var lyrics: [LyricLine]

    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
        case lyrics = "Lyrics"
    }

    var isSynced: Bool {
        metadata?.isSynced ?? lyrics.contains { $0.start != nil }
    }
}

nonisolated struct LyricMetadata: Codable, Sendable, Hashable {
    var artist: String?
    var album: String?
    var title: String?
    var author: String?
    /// Shift applied to every line, in ticks.
    var offset: Int64?
    var isSynced: Bool?

    enum CodingKeys: String, CodingKey {
        case artist = "Artist"
        case album = "Album"
        case title = "Title"
        case author = "Author"
        case offset = "Offset"
        case isSynced = "IsSynced"
    }
}

nonisolated struct LyricLine: Codable, Sendable, Hashable {
    var text: String
    /// When the line starts, in ticks; nil for unsynced lyrics.
    var start: Int64?

    enum CodingKeys: String, CodingKey {
        case text = "Text"
        case start = "Start"
    }
}

nonisolated enum ItemKind: String, Sendable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case boxSet = "BoxSet"
    case collectionFolder = "CollectionFolder"
    case folder = "Folder"
    case person = "Person"
    case video = "Video"
    case musicVideo = "MusicVideo"
    case trailer = "Trailer"
    case userView = "UserView"
    case tvChannel = "TvChannel"
    case program = "Program"
    case recording = "Recording"
    case musicAlbum = "MusicAlbum"
    case musicArtist = "MusicArtist"
    case audio = "Audio"
    case playlist = "Playlist"
    case musicGenre = "MusicGenre"
    /// One audiobook file: a whole book (an .m4b), or one part of a book
    /// kept as a folder of files.
    case audioBook = "AudioBook"
    case other = ""

    /// Albums, artists, playlists and songs.
    var isMusic: Bool {
        switch self {
        case .musicAlbum, .musicArtist, .audio, .playlist, .musicGenre: return true
        default: return false
        }
    }
}

nonisolated enum ImageKind: String, Sendable {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case thumb = "Thumb"
    case logo = "Logo"
    case banner = "Banner"
    case chapter = "Chapter"
}

// MARK: - Playback reporting

nonisolated struct PlaybackReport: Encodable, Sendable {
    var itemId: String
    var mediaSourceId: String?
    var playSessionId: String?
    var positionTicks: Int64
    var isPaused: Bool
    var isMuted: Bool = false
    var canSeek: Bool = true
    var playMethod: String
    var volumeLevel: Int = 100
    var repeatMode: String = "RepeatNone"
    var playbackStartTimeTicks: Int64?
    var liveStreamId: String?
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int?
    /// The title's running time, for the app's own resume-point rules
    /// (`ResumePoints`); not sent to the server.
    var runTimeTicks: Int64?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case isMuted = "IsMuted"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
        case volumeLevel = "VolumeLevel"
        case repeatMode = "RepeatMode"
        case playbackStartTimeTicks = "PlaybackStartTimeTicks"
        case liveStreamId = "LiveStreamId"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
    }
}

// MARK: - OP/ED plugin

/// `GET /OpEd/Items/{itemId}/Themes` from the OP/ED server plugin: anime
/// openings and endings the server owner supplied as files.
nonisolated struct OpEdThemeList: Decodable, Sendable {
    var itemId: String
    var seriesId: String?
    var themes: [OpEdTheme]

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case seriesId = "SeriesId"
        case themes = "Themes"
    }
}

/// One opening or ending. Absent fields are omitted by the server, so all
/// optional ones are optional here; unknown new fields are ignored.
nonisolated struct OpEdTheme: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var type: String
    var sequence: Int
    var version: Int
    var variant: String?
    var slug: String
    var seriesId: String?
    var seasonId: String?
    var aniDbId: Int?
    var songTitle: String?
    var artists: [String]
    var episodes: String?
    var playsInEpisode: Bool?
    var spoiler: Bool
    var nsfw: Bool
    var hasVideo: Bool
    var hasAudio: Bool
    var videoMp4Url: String?
    var videoMp4Status: String?
    /// The AAC copy of the audio (or an original MP3/AAC). The original
    /// `AudioUrl` is often Ogg/Opus, which tvOS can't play, so it isn't used.
    var audioM4aUrl: String?
    var audioM4aStatus: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case type = "Type"
        case sequence = "Sequence"
        case version = "Version"
        case variant = "Variant"
        case slug = "Slug"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case aniDbId = "AniDbId"
        case songTitle = "SongTitle"
        case artists = "Artists"
        case episodes = "Episodes"
        case playsInEpisode = "PlaysInEpisode"
        case spoiler = "Spoiler"
        case nsfw = "Nsfw"
        case hasVideo = "HasVideo"
        case hasAudio = "HasAudio"
        case videoMp4Url = "VideoMp4Url"
        case videoMp4Status = "VideoMp4Status"
        case audioM4aUrl = "AudioM4aUrl"
        case audioM4aStatus = "AudioM4aStatus"
    }

    var isOpening: Bool { type.uppercased() == "OP" }

    /// What to hand AVPlayer: the H.264 MP4 when ready, else the AAC audio.
    /// Nil when nothing is playable on Apple TV yet.
    var playablePath: String? { videoMp4Url ?? audioM4aUrl }

    /// Only the song plays: there's no video copy.
    var isAudioOnly: Bool { videoMp4Url == nil && audioM4aUrl != nil }

    /// A copy is still being made; worth showing and checking again.
    var isPreparing: Bool {
        playablePath == nil && [videoMp4Status, audioM4aStatus].contains { ["pending", "converting"].contains($0 ?? "") }
    }

    /// "OP1", "OP1 v2", "ED1-TV".
    var code: String { version > 1 ? "\(slug) v\(version)" : slug }

    /// "Yuusha — YOASOBI", or nil when the plugin has no song details.
    var songLine: String? {
        guard let songTitle else { return artists.isEmpty ? nil : artists.joined(separator: ", ") }
        return artists.isEmpty ? songTitle : "\(songTitle) — \(artists.joined(separator: ", "))"
    }
}
