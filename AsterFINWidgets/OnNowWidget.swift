//
//  OnNowWidget.swift
//  AsterFINWidgets
//
//  What's on the first Channels-tab channels, from the guide the app leaves
//  in the App Group: an entry at each programme change, so it stays right
//  for hours without the app. Tap a channel to tune in.
//

import SwiftUI
import WidgetKit

struct OnNowEntry: TimelineEntry {
    let date: Date
    let channels: [OnNowGuide.Channel]
}

struct OnNowProvider: TimelineProvider {
    func placeholder(in context: Context) -> OnNowEntry { OnNowEntry(date: .now, channels: []) }

    func getSnapshot(in context: Context, completion: @escaping (OnNowEntry) -> Void) {
        completion(OnNowEntry(date: .now, channels: Self.guide()?.channels ?? []))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OnNowEntry>) -> Void) {
        let count = context.family == .systemLarge ? 6 : 3
        guard let guide = Self.guide() else {
            completion(Timeline(entries: [OnNowEntry(date: .now, channels: [])], policy: .never))
            return
        }
        let channels = Array(guide.channels.prefix(count))
        // A new entry wherever any shown channel changes programme.
        let changes = Set(channels.flatMap { $0.programs.map(\.start) }).filter { $0 > .now }.sorted().prefix(100)
        let entries = [OnNowEntry(date: .now, channels: channels)] + changes.map { OnNowEntry(date: $0, channels: channels) }
        let last = channels.compactMap { $0.programs.last?.end }.min() ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: entries, policy: .after(last)))
    }

    private static func guide() -> OnNowGuide? {
        guard let url = WidgetShared.onNowURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OnNowGuide.self, from: data)
    }
}

struct OnNowView: View {
    let entry: OnNowEntry

    var body: some View {
        if entry.channels.isEmpty {
            Text("Open Channels in Aster to fill this in").font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("On Now").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(entry.channels) { channel in
                    Link(destination: URL(string: "aster://channel/\(channel.id)")!) {
                        row(channel)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ channel: OnNowGuide.Channel) -> some View {
        HStack(spacing: 10) {
            Text("\(channel.number)")
                .font(.headline.monospacedDigit())
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                if let program = channel.airing(at: entry.date) {
                    Text(program.title).font(.subheadline.bold()).lineLimit(1)
                    // Moves on its own between entries.
                    ProgressView(timerInterval: program.start...program.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .tint(.white)
                } else {
                    Text(channel.name).font(.subheadline.bold()).lineLimit(1)
                    Text("Open Aster to update").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct OnNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.onNowKind, provider: OnNowProvider()) { entry in
            OnNowView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("On Now")
        .description("What's on your channels right now.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
