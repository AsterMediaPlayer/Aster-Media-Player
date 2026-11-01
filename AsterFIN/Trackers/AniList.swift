//
//  AniList.swift
//  AsterFIN
//
//  AniList (anilist.co): signing in by its implicit grant (a year-long
//  token, no secret), and an episode's progress written to the viewer's
//  list, through its GraphQL API.
//

import Foundation

/// A GraphQL variable's value.
nonisolated enum AniListValue: Encodable, Sendable {
    case string(String)
    case int(Int)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

nonisolated enum AniList {
    static let redirect = "aster://anilist-auth"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    /// Where the viewer signs in; the token comes back in the redirect's fragment.
    static var signInURL: URL? {
        guard !TrackerKeys.aniListClientId.isEmpty else { return nil }
        return URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=\(TrackerKeys.aniListClientId)&response_type=token")
    }

    /// The token in a sign-in's redirect ("#access_token=…&expires_in=…").
    static func token(fromRedirect url: URL) -> (token: String, expires: Date?)? {
        guard let fragment = url.fragment else { return nil }
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        guard let token = values["access_token"], !token.isEmpty else { return nil }
        let expires = values["expires_in"].flatMap(Double.init).map { Date().addingTimeInterval($0) }
        return (token, expires)
    }

    static func request(_ query: String, variables: [String: AniListValue] = [:], token: String?) async throws -> Data {
        struct Body: Encodable { var query: String; var variables: [String: AniListValue] }
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Body(query: query, variables: variables))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw TrackerError.signedOut }
        guard status == 200 else { throw TrackerError.http(status) }
        return data
    }

    /// The signed-in viewer's name.
    static func viewerName(token: String) async throws -> String {
        struct Reply: Decodable {
            struct DataPart: Decodable { var Viewer: Viewer? }
            struct Viewer: Decodable { var name: String }
            var data: DataPart?
        }
        let data = try await request("{Viewer{name}}", token: token)
        guard let name = try JSONDecoder().decode(Reply.self, from: data).data?.Viewer?.name else { throw TrackerError.badReply }
        return name
    }

    /// Episode `number` of `mediaId` watched: progress set to it (never
    /// lowered) and the entry Watching, or Completed at the last episode.
    static func watched(mediaId: Int, episode number: Int, token: String) async throws -> TrackerUpdate {
        struct Reply: Decodable {
            struct DataPart: Decodable { var Media: Media? }
            struct Media: Decodable {
                var episodes: Int?
                var mediaListEntry: Entry?
            }
            struct Entry: Decodable { var progress: Int?; var status: String? }
            var data: DataPart?
        }
        let lookup = try await request("query($id:Int){Media(id:$id,type:ANIME){episodes mediaListEntry{progress status}}}",
                                       variables: ["id": .int(mediaId)], token: token)
        let media = try JSONDecoder().decode(Reply.self, from: lookup).data?.Media
        let progress = media?.mediaListEntry?.progress ?? 0
        let status = media?.mediaListEntry?.status
        guard number > progress || status == nil || status == "PLANNING" else { return .unchanged }
        let total = media?.episodes
        let newProgress = max(number, progress)
        let done = total.map { newProgress >= $0 } ?? false
        // A rewatch stays a rewatch until it's done.
        let newStatus = done ? "COMPLETED" : (status == "REPEATING" ? "REPEATING" : "CURRENT")
        _ = try await request("mutation($id:Int,$progress:Int,$status:MediaListStatus){SaveMediaListEntry(mediaId:$id,progress:$progress,status:$status){id}}",
                              variables: ["id": .int(mediaId), "progress": .int(newProgress), "status": .string(newStatus)], token: token)
        return done ? .completed(newProgress) : .progress(newProgress)
    }
}
