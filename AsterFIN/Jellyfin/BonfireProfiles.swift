//
//  BonfireProfiles.swift
//  AsterFIN
//
//  A Jellyfin server's household, through the Bonfire plugin: who's in
//  it, switching, and making a new profile.
//

import Foundation

@MainActor
final class BonfireProfiles: ProfileProvider, ProfileCreation {
    let client: BonfireClient
    let serverURL: URL
    let serverName: String?
    let kind = ProfileProviderKind.bonfire
    /// The plugin's version and features, once asked (1.9 and later say).
    private(set) var info: BonfireInfo?
    private var askedInfo = false

    init(jellyfin: JellyfinClient, serverName: String?) {
        client = BonfireClient(jellyfin: jellyfin)
        serverURL = jellyfin.baseURL
        self.serverName = serverName
    }

    var creation: (any ProfileCreation)? { self }

    func askOnStartup() async throws -> Bool? {
        try await client.preferences().askOnStartup
    }

    func profiles(currentUserId: String) async throws -> [HouseholdProfile] {
        guard let records = try await client.list() else { throw ProfileSwitchError.unavailable }
        await noteInfo()
        return records.map { HouseholdProfile(bonfire: $0, client: client, currentUserId: currentUserId) }
    }

    func verifyPin(_ pin: String, for profile: HouseholdProfile) async throws {
        try await client.verifyPin(id: profile.rawId, pin: pin)
    }

    func switchSession(to profile: HouseholdProfile, pin: String?) async throws -> StoredSession {
        if profile.requiresPin, pin?.isEmpty ?? true { throw ProfileSwitchError.pinNeeded }
        let result = try await client.switchProfile(id: profile.rawId, pin: pin)
        // The plain id: the same user signed in through the sign-in screen
        // (AuthenticateByName writes it that way) lands on the same saved
        // entry, cache and settings.
        return StoredSession(
            serverURL: serverURL, serverName: serverName,
            userId: HouseholdProfile.plainId(result.jellyfinUserId), userName: profile.name,
            accessToken: result.activeProfileToken, serverKind: .jellyfin,
            household: profile.storedHousehold
        )
    }

    // MARK: Making a profile

    /// All three at once; one that fails leaves its list empty rather than
    /// holding the form up (no ratings is still a form).
    func creationChoices() async -> ProfileCreationOptions {
        async let avatars = try? client.avatars()
        async let libraries = try? client.libraries()
        async let ratings = try? client.ratings()
        return ProfileCreationOptions(avatars: await avatars, libraries: await libraries, ratings: await ratings, client: client)
    }

    func createProfile(_ draft: ProfileDraft) async throws -> String {
        let created = try await client.createProfile(BonfireCreateRequest(draft))
        DebugLog.note("profiles", "Made profile \(created.profileName)")
        return HouseholdProfile.plainId(created.profileUserId)
    }

    /// Which Bonfire this is, for the debug report; once per sign-in.
    private func noteInfo() async {
        guard !askedInfo else { return }
        askedInfo = true
        guard let info = try? await client.info() else {
            DebugLog.note("profiles", "Bonfire before 1.9 (no info route)")
            return
        }
        self.info = info
        let features = info.features
        DebugLog.note("profiles", "Bonfire \(info.version ?? "?") (API \(info.apiVersion ?? 0))\(info.disabled == true ? ", switched off" : "")"
            + ", app PIN sign-in \(features?.clientPinLogin == true ? "on" : "off"), app profile list \(features?.clientProfileList == true ? "on" : "off")"
            + (info.maintenance.map { ", maintenance: \($0.message ?? "")" } ?? ""))
    }
}

extension HouseholdProfile {
    init(bonfire record: BonfireProfileRecord, client: BonfireClient, currentUserId: String) {
        let plain = Self.plainId(record.profileUserId)
        let name = record.profileName
        let initial = record.avatarInitial.flatMap { $0.isEmpty ? nil : $0 } ?? String(name.prefix(1)).uppercased()
        let color = record.avatarColor.flatMap { $0.isEmpty ? nil : $0 } ?? Bonfire.defaultAvatarColor
        let isMaster = record.isMaster ?? false
        let masterId = record.masterUserId.map(Self.plainId)
        var imageURL: URL?
        if let image = record.profileImage, !image.isEmpty {
            // A picture elsewhere is loaded from there; anything stored on
            // the server comes through the plugin's image route.
            if image.lowercased().hasPrefix("http://") || image.lowercased().hasPrefix("https://") {
                imageURL = URL(string: image)
            } else {
                imageURL = client.imageURL(profileUserId: record.profileUserId)
            }
        }
        self.init(
            id: plain, rawId: record.profileUserId, name: name, imageURL: imageURL,
            initial: initial, colorHex: color,
            isCurrent: plain == Self.plainId(currentUserId),
            isMaster: isMaster,
            requiresPin: record.requiresPin ?? (record.hasPin ?? false),
            hasPin: record.hasPin ?? false,
            isOtherHousehold: record.isBonfire ?? false,
            masterUserId: masterId,
            maxProfiles: record.maxSubProfiles,
            storedHousehold: StoredHousehold(
                masterUserId: masterId ?? plain, isMaster: isMaster,
                avatarInitial: initial, avatarColor: color, profileImage: record.profileImage
            )
        )
    }
}

extension ProfileCreationOptions {
    /// The server's lists as the form shows them: pictures by the plugin's
    /// small route, ratings with their labels joined.
    init(avatars: BonfireAvatarLibrary?, libraries: [BonfireLibrary]?, ratings: BonfireRatings?, client: BonfireClient) {
        self.init(
            avatars: (avatars?.avatars ?? []).map {
                ProfileAvatarChoice(id: $0.id, name: $0.displayName ?? $0.id, url: client.avatarURL(id: $0.id))
            },
            libraries: (libraries ?? []).map { ProfileLibraryChoice(id: $0.id, name: $0.name, collectionType: $0.collectionType) },
            ratings: (ratings?.ratings ?? [])
                .sorted { $0.score < $1.score }
                .map { ProfileRatingChoice(score: $0.score, label: $0.labels.joined(separator: " / ")) },
            ratingCountry: ratings?.country
        )
    }
}

extension BonfireCreateRequest {
    init(_ draft: ProfileDraft) {
        let pin = draft.pin.isEmpty ? nil : draft.pin
        self.init(
            profileName: draft.trimmedName,
            pin: pin,
            avatarColor: draft.colorHex,
            maxParentalRating: draft.ratingScore.map(String.init),
            enabledFolders: draft.libraryIds.map { Array($0).sorted() },
            masterPin: draft.masterPin.isEmpty ? nil : draft.masterPin,
            avatarLibraryId: draft.avatarId,
            bypassPinOnLocalNetwork: pin == nil ? nil : draft.bypassPinOnLocalNetwork
        )
    }
}
