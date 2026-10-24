//
//  WidgetShared.swift
//  AsterFIN
//
//  What the app leaves for the Home Screen widgets, and how it asks them to
//  refresh. The guide type is also in the widgets (`OnNowGuide.swift`); keep
//  the two alike, as the JSON is the contract.
//

import Foundation

#if os(iOS)
import WidgetKit

nonisolated enum WidgetShared {
    static let appGroup = "group.app.asterfin"
    static let continueWatchingKind = "ContinueWatching"
    static let onNowKind = "OnNow"

    /// The next few hours of the first channels, written by the app.
    static var onNowURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("on-now.json")
    }
}

/// The On Now widget's guide: a few channels and their programmes ahead.
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
    }
    var made: Date
    var channels: [Channel]
}

/// Asks the Home Screen widgets to fetch again after something they show has
/// changed: a title stopped partway, the channels reloaded.
enum WidgetRefresh {
    /// After playback stops. The server needs a moment to record where it
    /// stopped, so the widget asks a couple of seconds later.
    static func continueWatching() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.continueWatchingKind)
        }
    }

    static func onNow() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.onNowKind)
    }
}

extension ChannelTuner {
    /// The next twelve hours of the first channels, for the On Now widget.
    static func writeOnNowGuide(channels count: Int = 8, hours: Double = 12) {
        guard let url = WidgetShared.onNowURL else { return }
        let now = Date()
        let guide = OnNowGuide(made: now, channels: orderedChannels.prefix(count).map { channel in
            OnNowGuide.Channel(
                id: channel.id,
                number: channel.number,
                name: channel.name,
                programs: channel.programs(from: now, to: now.addingTimeInterval(hours * 3600)).map { program in
                    let item = program.item
                    let isEpisode = item.kind == .episode
                    return OnNowGuide.Program(
                        title: isEpisode ? (item.seriesName ?? item.displayTitle) : item.displayTitle,
                        subtitle: isEpisode ? [item.episodeCode, item.name].compactMap { $0 }.joined(separator: " · ") : nil,
                        start: program.start,
                        end: program.end
                    )
                }
            )
        })
        guard let data = try? JSONEncoder().encode(guide) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetRefresh.onNow()
    }
}
#endif
