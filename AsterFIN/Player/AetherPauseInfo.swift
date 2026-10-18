//
//  AetherPauseInfo.swift
//  AsterFIN
//
//  What the AetherEngine player shows over a paused picture, on Apple TV and
//  the Mac: the title's clear logo in the top left, and above the timeline a
//  panel of its details, a long description drifting slowly up so it can be
//  read to the end. Paused on a Live TV channel, the channel's logo takes the
//  clear logo's place and the panel tells of the programme on now; paused in
//  a Channels-tab channel's break, the channel's logo, and what's up next
//  after the break. Each screen sizes it for how far away it's watched.
//

#if canImport(AetherEngine)
import AetherEngine
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The sizes for this screen.
private enum PauseMetrics {
    #if os(tvOS)
    static let logo = CGSize(width: 644, height: 230)
    static let panelWidth: CGFloat = 1150
    static let panelPadding = EdgeInsets(top: 30, leading: 36, bottom: 30, trailing: 36)
    static let cornerRadius: CGFloat = 36
    static let spacing: CGFloat = 14
    static let overview: Font = .callout
    static let overviewLineHeight = UIFont.preferredFont(forTextStyle: .callout).lineHeight
    static let facts: Font = .callout
    #else
    static let logo = CGSize(width: 420, height: 150)
    static let panelWidth: CGFloat = 760
    static let panelPadding = EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24)
    static let cornerRadius: CGFloat = 22
    static let spacing: CGFloat = 10
    static let overview: Font = .title3
    static let overviewLineHeight: CGFloat = {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: .title3).lineHeight
        #else
        let font = NSFont.preferredFont(forTextStyle: .title3)
        return font.ascender - font.descender + font.leading
        #endif
    }()
    static let facts: Font = .body
    #endif
}

/// The Channels-tab channel whose break `item` is part of: a clip, not a
/// movie or an episode (which is all a channel's programmes are).
private func channelInBreak(_ item: BaseItem, channelId: String?) -> PlaylistChannel? {
    guard let channelId, item.kind != .movie, item.kind != .episode else { return nil }
    return ChannelTuner.channel(channelId)
}

/// The title's clear logo (the series' for an episode), or a Live TV
/// channel's logo, or in a channel's break the channel's own; its name in
/// large type when there's none.
struct AetherPauseLogo: View {
    let item: BaseItem
    /// The Channels-tab channel playing, if one is.
    var channelId: String? = nil

    @Environment(AppSession.self) private var session

    private var name: String {
        if let channel = channelInBreak(item, channelId: channelId) { return channel.name }
        return item.kind == .episode ? (item.seriesName ?? item.displayTitle) : item.displayTitle
    }

    private var url: URL? {
        guard let client = session.client else { return nil }
        if let channel = channelInBreak(item, channelId: channelId) { return channel.logoURL(client: client, maxWidth: 900) }
        return item.kind == .tvChannel ? client.channelLogoURL(item, width: 900) : client.logoURL(for: item, width: 900)
    }

    var body: some View {
        Group {
            if let url {
                RemoteImage(url: url, contentMode: .fit) { Color.clear }
                    .frame(maxWidth: PauseMetrics.logo.width, maxHeight: PauseMetrics.logo.height, alignment: .topLeading)
            } else {
                Text(name)
                    .font(.largeTitle.weight(.heavy))
                    .lineLimit(2)
                    .frame(maxWidth: PauseMetrics.logo.width * 1.4, alignment: .leading)
            }
        }
        .accessibilityLabel(name)
    }
}

/// What's paused: its description, and what the stream is. For a Live TV
/// channel (`item` the channel), the programme on it: its title and episode,
/// its story, and the channel, time slot and time left.
struct AetherPauseDetails: View {
    let item: BaseItem
    @ObservedObject var engine: AetherEngine
    /// What's on, when `item` is a Live TV channel; nil until it's fetched.
    var program: BaseItem?
    /// The Channels-tab channel playing, if one is.
    var channelId: String? = nil

    private var isLive: Bool { item.kind == .tvChannel }
    /// In a channel's break: the channel, and the programme after the break.
    private var breakInfo: (channel: PlaylistChannel, next: ScheduledProgram?)? {
        channelInBreak(item, channelId: channelId).map { ($0, $0.programmeAfterBreak()) }
    }
    /// What the description and facts are of.
    private var subject: BaseItem {
        if let breakInfo { return breakInfo.next?.item ?? item }
        return isLive ? (program ?? item) : item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PauseMetrics.spacing) {
            if let breakInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Break")
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    if let next = breakInfo.next {
                        Text("Up next: " + Self.describe(next.item) + " at " + next.start.formatted(date: .omitted, time: .shortened))
                            .font(PauseMetrics.facts.weight(.semibold))
                            .lineLimit(1)
                    }
                }
            } else if isLive, let program {
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.displayTitle)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    if let episode = program.episodeTitle, !episode.isEmpty, episode != program.displayTitle {
                        Text(episode)
                            .font(PauseMetrics.facts.weight(.semibold))
                            .lineLimit(1)
                    }
                }
            }
            if let overview = subject.overview, !overview.isEmpty {
                AutoScrollingText(text: overview, font: PauseMetrics.overview, lineHeight: PauseMetrics.overviewLineHeight)
                    .foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: PauseMetrics.spacing) {
                let facts = breakInfo.map(breakFacts) ?? (isLive ? liveFacts : [item.productionYear.map(String.init), item.officialRating, runtime].compactMap { $0 })
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(PauseMetrics.facts)
                        .foregroundStyle(.white.opacity(0.85))
                }
                ForEach(breakInfo == nil ? badges : [], id: \.text) { badge in
                    MediaBadge(text: badge.text, filled: badge.filled)
                }
            }
        }
        .padding(PauseMetrics.panelPadding)
        .frame(maxWidth: PauseMetrics.panelWidth, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: PauseMetrics.cornerRadius, style: .continuous)
            // Darkened, so the glass doesn't take on the picture's colours.
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(.black.opacity(0.4)))
        }
        .foregroundStyle(.white)
    }

    /// "103 Hellaverse · back in 2 min".
    private func breakFacts(_ info: (channel: PlaylistChannel, next: ScheduledProgram?)) -> [String] {
        var facts = ["\(info.channel.number) \(info.channel.name)"]
        if let start = info.next?.start, start > Date() {
            let minutes = max(1, Int((start.timeIntervalSinceNow / 60).rounded(.up)))
            facts.append("back in " + Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        }
        return facts
    }

    /// "Friends · S1, E3", or a movie's name.
    private static func describe(_ item: BaseItem) -> String {
        guard item.kind == .episode else { return item.displayTitle }
        return [item.seriesName ?? item.displayTitle, item.episodeCode].compactMap { $0 }.joined(separator: " · ")
    }

    /// "511 NBC · 8:00 – 9:00 PM · 23 min left · TV-PG".
    private var liveFacts: [String] {
        var facts: [String] = []
        let channel = [item.channelNumber, item.displayTitle].compactMap { $0 }.joined(separator: " ")
        if !channel.isEmpty { facts.append(channel) }
        if let program {
            let slot = LiveTVFormat.timeRange(start: program.start, end: program.end)
            if !slot.isEmpty { facts.append(slot) }
            if let end = program.end, end > Date() {
                let minutes = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
                facts.append(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " left")
            }
            if let rating = program.officialRating { facts.append(rating) }
        }
        return facts
    }

    /// "23 min", "1 hr, 52 min".
    private var runtime: String? {
        let seconds = engine.duration > 0 ? engine.duration : Double(item.runTimeTicks ?? 0) / 10_000_000
        guard seconds >= 60 else { return nil }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// What the stream is, as the system player shows it: picture size and
    /// range filled, captions outlined.
    private var badges: [(text: String, filled: Bool)] {
        var badges: [(String, Bool)] = []
        let width = engine.sourceVideoWidth
        if width >= 3200 {
            badges.append(("4K", true))
        } else if width >= 1200 {
            badges.append(("HD", true))
        }
        switch engine.videoFormat {
        case .dolbyVision: badges.append(("Dolby Vision", true))
        case .hdr10, .hdr10Plus, .hlg: badges.append(("HDR", true))
        default: break
        }
        if engine.audioTracks.contains(where: \.isAtmos) { badges.append(("Atmos", true)) }
        if !engine.subtitleTracks.isEmpty { badges.append(("CC", false)) }
        return badges
    }
}

/// Text in a window of a few lines. When it runs longer, it waits, drifts
/// slowly up to its last line, holds there, and glides back to the top, over
/// and over while it's on screen, the edges fading as it moves.
private struct AutoScrollingText: View {
    let text: String
    let font: Font
    /// One line of `font`, for sizing the window.
    let lineHeight: CGFloat
    var visibleLines = 4

    /// How fast it reads up, in points a second: slow enough to read along.
    private static let speed: CGFloat = 18
    private static let hold: Duration = .seconds(3)

    @State private var textHeight: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var window: CGFloat {
        ceil(lineHeight * CGFloat(visibleLines))
    }

    private var overflow: CGFloat { max(textHeight - window, 0) }

    var body: some View {
        Text(text)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
            .offset(y: -offset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: textHeight > 0 ? min(textHeight, window) : window, alignment: .top)
            .clipped()
            .mask {
                // Fades an edge only while there's more text past it.
                let top: CGFloat = offset > 1 ? 0.14 : 0
                let bottom: CGFloat = overflow - offset > 1 ? 0.86 : 1
                LinearGradient(stops: [
                    .init(color: top > 0 ? .clear : .black, location: 0),
                    .init(color: .black, location: top),
                    .init(color: .black, location: bottom),
                    .init(color: bottom < 1 ? .clear : .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .task(id: textHeight) { await scrollWhileTooLong() }
    }

    private func scrollWhileTooLong() async {
        offset = 0
        let distance = overflow
        guard distance > 1 else { return }
        let duration = Double(distance / Self.speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.hold)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) { offset = distance }
            try? await Task.sleep(for: .seconds(duration) + Self.hold)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) { offset = 0 }
            try? await Task.sleep(for: .seconds(0.8))
        }
    }
}

/// "HD", "4K", "CC": filled, or outlined for captions, as the system shows them.
private struct MediaBadge: View {
    let text: String
    let filled: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(text)
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(filled ? .black : .white)
            .background { if filled { shape.fill(.white) } }
            .overlay { if !filled { shape.strokeBorder(.white, lineWidth: 2) } }
    }
}
#endif
