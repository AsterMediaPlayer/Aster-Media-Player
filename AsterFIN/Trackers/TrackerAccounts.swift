//
//  TrackerAccounts.swift
//  AsterFIN
//
//  The viewer's tracking accounts (AniList, MyAnimeList), and their
//  watching sent to them. A sign-in made on any Aster app reaches the
//  others through the media server: kept scrambled in Aster's display
//  preferences on Jellyfin and Emby, or in the description of an empty
//  playlist of the Plex user's own on Plex, and on the device too, so it
//  works when the server can't be reached. TVs, which can't show a sign-in
//  page, take what the phone and computer apps signed in to.
//
//  The scrambling (AES-GCM, key from HKDF-SHA256) keeps tokens out of plain
//  sight on the server. Its key is in Aster's open source, so it isn't
//  secrecy from someone with both the server's data and the code. The
//  tokens can only edit the viewer's lists on those sites. Format, for the
//  other Aster apps: "aster1:" + base64(nonce ‖ ciphertext ‖ tag), the key
//  HKDF-SHA256(ikm: `scramble`, salt: the server user's id lowercased
//  without dashes, info: "aster-trackers", 32 bytes), the plaintext the
//  `TrackerSecrets` JSON.
//

import CryptoKit
import Foundation
import Synchronization

nonisolated enum TrackerError: LocalizedError, Equatable {
    case signedOut
    case http(Int)
    case badReply

    var errorDescription: String? {
        switch self {
        case .signedOut: "The sign-in has run out. Sign in again."
        case .http(let code): "The service answered \(code)."
        case .badReply: "The service's answer couldn't be read."
        }
    }
}

/// What an update did.
nonisolated enum TrackerUpdate: Equatable, Sendable {
    case unchanged
    case progress(Int)
    case completed(Int)
    /// Added to a history (Trakt, Simkl).
    case watched
}

/// The accounts, as kept and synced.
nonisolated struct TrackerSecrets: Codable, Sendable, Equatable {
    struct AniListAccount: Codable, Sendable, Equatable {
        var token: String
        var name: String
        var expires: Date?
    }

    struct MyAnimeListAccount: Codable, Sendable, Equatable {
        var tokens: MyAnimeList.Tokens
        var name: String
    }

    struct TraktAccount: Codable, Sendable, Equatable {
        var tokens: Trakt.Tokens
        var name: String
    }

    struct SimklAccount: Codable, Sendable, Equatable {
        var token: String
        var name: String
    }

    var aniList: AniListAccount?
    var myAnimeList: MyAnimeListAccount?
    var trakt: TraktAccount?
    var simkl: SimklAccount?
    /// When last changed anywhere: the newer copy wins.
    var updated: Date = .distantPast
}

nonisolated enum TrackerVault {
    static let prefix = "aster1:"
    /// Shared by every Aster app (see the format above).
    private static let scramble = "Aster Media Player tracker accounts, scrambled on the media server. v1"

    private static func key(user: String) -> SymmetricKey {
        let salt = user.lowercased().replacingOccurrences(of: "-", with: "")
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(scramble.utf8)),
                                      salt: Data(salt.utf8), info: Data("aster-trackers".utf8), outputByteCount: 32)
    }

    static func seal(_ secrets: TrackerSecrets, user: String) -> String? {
        guard let plain = try? JSONEncoder.trackers.encode(secrets),
              let combined = try? AES.GCM.seal(plain, using: key(user: user)).combined else { return nil }
        return prefix + combined.base64EncodedString()
    }

    static func open(_ text: String, user: String) -> TrackerSecrets? {
        guard text.hasPrefix(prefix), let combined = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key(user: user)) else { return nil }
        return try? JSONDecoder.trackers.decode(TrackerSecrets.self, from: plain)
    }
}

nonisolated extension JSONEncoder {
    static var trackers: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

nonisolated extension JSONDecoder {
    static var trackers: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
@Observable
final class TrackerAccounts {
    static let shared = TrackerAccounts()

    private(set) var secrets = TrackerSecrets()
    /// The last thing sent, for Settings: "Beastars: episode 5 on AniList".
    private(set) var lastUpdate: String?
    /// An account that needs signing in again, by its service's name.
    private(set) var needsSignIn: Set<String> = []

    /// Whose accounts these are: the server and its user.
    private var owner: String?
    private var client: (any MediaServer)?
    private var userId: String?
    /// What was sent lately, so an episode stopped twice is sent once.
    private var recent: [String: Date] = [:]

    static var isAvailable: Bool {
        !TrackerKeys.aniListClientId.isEmpty || !TrackerKeys.myAnimeListClientId.isEmpty || TrackerKeys.hasTrakt || TrackerKeys.hasSimkl
    }
    var isSignedIn: Bool { secrets.aniList != nil || secrets.myAnimeList != nil || secrets.trakt != nil || secrets.simkl != nil }

    // MARK: Keeping

    /// The accounts of `userId` on `client`'s server: this device's copy,
    /// then the server's when it's newer (or this one's sent up when it is).
    func load(client: any MediaServer, userId: String) async {
        let owner = "\(client.baseURL.absoluteString)|\(userId)"
        if owner != self.owner {
            self.owner = owner
            secrets = Self.local(owner) ?? TrackerSecrets()
            needsSignIn = []
        }
        self.client = client
        self.userId = userId
        guard let blob = await Self.readServer(client), let server = TrackerVault.open(blob, user: userId) else {
            if isSignedIn { await writeServer() }
            return
        }
        if server.updated > secrets.updated {
            secrets = server
            Self.keepLocal(secrets, owner: owner)
        } else if secrets.updated > server.updated {
            await writeServer()
        }
    }

    private func change(_ edit: (inout TrackerSecrets) -> Void) {
        edit(&secrets)
        secrets.updated = Date()
        if let owner { Self.keepLocal(secrets, owner: owner) }
        Task { await writeServer() }
    }

    private func writeServer() async {
        guard let client, let userId, let blob = TrackerVault.seal(secrets, user: userId) else { return }
        await Self.writeServer(blob, client: client)
    }

    private static func local(_ owner: String) -> TrackerSecrets? {
        Keychain.load(account: "trackers|\(owner)").flatMap { try? JSONDecoder.trackers.decode(TrackerSecrets.self, from: $0) }
    }

    private static func keepLocal(_ secrets: TrackerSecrets, owner: String) {
        if let data = try? JSONEncoder.trackers.encode(secrets) { Keychain.save(data, account: "trackers|\(owner)") }
    }

    private static func readServer(_ client: any MediaServer) async -> String? {
        if let jellyfin = client as? JellyfinClient { return try? await jellyfin.appSettings()["trackers"] }
        if let plex = client as? PlexClient { return await plex.asterSettingsNote() }
        return nil
    }

    private static func writeServer(_ blob: String, client: any MediaServer) async {
        if let jellyfin = client as? JellyfinClient {
            try? await jellyfin.saveAppSettings(["trackers": blob])
        } else if let plex = client as? PlexClient {
            await plex.setAsterSettingsNote(blob)
        }
    }

    // MARK: Accounts

    func signedInToAniList(token: String, expires: Date?) async throws {
        let name = try await AniList.viewerName(token: token)
        needsSignIn.remove("AniList")
        change { $0.aniList = .init(token: token, name: name, expires: expires) }
    }

    func signedInToMyAnimeList(_ tokens: MyAnimeList.Tokens) async throws {
        let name = try await MyAnimeList.userName(token: tokens.access)
        needsSignIn.remove("MyAnimeList")
        change { $0.myAnimeList = .init(tokens: tokens, name: name) }
    }

    func signedInToTrakt(_ tokens: Trakt.Tokens) async throws {
        let name = try await Trakt.userName(token: tokens.access)
        needsSignIn.remove("Trakt")
        change { $0.trakt = .init(tokens: tokens, name: name) }
    }

    func signedInToSimkl(token: String) async throws {
        let name = try await Simkl.userName(token: token)
        needsSignIn.remove("Simkl")
        change { $0.simkl = .init(token: token, name: name) }
    }

    func signOutOfTrakt() {
        needsSignIn.remove("Trakt")
        change { $0.trakt = nil }
    }

    func signOutOfSimkl() {
        needsSignIn.remove("Simkl")
        change { $0.simkl = nil }
    }

    /// Trakt's token, refreshed when it has under a day left.
    private func traktToken() async throws -> String? {
        guard var account = secrets.trakt else { return nil }
        if account.tokens.expires.timeIntervalSinceNow < 24 * 60 * 60 {
            account.tokens = try await Trakt.refreshed(account.tokens)
            let refreshed = account
            change { $0.trakt = refreshed }
        }
        return account.tokens.access
    }

    func signOutOfAniList() {
        needsSignIn.remove("AniList")
        change { $0.aniList = nil }
    }

    func signOutOfMyAnimeList() {
        needsSignIn.remove("MyAnimeList")
        change { $0.myAnimeList = nil }
    }

    /// MyAnimeList's token, refreshed when it has under a day left.
    private func myAnimeListToken() async throws -> String? {
        guard var account = secrets.myAnimeList else { return nil }
        if account.tokens.expires.timeIntervalSinceNow < 24 * 60 * 60 {
            account.tokens = try await MyAnimeList.refreshed(account.tokens)
            let refreshed = account
            change { $0.myAnimeList = refreshed }
        }
        return account.tokens.access
    }

    // MARK: Watching

    /// A video stopped: when it was an anime episode or film watched past
    /// 85%, it's marked on each account. Called with every stop report.
    func stopped(_ report: PlaybackReport, client: any MediaServer) {
        guard isSignedIn, AppSettings.trackWatching else { return }
        Task { await send(report, client: client) }
    }

    private func send(_ report: PlaybackReport, client: any MediaServer) async {
        guard let item = try? await client.item(report.itemId),
              item.kind == .episode || item.kind == .movie,
              let length = item.runTimeTicks, length > 0,
              Double(report.positionTicks) >= Double(length) * 0.85 else { return }
        if let sent = recent[item.id], Date().timeIntervalSince(sent) < 6 * 60 * 60 { return }
        recent[item.id] = Date()
        let title = item.seriesName ?? item.displayTitle
        let show = item.kind == .episode ? await item.seriesId.asyncMap { try? await client.item($0) } ?? nil : nil
        let anime = await isAnime(item, show: show, client: client)
        let entry = anime ? await AnimeIds.entry(for: item, client: client) : nil

        // AniList and MyAnimeList: anime, by its season's entry.
        if let entry {
            let number = item.kind == .movie ? 1 : (item.indexNumber ?? 0)
            if number > 0 {
                if let id = entry.aniList, let token = secrets.aniList?.token {
                    await note(title, number, "AniList") { try await AniList.watched(mediaId: id, episode: number, token: token) }
                }
                if let id = entry.myAnimeList, secrets.myAnimeList != nil {
                    await note(title, number, "MyAnimeList") {
                        guard let token = try await self.myAnimeListToken() else { return .unchanged }
                        return try await MyAnimeList.watched(animeId: id, episode: number, token: token)
                    }
                }
            }
        }
        // Trakt and Simkl: everything, by the film's or show's ids.
        guard secrets.trakt != nil || secrets.simkl != nil, let watched = WatchedTitle(item: item, show: show, anime: entry) else { return }
        let number = item.indexNumber ?? 1
        if secrets.trakt != nil {
            await note(title, number, "Trakt") {
                guard let token = try await self.traktToken() else { return .unchanged }
                return try await Trakt.watched(watched, token: token)
            }
        }
        if let token = secrets.simkl?.token {
            await note(title, number, "Simkl") { try await Simkl.watched(watched, token: token) }
        }
    }

    private func note(_ title: String, _ number: Int, _ service: String, _ update: () async throws -> TrackerUpdate) async {
        do {
            switch try await update() {
            case .unchanged: break
            case .progress(let count): lastUpdate = "\(title): episode \(count) on \(service)"
            case .completed: lastUpdate = "\(title): completed on \(service)"
            case .watched: lastUpdate = "\(title)\(number > 0 ? ", episode \(number)" : ""): added to \(service)"
            }
        } catch TrackerError.signedOut {
            needsSignIn.insert(service)
        } catch {
            #if DEBUG
            print("DEBUG trackers: \(service) update failed: \(error)")
            #endif
        }
    }

    /// Anime only: a title in the anime libraries, or one marked as anime.
    private func isAnime(_ item: BaseItem, show: BaseItem?, client: any MediaServer) async -> Bool {
        if AppSession.shared.animeItemIds.contains(item.seriesId ?? item.id) { return true }
        if item.isAnime(on: client.kind) { return true }
        return show?.isAnime(on: client.kind) ?? false
    }
}

nonisolated extension Optional {
    /// `transform` of the value, when there's one.
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
