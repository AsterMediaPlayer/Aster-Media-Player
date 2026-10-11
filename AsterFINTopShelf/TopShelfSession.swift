//
//  TopShelfSession.swift
//  AsterFINTopShelf
//
//  The app's signed-in session, read from the Keychain item the app stores in
//  the shared App Group, plus the device id the app reports to the server.
//

import Foundation
import Security

/// Mirrors the app's `StoredSession` so the same JSON decodes here.
nonisolated struct TopShelfSession: Decodable, Sendable {
    var serverURL: URL
    var userId: String
    var accessToken: String

    private static let service = "com.berrymancloud.AsterFIN"
    private static let account = "session"
    private static let accessGroup = "group.app.asterfin"

    static func load() -> TopShelfSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TopShelfSession.self, from: data)
    }

    /// The app's device id, so the server sees one Apple TV rather than two.
    var deviceId: String {
        UserDefaults(suiteName: Self.accessGroup)?.string(forKey: "AsterFIN.deviceId") ?? "AsterFIN-TopShelf"
    }
}
