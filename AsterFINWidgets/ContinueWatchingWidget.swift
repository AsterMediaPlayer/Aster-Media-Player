//
//  ContinueWatchingWidget.swift
//  AsterFINWidgets
//
//  What you were watching, and the next episodes: tap one to carry on.
//  Refreshed every half hour, and by the app whenever playback stops.
//

import SwiftUI
import WidgetKit

struct ContinueWatchingEntry: TimelineEntry {
    let date: Date
    let titles: [WidgetTitle]
    let signedIn: Bool
}

struct ContinueWatchingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(date: .now, titles: [], signedIn: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        Task { completion(await entry(for: context.family)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        Task {
            let entry = await entry(for: context.family)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
        }
    }

    private func entry(for family: WidgetFamily) async -> ContinueWatchingEntry {
        guard let session = WidgetSession.load() else {
            return ContinueWatchingEntry(date: .now, titles: [], signedIn: false)
        }
        let limit = switch family { case .systemSmall: 1; case .systemMedium: 3; default: 5 }
        return ContinueWatchingEntry(date: .now, titles: await WidgetAPI(session: session).continueWatching(limit: limit), signedIn: true)
    }
}

struct ContinueWatchingView: View {
    let entry: ContinueWatchingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.signedIn {
            Text("Sign in to Aster").font(.headline)
        } else if entry.titles.isEmpty {
            Text("Nothing to continue").font(.headline).foregroundStyle(.secondary)
        } else if family == .systemSmall, let first = entry.titles.first {
            Picture(data: first.image)
                .overlay(alignment: .bottomLeading) { Label(title: first) .padding(10) }
                .widgetURL(URL(string: "aster://play/\(first.id)"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continue Watching").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(entry.titles) { title in
                    Link(destination: URL(string: "aster://play/\(title.id)")!) {
                        HStack(spacing: 10) {
                            Picture(data: title.image)
                                .frame(width: 88, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Label(title: title)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct Picture: View {
        let data: Data?
        var body: some View {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
    }

    private struct Label: View {
        let title: WidgetTitle
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.title).font(.subheadline.bold()).lineLimit(1)
                if let subtitle = title.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let progress = title.progress {
                    ProgressView(value: progress).tint(.white)
                }
            }
        }
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.continueWatchingKind, provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
