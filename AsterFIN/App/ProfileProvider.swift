//
//  ProfileProvider.swift
//  AsterFIN
//
//  A household's profiles, wherever they come from: Bonfire on a Jellyfin
//  server, or a Plex Home. The picker shows them the same way; each
//  provider knows how to list its own and how to switch to one.
//

import Foundation

/// One person in the household, as the picker shows them.
nonisolated struct HouseholdProfile: Identifiable, Hashable, Sendable, Codable {
    /// The id as Jellyfin writes it either way (lowercase, no dashes), or
    /// a Plex Home user's uuid: what the session's `userId` is compared to.
    var id: String
    /// The id as the server sent it, for its own routes.
    var rawId: String
    var name: String
    /// The profile's picture, when it has one; the initial shows meanwhile.
    var imageURL: URL?
    var initial: String
    /// `#RRGGBB`.
    var colorHex: String
    /// The one signed in right now.
    var isCurrent: Bool
    /// The household's main account.
    var isMaster: Bool
    /// A PIN is asked for before switching, right now.
    var requiresPin: Bool
    /// A PIN is set at all.
    var hasPin: Bool
    /// A member of a linked household, not this one.
    var isOtherHousehold: Bool
    var masterUserId: String?
    /// What the sign-in remembers about the household once switched to.
    var storedHousehold: StoredHousehold

    /// An id as Jellyfin writes it either way: lowercase, without dashes.
    static func plainId(_ id: String) -> String {
        id.lowercased().replacingOccurrences(of: "-", with: "")
    }

    var accessibilityDescription: String {
        var parts = [name]
        if requiresPin { parts.append("PIN required") }
        if isCurrent { parts.append("watching now") }
        return parts.joined(separator: ", ")
    }
}

nonisolated enum ProfileProviderKind: Sendable {
    case bonfire
    case plexHome

    /// What the PIN belongs to, in messages.
    var serviceName: String {
        switch self {
        case .bonfire: "Bonfire"
        case .plexHome: "Plex Home"
        }
    }
}

/// Lists a household's profiles and switches to one.
@MainActor
protocol ProfileProvider: AnyObject {
    var kind: ProfileProviderKind { get }
    /// Whether the household asks who's watching when the app opens; nil
    /// where the service has no such setting.
    func askOnStartup() async throws -> Bool?
    /// Every profile that can be switched to, the one signed in included.
    /// Throws `ProfileSwitchError.unavailable` when the service isn't there.
    func profiles(currentUserId: String) async throws -> [HouseholdProfile]
    func verifyPin(_ pin: String, for profile: HouseholdProfile) async throws
    /// A fresh sign-in as `profile`, ready to switch to.
    func switchSession(to profile: HouseholdProfile, pin: String?) async throws -> StoredSession
}

nonisolated enum ProfileSwitchError: LocalizedError, Sendable, Equatable {
    case wrongPin
    case rateLimited
    case pinNeeded
    /// The service isn't on this server.
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .wrongPin: "That PIN isn't right."
        case .rateLimited: "Too many tries. Wait a few minutes, then try again."
        case .pinNeeded: "This profile needs its PIN."
        case .unavailable: "This server has no profiles."
        case .failed(let message): message
        }
    }
}

/// How to get to a profile: the current one, a sign-in already saved, a
/// switch the server can do at once, or one that needs the PIN first. A
/// saved sign-in never stands in for a PIN.
nonisolated enum ProfileSwitchPlan: Equatable, Sendable {
    case alreadyCurrent
    case reuseStored(StoredSession)
    case switchNow
    case needsPin

    static func make(for profile: HouseholdProfile, stored: StoredSession?) -> ProfileSwitchPlan {
        if profile.isCurrent { return .alreadyCurrent }
        if profile.requiresPin { return .needsPin }
        if let stored { return .reuseStored(stored) }
        return .switchNow
    }
}

/// When the app asks who's watching as it opens.
nonisolated enum ProfileGateMode: String, CaseIterable, Sendable {
    /// Every time the app opens.
    case always
    /// As the household's setting on the server says (Bonfire's "ask on
    /// startup"); never for a service without one.
    case server
    case never

    var title: String {
        switch self {
        case .always: "Every Time"
        case .server: "As the Server Is Set"
        case .never: "Never"
        }
    }
}

nonisolated enum ProfileGate {
    /// Whether to ask who's watching on a cold launch, from what's known
    /// without asking the server: the saved sign-in, the setting here, and
    /// the household's preference as last read.
    static func shouldAsk(stored: StoredSession, mode: ProfileGateMode, cachedAskOnStartup: Bool?) -> Bool {
        let inHousehold = stored.household != nil
            || (stored.plex?.homeUserUUID != nil && stored.plex?.homeToken != nil)
        switch mode {
        case .never: return false
        case .always: return inHousehold
        case .server: return stored.household != nil && cachedAskOnStartup == true
        }
    }
}

/// Why the picker is up: the app opened, or someone asked to switch.
nonisolated enum ProfilePickerReason: Equatable, Sendable, Identifiable {
    case launch
    case switcher

    var id: Self { self }
}
