//
//  ChannelActivity.swift
//  AsterFIN
//
//  A Channels-tab channel on the Lock Screen and in the Dynamic Island while
//  it plays: what's on, how long it has left, and what's next. Brought up to
//  date each time the channel moves on, as every programme and break clip
//  starts through the player's `begin`.
//

#if os(iOS)
import ActivityKit
import Foundation

enum ChannelActivity {
    private static var activity: Activity<ChannelActivityAttributes>?

    /// The channel is playing something new: shown, or brought up to date.
    static func show(channelId: String) {
        guard let channel = ChannelTuner.channel(channelId), let now = channel.airing(at: Date()) else {
            end()
            return
        }
        let next = channel.airing(at: now.end)
        let state = ChannelActivityAttributes.ContentState(
            title: title(now.item),
            subtitle: now.item.kind == .episode ? [now.item.episodeCode, now.item.name].compactMap { $0 }.joined(separator: " · ") : nil,
            start: now.start,
            end: now.end,
            nextTitle: next.map { title($0.item) }
        )
        let content = ActivityContent(state: state, staleDate: now.end.addingTimeInterval(120))
        if let activity, activity.attributes.channelId == channelId {
            Task { await activity.update(content) }
            return
        }
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ChannelActivityAttributes(channelId: channelId, number: channel.number, name: channel.name)
        activity = try? Activity.request(attributes: attributes, content: content)
    }

    static func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private static func title(_ item: BaseItem) -> String {
        item.kind == .episode ? (item.seriesName ?? item.displayTitle) : item.displayTitle
    }
}
#endif
