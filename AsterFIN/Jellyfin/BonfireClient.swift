//
//  BonfireClient.swift
//  AsterFIN
//
//  The Bonfire (JellyProfiles) plugin's routes: a household's profiles,
//  switching to one (with its PIN), and the household's preferences. The
//  plugin answers at /plugins/profiles on the server, with the ordinary
//  sign-in header; a server without it answers 404.
//

import Foundation

nonisolated enum Bonfire {
    static let basePath = "/plugins/profiles"
    static let pluginGUID = "b1462fca-774b-4b13-8d02-e2d4f2bc18b9"
    /// Bonfire's colour for a tile without one of its own.
    static let defaultAvatarColor = "#00A4DC"
    /// From 1.9: a code naming what went wrong, beside the plain-text body.
    static let errorHeader = "X-Bonfire-Error"

    /// The plugin writes its keys in camelCase in its own pages and
    /// PascalCase through Jellyfin's default serializer: the first letter
    /// is lowered, so either decodes.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last?.stringValue ?? ""
            return AnyKey(stringValue: key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }()
}

/// One entry of the household: the main account, a profile, or a member of
/// a linked household (`isBonfire`).
nonisolated struct BonfireProfileRecord: Codable, Sendable, Equatable {
    /// The profile's own Jellyfin user, as a dashed GUID.
    var profileUserId: String
    var profileName: String
    var avatarInitial: String?
    var avatarColor: String?
    var transparentAvatar: Bool?
    /// Whether a PIN is asked for right now (false on the home network
    /// when the profile skips it there).
    var requiresPin: Bool?
    /// Whether a PIN is set at all.
    var hasPin: Bool?
    var isMaster: Bool?
    var isAdministrator: Bool?
    /// Belongs to another household linked to this one.
    var isBonfire: Bool?
    /// Nil, one of the plugin's avatars, a URL, or a stored picture.
    var profileImage: String?
    var masterUserId: String?
    var lockoutMinutes: Int?
    var bypassPinOnLocalNetwork: Bool?
}

/// The household's switcher preferences, read from the main account.
nonisolated struct BonfirePreferences: Codable, Sendable, Equatable {
    /// Ask who's watching when the app opens.
    var askOnStartup: Bool?
    var switcherLocation: String?
    var switcherMode: String?
    var masterUserId: String?
}

/// A switch that went through: the profile's own sign-in.
nonisolated struct BonfireSwitchResult: Codable, Sendable, Equatable {
    var activeProfileToken: String
    var jellyfinUserId: String
}

/// What the plugin says about itself before anyone signs in (from 1.9):
/// its version, whether it's switched off, which app features are on, and
/// whether the server is closed for maintenance.
nonisolated struct BonfireInfo: Codable, Sendable, Equatable {
    nonisolated struct Features: Codable, Sendable, Equatable {
        /// Profiles sign in with their PIN where an app asks for a password.
        var clientPinLogin: Bool?
        /// `/Users/Public` lists the household's profiles on a known device.
        var clientProfileList: Bool?
        var requireMainPin: Bool?
    }

    nonisolated struct Maintenance: Codable, Sendable, Equatable {
        var message: String?
        var untilUtc: String?
    }

    var version: String?
    var apiVersion: Int?
    var disabled: Bool?
    var features: Features?
    var maintenance: Maintenance?
}

nonisolated struct BonfireClient: Sendable {
    let jellyfin: JellyfinClient

    private nonisolated struct SwitchBody: Encodable, Sendable {
        var profileId: String
        /// Left out when there's none to send.
        var pin: String?
    }

    /// What the server answered: the body, the status, and (from 1.9) the
    /// plugin's own code for what went wrong.
    private struct Answer {
        var data: Data
        var status: Int
        var code: String?
    }

    /// Every profile the signed-in person can switch to, or nil when the
    /// server has no plugin (the route answers 404).
    func list() async throws -> [BonfireProfileRecord]? {
        let answer = try await send("/list")
        if answer.status == 404 { return nil }
        try Self.check(answer, pinSent: false)
        return try Bonfire.decoder.decode([BonfireProfileRecord].self, from: answer.data)
    }

    func preferences() async throws -> BonfirePreferences {
        let answer = try await send("/preferences")
        try Self.check(answer, pinSent: false)
        return try Bonfire.decoder.decode(BonfirePreferences.self, from: answer.data)
    }

    /// The plugin's description of itself; nil on a version without the
    /// route (before 1.9 it answers 404 or 405).
    func info() async throws -> BonfireInfo? {
        let answer = try await send("/info")
        if answer.status == 404 || answer.status == 405 { return nil }
        try Self.check(answer, pinSent: false)
        return try Bonfire.decoder.decode(BonfireInfo.self, from: answer.data)
    }

    /// Switches to a profile, with its PIN where one is asked for: a token
    /// for the profile's own user. The server ends that user's earlier
    /// sign-ins from this device first; the one making the call stays.
    func switchProfile(id: String, pin: String?) async throws -> BonfireSwitchResult {
        let pin = pin.flatMap { $0.isEmpty ? nil : $0 }
        let answer = try await send("/switch", method: "POST", body: SwitchBody(profileId: id, pin: pin))
        try Self.check(answer, pinSent: pin != nil)
        return try Bonfire.decoder.decode(BonfireSwitchResult.self, from: answer.data)
    }

    /// Checks a profile's PIN without switching to it.
    func verifyPin(id: String, pin: String) async throws {
        let answer = try await send("/verify-pin", method: "POST", body: SwitchBody(profileId: id, pin: pin))
        try Self.check(answer, pinSent: true)
    }

    /// A profile's stored picture, small; 404 without one. Anyone can read it.
    func imageURL(profileUserId: String) -> URL {
        jellyfin.url(Bonfire.basePath + "/image/" + profileUserId, query: ["size": "thumb"])
    }

    /// One of the plugin's own avatars, small.
    func starterAvatarURL(_ id: String) -> URL {
        jellyfin.url(Bonfire.basePath + "/avatars/" + id, query: ["size": "thumb"])
    }

    private func send(_ path: String, method: String = "GET", body: (any Encodable & Sendable)? = nil) async throws -> Answer {
        var request = jellyfin.authorizedRequest(jellyfin.url(Bonfire.basePath + path), method: method)
        request.timeoutInterval = 15
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await jellyfin.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.invalidURL }
        return Answer(data: data, status: http.statusCode, code: http.value(forHTTPHeaderField: Bonfire.errorHeader)?.lowercased())
    }

    /// The plugin's refusals. From 1.9 a header names them; before, the
    /// status has to do: a wrong PIN is a 400 when one was sent, too many
    /// tries a 429. The body is plain text written for the person.
    private static func check(_ answer: Answer, pinSent: Bool) throws {
        guard !(200..<300).contains(answer.status) else { return }
        let trimmed = String(data: answer.data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed?.isEmpty == false ? trimmed : nil
        switch answer.code {
        case "pin_wrong": throw ProfileSwitchError.wrongPin
        case "pin_missing", "main_pin_required": throw ProfileSwitchError.pinNeeded
        case "daily_limit_reached", "rate_limited", "too_many_attempts": throw ProfileSwitchError.rateLimited
        case "maintenance": throw ProfileSwitchError.failed(text ?? "The server is closed for maintenance.")
        case .some(let code) where !code.isEmpty:
            throw ProfileSwitchError.failed(text ?? "The server didn't allow it (\(code)).")
        default: break
        }
        switch answer.status {
        case 400 where pinSent: throw ProfileSwitchError.wrongPin
        case 429: throw ProfileSwitchError.rateLimited
        case 401, 403: throw ProfileSwitchError.failed(text ?? "The server didn't allow it.")
        default: throw ProfileSwitchError.failed(text ?? "The server answered \(answer.status).")
        }
    }
}
