//
//  OnNowGuide.swift
//  AsterFINWidgets
//
//  The On Now widget's guide: a few channels and their programmes ahead,
//  which the app writes to the App Group. The same type is in the app
//  (`WidgetShared.swift`); keep the two alike, as the JSON is the contract.
//

import Foundation

nonisolated enum WidgetShared {
    static let appGroup = "group.app.asterfin"
    static let continueWatchingKind = "ContinueWatching"
    static let onNowKind = "OnNow"

    static var onNowURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("on-now.json")
    }
}

nonisolated struct OnNowGuide: Codable, Sendable {
    struct Program: Codable, Sendable, Hashable {
        var title: String
        var subtitle: String?
        var start: Date
        var end: Date
    }
    struct Channel: Codable, Sendable, Hashable, Identifiable {
        var id: String
        var number: Int
        var name: String
        var programs: [Program]

        func airing(at date: Date) -> Program? {
            programs.first { $0.start <= date && date < $0.end }
        }
    }
    var made: Date
    var channels: [Channel]
}
