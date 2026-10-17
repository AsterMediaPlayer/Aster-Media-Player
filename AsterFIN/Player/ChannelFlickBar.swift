//
//  ChannelFlickBar.swift
//  AsterFIN
//
//  The channel row the Apple TV player opens with Up (see `ChannelFlick`):
//  what's on the picked channel across the top, and the channels either
//  side of it in a row beneath, over the picture, which plays on. The
//  remote is the player's own; this only draws.
//

#if os(tvOS)
import SwiftUI

struct ChannelFlickBar: View {
    let model: ChannelFlickModel

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let channel = model.selectedChannel {
                ChannelFlickDetail(channel: channel, isCurrent: channel.id == model.currentId)
                    .id(channel.id)
                    .transition(.opacity)
            }
            HStack(spacing: 24) {
                ForEach(-2...2, id: \.self) { offset in
                    if let channel = model.neighbour(offset) {
                        ChannelFlickCard(channel: channel, isSelected: offset == 0, isCurrent: channel.id == model.currentId)
                    } else {
                        Color.clear.frame(width: ChannelFlickCard.width, height: ChannelFlickCard.height)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: model.selectedChannel?.id)
        .padding(EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: UnitPoint(x: 0.5, y: 0.2), endPoint: .bottom)
                .ignoresSafeArea()
        }
        .foregroundStyle(.white)
    }
}

/// What's on the picked channel: its picture, title, episode, time and story.
private struct ChannelFlickDetail: View {
    let channel: FlickChannel
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            if let url = channel.now?.imageURL {
                RemoteImage(url: url, contentMode: .fill) { Color.white.opacity(0.08) }
                    .frame(width: 400, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    if let number = channel.number {
                        Text(number)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(channel.name)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Text(channel.now?.title ?? "No programme information")
                    .font(.system(size: 40, weight: .bold))
                    .lineLimit(1)
                if let subtitle = channel.now?.subtitle {
                    Text(subtitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                if let overview = channel.now?.overview {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
                if let program = channel.now {
                    ChannelFlickTime(program: program)
                }
                Label(isCurrent ? "Watching" : "Press to watch", systemImage: isCurrent ? "play.tv" : "play.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isCurrent ? .white.opacity(0.6) : .white)
                    .padding(.top, 4)
            }
            // Clear of the bug, which sits in the top right corner beside the
            // channel and what's on without pushing the lines below apart.
            .padding(.trailing, channel.bugURL == nil ? 0 : Self.bugWidth + 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if let bug = channel.bugURL {
                    RemoteImage(url: bug, contentMode: .fit) { EmptyView() }
                        .frame(width: Self.bugWidth, height: 180, alignment: .topTrailing)
                }
            }
        }
        // As tall as what it holds, at least the picture's height, so the
        // channel row below always stays below it.
        .frame(minHeight: 225, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let bugWidth: CGFloat = 280
}

/// "8:00 – 8:30 PM", how far into it the channel is, and the time left.
private struct ChannelFlickTime: View {
    let program: FlickProgram

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 16) {
                Text(LiveTVFormat.timeRange(start: program.start, end: program.end))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                if let progress = program.progress(at: context.date) {
                    ChannelFlickProgress(fraction: progress)
                        .frame(width: 220, height: 6)
                }
                if let left = timeLeft(at: context.date) {
                    Text(left)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }

    /// "12 min left", "1 hr, 5 min left"; nil once it's over.
    private func timeLeft(at date: Date) -> String? {
        guard let end = program.end, end > date else { return nil }
        let minutes = max(1, Int((end.timeIntervalSince(date) / 60).rounded(.up)))
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " left"
    }
}

private struct ChannelFlickProgress: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: proxy.size.width * fraction)
            }
        }
    }
}

/// A channel in the row: its logo or name, number, and what's on.
private struct ChannelFlickCard: View {
    static let width: CGFloat = 300
    static let height: CGFloat = 150

    let channel: FlickChannel
    let isSelected: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let number = channel.number {
                    Text(number)
                        .font(.callout.weight(.bold).monospacedDigit())
                }
                if let logo = channel.logoURL {
                    RemoteImage(url: logo, contentMode: .fit) {
                        Text(channel.name).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    .frame(height: 36, alignment: .leading)
                } else {
                    Text(channel.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Text(channel.now?.title ?? " ")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
            Spacer(minLength: 0)
            if let now = channel.now {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let progress = now.progress(at: context.date) {
                        ChannelFlickProgress(fraction: progress)
                            .frame(height: 4)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(.white.opacity(isSelected ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(isSelected ? 0.9 : 0), lineWidth: 3)
        }
        .scaleEffect(isSelected ? 1.08 : 1)
    }
}
#endif
