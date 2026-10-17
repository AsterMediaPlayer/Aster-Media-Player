//
//  SettingsSync.swift
//  AsterFIN
//
//  Settings that follow the Jellyfin user from device to device, kept on
//  their server in AsterFIN's own display preferences (see
//  `JellyfinClient.appSettings`). These are matters of taste: Up Next, skipping
//  intros, styled subtitles, disc menus, theme music and videos, song cards.
//  Settings tied to the device stay on it: streaming quality, the system
//  player switch, the tab bar, downloads and the Mac's full screen. Audio and
//  subtitle languages follow the user through their own Jellyfin settings.
//
//  The server's values are fetched when the app opens or comes back to the
//  foreground, and when Settings opens. A change to a synced setting is
//  saved a moment after it's made, wherever it's made; the last change wins.
//  A setting the server doesn't have yet is sent up from the first device
//  that has set it, and a device that never set one keeps the default
//  rather than pushing it over another device's choice.
//

import Foundation

enum SettingsSync {
    /// The synced settings: their key on the device, and on the server.
    private static let synced: [(local: String, server: String)] = [
        (AppSettings.autoplayNextKey, "autoplayNext"),
        (AppSettings.autoSkipIntroKey, "autoSkipIntro"),
        (AppSettings.styledSubtitlesKey, "styledSubtitles"),
        (AppSettings.preferDiscMenuKey, "preferDiscMenu"),
        (AppSettings.discMenuSoundsKey, "discMenuSounds"),
        (AppSettings.themeMusicKey, "themeMusic"),
        (AppSettings.themeVideosKey, "themeVideos"),
        (AppSettings.openingSoundKey, "openingSound"),
        (AppSettings.themeCardsKey, "themeCards"),
    ]

    /// What the server holds for the signed-in user, as last fetched or
    /// saved, so a value just fetched isn't sent straight back.
    private static var serverValues: [String: String] = [:]
    /// Who `serverValues` belongs to (server and user), and whether they've
    /// been fetched yet; nothing is saved before they have, so a device
    /// opening with old values can't overwrite newer ones.
    private static var owner: String?
    private static var hasPulled = false
    private static var client: JellyfinClient?
    private static var observer: NSObjectProtocol?
    private static var saveTask: Task<Void, Never>?

    /// Takes the server's values, and sends up any it hasn't got.
    static func pull(client: JellyfinClient) async {
        watch(client)
        guard let remote = try? await client.appSettings() else { return }
        let defaults = UserDefaults.standard
        var missing: [String: String] = [:]
        for key in synced {
            if let value = remote[key.server], let flag = Bool(value) {
                // Noted before the change lands, so the save that follows
                // the change sees nothing new.
                serverValues[key.server] = value
                if localValue(key.local) != value { defaults.set(flag, forKey: key.local) }
            } else if let value = localValue(key.local) {
                missing[key.server] = value
            }
        }
        hasPulled = true
        if !missing.isEmpty { await save(missing, client: client) }
    }

    /// The setting as the server stores it, "true" or "false"; nil when it
    /// has never been set on this device.
    private static func localValue(_ key: String) -> String? {
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else { return nil }
        return value ? "true" : "false"
    }

    /// Follows `client`'s user, and starts watching for changes the first time.
    private static func watch(_ client: JellyfinClient) {
        let id = "\(client.baseURL.absoluteString)|\(client.userId ?? "")"
        if owner != id {
            owner = id
            serverValues = [:]
            hasPulled = false
        }
        self.client = client
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { saveSoon() }
        }
    }

    /// Something in the settings changed: a second later, any synced
    /// setting that differs from the server's is saved.
    private static func saveSoon() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, hasPulled, let client else { return }
            var changed: [String: String] = [:]
            for key in synced {
                if let value = localValue(key.local), serverValues[key.server] != value {
                    changed[key.server] = value
                }
            }
            if !changed.isEmpty { await save(changed, client: client) }
        }
    }

    private static func save(_ values: [String: String], client: JellyfinClient) async {
        do {
            try await client.saveAppSettings(values)
            serverValues.merge(values) { _, new in new }
        } catch {
            #if DEBUG
            print("DEBUG settings sync: saving \(values.keys.sorted()) failed: \(error)")
            #endif
        }
    }
}
