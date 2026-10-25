//
//  ServerPlugins.swift
//  AsterFIN
//
//  Aster's companion plugins for Jellyfin: which are on the server, and,
//  for an administrator, installing them and turning them on or off.
//  Installing adds Aster's repository to the server's list (keeping the
//  others) and asks the server for the newest version that runs on it; any
//  change takes a server restart, which the app can ask for.
//

import Foundation
import Observation

/// A companion plugin with features in the app.
nonisolated enum AsterPlugin: String, CaseIterable, Identifiable, Sendable {
    case channels, disc, opEd

    var id: String { rawValue }

    /// The repository the plugins are published to.
    static let repositoryURL = "https://raw.githubusercontent.com/AsterMediaPlayer/aster-companion-plugins/main/manifest.json"
    static let repositoryName = "Aster Companion Plugins"

    var guid: String {
        switch self {
        case .channels: "5b489227-2fc4-4dce-b7f8-6d0e3b2082ee"
        case .disc: "913b9d44-cafe-4fe7-ae0b-f1362dc12cc7"
        case .opEd: "d459e0a2-e073-4e1e-b0ec-71883075cf4a"
        }
    }

    /// Its name in the repository, which installing asks for.
    var packageName: String {
        switch self {
        case .channels: "Aster Channels"
        case .disc: "Aster Disc"
        case .opEd: "Aster OP-ED"
        }
    }

    var systemImage: String {
        switch self {
        case .channels: "tv.and.mediabox"
        case .disc: "opticaldisc"
        case .opEd: "music.note.tv"
        }
    }

    /// What it gets you, in a few words.
    var headline: String {
        switch self {
        case .channels: "Live TV, sorted"
        case .disc: "Real disc menus"
        case .opEd: "Every anime opening and ending"
        }
    }

    var summary: String {
        switch self {
        case .channels:
            "Group your Live TV channels into sports, news, kids and more, in the guide and as you flip. Then rename, renumber and rearrange Aster's channels right from Jellyfin's dashboard."
        case .disc:
            "Explore a film's extras through a menu just like the one on the disc, with moving backgrounds and music. Pick from a community catalogue, or design your own."
        case .opEd:
            "Watch a show's openings and endings on their own, play them back to back, or have each series greet you with its theme song. The song and artist come along too."
        }
    }

    /// The oldest server it runs on, until the repository says.
    var minimumServer: String {
        self == .channels ? "12.1" : "12.0"
    }

    /// A route that answers whenever the plugin is running, for anyone
    /// signed in (or no one): how a user who isn't an administrator, and
    /// can't list plugins, can tell it's there.
    var probePath: String {
        switch self {
        case .channels: "/AsterChannels/web/channels.js"
        case .disc: "/DiscMenus/web/discmenus.js"
        case .opEd: "/OpEd/Library"
        }
    }
}

/// Where a plugin stands on the server.
nonisolated enum PluginState: Equatable, Sendable {
    /// Not known yet, or the server didn't say.
    case unknown
    case notInstalled
    /// Being downloaded onto the server.
    case installing
    /// Changed: on or off after the server restarts.
    case afterRestart(on: Bool)
    case active
    case disabled
    /// No version of it runs on this server: it needs this one or later.
    case needsNewerServer(String)
    /// Jellyfin couldn't load it.
    case broken
    /// For someone who isn't an administrator: whether it's running.
    case present(Bool)

    var isOn: Bool {
        switch self {
        case .active, .installing: true
        case .afterRestart(let on): on
        case .present(let present): present
        default: false
        }
    }

    /// Whether an administrator's switch can change it now.
    var canSwitch: Bool {
        switch self {
        case .notInstalled, .active, .disabled, .afterRestart: true
        default: false
        }
    }

    var caption: String {
        switch self {
        case .unknown: ""
        case .notInstalled: "Not installed yet"
        case .installing: "Installing…"
        case .afterRestart(let on): on ? "Ready after a quick server restart" : "Turns off after a server restart"
        case .active: "On"
        case .disabled: "Off"
        case .needsNewerServer(let version): "Needs Jellyfin \(version) or newer"
        case .broken: "Jellyfin couldn't start it. Check Plugins in your dashboard."
        case .present(let present): present ? "On your server" : "Not on your server yet"
        }
    }

    /// What the server's plugin list, its catalogue and its version say.
    static func from(installed: [InstalledPlugin], packages: [PluginPackage]?, serverVersion: String?, for plugin: AsterPlugin) -> PluginState {
        let guid = plainGUID(plugin.guid)
        // A replaced version stays listed as superseded beside its successor.
        let current = installed
            .filter { plainGUID($0.id) == guid && $0.status != "Superceded" && $0.status != "Superseded" }
            .max { versionLess($0.version, $1.version) }
        if let current {
            switch current.status {
            case "Active", nil: return .active
            case "Restart": return .afterRestart(on: true)
            case "Disabled": return .disabled
            case "Deleted": return .afterRestart(on: false)
            default: return .broken
            }
        }
        // Not installed: can it be, on this server?
        guard let serverVersion else { return .notInstalled }
        let versions = packages?.first { plainGUID($0.guid) == guid }?.versions ?? []
        let oldestNeeded = versions.compactMap(\.targetAbi).min { versionLess($0, $1) } ?? plugin.minimumServer
        return versionLess(serverVersion, oldestNeeded) ? .needsNewerServer(shortVersion(oldestNeeded)) : .notInstalled
    }

    /// Jellyfin writes GUIDs without dashes; the repository with them.
    static func plainGUID(_ guid: String) -> String {
        guid.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// "12.1.0" < "12.1.0.1": by number, missing parts as 0.
    static func versionLess(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// "12.1.0.0" as "12.1".
    static func shortVersion(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        while parts.count > 2, parts.last == "0" { parts.removeLast() }
        return parts.joined(separator: ".")
    }
}

/// The companion plugins on the signed-in server, for the welcome screen
/// and Settings ▸ Server Plugins.
@Observable
final class ServerPluginsModel {
    enum Restart: Equatable {
        case idle, restarting, failed(String)
    }

    private(set) var states: [AsterPlugin: PluginState] = [:]
    /// Whether the user is an administrator; nil until known.
    private(set) var isAdministrator: Bool?
    /// A change waits on a restart.
    private(set) var needsRestart = false
    /// False where something else must restart the server (Docker, say).
    private(set) var canRestart = true
    private(set) var restart: Restart = .idle
    var errorMessage: String?

    private var installed: [InstalledPlugin] = []
    private var packages: [PluginPackage]?
    private var serverVersion: String?
    /// Changes made here since the last restart, which the server's list
    /// doesn't always show yet.
    private var pending: [AsterPlugin: Bool] = [:]

    func state(of plugin: AsterPlugin) -> PluginState {
        states[plugin] ?? .unknown
    }

    func load(_ session: AppSession) async {
        guard session.isJellyfin, let client = session.jellyfin else { return }
        let admin = (try? await client.me())?.policy?.isAdministrator ?? false
        isAdministrator = admin
        if admin {
            async let plugins = try? client.installedPlugins()
            async let info = try? client.serverSystemInfo()
            async let catalogue = try? client.pluginPackages()
            installed = await plugins ?? []
            let system = await info
            packages = await catalogue
            serverVersion = system?.version
            canRestart = system?.canSelfRestart ?? true
            needsRestart = needsRestart || system?.hasPendingRestart == true
            updateStates()
        } else {
            for plugin in AsterPlugin.allCases {
                states[plugin] = await client.serverHas(plugin.probePath).map(PluginState.present) ?? .unknown
            }
        }
    }

    /// An administrator's switch: installs, turns on or turns off.
    func set(_ plugin: AsterPlugin, on: Bool, session: AppSession) async {
        guard let client = session.jellyfin else { return }
        let state = state(of: plugin)
        errorMessage = nil
        do {
            switch (state, on) {
            case (.notInstalled, true):
                states[plugin] = .installing
                try await addRepository(client)
                try await client.installPackage(name: plugin.packageName, guid: plugin.guid, repositoryURL: AsterPlugin.repositoryURL)
            case (.disabled, true), (.afterRestart(on: false), true), (.active, false), (.afterRestart(on: true), false):
                guard let current = installedVersion(of: plugin) else {
                    // Installed here and not listed yet: the server can't change it until it restarts.
                    errorMessage = "Restart the server first, then turn \(plugin.packageName) off."
                    return
                }
                try await client.setPlugin(id: current.id, version: current.version, enabled: on)
            default:
                return
            }
            pending[plugin] = on
            needsRestart = true
        } catch {
            errorMessage = on
                ? "Couldn't install \(plugin.packageName): \(error.localizedDescription)"
                : "Couldn't turn \(plugin.packageName) off: \(error.localizedDescription)"
        }
        installed = (try? await client.installedPlugins()) ?? installed
        updateStates()
    }

    /// Restarts the server and waits for it to come back, then looks again.
    func restartServer(_ session: AppSession) async {
        guard let client = session.jellyfin else { return }
        restart = .restarting
        do {
            try await client.restartServer()
        } catch {
            restart = .failed("The server wouldn't restart: \(error.localizedDescription)")
            return
        }
        // It takes a moment to go; then it's back once it answers again.
        let started = Date()
        var wentDown = false
        while Date().timeIntervalSince(started) < 180 {
            try? await Task.sleep(for: .seconds(2))
            let answers = (try? await client.publicSystemInfo()) != nil
            if !answers { wentDown = true }
            if answers, wentDown || Date().timeIntervalSince(started) > 20 {
                pending = [:]
                needsRestart = false
                restart = .idle
                await load(session)
                return
            }
        }
        restart = .failed("The server hasn't come back after three minutes. Check on it, then open this page again.")
    }

    /// Aster's repository in the server's list, turned on, keeping the rest.
    private func addRepository(_ client: JellyfinClient) async throws {
        var repositories = try await client.pluginRepositories()
        let url = AsterPlugin.repositoryURL
        if let index = repositories.firstIndex(where: { $0.url?.caseInsensitiveCompare(url) == .orderedSame }) {
            guard repositories[index].enabled == false else { return }
            repositories[index].enabled = true
        } else {
            repositories.append(PluginRepository(name: AsterPlugin.repositoryName, url: url, enabled: true))
        }
        try await client.setPluginRepositories(repositories)
    }

    private func installedVersion(of plugin: AsterPlugin) -> InstalledPlugin? {
        let guid = PluginState.plainGUID(plugin.guid)
        return installed
            .filter { PluginState.plainGUID($0.id) == guid && $0.status != "Superceded" && $0.status != "Superseded" }
            .max { PluginState.versionLess($0.version, $1.version) }
    }

    private func updateStates() {
        for plugin in AsterPlugin.allCases {
            if let on = pending[plugin] {
                states[plugin] = .afterRestart(on: on)
            } else {
                states[plugin] = PluginState.from(installed: installed, packages: packages, serverVersion: serverVersion, for: plugin)
            }
        }
    }
}
