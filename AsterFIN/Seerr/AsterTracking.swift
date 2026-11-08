//
//  AsterTracking.swift
//  AsterFIN
//
//  The Aster Discovery and Tracking plugin on the Jellyfin server, which
//  holds discovery and tracking for every Aster app (the contract is
//  AsterMediaPlayer/.github docs/aster-tracking-clients.md). Seerr is
//  reached through it, as the signed-in person, so no app signs in to Seerr;
//  and the server builds each person's Discover page. A server without the
//  plugin (Plex, or Jellyfin without it) shows none of this.
//

import Foundation

/// What `GET /AsterTracking/Features` says.
nonisolated struct TrackingFeatures: Decodable, Sendable, Equatable {
    struct SeerrFeature: Decodable, Sendable, Equatable {
        var enabled: Bool
        /// "/AsterTracking/Seerr/api/v1": Seerr's own API, under the server.
        var proxy: String?
    }
    var seerr: SeerrFeature?
    /// What people can link on this server (simkl, anilist, myanimelist, …).
    var services: [String]?
    /// The services whose watchlist the apps can add to (plugin 0.9.8);
    /// nil from an older plugin, which has none.
    var watchlist: [String]?

    /// The plugin's JSON is PascalCase, read here case-insensitively.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            return AnyKey(stringValue: key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }()
}

/// A coding key for any name.
nonisolated struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

@MainActor
@Observable
final class AsterTracking {
    static let shared = AsterTracking()

    /// Nil while there's no plugin (or not yet known).
    private(set) var features: TrackingFeatures?
    /// Seerr, as the signed-in person; nil unless the server turned it on.
    private(set) var seerr: SeerrAccount?
    /// Whether the plugin has been asked yet, for this server.
    private(set) var checked = false
    private var checkedAt: Date?

    /// Whether this server has the plugin, which gives it Discover's rows.
    var isPresent: Bool { features != nil }

    /// Whether the server's plugin sends this service's updates (simkl,
    /// anilist, myanimelist, lastfm, listenbrainz, hardcover), so the app
    /// doesn't send them itself: never both for one person.
    func serves(_ service: String) -> Bool {
        features?.services?.contains { $0.caseInsensitiveCompare(service) == .orderedSame } ?? false
    }

    /// Asks the server what it has: once after sign-in, and again when the
    /// app comes back after a long while. A Plex server, or none, clears it.
    func refresh(session: AppSession, force: Bool = false) async {
        guard let jellyfin = session.jellyfin, session.serverKind == .jellyfin else {
            clear()
            checked = true
            return
        }
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < 30 * 60, checked { return }
        var request = jellyfin.authorizedRequest(jellyfin.baseURL.appending(path: "AsterTracking/Features"))
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                let found = try TrackingFeatures.decoder.decode(TrackingFeatures.self, from: data)
                features = found
                DebugLog.note("tracking", "Plugin present; Seerr \(found.seerr?.enabled == true ? "on" : "off"), services \(found.services?.joined(separator: ",") ?? "none"), watchlist \(found.watchlist?.joined(separator: ",") ?? "none (plugin before 0.9.8)")")
            case 404:
                // No plugin, which counts as Seerr off and no Discover lists.
                features = nil
                DebugLog.note("tracking", "No plugin on this server")
            default:
                // Anything else: as 404 for now, but a 200 got earlier in this
                // session isn't forgotten.
                DebugLog.note("tracking", "Features answered \(status)")
            }
        } catch {
            DebugLog.note("tracking", "Features failed: \(error.localizedDescription)")
        }
        checked = true
        checkedAt = Date()
        await updateSeerr(jellyfin)
    }

    /// Seerr's "account": the plugin's address, and the Jellyfin header.
    private func updateSeerr(_ jellyfin: JellyfinClient) async {
        guard let feature = features?.seerr, feature.enabled else {
            seerr = nil
            return
        }
        let account = SeerrAccount(base: Self.seerrBase(server: jellyfin.baseURL, proxy: feature.proxy),
                                   authorization: jellyfin.authorizationHeader, name: "", userId: 0)
        do {
            let me = try await SeerrClient.me(account: account)
            seerr = SeerrAccount(base: account.url, authorization: account.authorization, name: me.displayName ?? "", userId: me.id)
        } catch SeerrError.off {
            seerr = nil
        } catch {
            // Seerr briefly out of reach: kept, to try again as pages ask.
            DebugLog.note("tracking", "Seerr's user couldn't be read: \(error.localizedDescription)")
            seerr = account
        }
    }

    /// "{server}/AsterTracking/Seerr": where Seerr's `/api/v1/…` paths go on.
    nonisolated static func seerrBase(server: URL, proxy: String?) -> URL {
        var path = proxy ?? "/AsterTracking/Seerr/api/v1"
        if path.hasSuffix("/api/v1") { path.removeLast("/api/v1".count) }
        while path.hasSuffix("/") { path.removeLast() }
        var base = server.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + (path.hasPrefix("/") ? path : "/" + path)) ?? server
    }

    /// The server turned a Seerr call down as signed out: its own sign-in has
    /// run out, which the app handles everywhere, so only noted here.
    func noteRefused() {
        DebugLog.note("tracking", "Seerr refused the server's sign-in")
    }

    func clear() {
        features = nil
        seerr = nil
        checked = false
        checkedAt = nil
    }
}
