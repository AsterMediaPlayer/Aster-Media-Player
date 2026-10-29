//
//  TopShelfServers.swift
//  AsterFIN
//
//  The saved servers kept off the Top Shelf, by `SavedServer.id`, in the App
//  Group so the Top Shelf extension can leave the shelf empty while one of
//  them is in use.
//

import Foundation
#if os(tvOS)
import TVServices
#endif

enum TopShelfServers {
    /// Read by the Top Shelf extension under the same key.
    static let key = "AsterFIN.topShelfHiddenServers"

    static func isShown(_ serverID: String) -> Bool {
        !(UserDefaults(suiteName: AppSession.appGroup)?.stringArray(forKey: key) ?? []).contains(serverID)
    }

    static func setShown(_ shown: Bool, for serverID: String) {
        guard let defaults = UserDefaults(suiteName: AppSession.appGroup) else { return }
        var ids = defaults.stringArray(forKey: key) ?? []
        ids.removeAll { $0 == serverID }
        if !shown { ids.append(serverID) }
        defaults.set(ids, forKey: key)
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }
}
