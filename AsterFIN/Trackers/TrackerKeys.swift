//
//  TrackerKeys.swift
//  AsterFIN
//
//  The client ids Aster is registered under with each tracking service.
//  These are public identifiers (they're in every sign-in address), not
//  secrets: AniList's implicit grant and MyAnimeList's PKCE sign-in need no
//  client secret. Empty leaves that service out of Settings.
//
//  AniList: anilist.co/settings/developer, redirect URL aster://anilist-auth
//  MyAnimeList: myanimelist.net/apiconfig, app type "other",
//               redirect URL aster://mal-auth
//

import Foundation

nonisolated enum TrackerKeys {
    static let aniListClientId = ""
    static let myAnimeListClientId = ""
}
