//
//  AnimeIds.swift
//  AsterFIN
//
//  Which AniList and MyAnimeList entry an episode belongs to. Those sites
//  list each season (each cour, often) apart, so it's the season's ids that
//  count: the AniList, MyAnimeList or AniDB id the server has for the
//  season (Shoko and the AniDB plugins give AniDB's), then the show's when
//  it has only the one season. AniDB ids become the others through ARM
//  (arm.haglund.dev, the anime-lists project's id map). With none known,
//  AniList is searched by the show's name and the year the season began.
//

import Foundation
import Synchronization

/// An entry on the anime sites.
nonisolated struct AnimeEntry: Hashable, Sendable {
    var aniList: Int?
    var myAnimeList: Int?
}

nonisolated enum AnimeIds {
    private static let found = Mutex<[String: AnimeEntry]>([:])

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// The entry for `episode`'s season (or a film's own), nil when it can't
    /// be found. Remembered per season for the launch.
    static func entry(for item: BaseItem, client: any MediaServer) async -> AnimeEntry? {
        let key = item.seasonId ?? item.id
        if let known = found.withLock({ $0[key] }) { return known }
        var candidates: [BaseItem] = []
        if item.kind == .movie {
            candidates = [(try? await client.item(item.id)) ?? item]
        } else {
            if let seasonId = item.seasonId, let season = try? await client.item(seasonId) { candidates.append(season) }
            if let seriesId = item.seriesId, let series = try? await client.item(seriesId) {
                // The show's ids are the first season's.
                if (item.parentIndexNumber ?? 1) <= 1 { candidates.append(series) }
            }
        }
        var entry: AnimeEntry?
        for candidate in candidates {
            if let byIds = await fromIds(candidate) {
                entry = byIds
                break
            }
        }
        if entry == nil {
            let name = item.kind == .movie ? item.displayTitle : (item.seriesName ?? item.displayTitle)
            let year = candidates.first?.productionYear ?? item.productionYear
            entry = await search(name, year: year, film: item.kind == .movie)
        }
        if let entry { found.withLock { $0[key] = entry } }
        return entry
    }

    private static func fromIds(_ item: BaseItem) async -> AnimeEntry? {
        let aniList = item.providerId("AniList").flatMap { Int($0) }
        let myAnimeList = item.providerId("MyAnimeList").flatMap { Int($0) }
        if aniList != nil || myAnimeList != nil {
            if aniList != nil, myAnimeList != nil { return AnimeEntry(aniList: aniList, myAnimeList: myAnimeList) }
            // The other from ARM, else as far as it goes.
            let source = aniList != nil ? "anilist" : "myanimelist"
            let mapped = await arm(source: source, id: aniList ?? myAnimeList!)
            return AnimeEntry(aniList: aniList ?? mapped?.aniList, myAnimeList: myAnimeList ?? mapped?.myAnimeList)
        }
        if let aniDB = item.providerId("AniDB").flatMap({ Int($0) }) {
            return await arm(source: "anidb", id: aniDB)
        }
        return nil
    }

    /// ARM's other ids for one site's.
    private static func arm(source: String, id: Int) async -> AnimeEntry? {
        guard let url = URL(string: "https://arm.haglund.dev/api/v2/ids?source=\(source)&id=\(id)") else { return nil }
        struct Reply: Decodable { var anilist: Int?; var myanimelist: Int? }
        guard let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.anilist != nil || reply.myanimelist != nil else { return nil }
        return AnimeEntry(aniList: reply.anilist, myAnimeList: reply.myanimelist)
    }

    /// AniList's best match for a name, from the season's year when known.
    private static func search(_ name: String, year: Int?, film: Bool) async -> AnimeEntry? {
        let query = "query($search:String,$year:Int,$format:MediaFormat){Media(search:$search,type:ANIME,seasonYear:$year,format:$format){id idMal}}"
        var variables: [String: AniListValue] = ["search": .string(name)]
        if let year { variables["year"] = .int(year) }
        if film { variables["format"] = .string("MOVIE") }
        struct Reply: Decodable {
            struct DataPart: Decodable { var Media: Media? }
            struct Media: Decodable { var id: Int; var idMal: Int? }
            var data: DataPart?
        }
        guard let data = try? await AniList.request(query, variables: variables, token: nil),
              let media = (try? JSONDecoder().decode(Reply.self, from: data))?.data?.Media else {
            // A year can be off by one (a season over New Year): once without it.
            return year != nil ? await search(name, year: nil, film: film) : nil
        }
        return AnimeEntry(aniList: media.id, myAnimeList: media.idMal)
    }
}
