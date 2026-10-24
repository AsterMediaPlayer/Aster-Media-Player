//
//  DownloadsLiveActivity.swift
//  AsterFINWidgets
//
//  Downloads under way, on the Lock Screen and in the Dynamic Island. Tap
//  to open the Downloads tab.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadsActivityAttributes.self) { context in
            // Lock Screen.
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.remaining > 1 ? "Downloading \(context.state.remaining) titles" : context.state.title)
                        .font(.headline).lineLimit(1)
                    ProgressView(value: context.state.progress)
                }
            }
            .padding()
            .activityBackgroundTint(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "arrow.down.circle.fill") }
                DynamicIslandExpandedRegion(.trailing) { Text("\(context.state.remaining) left").font(.caption) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        Text(context.state.title).lineLimit(1)
                        ProgressView(value: context.state.progress)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle")
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%").monospacedDigit()
            } minimal: {
                Image(systemName: "arrow.down.circle")
            }
            .widgetURL(URL(string: "aster://downloads"))
        }
    }
}
