//
//  JellyfinClient.swift
//  AsterFIN
//
//  A thin async client for the Jellyfin REST API (10.9+ routes) plus the
//  JellyDisc plugin's player-facing endpoint.
//

import Foundation

nonisolated enum JellyfinError: LocalizedError, Sendable {
    case invalidURL
    case http(Int, String?)
    case notSignedIn
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That server address is not valid."
        case .http(let code, let message):
            if code == 401 { return "Incorrect user name or password." }
            if let message, !message.isEmpty { return "Server error \(code): \(message)" }
            return "Server error \(code)."
        case .notSignedIn: return "You are not signed in."
        case .decoding(let detail): return "Unexpected server response: \(detail)"
        }
    }
}

nonisolated enum JellyfinDevice {
    static let clientName = "Aster"
    static let version = "1.0"

    static let deviceName = "Apple TV"

    static var deviceId: String {
        let key = "AsterFIN.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

nonisolated final class JellyfinClient: Sendable {
    let baseURL: URL
    let accessToken: String?
    let userId: String?
    let session: URLSession

    static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    init(baseURL: URL, accessToken: String? = nil, userId: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.userId = userId
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func signedIn(token: String, userId: String) -> JellyfinClient {
        JellyfinClient(baseURL: baseURL, accessToken: token, userId: userId)
    }

    // MARK: Request plumbing

    var authorizationHeader: String {
        var header = "MediaBrowser Client=\"\(JellyfinDevice.clientName)\", Device=\"\(JellyfinDevice.deviceName)\", DeviceId=\"\(JellyfinDevice.deviceId)\", Version=\"\(JellyfinDevice.version)\""
        if let accessToken {
            header += ", Token=\"\(accessToken)\""
        }
        return header
    }

    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + (path.hasPrefix("/") ? path : "/" + path)
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        components.queryItems = items.isEmpty ? nil : items.sorted { $0.name < $1.name }
        return components.url ?? baseURL
    }

    /// A URL that carries the token as a query parameter, for AVPlayer and other
    /// loaders that cannot send headers. Newer servers read `ApiKey` and only
    /// honour the legacy `api_key` on a few stream endpoints, so both are sent.
    func tokenURL(_ path: String, query: [String: String?] = [:]) -> URL {
        var merged = query
        merged["ApiKey"] = accessToken
        merged["api_key"] = accessToken
        return url(path, query: merged)
    }

    func authorizedRequest(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(authorizationHeader, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    @concurrent
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.invalidURL }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8))
        }
        return (data, http)
    }

    @concurrent
    private func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [String: String?] = [:]) async throws -> T {
        let (data, _) = try await send(authorizedRequest(url(path, query: query)))
        return try await decode(T.self, from: data)
    }

    func post<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [String: String?] = [:], body: (any Encodable & Sendable)? = nil) async throws -> T {
        var request = authorizedRequest(url(path, query: query), method: "POST")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, _) = try await send(request)
        return try await decode(T.self, from: data)
    }

    func post(_ path: String, query: [String: String?] = [:], body: (any Encodable & Sendable)? = nil) async throws {
        var request = authorizedRequest(url(path, query: query), method: "POST")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        _ = try await send(request)
    }

    func delete(_ path: String, query: [String: String?] = [:]) async throws {
        _ = try await send(authorizedRequest(url(path, query: query), method: "DELETE"))
    }

    /// Raw bytes with authentication (pictures, sounds), from the disk cache
    /// when it has them. `fresh` skips the cache and drops what it held, for
    /// a cached copy that turned out to be damaged.
    func data(from url: URL, fresh: Bool = false) async throws -> Data {
        var request = authorizedRequest(url)
        if fresh {
            Self.imageSession.configuration.urlCache?.removeCachedResponse(for: request)
            request.cachePolicy = .reloadIgnoringLocalCacheData
        } else {
            request.cachePolicy = .returnCacheDataElseLoad
        }
        let (data, response) = try await Self.imageSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw JellyfinError.http(http.statusCode, nil)
        }
        return data
    }

    // MARK: Server and sign-in

    func publicSystemInfo() async throws -> PublicSystemInfo {
        try await get(PublicSystemInfo.self, "/System/Info/Public")
    }

    func publicUsers() async throws -> [JellyfinUser] {
        try await get([JellyfinUser].self, "/Users/Public")
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        nonisolated struct Body: Encodable, Sendable {
            var Username: String
            var Pw: String
        }
        return try await post(AuthenticationResult.self, "/Users/AuthenticateByName", body: Body(Username: username, Pw: password))
    }

    func quickConnectEnabled() async throws -> Bool {
        try await get(Bool.self, "/QuickConnect/Enabled")
    }

    func quickConnectInitiate() async throws -> QuickConnectResult {
        try await post(QuickConnectResult.self, "/QuickConnect/Initiate")
    }

    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        try await get(QuickConnectResult.self, "/QuickConnect/Connect", query: ["secret": secret])
    }

    func authenticateWithQuickConnect(secret: String) async throws -> AuthenticationResult {
        nonisolated struct Body: Encodable, Sendable { var Secret: String }
        return try await post(AuthenticationResult.self, "/Users/AuthenticateWithQuickConnect", body: Body(Secret: secret))
    }

    func logout() async {
        try? await post("/Sessions/Logout")
    }

    // MARK: Library

    static let listFields = "SortName,PrimaryImageAspectRatio,Overview,Genres,ProductionYear,OfficialRating,CommunityRating,RunTimeTicks,ParentId,Status,EndDate,ChildCount,DateCreated,MediaStreams,ProviderIds"
    static let detailFields = "Trickplay,PrimaryImageAspectRatio,Overview,Genres,Studios,People,Taglines,ProductionYear,OfficialRating,CommunityRating,CriticRating,RunTimeTicks,ParentId,Status,EndDate,ChildCount,RecursiveItemCount,Chapters,MediaSources,MediaStreams,ProviderIds,RemoteTrailers,DateCreated"

    private func requireUser() throws -> String {
        guard let userId else { throw JellyfinError.notSignedIn }
        return userId
    }

    func userViews() async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/UserViews", query: ["userId": user]).items
    }

    func item(_ id: String) async throws -> BaseItem {
        let user = try requireUser()
        return try await get(BaseItem.self, "/Items/\(id)", query: ["userId": user, "fields": Self.detailFields])
    }

    func items(_ query: [String: String?]) async throws -> ItemsResult {
        let user = try requireUser()
        var merged: [String: String?] = [
            "userId": user,
            "fields": Self.listFields,
            "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
            "imageTypeLimit": "1",
        ]
        for (key, value) in query { merged[key] = value }
        return try await get(ItemsResult.self, "/Items", query: merged)
    }

    // MARK: Sources (for genre, network and collection Channels)

    /// The genres of the server's movies and shows, by name.
    func videoGenres() async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Genres", query: [
            "userId": user,
            "recursive": "true",
            "includeItemTypes": "Movie,Series",
            "sortBy": "SortName",
        ]).items
    }

    /// Every show on the server, by name, for making a channel of one.
    func seriesList() async throws -> [BaseItem] {
        let user = try requireUser()
        return try await allItems([
            "userId": user,
            "recursive": "true",
            "includeItemTypes": "Series",
            "sortBy": "SortName",
            "enableImages": "false",
            "enableUserData": "false",
        ])
    }

    /// The studios and networks of the server's movies and shows, by name.
    func videoStudios() async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Studios", query: [
            "userId": user,
            "recursive": "true",
            "includeItemTypes": "Movie,Series",
            "sortBy": "SortName",
        ]).items
    }

    /// The server's collections.
    func collections() async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Users/\(user)/Items", query: [
            "includeItemTypes": "BoxSet",
            "recursive": "true",
            "sortBy": "SortName",
            "fields": "ChildCount",
        ]).items
    }

    /// The content ratings the server's movies and shows carry, most used first.
    func videoRatings() async throws -> [String] {
        let user = try requireUser()
        let items = try await get(ItemsResult.self, "/Items", query: [
            "userId": user,
            "recursive": "true",
            "includeItemTypes": "Movie,Series",
            "fields": "OfficialRating",
            "enableImages": "false",
            "enableUserData": "false",
        ]).items
        var counts: [String: Int] = [:]
        for rating in items.compactMap(\.officialRating) where !rating.isEmpty { counts[rating, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// What a Channel's schedule and menus use of each title, and no more
    /// (no media streams), so thousands of episodes stay a small download.
    private static let channelItemQuery: [String: String?] = [
        "fields": "Overview",
        "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
        "imageTypeLimit": "1",
        "enableUserData": "false",
    ]

    /// Every item `query` finds, 500 at a time.
    private func allItems(_ query: [String: String?]) async throws -> [BaseItem] {
        var found: [BaseItem] = []
        let pageSize = 500
        while true {
            var page = query
            page["startIndex"] = String(found.count)
            page["limit"] = String(pageSize)
            let result = try await get(ItemsResult.self, "/Items", query: page)
            found += result.items
            if result.items.count < pageSize || found.count >= (result.totalRecordCount ?? 0) { break }
        }
        return found
    }

    /// The movies and series in any of `genreIds`, or from any of
    /// `studioIds` (ids, not names, so a name with "&" in it can't break the
    /// request), of `types`, under `parentId` (a library) or everywhere,
    /// from `years` and with `ratings` when given.
    func sourceTitles(genreIds: [String] = [], studioIds: [String] = [], types: String, parentId: String?, years: ClosedRange<Int>?, ratings: [String]) async throws -> [BaseItem] {
        var query = Self.channelItemQuery
        query["userId"] = try requireUser()
        query["recursive"] = "true"
        query["includeItemTypes"] = types
        query["parentId"] = parentId
        query["isMissing"] = "false"
        query["sortBy"] = "SortName"
        // Ids are comma-separated; names (ratings, below) take "|". Ids
        // joined with "|" make Jellyfin drop the filter and return
        // everything, so a two-network channel played the whole library.
        if !genreIds.isEmpty { query["genreIds"] = genreIds.joined(separator: ",") }
        if !studioIds.isEmpty { query["studioIds"] = studioIds.joined(separator: ",") }
        if let years { query["years"] = years.map(String.init).joined(separator: ",") }
        if !ratings.isEmpty { query["officialRatings"] = ratings.joined(separator: "|") }
        return try await allItems(query)
    }

    /// What a collection holds: its movies and series.
    func collectionTitles(_ collectionId: String) async throws -> [BaseItem] {
        var query = Self.channelItemQuery
        query["userId"] = try requireUser()
        query["parentId"] = collectionId
        query["fields"] = "Overview,OfficialRating"
        return try await allItems(query)
    }

    /// A series' episodes, as a Channel plays them (missing ones left out).
    func seriesEpisodes(_ seriesId: String) async throws -> [BaseItem] {
        var query = Self.channelItemQuery
        query["userId"] = try requireUser()
        query["parentId"] = seriesId
        query["recursive"] = "true"
        query["includeItemTypes"] = "Episode"
        query["isMissing"] = "false"
        return try await allItems(query)
    }

    func latest(parentId: String?, limit: Int = 20, includeTypes: String? = nil) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get([BaseItem].self, "/Items/Latest", query: [
            "userId": user,
            "parentId": parentId,
            "limit": String(limit),
            "fields": Self.listFields,
            "includeItemTypes": includeTypes,
            "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
            "imageTypeLimit": "1",
        ])
    }

    func resume(limit: Int = 20, parentId: String? = nil) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/UserItems/Resume", query: [
            "userId": user,
            "parentId": parentId,
            "limit": String(limit),
            "mediaTypes": "Video",
            "fields": Self.listFields,
            "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
            "imageTypeLimit": "1",
        ]).items
    }

    /// Episodes of shows in the library that air soon, soonest first; most
    /// are placeholders from the show's schedule rather than files.
    func upcoming(limit: Int = 100) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Shows/Upcoming", query: [
            "userId": user,
            "limit": String(limit),
            "fields": Self.listFields,
            "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
            "imageTypeLimit": "1",
        ]).items
    }

    /// The TV and movie libraries that hold anime. Reading a library's
    /// metadata settings needs an admin account, so instead a few titles in
    /// each are sampled: when at least half were matched by Shoko/AniDB, the
    /// library is anime. One stray anime title doesn't claim a library.
    func animeLibraries(among views: [BaseItem]) async -> [BaseItem] {
        let candidates = views.filter { $0.collectionType == "tvshows" || $0.collectionType == "movies" }
        let verdicts = await withTaskGroup(of: (String, Bool).self) { group in
            for library in candidates {
                group.addTask {
                    let sample = (try? await self.items([
                        "parentId": library.id,
                        "recursive": "true",
                        "includeItemTypes": "Series,Movie",
                        "limit": "5",
                        "fields": "ProviderIds",
                    ]))?.items ?? []
                    let anime = sample.filter(\.isAnime).count
                    return (library.id, !sample.isEmpty && anime * 2 >= sample.count)
                }
            }
            var found: [String: Bool] = [:]
            for await (id, isAnime) in group { found[id] = isAnime }
            return found
        }
        return candidates.filter { verdicts[$0.id] == true }
    }

    /// Just the ids of the given kinds of item in some libraries: no images
    /// or extra fields, so even large libraries come back quickly.
    func itemIds(inLibraries libraryIds: [String], types: String) async -> Set<String> {
        await withTaskGroup(of: [String].self) { group in
            for libraryId in libraryIds {
                group.addTask {
                    let result = try? await self.items([
                        "parentId": libraryId,
                        "recursive": "true",
                        "includeItemTypes": types,
                        "fields": nil,
                        "enableImageTypes": nil,
                        "imageTypeLimit": nil,
                        "enableImages": "false",
                        "enableUserData": "false",
                    ])
                    return result?.items.map(\.id) ?? []
                }
            }
            var ids = Set<String>()
            for await chunk in group { ids.formUnion(chunk) }
            return ids
        }
    }

    func nextUp(limit: Int = 20, seriesId: String? = nil, parentId: String? = nil) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Shows/NextUp", query: [
            "userId": user,
            "seriesId": seriesId,
            "parentId": parentId,
            "limit": String(limit),
            "fields": Self.listFields,
            "enableImageTypes": "Primary,Backdrop,Thumb,Logo",
            "imageTypeLimit": "1",
            "enableResumable": "false",
        ]).items
    }

    func seasons(seriesId: String) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Shows/\(seriesId)/Seasons", query: [
            "userId": user,
            "fields": Self.listFields,
        ]).items
    }

    func episodes(seriesId: String, seasonId: String?) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Shows/\(seriesId)/Episodes", query: [
            "userId": user,
            "seasonId": seasonId,
            "fields": Self.listFields + ",MediaSources",
        ]).items
    }

    /// Openings and endings from the OP/ED server plugin for a series, season
    /// or episode. Nil when the plugin isn't installed, the item is unknown,
    /// or the request fails; callers then fall back to chapter markers.
    func opEdThemes(for itemId: String) async -> [OpEdTheme]? {
        try? await get(OpEdThemeList.self, "/OpEd/Items/\(itemId)/Themes").themes
    }

    /// The theme a published music video (or song) is, from the OP/ED
    /// plugin; nil for any other item, or without the plugin.
    func opEdTheme(forLibraryItem itemId: String) async -> OpEdTheme? {
        try? await get(OpEdTheme.self, "/OpEd/LibraryItems/\(itemId)/Theme")
    }

    /// Live TV channels' groups, by channel id, from the Aster Channels
    /// plugin; nil without it (or before 0.2), which leaves Live TV as it was.
    func liveTvGroups() async -> [String: String]? {
        try? await get(LiveTvGroupList.self, "/AsterChannels/LiveTvGroups").byChannel
    }

    /// Puts a Live TV channel in `group`, or out of its group for nil
    /// (administrators only); every channel's group after.
    func setLiveTvGroup(channelId: String, group: String?) async throws -> [String: String] {
        let change = LiveTvGroupList.Entry(channelId: channelId, group: group ?? "")
        return try await post(LiveTvGroupList.self, "/AsterChannels/LiveTvGroups", body: change).byChannel
    }

    /// The OP/ED plugin's published libraries; nil without the plugin (or
    /// before 0.2).
    func opEdLibraries() async -> OpEdLibraries? {
        try? await get(OpEdLibraries.self, "/OpEd/Library")
    }

    /// A library's newest music videos, for a shelf.
    func latestMusicVideos(inLibrary libraryId: String, limit: Int = 20) async -> [BaseItem] {
        (try? await items([
            "parentId": libraryId,
            "includeItemTypes": "MusicVideo",
            "recursive": "true",
            "sortBy": "DateCreated,SortName",
            "sortOrder": "Descending",
            "limit": String(limit),
        ]).items) ?? []
    }

    /// A plugin media path (e.g. `VideoMp4Url`) as a URL AVPlayer can open,
    /// with the token in the query string.
    func opEdMediaURL(_ path: String) -> URL {
        tokenURL(path)
    }

    /// Every episode of a series in airing order, with its chapters, in one
    /// request: what finding openings and endings reads.
    func episodesWithChapters(seriesId: String) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Shows/\(seriesId)/Episodes", query: [
            "userId": user,
            "fields": "Chapters,RunTimeTicks",
            "enableImageTypes": "Primary,Thumb",
            "imageTypeLimit": "1",
            "enableUserData": "false",
        ]).items
    }

    func similar(to id: String, limit: Int = 20) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Items/\(id)/Similar", query: [
            "userId": user,
            "limit": String(limit),
            "fields": Self.listFields,
        ]).items
    }

    func specialFeatures(of id: String) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get([BaseItem].self, "/Items/\(id)/SpecialFeatures", query: ["userId": user])
    }

    func search(_ term: String, limit: Int = 60) async throws -> [BaseItem] {
        try await items([
            "searchTerm": term,
            "recursive": "true",
            "includeItemTypes": "Movie,Series,Episode,MusicAlbum,MusicArtist,Audio,Playlist",
            "limit": String(limit),
            "sortBy": "SortName",
        ]).items
    }

    // MARK: User data

    func setFavorite(_ id: String, _ favorite: Bool) async throws {
        let user = try requireUser()
        if favorite {
            try await post("/UserFavoriteItems/\(id)", query: ["userId": user])
        } else {
            try await delete("/UserFavoriteItems/\(id)", query: ["userId": user])
        }
    }

    func setPlayed(_ id: String, _ played: Bool) async throws {
        let user = try requireUser()
        if played {
            try await post("/UserPlayedItems/\(id)", query: ["userId": user])
        } else {
            try await delete("/UserPlayedItems/\(id)", query: ["userId": user])
        }
    }

    // MARK: Playback

    /// The signed-in user, including their server-side settings.
    /// Everyone's user names on the server, which only an administrator
    /// can list.
    func userNames() async throws -> [String] {
        try await get([JellyfinUser].self, "/Users").map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func me() async throws -> JellyfinUser {
        try await get(JellyfinUser.self, "/Users/Me")
    }

    /// Replaces the user's settings wholesale; send a complete configuration.
    func updateConfiguration(_ configuration: UserConfiguration) async throws {
        let user = try requireUser()
        try await post("/Users/Configuration", query: ["userId": user], body: configuration)
    }

    /// `allowDirect: false` makes the server offer an HLS stream even when the
    /// file could play directly. `subtitleStreamIndex` only matters to the
    /// server for picture-based tracks, which it burns in; -1 means none.
    /// `mostCompatible` asks for a fresh 8-bit H.264 + AAC encode, copying
    /// nothing from the file: the last resort when other streams won't play.
    func playbackInfo(itemId: String, mediaSourceId: String? = nil, startTicks: Int64, maxBitrate: Int, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil, allowDirect: Bool = true, mostCompatible: Bool = false, profile: DeviceProfile? = nil) async throws -> PlaybackInfoResponse {
        let user = try requireUser()
        nonisolated struct Body: Encodable, Sendable {
            var DeviceProfile: DeviceProfile
            /// The server applies the track indexes only when this names the file.
            var MediaSourceId: String?
            var StartTimeTicks: Int64
            var MaxStreamingBitrate: Int
            var AudioStreamIndex: Int?
            var SubtitleStreamIndex: Int?
            var AutoOpenLiveStream: Bool = true
            var EnableDirectPlay: Bool = true
            var EnableDirectStream: Bool = true
            var EnableTranscoding: Bool = true
            var AllowVideoStreamCopy: Bool = true
            var AllowAudioStreamCopy: Bool = true
        }
        let direct = allowDirect && !mostCompatible
        let body = Body(
            DeviceProfile: profile ?? (mostCompatible ? .appleTVMostCompatible(maxBitrate: maxBitrate) : .appleTV(maxBitrate: maxBitrate)),
            MediaSourceId: mediaSourceId,
            StartTimeTicks: startTicks,
            MaxStreamingBitrate: maxBitrate,
            AudioStreamIndex: audioStreamIndex,
            SubtitleStreamIndex: subtitleStreamIndex,
            EnableDirectPlay: direct,
            EnableDirectStream: direct,
            AllowVideoStreamCopy: !mostCompatible,
            AllowAudioStreamCopy: !mostCompatible
        )
        return try await post(PlaybackInfoResponse.self, "/Items/\(itemId)/PlaybackInfo", query: ["userId": user], body: body)
    }

    /// The cues of a text subtitle track, converted by the server to its
    /// JSON form (what Jellyfin's web player reads). The first request for
    /// a track inside an MKV makes the server extract it, which can take
    /// minutes; later ones come from its cache.
    func subtitleCues(itemId: String, mediaSourceId: String, streamIndex: Int) async throws -> [SubtitleCue] {
        var request = authorizedRequest(url("/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/Stream.js"))
        request.timeoutInterval = 600
        let (data, _) = try await send(request)
        return try SubtitleCue.parse(json: data)
    }

    /// An ASS/SSA track as the script itself, with its styles and
    /// positions, for drawing with libass. Extracted on first request, as
    /// with `subtitleCues`.
    func subtitleScript(itemId: String, mediaSourceId: String, streamIndex: Int) async throws -> String {
        var request = authorizedRequest(url("/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/Stream.ass"))
        request.timeoutInterval = 600
        let (data, _) = try await send(request)
        guard let script = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw JellyfinError.decoding("Subtitle script isn't text")
        }
        return script
    }

    /// A file embedded in the video's container, such as a font.
    func attachment(itemId: String, mediaSourceId: String, index: Int) async throws -> Data {
        try await send(authorizedRequest(url("/Videos/\(itemId)/\(mediaSourceId)/Attachments/\(index)"))).0
    }

    func reportStart(_ report: PlaybackReport) async {
        try? await post("/Sessions/Playing", body: report)
    }

    /// Also saves the position as the resume point when it's due, at once,
    /// or never (music, which starts each song from the top); see `ResumePoints`.
    func reportProgress(_ report: PlaybackReport, savingResumePoint saving: ResumePoints.Saving = .whenDue) async {
        try? await post("/Sessions/Playing/Progress", body: report)
        guard saving != .never else { return }
        await ResumePoints.shared.progress(report, client: self, force: saving == .now)
    }

    func reportStopped(_ report: PlaybackReport) async {
        // A resume point still on its way mustn't land after the stop.
        await ResumePoints.shared.stopping(report.itemId)
        try? await post("/Sessions/Playing/Stopped", body: report)
    }

    /// Sets the user's resume point on an item, leaving its watched state alone.
    func saveResumePosition(itemId: String, ticks: Int64) async throws {
        guard let userId else { return }
        try await post("/UserItems/\(itemId)/UserData", query: ["userId": userId], body: ResumePositionUpdate(playbackPositionTicks: ticks))
    }

    // MARK: Images

    /// `quality` is the server's JPEG/WebP quality, 0 to 100.
    func imageURL(itemId: String, kind: ImageKind, tag: String? = nil, index: Int? = nil, maxWidth: Int? = nil, maxHeight: Int? = nil, quality: Int = 90) -> URL {
        var path = "/Items/\(itemId)/Images/\(kind.rawValue)"
        if let index { path += "/\(index)" }
        return url(path, query: [
            "tag": tag,
            "maxWidth": maxWidth.map(String.init),
            "maxHeight": maxHeight.map(String.init),
            "quality": String(quality),
        ])
    }

    func userImageURL(userId: String, tag: String?) -> URL {
        url("/UserImage", query: ["userId": userId, "tag": tag, "maxWidth": "300"])
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

    // MARK: Streams

    func directStreamURL(itemId: String, mediaSourceId: String, playSessionId: String?, container: String?) -> URL {
        tokenURL("/Videos/\(itemId)/stream", query: [
            "static": "true",
            "mediaSourceId": mediaSourceId,
            "playSessionId": playSessionId,
            "deviceId": JellyfinDevice.deviceId,
        ])
    }

    /// The original file, for saving; refused unless the account may download.
    func downloadURL(itemId: String) -> URL {
        tokenURL("/Items/\(itemId)/Download")
    }

    func audioStreamURL(itemId: String) -> URL {
        tokenURL("/Audio/\(itemId)/stream", query: ["static": "true"])
    }

    func videoStreamURL(itemId: String) -> URL {
        tokenURL("/Videos/\(itemId)/stream", query: ["static": "true"])
    }

    func subtitleURL(itemId: String, mediaSourceId: String, streamIndex: Int) -> URL {
        tokenURL("/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/Stream.vtt")
    }

    // MARK: Music

    /// Artists credited on albums, paged.
    func albumArtists(parentId: String? = nil, startIndex: Int = 0, limit: Int = 100) async throws -> ItemsResult {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Artists/AlbumArtists", query: [
            "userId": user,
            "parentId": parentId,
            "startIndex": String(startIndex),
            "limit": String(limit),
            "sortBy": "SortName",
            "sortOrder": "Ascending",
            "fields": "PrimaryImageAspectRatio,Overview",
            "enableImageTypes": "Primary,Backdrop",
            "imageTypeLimit": "1",
        ])
    }

    /// An album's songs in disc and track order.
    func albumTracks(albumId: String) async throws -> [BaseItem] {
        try await items([
            "parentId": albumId,
            "includeItemTypes": "Audio",
            "sortBy": "ParentIndexNumber,IndexNumber,SortName",
        ]).items
    }

    /// Albums an artist is credited on, newest first.
    func artistAlbums(artistId: String) async throws -> [BaseItem] {
        try await items([
            "albumArtistIds": artistId,
            "includeItemTypes": "MusicAlbum",
            "recursive": "true",
            "sortBy": "ProductionYear,SortName",
            "sortOrder": "Descending",
        ]).items
    }

    /// Every song by an artist, in album order, for Play and Shuffle.
    func artistTracks(artistId: String, limit: Int = 400) async throws -> [BaseItem] {
        try await items([
            "artistIds": artistId,
            "includeItemTypes": "Audio",
            "recursive": "true",
            "sortBy": "Album,ParentIndexNumber,IndexNumber",
            "limit": String(limit),
        ]).items
    }

    func playlistItems(playlistId: String) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Playlists/\(playlistId)/Items", query: [
            "userId": user,
            // Tags too, for a break clip's `aster:bumper=in`.
            "fields": Self.listFields + ",Tags",
            // Logo too, so an episode carries its series' clear logo.
            "enableImageTypes": "Primary,Logo",
            "imageTypeLimit": "1",
        ]).items
    }

    /// Songs the server thinks go with an item: a song, album, artist or genre.
    func instantMix(for itemId: String, limit: Int = 100) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Items/\(itemId)/InstantMix", query: [
            "userId": user,
            "limit": String(limit),
            "fields": Self.listFields,
            "enableImageTypes": "Primary",
            "imageTypeLimit": "1",
        ]).items
    }

    /// A stream AVPlayer can play: the file itself when Apple TV decodes its
    /// format, else an HLS transcode to AAC. The server decides per request.
    func universalAudioURL(itemId: String, playSessionId: String, maxBitrate: Int) -> URL {
        tokenURL("/Audio/\(itemId)/universal", query: [
            "userId": userId,
            "deviceId": JellyfinDevice.deviceId,
            "playSessionId": playSessionId,
            "container": "mp3,aac,m4a|aac,m4b|aac,flac,alac,m4a|alac,wav,aiff",
            "transcodingContainer": "ts",
            "transcodingProtocol": "hls",
            "audioCodec": "aac",
            "maxStreamingBitrate": String(maxBitrate),
            "startTimeTicks": "0",
            "enableRedirection": "true",
            "enableRemoteMedia": "false",
        ])
    }

    func absoluteURL(serverRelative path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let relative = URLComponents(string: path)
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + (relative?.path ?? path)
        components.queryItems = relative?.queryItems
        return components.url
    }

    // MARK: Live TV

    func liveTVInfo() async throws -> LiveTVInfo {
        try await get(LiveTVInfo.self, "/LiveTv/Info")
    }

    func channels(limit: Int = 500) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/LiveTv/Channels", query: [
            "userId": user,
            "limit": String(limit),
            "addCurrentProgram": "true",
            "enableUserData": "true",
            "enableImages": "true",
            "imageTypeLimit": "1",
            "enableImageTypes": "Primary",
            "sortBy": "DefaultChannelOrder",
            "sortOrder": "Ascending",
        ]).items
    }

    /// Programs on one channel that overlap the window.
    func programs(channelId: String, from start: Date, to end: Date) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/LiveTv/Programs", query: [
            "userId": user,
            "channelIds": channelId,
            "minEndDate": JellyfinDate.string(start),
            "maxStartDate": JellyfinDate.string(end),
            "sortBy": "StartDate",
            "limit": "200",
            // Image tags and the overview let the guide's now-playing panel
            // show artwork and text without a second request per programme.
            "enableImages": "true",
            "imageTypeLimit": "1",
            "enableImageTypes": "Primary,Thumb",
            "fields": "Overview",
            "enableUserData": "false",
        ]).items
    }

    /// What the server recommends right now, optionally filtered by kind.
    func recommendedPrograms(limit: Int = 24, isMovie: Bool? = nil, isSports: Bool? = nil, isKids: Bool? = nil, isNews: Bool? = nil, isSeries: Bool? = nil) async throws -> [BaseItem] {
        let user = try requireUser()
        func flag(_ value: Bool?) -> String? { value.map { $0 ? "true" : "false" } }
        return try await get(ItemsResult.self, "/LiveTv/Programs/Recommended", query: [
            "userId": user,
            "isAiring": "true",
            "limit": String(limit),
            "enableImages": "true",
            "imageTypeLimit": "1",
            "enableImageTypes": "Primary,Thumb,Backdrop",
            "fields": "ChannelInfo,PrimaryImageAspectRatio,Overview",
            "isMovie": flag(isMovie),
            "isSports": flag(isSports),
            "isKids": flag(isKids),
            "isNews": flag(isNews),
            "isSeries": flag(isSeries),
        ]).items
    }

    func program(_ id: String) async throws -> BaseItem {
        let user = try requireUser()
        return try await get(BaseItem.self, "/LiveTv/Programs/\(id)", query: ["userId": user])
    }

    func recordings(limit: Int = 100) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/LiveTv/Recordings", query: [
            "userId": user,
            "limit": String(limit),
            "fields": Self.listFields,
            "enableImages": "true",
            "imageTypeLimit": "1",
            "enableImageTypes": "Primary,Thumb,Backdrop",
        ]).items
    }

    func timers() async throws -> [TimerInfo] {
        try await get(ItemsEnvelope<TimerInfo>.self, "/LiveTv/Timers", query: ["isScheduled": "true"]).items
    }

    func seriesTimers() async throws -> [SeriesTimerInfo] {
        try await get(ItemsEnvelope<SeriesTimerInfo>.self, "/LiveTv/SeriesTimers").items
    }

    /// Schedules a recording of one program using the server's defaults.
    func recordProgram(_ programId: String) async throws {
        let defaults = try await rawGet("/LiveTv/Timers/Defaults", query: ["programId": programId])
        try await postRaw("/LiveTv/Timers", body: defaults)
    }

    /// Records every airing of a series using the server's defaults. The server
    /// has a single defaults endpoint, `Timers/Defaults`, whose response is a
    /// series timer; the web client posts that same payload to `SeriesTimers`.
    func recordSeries(programId: String) async throws {
        let defaults = try await rawGet("/LiveTv/Timers/Defaults", query: ["programId": programId])
        try await postRaw("/LiveTv/SeriesTimers", body: defaults)
    }

    func cancelTimer(_ timerId: String) async throws {
        try await delete("/LiveTv/Timers/\(timerId)")
    }

    func cancelSeriesTimer(_ seriesTimerId: String) async throws {
        try await delete("/LiveTv/SeriesTimers/\(seriesTimerId)")
    }

    func seriesTimer(_ id: String) async throws -> SeriesTimerInfo {
        try await get(SeriesTimerInfo.self, "/LiveTv/SeriesTimers/\(id)")
    }

    /// Saves a changed series rule; the whole record is posted back.
    func updateSeriesTimer(_ timer: SeriesTimerInfo) async throws {
        try await post("/LiveTv/SeriesTimers/\(timer.id)", body: timer)
    }

    func deleteRecording(_ recordingId: String) async throws {
        try await delete("/LiveTv/Recordings/\(recordingId)")
    }

    /// The text at a stream address (an HLS playlist), signed in; for checking
    /// a stream is serving video before switching to it.
    func playlistText(at url: URL) async throws -> String {
        var request = authorizedRequest(url)
        request.timeoutInterval = 10
        let (data, _) = try await send(request)
        return String(decoding: data, as: UTF8.self)
    }

    func closeLiveStream(_ liveStreamId: String) async {
        try? await post("/LiveStreams/Close", query: ["liveStreamId": liveStreamId])
    }

    /// Ends the server's transcode for a play session that playback reports
    /// don't cover, so it doesn't keep encoding after playback moves on.
    func stopTranscoding(playSessionId: String) async {
        try? await delete("/Videos/ActiveEncodings", query: ["deviceId": JellyfinDevice.deviceId, "playSessionId": playSessionId])
    }

    private func rawGet(_ path: String, query: [String: String?]) async throws -> Data {
        try await send(authorizedRequest(url(path, query: query))).0
    }

    private func postRaw(_ path: String, query: [String: String?] = [:], body: Data) async throws {
        var request = authorizedRequest(url(path, query: query), method: "POST")
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(request)
    }

    // MARK: Settings on the server

    /// AsterFIN's own settings for this user are kept in Jellyfin's display
    /// preferences, the place the server gives each app for its settings
    /// (Jellyfin's web app keeps its own under the client name "emby").
    private static let settingsRecord = "asterfin"
    private static let settingsClient = "AsterFIN"
    /// Account-wide web settings the server mixes into every record it
    /// returns, and saves to the account from any record posted. Never sent
    /// back, so AsterFIN can't change them.
    private static let accountWidePrefs: Set<String> = ["chromecastversion", "skipforwardlength", "skipbacklength", "enablenextvideoinfooverlay", "tvhome", "dashboardtheme"]

    private func settingsRecordJSON() async throws -> [String: Any] {
        let data = try await rawGet("/DisplayPreferences/\(Self.settingsRecord)", query: ["userId": try requireUser(), "client": Self.settingsClient])
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func ownPrefs(in record: [String: Any]) -> [String: String] {
        let prefs = record["CustomPrefs"] as? [String: Any] ?? [:]
        return prefs.filter { !accountWidePrefs.contains($0.key.lowercased()) }.compactMapValues { $0 as? String }
    }

    /// AsterFIN's settings saved on the server, by key.
    func appSettings() async throws -> [String: String] {
        Self.ownPrefs(in: try await settingsRecordJSON())
    }

    /// Saves settings on the server, keeping the others already there.
    func saveAppSettings(_ values: [String: String]) async throws {
        var record = try await settingsRecordJSON()
        record["CustomPrefs"] = Self.ownPrefs(in: record).merging(values) { _, new in new }
        let body = try JSONSerialization.data(withJSONObject: record)
        try await postRaw("/DisplayPreferences/\(Self.settingsRecord)", query: ["userId": try requireUser(), "client": Self.settingsClient], body: body)
    }

    // MARK: Tags

    /// The fields an item update writes back. Each is asked for when reading
    /// the item first, since one left out of the update would be cleared.
    private static let editableFields = "Tags,Overview,Genres,Studios,People,ProviderIds,DateCreated,Taglines,SortName,PremiereDate,ProductionYear,OfficialRating,CustomRating,LockedFields,LockData,ChildCount"

    /// Replaces an item's tags, leaving the rest of its metadata as it was:
    /// the full record is read and written back with only the tags changed.
    /// Needs a user allowed to edit metadata (an administrator).
    func setTags(_ tags: [String], onItem itemId: String) async throws {
        let user = try requireUser()
        let data = try await rawGet("/Users/\(user)/Items/\(itemId)", query: ["fields": Self.editableFields])
        guard var record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JellyfinError.decoding("The item's record wasn't readable")
        }
        record["Tags"] = tags
        try await postRaw("/Items/\(itemId)", body: try JSONSerialization.data(withJSONObject: record))
    }

    // MARK: Playlists

    /// The user's playlists of one media type ("Audio" or "Video").
    func playlists(mediaType: String) async throws -> [BaseItem] {
        try await items([
            "fields": Self.listFields + ",Tags",
            "includeItemTypes": "Playlist",
            "mediaTypes": mediaType,
            "recursive": "true",
            "sortBy": "SortName",
            "sortOrder": "Ascending",
        ]).items
    }

    /// Creates a playlist holding the items and returns its id.
    /// `isPublic` lets every user on the server see it (a genre Channel's).
    func createPlaylist(name: String, itemIds: [String], mediaType: String, isPublic: Bool? = nil) async throws -> String {
        let user = try requireUser()
        nonisolated struct Body: Encodable, Sendable {
            var Name: String
            var Ids: [String]
            var UserId: String
            var MediaType: String
            var IsPublic: Bool?
        }
        return try await post(PlaylistCreationResult.self, "/Playlists", body: Body(Name: name, Ids: itemIds, UserId: user, MediaType: mediaType, IsPublic: isPublic)).id
    }

    func addToPlaylist(_ playlistId: String, itemIds: [String]) async throws {
        let user = try requireUser()
        try await post("/Playlists/\(playlistId)/Items", query: ["ids": itemIds.joined(separator: ","), "userId": user])
    }

    /// Removes entries by their playlist entry ids, not item ids.
    func removeFromPlaylist(_ playlistId: String, entryIds: [String]) async throws {
        try await delete("/Playlists/\(playlistId)/Items", query: ["entryIds": entryIds.joined(separator: ",")])
    }

    func movePlaylistItem(_ playlistId: String, entryId: String, to newIndex: Int) async throws {
        try await post("/Playlists/\(playlistId)/Items/\(entryId)/Move/\(newIndex)")
    }

    // MARK: Theme media and lyrics

    /// Theme songs for a title, inheriting the series' for seasons and episodes.
    func themeSongs(itemId: String) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Items/\(itemId)/ThemeSongs", query: ["userId": user, "inheritFromParent": "true"]).items
    }

    func themeVideos(itemId: String) async throws -> [BaseItem] {
        let user = try requireUser()
        return try await get(ItemsResult.self, "/Items/\(itemId)/ThemeVideos", query: ["userId": user, "inheritFromParent": "true"]).items
    }

    /// A song's lyrics, or nil when the server has none.
    func lyrics(itemId: String) async throws -> Lyrics? {
        let request = authorizedRequest(url("/Audio/\(itemId)/Lyrics"))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(http.statusCode, nil)
        }
        return try await decode(Lyrics.self, from: data)
    }

    // MARK: Media segments

    /// The marker kinds the player offers to skip.
    private static let skippableSegmentTypes: Set<String> = ["Intro", "Outro", "Preview", "Recap", "Commercial"]

    /// Intro, credits and similar markers for an item, when a provider has made
    /// them. An empty list is the normal "nothing to skip", as is a 404.
    ///
    /// No `includeSegmentTypes` filter is sent: the server wants each type as
    /// its own repeated parameter and rejects a comma-joined list with a 400,
    /// so all markers are fetched and the skippable kinds kept here.
    func mediaSegments(itemId: String) async throws -> [MediaSegment] {
        let request = authorizedRequest(url("/MediaSegments/\(itemId)"))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return [] }
        if http.statusCode == 404 { return [] }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(http.statusCode, nil)
        }
        return try await decode(ItemsEnvelope<MediaSegment>.self, from: data).items
            .filter { Self.skippableSegmentTypes.contains($0.type) }
    }

    // MARK: JellyDisc

    /// The resolved disc menu for a movie, series or season, or nil when the
    /// server has none (404 is "nothing to show", never an error).
    func discMenu(for itemId: String) async throws -> DiscMenuDocument? {
        let request = authorizedRequest(url("/DiscMenus/\(itemId)/Menu"))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(http.statusCode, nil)
        }
        return try await decode(DiscMenuDocument.self, from: data)
    }

    func discAssetURL(path segments: [String]) -> URL {
        var url = baseURL
        for component in ["DiscMenus", "Assets"] + segments {
            url.appendPathComponent(component)
        }
        return url
    }

    func fanartURL(itemId: String, fanartId: String) -> URL {
        url("/DiscMenus/Fanart/\(itemId)/\(fanartId)")
    }

    func chapterImageURL(itemId: String, index: Int, stamp: Int64?) -> URL {
        url("/Items/\(itemId)/Images/Chapter/\(index)", query: [
            "maxWidth": "480",
            "tag": stamp.map(String.init),
        ])
    }

    /// A chapter's frame from Jellyfin's own chapter images, as JPEG for the
    /// player's chapter list.
    /// One sheet of a title's trickplay frames (see `TrickplayInfo`).
    func trickplayTileURL(itemId: String, width: Int, index: Int, mediaSourceId: String) -> URL {
        url("/Videos/\(itemId)/Trickplay/\(width)/\(index).jpg", query: ["MediaSourceId": mediaSourceId])
    }

    func chapterImageURL(itemId: String, index: Int, tag: String) -> URL {
        url("/Items/\(itemId)/Images/Chapter/\(index)", query: [
            "maxWidth": "480",
            "tag": tag,
            "format": "Jpg",
        ])
    }
}

/// Jellyfin's `{ Items: [...] }` wrapper for lists other than library items.
nonisolated struct ItemsEnvelope<Element: Decodable & Sendable>: Decodable, Sendable {
    var items: [Element]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

// MARK: - Device profile

nonisolated struct DeviceProfile: Encodable, Sendable {
    nonisolated struct DirectPlayProfile: Encodable, Sendable {
        var Container: String
        var kind: String
        var VideoCodec: String?
        var AudioCodec: String?

        enum CodingKeys: String, CodingKey {
            case Container, VideoCodec, AudioCodec
            case kind = "Type"
        }
    }

    nonisolated struct TranscodingProfile: Encodable, Sendable {
        var Container: String
        var kind: String
        var VideoCodec: String?
        var AudioCodec: String
        var Context: String = "Streaming"
        var `Protocol`: String
        var MaxAudioChannels: String = "6"
        var MinSegments: Int = 2
        var BreakOnNonKeyFrames: Bool = true
        var CopyTimestamps: Bool = false
        /// Off: subtitle renditions in the server's HLS playlists would show
        /// in the system menu and play 10 s late (Jellyfin issue 16647);
        /// the app draws subtitles itself instead.
        var EnableSubtitlesInManifest: Bool = false

        enum CodingKeys: String, CodingKey {
            case Container, VideoCodec, AudioCodec, Context, `Protocol`, MaxAudioChannels, MinSegments, BreakOnNonKeyFrames, CopyTimestamps, EnableSubtitlesInManifest
            case kind = "Type"
        }
    }

    nonisolated struct SubtitleProfile: Encodable, Sendable {
        var Format: String
        var Method: String
    }

    nonisolated struct CodecProfile: Encodable, Sendable {
        nonisolated struct Condition: Encodable, Sendable {
            var Condition: String
            var Property: String
            var Value: String
            var IsRequired: Bool = false
        }
        var kind: String
        var Codec: String?
        var Conditions: [Condition]

        enum CodingKeys: String, CodingKey {
            case Codec, Conditions
            case kind = "Type"
        }
    }

    var Name: String = "Aster Apple TV"
    var MaxStreamingBitrate: Int
    var MaxStaticBitrate: Int
    var MusicStreamingTranscodingBitrate: Int = 320_000
    var DirectPlayProfiles: [DirectPlayProfile]
    var TranscodingProfiles: [TranscodingProfile]
    var SubtitleProfiles: [SubtitleProfile]
    var CodecProfiles: [CodecProfile]

    static func appleTV(maxBitrate: Int) -> DeviceProfile {
        // Audio for fMP4 HLS. Codecs listed here are copied as they are, and
        // the first is what anything else (Opus, DTS, TrueHD) is re-encoded
        // to. Apple's HLS spec allows FLAC and ALAC, up to 7.1, in fMP4 only.
        // Lossless needs a few Mbps of headroom, so it leads only when the
        // quality setting leaves room; otherwise AAC keeps the video sharp.
        let losslessFirst = maxBitrate >= 20_000_000
        let fmp4Audio = losslessFirst ? "flac,alac,eac3,ac3,aac" : "aac,eac3,ac3,flac,alac"
        return DeviceProfile(
            MaxStreamingBitrate: maxBitrate,
            MaxStaticBitrate: maxBitrate,
            DirectPlayProfiles: [
                DirectPlayProfile(Container: "mp4,m4v,mov", kind: "Video", VideoCodec: "h264,hevc,mpeg4", AudioCodec: "aac,mp3,ac3,eac3,alac,flac"),
                DirectPlayProfile(Container: "mp3", kind: "Audio", VideoCodec: nil, AudioCodec: nil),
                DirectPlayProfile(Container: "m4a,m4b,aac", kind: "Audio", VideoCodec: nil, AudioCodec: "aac,alac"),
                DirectPlayProfile(Container: "flac", kind: "Audio", VideoCodec: nil, AudioCodec: nil),
                DirectPlayProfile(Container: "wav", kind: "Audio", VideoCodec: nil, AudioCodec: nil),
            ],
            TranscodingProfiles: [
                TranscodingProfile(Container: "mp4", kind: "Video", VideoCodec: "hevc,h264", AudioCodec: fmp4Audio, Protocol: "hls", MaxAudioChannels: "8"),
                // MPEG-TS can't carry FLAC or ALAC.
                TranscodingProfile(Container: "ts", kind: "Video", VideoCodec: "h264", AudioCodec: "aac,ac3,eac3", Protocol: "hls"),
                TranscodingProfile(Container: "aac", kind: "Audio", VideoCodec: nil, AudioCodec: "aac", Protocol: "hls"),
            ],
            // Text tracks are fetched separately and drawn by the app, so
            // they never force a transcode or get burned in. Picture-based
            // ones (PGS, VobSub) are not listed, which makes the server burn
            // them into the video when one is chosen.
            SubtitleProfiles: [
                SubtitleProfile(Format: "vtt", Method: "External"),
                SubtitleProfile(Format: "subrip", Method: "External"),
                SubtitleProfile(Format: "srt", Method: "External"),
                SubtitleProfile(Format: "ass", Method: "External"),
                SubtitleProfile(Format: "ssa", Method: "External"),
                SubtitleProfile(Format: "mov_text", Method: "External"),
                SubtitleProfile(Format: "ttml", Method: "External"),
                SubtitleProfile(Format: "cc_dec", Method: "Embed"),
            ],
            CodecProfiles: [
                CodecProfile(kind: "Video", Codec: "h264", Conditions: [
                    .init(Condition: "LessThanEqual", Property: "VideoLevel", Value: "52"),
                    .init(Condition: "NotEquals", Property: "IsAnamorphic", Value: "true"),
                ]),
                CodecProfile(kind: "Video", Codec: "hevc", Conditions: [
                    .init(Condition: "NotEquals", Property: "IsAnamorphic", Value: "true"),
                ]),
            ]
        )
    }

    /// Only what every Apple TV plays: a fresh 8-bit H.264 + AAC encode. Used
    /// when a direct or copied stream has already failed for a title.
    static func appleTVMostCompatible(maxBitrate: Int) -> DeviceProfile {
        var profile = appleTV(maxBitrate: maxBitrate)
        profile.Name = "Aster Apple TV (most compatible)"
        profile.DirectPlayProfiles = []
        profile.TranscodingProfiles = [
            TranscodingProfile(Container: "mp4", kind: "Video", VideoCodec: "h264", AudioCodec: "aac", Protocol: "hls"),
            TranscodingProfile(Container: "ts", kind: "Video", VideoCodec: "h264", AudioCodec: "aac", Protocol: "hls"),
            TranscodingProfile(Container: "aac", kind: "Audio", VideoCodec: nil, AudioCodec: "aac", Protocol: "hls"),
        ]
        profile.CodecProfiles = [
            CodecProfile(kind: "Video", Codec: "h264", Conditions: [
                .init(Condition: "LessThanEqual", Property: "VideoLevel", Value: "52"),
                .init(Condition: "LessThanEqual", Property: "VideoBitDepth", Value: "8"),
                .init(Condition: "NotEquals", Property: "IsAnamorphic", Value: "true"),
            ]),
        ]
        return profile
    }

    /// A file for offline viewing on a phone or tablet: always an HLS stream
    /// (so it downloads in segments and resumes), with stereo AAC, at most
    /// `maxWidth` pixels wide. The video is copied when it already fits.
    static func download(maxBitrate: Int, maxWidth: Int?, allowHEVC: Bool) -> DeviceProfile {
        var profile = appleTV(maxBitrate: maxBitrate)
        profile.Name = "Aster Download"
        profile.DirectPlayProfiles = []
        let videoCodecs = allowHEVC ? "hevc,h264" : "h264"
        profile.TranscodingProfiles = [
            TranscodingProfile(Container: "mp4", kind: "Video", VideoCodec: videoCodecs, AudioCodec: "aac", Protocol: "hls", MaxAudioChannels: "2"),
        ]
        let sizeLimit: [CodecProfile.Condition] = maxWidth.map {
            [.init(Condition: "LessThanEqual", Property: "Width", Value: String($0))]
        } ?? []
        profile.CodecProfiles = [
            CodecProfile(kind: "Video", Codec: "h264", Conditions: [
                .init(Condition: "LessThanEqual", Property: "VideoLevel", Value: "52"),
                .init(Condition: "NotEquals", Property: "IsAnamorphic", Value: "true"),
            ] + sizeLimit),
        ]
        if allowHEVC {
            profile.CodecProfiles.append(CodecProfile(kind: "Video", Codec: "hevc", Conditions: [
                .init(Condition: "NotEquals", Property: "IsAnamorphic", Value: "true"),
            ] + sizeLimit))
        }
        return profile
    }
}
