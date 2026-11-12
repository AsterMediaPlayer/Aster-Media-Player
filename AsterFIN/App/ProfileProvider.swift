//
//  ProfileProvider.swift
//  AsterFIN
//
//  A household's profiles, wherever they come from: Bonfire on a Jellyfin
//  server, or a Plex Home. The picker shows them the same way; each
//  provider knows how to list its own and how to switch to one, and some
//  can make, change and remove them.
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
    /// On the main account: how many profiles it may have.
    var maxProfiles: Int?
    /// On a profile of this household: every library the account has
    /// (now and later), or the ones it was given (plain ids).
    var allLibraries: Bool?
    var enabledFolders: [String]?
    /// Its PIN isn't asked on the home network.
    var bypassPinOnLocalNetwork: Bool?
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
    /// Makes, changes and removes profiles, where the service can; nil
    /// where it can't.
    var creation: (any ProfileCreation)? { get }
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

extension ProfileProvider {
    var creation: (any ProfileCreation)? { nil }
}

// MARK: - Making and changing a profile

/// A picture a profile may have.
nonisolated struct ProfileAvatarChoice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var url: URL
}

nonisolated struct ProfileLibraryChoice: Identifiable, Hashable, Sendable {
    /// The library's plain id.
    var id: String
    var name: String
    var collectionType: String?
}

/// A rating limit: everything up to this age.
nonisolated struct ProfileRatingChoice: Identifiable, Hashable, Sendable {
    var score: Int
    var label: String

    var id: Int { score }
}

/// What the form offers: the pictures, libraries and ratings the server
/// has, and what the household's rules add.
nonisolated struct ProfileCreationOptions: Sendable, Equatable {
    var avatars: [ProfileAvatarChoice] = []
    var libraries: [ProfileLibraryChoice] = []
    var ratings: [ProfileRatingChoice] = []
    var ratingCountry: String?
    /// The main account's own PIN is asked for before making or changing
    /// a profile (the account has one; the server insists on it).
    var asksMasterPin = false
    /// How many more profiles the account may make; nil when not known.
    var remaining: Int?
}

/// A profile as it's filled in: a new one, or (with `profileId`) one
/// being changed.
nonisolated struct ProfileDraft: Sendable, Equatable {
    /// The profile being changed, as the server knows it; nil for a new one.
    var profileId: String?
    var name = ""
    /// A new PIN; empty keeps the one there is (or sets none).
    var pin = ""
    /// Changing: take the PIN away.
    var removePin = false
    /// One of the offered pictures; nil for the initial on the colour (a
    /// new profile) or the picture it has (changing).
    var avatarId: String?
    var colorHex = Bonfire.defaultAvatarColor
    /// Everything up to this rating; nil for no limit beyond the account's.
    var ratingScore: Int?
    /// The libraries it may see (plain ids); nil for all the account has,
    /// now and later.
    var libraryIds: Set<String>?
    var masterPin = ""
    /// A PIN that isn't asked on the home network.
    var bypassPinOnLocalNetwork = false

    /// The colours offered for the initial's tile.
    static let colors = ["#00A4DC", "#1F77B4", "#30A46C", "#FFB224", "#F76B15", "#E5484D", "#E93D82", "#8E4EC6"]

    var isEditing: Bool { profileId != nil }
    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    var initial: String { String(trimmedName.prefix(1)).uppercased() }

    /// What the server would turn down, said before it's asked (its rules:
    /// the name's length and letters, the PIN's digits); nil when it's fine.
    func validationMessage(confirmPin: String) -> String? {
        let name = trimmedName
        if name.isEmpty { return "Enter a name for the profile." }
        if name.count > Bonfire.maxProfileNameLength { return "A profile name can be at most \(Bonfire.maxProfileNameLength) characters." }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-'._@+ "))
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "A profile name can use letters, numbers, spaces and - ' . _ @ +."
        }
        if !pin.isEmpty, !removePin {
            if !Bonfire.pinLengths.contains(pin.count) || !pin.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return "A PIN is 4 to 8 digits."
            }
            if confirmPin != pin { return "The PINs don't match." }
        }
        return nil
    }
}

/// Makes, changes and removes profiles in the household.
@MainActor
protocol ProfileCreation: AnyObject {
    /// The pictures, libraries and ratings to offer. Each list is empty
    /// when the server can't say.
    func creationChoices() async -> ProfileCreationOptions
    /// Makes the profile: its plain id.
    func createProfile(_ draft: ProfileDraft) async throws -> String
    /// A profile as it is now, filled in to change.
    func draft(editing profile: HouseholdProfile) async -> ProfileDraft
    func updateProfile(_ draft: ProfileDraft) async throws
    func deleteProfile(_ profile: HouseholdProfile, masterPin: String?) async throws
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
