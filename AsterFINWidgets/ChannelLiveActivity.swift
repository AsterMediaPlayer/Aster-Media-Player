//
//  ChannelLiveActivity.swift
//  AsterFINWidgets
//
//  A Channels-tab channel playing: its number, what's on with a countdown,
//  and what's next. Tap to go back to the channel.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct ChannelLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChannelActivityAttributes.self) { context in
            // Lock Screen.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(context.attributes.number) · \(context.attributes.name)").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                        .font(.caption.monospacedDigit()).frame(maxWidth: 60, alignment: .trailing)
                }
                Text(context.state.title).font(.headline).lineLimit(1)
                if let subtitle = context.state.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(timerInterval: context.state.start...context.state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                if let next = context.state.nextTitle {
                    Text("Up next: \(next)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding()
            .activityBackgroundTint(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("\(context.attributes.number)").font(.title2.bold().monospacedDigit())
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                        .monospacedDigit().frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let next = context.state.nextTitle {
                        Text("Up next: \(next)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Text("\(context.attributes.number)").bold().monospacedDigit()
            } compactTrailing: {
                Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                    .monospacedDigit().frame(maxWidth: 44)
            } minimal: {
                Text("\(context.attributes.number)").bold()
            }
            .widgetURL(URL(string: "aster://channel/\(context.attributes.channelId)"))
        }
    }
}
