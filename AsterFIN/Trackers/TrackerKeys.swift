//
//  TrackerKeys.swift
//  AsterFIN
//
//  The client ids Aster is registered under with each tracking service.
//  These are public identifiers (they're in every sign-in address), not
//  secrets: AniList's implicit grant, MyAnimeList's PKCE sign-in and
//  Trakt's and Simkl's device codes need no client secret. Empty leaves that service out of
//  Settings.
//
//  AniList: anilist.co/settings/developer, redirect URL aster://anilist-auth
//  MyAnimeList: myanimelist.net/apiconfig, app type "other",
//               redirect URL aster://mal-auth
//  Trakt: developer.trakt.tv/apps, redirect URI http://localhost (the code
//         sign-in uses none; a Development app takes only localhost, and
//         lets in only the people added to it)
//  Simkl: simkl.com/settings/developer, Auth V2, app type "TV, devices &
//         command line" (device code sign-in, no redirect, no secret)
//
//  Trakt's apps made since its 2026 developer site use PKCE and are given no
//  client secret; its code sign-in works without one. An older app's secret
//  would go in Secrets.plist beside this file (ignored by git), as
//  TraktClientSecret, and is sent only when it's there.
//

import Foundation

nonisolated enum TrackerKeys {
    static let aniListClientId = "55643"
    static let myAnimeListClientId = "fdd07f4f85274c4a1e8a466193bfe90c"
    static let traktClientId = "mBY-5_3dD7dFPaZG7ILI7x7QOW-bixeR2-LpCDP5Ks8"
    static let simklClientId = "ebd388547e0ade13dad9e3196e820dcbc4b86ebb47d84d838b142a83b31bd71d"

    static var traktClientSecret: String {
        secrets["TraktClientSecret"] ?? ""
    }

    private static let secrets: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return values
    }()

    static var hasTrakt: Bool { !traktClientId.isEmpty }
    static var hasSimkl: Bool { !simklClientId.isEmpty }
}
