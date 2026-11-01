//
//  TitleScores.swift
//  AsterFIN
//
//  A title's scores from the sites that give them, each written as that
//  site writes it: IMDb 7.8, Rotten Tomatoes' Tomatometer and audience
//  score as percentages (fresh or rotten at 60%), the Metascore out of 100
//  coloured as Metacritic does, Letterboxd out of five, TMDB as a
//  percentage. Some come with the title from the server (Jellyfin's critic
//  score is the Tomatometer; Plex's title pages carry IMDb, Rotten Tomatoes
//  and TMDB); with an MDBList key in Settings, MDBList adds the rest.
//

import Foundation
import Synchronization
import SwiftUI

/// One site's score for a title, on a 0 to 10 scale.
nonisolated struct TitleScore: Hashable, Sendable {
    enum Source: String, Sendable, CaseIterable {
        case tomatometer, popcorn, imdb, tmdb, metacritic, letterboxd
        /// The server's own score, unattributed.
        case community
    }

    var source: Source
    var value: Double

    /// A score on the site's own scale (10 for IMDb, 100 for percentages,
    /// 5 for Letterboxd), as long as it's a score: missing, zero (sites write
    /// it for "not rated yet") or out of range isn't.
    init?(_ source: Source, _ value: Double?, outOf scale: Double) {
        guard let value, value.isFinite, value > 0, value <= scale else { return nil }
        self.source = source
        self.value = value * 10 / scale
    }

    /// As the site writes it: "7.8", "92%", "74", "3.9".
    var text: String {
        switch source {
        case .imdb, .community: String(format: "%.1f", value)
        case .tomatometer, .popcorn, .tmdb: "\(Int((value * 10).rounded()))%"
        case .metacritic: "\(Int((value * 10).rounded()))"
        case .letterboxd: String(format: "%.1f", value / 2)
        }
    }

    var siteName: String {
        switch source {
        case .tomatometer: "Rotten Tomatoes"
        case .popcorn: "Rotten Tomatoes audience score"
        case .imdb: "IMDb"
        case .tmdb: "TMDB"
        case .metacritic: "Metacritic"
        case .letterboxd: "Letterboxd"
        case .community: "Rating"
        }
    }

    /// The Tomatometer's own line between fresh and rotten.
    var isFresh: Bool { value >= 6 }

    /// The order they show in.
    static func ordered(_ scores: [TitleScore]) -> [TitleScore] {
        let order = Source.allCases
        return scores.sorted { order.firstIndex(of: $0.source)! < order.firstIndex(of: $1.source)! }
    }

    /// `own` (the server's) with `added` (MDBList's) over it: a site's score
    /// from MDBList replaces the server's copy, which is whatever its
    /// metadata agent last fetched. The server's unattributed score goes once
    /// there's a real one.
    static func merged(_ own: [TitleScore], _ added: [TitleScore]) -> [TitleScore] {
        guard !added.isEmpty else { return ordered(own) }
        let covered = Set(added.map(\.source))
        let kept = own.filter { !covered.contains($0.source) && $0.source != .community }
        return ordered(added + kept)
    }
}

nonisolated extension BaseItem {
    /// The scores the server sent with the title: Jellyfin's and Emby's
    /// critic score is the Tomatometer, their community score unattributed;
    /// Plex's are attributed on its title pages (see `PlexMapper`).
    var serverScores: [TitleScore] {
        if let scores { return TitleScore.ordered(scores) }
        return [
            TitleScore(.tomatometer, criticRating, outOf: 100),
            TitleScore(.community, communityRating, outOf: 10),
        ].compactMap { $0 }
    }
}

// MARK: - MDBList

/// Scores for a film or show from MDBList (mdblist.com), which gathers them
/// from IMDb, Rotten Tomatoes, Metacritic, Letterboxd and TMDB daily. Needs
/// the viewer's own free API key; asked once per title for twelve hours.
nonisolated enum MDBList {
    private static let cache = Mutex<[String: (scores: [TitleScore], at: Date)]>([:])
    private static let life: TimeInterval = 12 * 60 * 60

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    /// The key, kept in the Keychain; nil when none's been given.
    static var apiKey: String? {
        get {
            Keychain.load(account: "mdblistKey").flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                Keychain.delete(account: "mdblistKey")
            } else {
                Keychain.save(Data(trimmed.utf8), account: "mdblistKey")
            }
            cache.withLock { $0 = [:] }
        }
    }

    /// The title's scores, by its TMDB, IMDb or TVDB id; empty without a key,
    /// for anything but a film or show, or when MDBList doesn't know it.
    static func scores(for item: BaseItem) async -> [TitleScore] {
        guard let key = apiKey, let lookup = lookup(for: item) else { return [] }
        let cacheKey = "\(lookup.provider)/\(lookup.type)/\(lookup.id)"
        if let kept = cache.withLock({ $0[cacheKey] }), Date().timeIntervalSince(kept.at) < life { return kept.scores }
        var components = URLComponents(string: "https://api.mdblist.com/\(lookup.provider)/\(lookup.type)/\(lookup.id)")
        components?.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else { return [] }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A failure isn't kept, so the next visit asks again; "not known" is.
        guard status == 200 || status == 404 else {
            #if DEBUG
            print("DEBUG mdblist: \(cacheKey) -> \(status)")
            #endif
            return []
        }
        let scores = status == 200 ? parse(data) : []
        cache.withLock { $0[cacheKey] = (scores, Date()) }
        return scores
    }

    /// Which id MDBList is asked by: TMDB first, then IMDb, then TVDB.
    static func lookup(for item: BaseItem) -> (provider: String, type: String, id: String)? {
        let type: String
        switch item.kind {
        case .movie: type = "movie"
        case .series: type = "show"
        default: return nil
        }
        if let id = item.providerId("Tmdb") { return ("tmdb", type, id) }
        if let id = item.providerId("Imdb") { return ("imdb", type, id) }
        if let id = item.providerId("Tvdb"), type == "show" { return ("tvdb", type, id) }
        return nil
    }

    /// The `ratings` of a reply, each `value` on its site's own scale.
    static func parse(_ data: Data) -> [TitleScore] {
        struct Reply: Decodable {
            struct Rating: Decodable { var source: String; var value: Double? }
            var ratings: [Rating]?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return [] }
        return (reply.ratings ?? []).compactMap { rating in
            switch rating.source.lowercased() {
            case "imdb": TitleScore(.imdb, rating.value, outOf: 10)
            case "tomatoes": TitleScore(.tomatometer, rating.value, outOf: 100)
            case "popcorn", "tomatoesaudience": TitleScore(.popcorn, rating.value, outOf: 100)
            case "metacritic": TitleScore(.metacritic, rating.value, outOf: 100)
            case "letterboxd": TitleScore(.letterboxd, rating.value, outOf: 5)
            case "tmdb": TitleScore(.tmdb, rating.value, outOf: 100)
            default: nil
            }
        }
    }
}

// MARK: - Badges

/// A title's scores in a row, each with its site's mark.
struct TitleScoreRow: View {
    let scores: [TitleScore]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(scores, id: \.source) { score in
                TitleScoreBadge(score: score)
            }
        }
    }
}

struct TitleScoreBadge: View {
    let score: TitleScore

    var body: some View {
        HStack(spacing: 5) {
            mark
            Text(score.text).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(score.siteName) \(score.text)")
    }

    @ViewBuilder
    private var mark: some View {
        switch score.source {
        case .imdb:
            Text("IMDb")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.96, green: 0.77, blue: 0.09)))
        case .tomatometer:
            Text(score.isFresh ? "🍅" : "🟢").font(.caption)
        case .popcorn:
            Text("🍿").font(.caption).opacity(score.isFresh ? 1 : 0.6)
        case .metacritic:
            // Metacritic's own colours: green from 61, yellow from 40, else red.
            let metascore = score.value * 10
            RoundedRectangle(cornerRadius: 3)
                .fill(metascore >= 61 ? Color(red: 0.4, green: 0.8, blue: 0.2) : metascore >= 40 ? Color(red: 1, green: 0.8, blue: 0.2) : Color(red: 1, green: 0, blue: 0))
                .frame(width: 10, height: 10)
                .overlay(Text("M").font(.system(size: 7, weight: .black)).foregroundStyle(.black))
        case .letterboxd:
            HStack(spacing: 1) {
                Circle().fill(Color(red: 1, green: 0.5, blue: 0)).frame(width: 7, height: 7)
                Circle().fill(Color(red: 0, green: 0.88, blue: 0.33)).frame(width: 7, height: 7)
                Circle().fill(Color(red: 0.25, green: 0.74, blue: 0.96)).frame(width: 7, height: 7)
            }
        case .tmdb:
            Text("TMDB")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Color(red: 0.0, green: 0.82, blue: 0.69))
        case .community:
            Image(systemName: "star.fill").font(.caption)
        }
    }
}
