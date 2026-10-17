//
//  SettingsSync.swift
//  AsterFIN
//
//  Settings that follow the Jellyfin user from device to device, kept on
//  their server in AsterFIN's own display preferences (see
//  `JellyfinClient.appSettings`). They're fetched when the app opens or
//  comes back to the foreground, and again when Settings opens; and
//  one is saved as soon as it changes. Without a connection, the device
//  keeps what it has.
//

import Foundation

enum SettingsSync {
    /// The synced settings: their key on the device, and on the server.
    /// (Channels used to be here; they're playlist tags now, see `ChannelTags`.)
    private static let synced: [(local: String, server: String)] = []

    /// What the server last held for the signed-in user, so a value just
    /// fetched isn't sent straight back.
    private static var serverValues: [String: String] = [:]
    private static var serverValuesOwner: String?

    private static func owner(of client: JellyfinClient) -> String {
        "\(client.baseURL.absoluteString)|\(client.userId ?? "")"
    }

    /// Takes the server's values. One the server doesn't have yet is sent
    /// up from this device, if it has one, so the first device with
    /// channels sets them.
    static func pull(client: JellyfinClient) async {
        guard !synced.isEmpty, let remote = try? await client.appSettings() else { return }
        let defaults = UserDefaults.standard
        serverValuesOwner = owner(of: client)
        serverValues = [:]
        var missing: [String: String] = [:]
        for key in synced {
            if let value = remote[key.server] {
                // Noted before the change lands, so `push` sees nothing new.
                serverValues[key.server] = value
                if defaults.string(forKey: key.local) ?? "" != value {
                    defaults.set(value, forKey: key.local)
                }
            } else if let value = defaults.string(forKey: key.local), !value.isEmpty {
                // Only a real value: a device with nothing set must not
                // empty another device's channels by syncing first.
                missing[key.server] = value
            }
        }
        if !missing.isEmpty {
            await save(missing, client: client)
        }
    }

    /// Saves a setting that changed on this device, unless it's what the
    /// server already has.
    static func push(_ localKey: String, client: JellyfinClient) async {
        guard let key = synced.first(where: { $0.local == localKey }) else { return }
        let value = UserDefaults.standard.string(forKey: localKey) ?? ""
        if serverValuesOwner == owner(of: client), serverValues[key.server] == value { return }
        await save([key.server: value], client: client)
    }

    private static func save(_ values: [String: String], client: JellyfinClient) async {
        do {
            try await client.saveAppSettings(values)
            if serverValuesOwner != owner(of: client) {
                serverValuesOwner = owner(of: client)
                serverValues = [:]
            }
            serverValues.merge(values) { _, new in new }
        } catch {
            #if DEBUG
            print("DEBUG settings sync: saving \(values.keys.sorted()) failed: \(error)")
            #endif
        }
    }
}
