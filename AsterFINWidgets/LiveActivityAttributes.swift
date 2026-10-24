//
//  LiveActivityAttributes.swift
//  AsterFINWidgets
//
//  What the Live Activities carry. The same types are in the app
//  (`AsterFIN/App/LiveActivityAttributes.swift`); ActivityKit matches them by name,
//  so keep the two alike.
//

#if os(iOS)
import ActivityKit
import Foundation

/// Downloads under way, for the Lock Screen and the Dynamic Island.
nonisolated struct DownloadsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var remaining: Int
        var progress: Double
    }
}

/// A Channels-tab channel playing: what's on, and what's next.
nonisolated struct ChannelActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String?
        var start: Date
        var end: Date
        var nextTitle: String?
    }
    var channelId: String
    var number: Int
    var name: String
}
#endif
