//
//  TrackerKeys.swift
//  AsterFIN
//
//  The client ids Aster is registered under with each tracking service.
//  These are public identifiers (they're in every sign-in address), not
//  secrets: AniList's implicit grant, MyAnimeList's PKCE sign-in and
//  Simkl's PIN need no client secret. Empty leaves that service out of
//  Settings.
//
//  AniList: anilist.co/settings/developer, redirect URL aster://anilist-auth
//  MyAnimeList: myanimelist.net/apiconfig, app type "other",
//               redirect URL aster://mal-auth
//  Trakt: trakt.tv/oauth/applications, redirect URI urn:ietf:wg:oauth:2.0:oob
//  Simkl: simkl.com/settings/developer, redirect URL aster://simkl-auth
//
//  Trakt's sign-in also takes its client secret, which stays off the public
//  repo: in Secrets.plist beside this file (ignored by git), as
//  TraktClientSecret. Xcode bundles it when it's there; without it Trakt
//  doesn't show.
//

import Foundation

nonisolated enum TrackerKeys {
    static let aniListClientId = "55643"
    static let myAnimeListClientId = "fdd07f4f85274c4a1e8a466193bfe90c"
    static let traktClientId = ""
    static let simklClientId = ""

    static var traktClientSecret: String {
        secrets["TraktClientSecret"] ?? ""
    }

    private static let secrets: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return values
    }()

    static var hasTrakt: Bool { !traktClientId.isEmpty && !traktClientSecret.isEmpty }
    static var hasSimkl: Bool { !simklClientId.isEmpty }
}
