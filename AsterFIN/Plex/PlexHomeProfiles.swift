//
//  PlexHomeProfiles.swift
//  AsterFIN
//
//  A Plex Home's people, as a household the picker can switch between.
//  Switching asks plex.tv, with the person's PIN where they have one, for
//  their own token, then the server's token for them.
//

import Foundation

@MainActor
final class PlexHomeProfiles: ProfileProvider {
    let link: PlexLink
    /// The Home's account token, which checks PINs and lists its people.
    let homeToken: String
    let serverURL: URL
    let serverName: String?
    let kind = ProfileProviderKind.plexHome

    /// Nil for a sign-in from before the Home's token was kept: it can't
    /// check a PIN, so it can't switch.
    init?(link: PlexLink, serverURL: URL, serverName: String?) {
        guard let homeToken = link.homeToken, link.homeUserUUID != nil else { return nil }
        self.link = link
        self.homeToken = homeToken
        self.serverURL = serverURL
        self.serverName = serverName
    }

    func askOnStartup() async throws -> Bool? { nil }

    func profiles(currentUserId: String) async throws -> [HouseholdProfile] {
        let users = await PlexAccount.homeUsers(token: homeToken)
        guard !users.isEmpty else { throw ProfileSwitchError.unavailable }
        return users.map { HouseholdProfile(plex: $0, link: link, currentUserId: currentUserId) }
    }

    func verifyPin(_ pin: String, for profile: HouseholdProfile) async throws {
        _ = try await switchUser(profile, pin: pin)
    }

    func switchSession(to profile: HouseholdProfile, pin: String?) async throws -> StoredSession {
        let switched = try await switchUser(profile, pin: pin)
        let userToken = switched.authToken ?? homeToken
        // The server's token for this person (a shared server's is its own).
        let server = try? await PlexAccount.servers(token: userToken).first { $0.clientIdentifier == link.machineId }
        let fresh = PlexLink(
            accountToken: userToken, machineId: link.machineId,
            connections: server?.rankedConnections ?? link.connections,
            homeUserUUID: profile.rawId, homeUserHasPin: profile.hasPin, homeToken: homeToken
        )
        return StoredSession(
            serverURL: serverURL, serverName: serverName,
            userId: switched.uuid, userName: switched.displayName,
            accessToken: server?.accessToken ?? userToken, serverKind: .plex, plex: fresh
        )
    }

    /// plex.tv lets a profile switch to itself with no PIN at all, so an
    /// empty one is never sent for a profile that has one.
    private func switchUser(_ profile: HouseholdProfile, pin: String?) async throws -> PlexAccountUser {
        let pin = pin.flatMap { $0.isEmpty ? nil : $0 }
        if profile.hasPin, pin == nil { throw ProfileSwitchError.pinNeeded }
        do {
            return try await PlexAccount.switchUser(PlexHomeUser(id: 0, uuid: profile.rawId, title: profile.name), pin: pin, token: homeToken)
        } catch PlexError.http(let code) where code == 401 || code == 403 {
            throw ProfileSwitchError.wrongPin
        } catch PlexError.http(let code) where code == 429 {
            throw ProfileSwitchError.rateLimited
        }
    }
}

extension HouseholdProfile {
    /// Plex's gold, for a person without a picture.
    static let plexColor = "#E5A00D"

    init(plex user: PlexHomeUser, link: PlexLink, currentUserId: String) {
        let hasPin = user.protected ?? false
        self.init(
            id: user.uuid, rawId: user.uuid, name: user.title,
            imageURL: user.thumb.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            initial: String(user.title.prefix(1)).uppercased(), colorHex: Self.plexColor,
            isCurrent: user.uuid == currentUserId,
            isMaster: user.admin ?? false,
            requiresPin: hasPin, hasPin: hasPin,
            isOtherHousehold: false,
            masterUserId: nil,
            storedHousehold: StoredHousehold(masterUserId: link.machineId, isMaster: user.admin ?? false,
                                             avatarInitial: String(user.title.prefix(1)).uppercased(),
                                             avatarColor: Self.plexColor, profileImage: user.thumb)
        )
    }
}
