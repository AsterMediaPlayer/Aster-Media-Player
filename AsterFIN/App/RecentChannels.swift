//
//  RecentChannels.swift
//  AsterFIN
//
//  The Live TV channels last played on this Apple TV, newest first, kept in
//  the App Group so the Top Shelf extension can show them. Jellyfin has no
//  dependable "recently watched channels" list of its own.
//

import Foundation
#if os(tvOS)
import TVServices
#endif

enum RecentChannels {
    /// Read by the Top Shelf extension under the same key.
    static let key = "AsterFIN.recentChannels"
    static let limit = 10

    static func record(_ channelId: String) {
        guard let defaults = UserDefaults(suiteName: AppSession.appGroup) else { return }
        var ids = defaults.stringArray(forKey: key) ?? []
        guard ids.first != channelId else { return }
        ids.removeAll { $0 == channelId }
        ids.insert(channelId, at: 0)
        defaults.set(Array(ids.prefix(limit)), forKey: key)
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }
}
