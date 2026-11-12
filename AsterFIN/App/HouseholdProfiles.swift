//
//  HouseholdProfiles.swift
//  AsterFIN
//
//  The household of the server in use: whether it has profiles to switch
//  between (Bonfire on Jellyfin, a Plex Home), who they are, whether it
//  asks who's watching on opening, and whether the person signed in can
//  add to it. Asked once after sign-in and again after a while, like the
//  tracking plugin; cleared on switching server.
//

import Foundation
import Observation

@MainActor
@Observable
final class HouseholdProfiles {
    static let shared = HouseholdProfiles()

    /// Nil while there's no service (or not yet known).
    private(set) var provider: (any ProfileProvider)?
    private(set) var profiles: [HouseholdProfile] = []
    /// The household's "ask on startup", as the server last said.
    private(set) var askOnStartup: Bool?
    /// Whether the server has been asked yet, for this sign-in.
    private(set) var checked = false
    private var checkedAt: Date?
    private(set) var lastError: String?
    /// The server and user the list is for.
    private var owner: String?

    private static let cacheName = "household-profiles"

    /// Something to open the picker for: someone else to switch to, or
    /// room to add someone.
    var isAvailable: Bool { provider != nil && (profiles.count > 1 || canCreateProfiles) }
    var current: HouseholdProfile? { profiles.first { $0.isCurrent } }
    /// This household's main account.
    var master: HouseholdProfile? { profiles.first { $0.isMaster && !$0.isOtherHousehold } }

    /// The main account, signed in, on a service that makes profiles.
    var canCreateProfiles: Bool {
        guard provider?.creation != nil, let current, current.isMaster, !current.isOtherHousehold else { return false }
        return true
    }

    /// Asks the service what the household is. A server without one, or
    /// Emby, clears it.
    func refresh(session: AppSession, force: Bool = false) async {
        guard let serverURL = session.serverURL, let userId = session.userId else {
            clear()
            checked = true
            return
        }
        let owner = Self.owner(serverURL, userId)
        if owner != self.owner {
            clear()
            self.owner = owner
        }
        if !force, checked, let checkedAt, Date().timeIntervalSince(checkedAt) < 30 * 60 { return }
        guard let provider = self.provider ?? Self.makeProvider(session: session) else {
            clear()
            self.owner = owner
            checked = true
            return
        }
        do {
            let list = try await provider.profiles(currentUserId: userId)
            // Switched meanwhile: that answer isn't for this sign-in.
            guard self.owner == owner else { return }
            self.provider = provider
            profiles = list
            lastError = nil
            ResponseCache.save(list, Self.cacheName, server: serverURL, user: userId)
            DebugLog.note("profiles", "\(provider.kind.serviceName) present: \(list.count) profiles, \(list.filter(\.requiresPin).count) with a PIN")
            if let current = list.first(where: \.isCurrent) {
                session.noteHousehold(current.storedHousehold)
                if let ask = try? await provider.askOnStartup() {
                    guard self.owner == owner else { return }
                    askOnStartup = ask
                    ProfileGateCache.set(ask, for: Self.householdKey(serverURL, current.storedHousehold))
                    DebugLog.note("profiles", "Ask on startup: \(ask)")
                }
            }
        } catch ProfileSwitchError.unavailable {
            guard self.owner == owner else { return }
            self.provider = nil
            profiles = []
            DebugLog.note("profiles", "No profiles on this server")
        } catch {
            guard self.owner == owner else { return }
            // Out of reach for a moment: what was known stays.
            lastError = error.localizedDescription
            DebugLog.note("profiles", "Profiles couldn't be read: \(error.localizedDescription)")
        }
        checked = true
        checkedAt = Date()
    }

    /// The list as last read for this sign-in, at once, while the server
    /// is asked again. Nothing if it's known already.
    func restoreCached(session: AppSession) async {
        guard profiles.isEmpty, let serverURL = session.serverURL, let userId = session.userId,
              let provider = Self.makeProvider(session: session),
              let kept = await ResponseCache.load([HouseholdProfile].self, Self.cacheName, server: serverURL, user: userId) else { return }
        // Not if the fresh answer came first, or the sign-in changed.
        guard profiles.isEmpty, session.userId == userId else { return }
        if owner == nil { owner = Self.owner(serverURL, userId) }
        self.provider = provider
        profiles = kept.value
    }

    // MARK: Making a profile

    /// What the form offers, with the household's own rules: the main
    /// account's PIN is asked when it has one, and how many more profiles
    /// it may make.
    func creationOptions() async -> ProfileCreationOptions {
        guard let creation = provider?.creation else { return ProfileCreationOptions() }
        var options = await creation.creationChoices()
        options.asksMasterPin = master?.hasPin ?? false
        if let limit = master?.maxProfiles {
            let made = profiles.filter { !$0.isMaster && !$0.isOtherHousehold }.count
            options.remaining = max(0, limit - made)
        }
        return options
    }

    /// Makes the profile and reads the household again, so it's there to
    /// pick: its plain id.
    func create(_ draft: ProfileDraft, session: AppSession) async throws -> String {
        guard let creation = provider?.creation else { throw ProfileSwitchError.unavailable }
        let id = try await creation.createProfile(draft)
        await refresh(session: session, force: true)
        return id
    }

    func clear() {
        provider = nil
        profiles = []
        askOnStartup = nil
        checked = false
        checkedAt = nil
        lastError = nil
        owner = nil
    }

    private static func owner(_ serverURL: URL, _ userId: String) -> String {
        serverURL.absoluteString + "|" + userId
    }

    /// The key the household's preference is kept under (see `StoredSession.householdKey`).
    static func householdKey(_ serverURL: URL, _ household: StoredHousehold) -> String {
        serverURL.absoluteString + "|" + household.masterUserId
    }

    /// The service for the server in use, if it could have one.
    private static func makeProvider(session: AppSession) -> (any ProfileProvider)? {
        switch session.serverKind {
        case .jellyfin:
            return session.jellyfin.map { BonfireProfiles(jellyfin: $0, serverName: session.serverName) }
        case .plex:
            guard let link = session.plexLink, let serverURL = session.serverURL else { return nil }
            return PlexHomeProfiles(link: link, serverURL: serverURL, serverName: session.serverName)
        default:
            return nil
        }
    }
}

/// Each household's "ask on startup" as last read, so the decision on a
/// cold launch needs no network.
@MainActor
enum ProfileGateCache {
    static let key = "AsterFIN.profileAskOnStartup"

    static func askOnStartup(for householdKey: String, defaults: UserDefaults = .standard) -> Bool? {
        (defaults.dictionary(forKey: key) as? [String: Bool])?[householdKey]
    }

    static func set(_ ask: Bool?, for householdKey: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        all[householdKey] = ask
        defaults.set(all, forKey: key)
    }
}
