//
//  PlexAccount.swift
//  AsterFIN
//
//  Signing in through plex.tv: a link code the viewer enters at
//  plex.tv/link, the account's servers (its own and friends' shared ones,
//  each with its own token and addresses), and Plex Home users to pick
//  from, some behind a PIN.
//

import Foundation

/// A link code: shown to the viewer, then asked about until plex.tv says
/// it was entered.
nonisolated struct PlexPin: Codable, Sendable, Equatable {
    var id: Int
    var code: String
    /// Set once the code has been entered at plex.tv/link.
    var authToken: String?
    /// Seconds the code lasts.
    var expiresIn: Int?
}

/// A plex.tv account, or a Home user switched to.
nonisolated struct PlexAccountUser: Codable, Sendable, Equatable {
    var id: Int
    var uuid: String
    var username: String?
    var title: String?
    var thumb: String?
    var authToken: String?

    var displayName: String { title ?? username ?? "Plex" }
}

/// One of the account's devices that is a server.
nonisolated struct PlexResource: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var clientIdentifier: String
    var provides: String?
    var productVersion: String?
    /// The token for this server, for this account: a shared server's is
    /// its own, not the account's.
    var accessToken: String?
    var owned: Bool?
    var connections: [Connection]

    var id: String { clientIdentifier }
    var isServer: Bool { provides?.split(separator: ",").contains("server") == true }

    nonisolated struct Connection: Codable, Sendable, Equatable {
        var uri: String
        var address: String?
        var port: Int?
        var local: Bool?
        var relay: Bool?
    }

    /// Its connections, best first: on the home network, then over the
    /// internet, then through Plex's relay. Each home-network address is
    /// also tried as plain HTTP by its number, as Plex's own apps do: the
    /// secure `plex.direct` name needs a lookup that a home router can be
    /// slow with, or refuse.
    var rankedConnections: [PlexConnectionInfo] {
        var all: [PlexConnectionInfo] = []
        for connection in connections {
            guard let uri = URL(string: connection.uri) else { continue }
            let local = connection.local ?? false
            all.append(PlexConnectionInfo(uri: uri, local: local, relay: connection.relay ?? false))
            if local, uri.scheme == "https", let address = connection.address, let port = connection.port,
               let plain = URL(string: "http://\(address):\(port)") {
                all.append(PlexConnectionInfo(uri: plain, local: true, relay: false))
            }
        }
        // Stable: within a rank, plex.tv's order (secure first) is kept.
        return all.enumerated()
            .sorted { (PlexConnectionRace.rank($0.element), $0.offset) < (PlexConnectionRace.rank($1.element), $1.offset) }
            .map(\.element)
    }
}

/// A Plex Home's people.
nonisolated struct PlexHomeUser: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var uuid: String
    var title: String
    var username: String?
    var thumb: String?
    var admin: Bool?
    var restricted: Bool?
    /// A PIN is asked before switching to them.
    var `protected`: Bool?
}

nonisolated enum PlexAccount {
    static let base = URL(string: "https://plex.tv")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private static func send<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET",
                                           query: [String: String] = [:], token: String?) async throws -> T {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        for (name, value) in PlexDevice.headers(token: token) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlexError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A new link code to show.
    static func startLink() async throws -> PlexPin {
        try await send(PlexPin.self, "api/v2/pins", method: "POST", query: ["strong": "false"], token: nil)
    }

    /// The account's token once the code has been entered; nil until then.
    static func linkedToken(for pin: PlexPin) async throws -> String? {
        try await send(PlexPin.self, "api/v2/pins/\(pin.id)", token: nil).authToken
    }

    static func account(token: String) async throws -> PlexAccountUser {
        try await send(PlexAccountUser.self, "api/v2/user", token: token)
    }

    /// The servers this account can use, its own first.
    static func servers(token: String) async throws -> [PlexResource] {
        let resources = try await send([PlexResource].self, "api/v2/resources",
                                       query: ["includeHttps": "1", "includeRelay": "1"], token: token)
        return resources.filter(\.isServer).sorted { ($0.owned ?? false) && !($1.owned ?? false) }
    }

    /// The account's Home users; none for an account without a Home.
    static func homeUsers(token: String) async -> [PlexHomeUser] {
        nonisolated struct Home: Decodable { var users: [PlexHomeUser] }
        return (try? await send(Home.self, "api/v2/home/users", token: token).users) ?? []
    }

    /// Switches to a Home user, with their PIN if they have one: their own
    /// account token.
    static func switchUser(_ user: PlexHomeUser, pin: String?, token: String) async throws -> PlexAccountUser {
        var query: [String: String] = [:]
        if let pin { query["pin"] = pin }
        return try await send(PlexAccountUser.self, "api/v2/home/users/\(user.uuid)/switch", method: "POST", query: query, token: token)
    }
}

/// Finds which of a server's addresses answers. All are tried at once:
/// a server can list a dozen addresses (one per network it's on), most of
/// which don't answer from here, and one at a time would take minutes.
nonisolated enum PlexConnectionRace {
    /// Home network first, then the internet, then Plex's relay.
    static func rank(_ connection: PlexConnectionInfo) -> Int {
        connection.relay ? 2 : (connection.local ? 0 : 1)
    }

    /// The best address that answers, or nil if none does. A home-network
    /// one is taken as soon as it answers; otherwise every address gets
    /// its chance, and the best of those that answered wins.
    static func fastest(_ connections: [PlexConnectionInfo], token: String, timeout: TimeInterval = 10) async -> PlexConnectionInfo? {
        await withTaskGroup(of: PlexConnectionInfo?.self) { group in
            for connection in connections {
                group.addTask { await answers(connection.uri, token: token, timeout: timeout) ? connection : nil }
            }
            var best: PlexConnectionInfo?
            for await answered in group {
                guard let answered else { continue }
                if rank(answered) == 0 {
                    group.cancelAll()
                    return answered
                }
                if best == nil || rank(answered) < rank(best!) { best = answered }
            }
            return best
        }
    }

    private static func answers(_ uri: URL, token: String, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: uri.appending(path: "identity"), timeoutInterval: timeout)
        for (name, value) in PlexDevice.headers(token: token) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
