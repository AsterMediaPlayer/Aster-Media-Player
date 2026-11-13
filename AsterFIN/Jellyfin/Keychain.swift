//
//  Keychain.swift
//  AsterFIN
//
//  Minimal Keychain wrapper used to persist the signed-in session. The item is
//  stored in the App Group's access group so the Top Shelf extension can read
//  it; sessions saved before sharing existed are moved over on first read.
//

import Foundation
import Security

nonisolated enum Keychain {
    private static let service = "com.berrymancloud.AsterFIN"
    /// The App Group shared with the Top Shelf extension.
    static let accessGroup = "group.app.asterfin"

    static func save(_ data: Data, account: String) {
        SecItemDelete(query(account: account, shared: true) as CFDictionary)
        SecItemDelete(query(account: account, shared: false) as CFDictionary)
        var insert = query(account: account, shared: true)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // Built without the App Group: keep the session private instead.
            var fallback = query(account: account, shared: false)
            fallback[kSecValueData as String] = data
            fallback[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(fallback as CFDictionary, nil)
        }
    }

    static func load(account: String) -> Data? {
        if let shared = read(query(account: account, shared: true)) {
            return shared
        }
        guard let legacy = read(query(account: account, shared: false)) else { return nil }
        save(legacy, account: account)
        return legacy
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account, shared: true) as CFDictionary)
        SecItemDelete(query(account: account, shared: false) as CFDictionary)
    }

    /// Everything the app keeps here: the session, saved servers, PINs.
    static func deleteAll() {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        var shared = base
        shared[kSecAttrAccessGroup as String] = accessGroup
        SecItemDelete(shared as CFDictionary)
        SecItemDelete(base as CFDictionary)
    }

    /// The Keychain outlives the app: deleting Aster and installing it again
    /// found the old sign-ins still there, so a fresh install opened signed
    /// in. On a fresh install's first launch (the app's settings are gone
    /// with it, where an update keeps them) they're cleared, once.
    static func clearIfFreshInstall(defaults: UserDefaults = .standard) {
        let marker = "AsterFIN.installed"
        guard !defaults.bool(forKey: marker) else { return }
        let updating = defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("AsterFIN.") }
        if !updating { deleteAll() }
        defaults.set(true, forKey: marker)
    }

    private static func query(account: String, shared: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if shared {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func read(_ base: [String: Any]) -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}

/// What survives a relaunch: where the server is and who is signed in.
nonisolated struct StoredSession: Codable, Sendable, Equatable {
    var serverURL: URL
    var serverName: String?
    var userId: String
    var userName: String
    var accessToken: String
    /// Nil in sessions saved before Emby was supported: those are Jellyfin.
    var serverKind: ServerKind?
    /// A Plex sign-in's plex.tv side; nil for Jellyfin and Emby.
    var plex: PlexLink?
    /// The household (Bonfire profiles) this sign-in belongs to, once
    /// known; nil for an ordinary sign-in, and in sessions saved before.
    var household: StoredHousehold?

    var kind: ServerKind { serverKind ?? .jellyfin }

    /// The server and the household's main account, which every profile
    /// of the household shares; nil without a household.
    var householdKey: String? {
        household.map { serverURL.absoluteString + "|" + $0.masterUserId }
    }

    private static let account = "session"

    static func load() -> StoredSession? {
        guard let data = Keychain.load(account: account) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Keychain.save(data, account: Self.account)
        }
    }

    static func clear() {
        Keychain.delete(account: account)
    }
}

/// The household a sign-in is part of: a Bonfire main account and its
/// profiles. Enough to find the household's other saved sign-ins, decide
/// whether to ask who's watching on opening, and draw the profile's tile
/// before the server answers.
nonisolated struct StoredHousehold: Codable, Sendable, Hashable {
    /// The main account's id, as Jellyfin writes it: lowercase, no dashes.
    var masterUserId: String
    /// Whether this sign-in is the main account itself.
    var isMaster: Bool
    /// The tile without a picture: a letter on a colour (`#00A4DC`-style).
    var avatarInitial: String?
    var avatarColor: String?
    /// Bonfire's own picture value (an avatar's id, a URL, or a stored
    /// file's name); nil without one.
    var profileImage: String?
    /// Whether the profile has a PIN, which locking asks for.
    var hasPin: Bool?
}

/// What a Plex sign-in keeps beyond the server's own token: the plex.tv
/// account it came through, and every address plex.tv gave for the server,
/// to find it again when the one in use stops answering.
nonisolated struct PlexLink: Codable, Sendable, Equatable {
    /// The plex.tv account's token (the Home user's, once one is picked).
    var accountToken: String
    /// The server's `machineIdentifier`.
    var machineId: String
    /// Every connection plex.tv listed, best first.
    var connections: [PlexConnectionInfo]
    /// The Plex Home user signed in, and whether their profile has a PIN
    /// (which locking and switching then ask for). Nil without a Home.
    var homeUserUUID: String?
    var homeUserHasPin: Bool?
    /// The token from the plex.tv link code (the Home's account), which
    /// checks a PIN: a profile's own token switching to itself is let
    /// through without one.
    var homeToken: String?
}

/// One way to reach a Plex server.
nonisolated struct PlexConnectionInfo: Codable, Sendable, Equatable, Hashable {
    var uri: URL
    var local: Bool
    var relay: Bool
}

/// A server signed in to, kept so the app can switch back to it without
/// signing in again; the one in use is also the `StoredSession` the widget
/// and Top Shelf read.
nonisolated struct SavedServer: Codable, Sendable, Identifiable, Equatable {
    var session: StoredSession
    /// Switching to it asks for the user's own password first.
    var asksPasswordToSwitch = false
    /// Minutes away from the app after which it asks for the password to
    /// carry on with this server; nil for never.
    var lockAfterMinutes: Int?

    /// The lock-after choices offered, in minutes.
    static let lockChoices = [1, 5, 15, 30, 60, 240]

    /// What switching and Lock After ask for: the user's password on the
    /// server, or a Plex Home profile's or a Bonfire profile's PIN (the
    /// main account's too, when it has one).
    var credentialName: String {
        if session.kind == .plex { return "PIN" }
        if asksProfilePin { return "PIN" }
        return "password"
    }

    /// Whether this is a household profile (not the main account), whose
    /// password on the server is its PIN.
    var isHouseholdProfile: Bool { session.household?.isMaster == false }

    /// A Bonfire main account with a PIN: its lock asks for the PIN, typed
    /// on the PIN pad, rather than the account's password.
    var isPinnedMainAccount: Bool {
        session.kind != .plex && session.household?.isMaster == true && session.household?.hasPin == true
    }

    /// Whether what's asked for is a household PIN, on the PIN pad.
    var asksProfilePin: Bool { isHouseholdProfile || isPinnedMainAccount }

    /// Whether there's anything to ask for: a Plex Home profile or a
    /// household profile without a PIN can't be locked.
    var canBeLocked: Bool {
        if session.kind == .plex { return session.plex?.homeUserHasPin == true && session.plex?.homeToken != nil }
        if isHouseholdProfile { return session.household?.hasPin == true }
        return true
    }

    /// A household profile (or main account) with a PIN and a lock asks for
    /// the PIN as the app opens too, not only after time away.
    var locksOnOpening: Bool {
        asksProfilePin && canBeLocked && lockAfterMinutes != nil
    }

    /// Whether a new Lock After lets more past the lock than the one set:
    /// never, or a longer wait. That change asks for the credential first.
    func loosens(lockAfter minutes: Int?) -> Bool {
        guard canBeLocked, let current = lockAfterMinutes else { return false }
        return minutes.map { $0 > current } ?? true
    }

    /// Whether turning the ask-to-switch setting to `asks` lets anyone switch
    /// without the credential, which asks for it first.
    func loosens(asksToSwitch asks: Bool) -> Bool {
        canBeLocked && asksPasswordToSwitch && !asks
    }

    /// One per server and user. A Plex server by its own id: the address
    /// used to reach it can change.
    var id: String {
        if let plex = session.plex { return Self.plexID(plex.machineId, session.userId) }
        return Self.id(session.serverURL, session.userId)
    }

    static func plexID(_ machineId: String, _ userId: String) -> String {
        "plex:" + machineId + "|" + userId
    }

    static func id(_ url: URL, _ userId: String) -> String {
        url.absoluteString + "|" + userId
    }
}

/// The servers signed in to, in the Keychain beside the session in use.
nonisolated enum SavedServers {
    private static let account = "servers"

    static func load() -> [SavedServer] {
        guard let data = Keychain.load(account: account) else { return [] }
        return (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
    }

    static func save(_ servers: [SavedServer]) {
        if let data = try? JSONEncoder().encode(servers) {
            Keychain.save(data, account: account)
        }
    }

    static func clear() {
        Keychain.delete(account: account)
    }
}

