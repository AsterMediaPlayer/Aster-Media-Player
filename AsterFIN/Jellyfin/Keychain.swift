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

    var kind: ServerKind { serverKind ?? .jellyfin }

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

/// A server signed in to, kept so the app can switch back to it without
/// signing in again; the one in use is also the `StoredSession` the widget
/// and Top Shelf read.
nonisolated struct SavedServer: Codable, Sendable, Identifiable, Equatable {
    var session: StoredSession
    /// Switching to it asks for the user's own password first.
    var asksPasswordToSwitch = false

    /// One per server and user.
    var id: String { Self.id(session.serverURL, session.userId) }

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

