//
//  UpcomingAgenda.swift
//  AsterFIN
//
//  Upcoming as Discover shows it: an agenda. Each day down the side, big,
//  as a desk calendar shows it (weekday, date, how far off), with that
//  day's episodes beside it as wide pictures. The page takes the focused
//  show's picture, softly, behind everything. No hero: every row is plain
//  to move through, up to Discover's sections and back.
//

import SwiftUI

struct UpcomingAgenda: View {
    /// Room left above for Discover's sections.
    var topInset: CGFloat = 0

    @Environment(AppSession.self) private var session
    @State private var model = UpcomingModel()
    /// The episode with focus, whose show's picture fills the page.
    @FocusState private var focused: String?
    @State private var backdropEpisode: BaseItem?

    var body: some View {
        ZStack {
            backdrop
            if !model.days.isEmpty {
                agenda
            } else if let error = model.errorMessage {
                MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error) {
                    Task { await reload() }
                }
            } else if model.hasLoaded {
                MessageView(systemImage: "calendar", title: "Nothing coming up", detail: "Episodes of shows in your library that air soon show up here.")
            } else {
                ProgressView()
            }
        }
        .task { await reload() }
        .onChange(of: session.userDataRevision) { _, _ in
            Task { await reload() }
        }
        .onChange(of: focused) { _, id in
            guard let id, let episode = model.days.lazy.flatMap(\.episodes).first(where: { $0.id == id }) else { return }
            withAnimation(.easeInOut(duration: 0.6)) { backdropEpisode = episode }
        }
    }

    /// The focused show's picture, blurred and darkened, behind the page.
    private var backdrop: some View {
        ZStack {
            Color.black
            if let episode = backdropEpisode ?? model.days.first?.episodes.first {
                RemoteImage(url: session.jellyfin?.backdropURL(for: episode, width: 1280)) { Color.black }
                    .blur(radius: 50)
                    .scaleEffect(1.15)
                    .opacity(0.55)
                    .id(episode.seriesId ?? episode.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var agenda: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Self.daySpacing) {
                ForEach(Array(model.days.enumerated()), id: \.element.day) { _, entry in
                    day(entry.day, entry.episodes)
                }
            }
            .padding(.top, topInset + Lockup.pageTopPadding)
            .padding(.bottom, Lockup.pageBottomPadding)
        }
        .scrollClipDisabled()
    }

    private func day(_ day: Date, _ episodes: [BaseItem]) -> some View {
        HStack(alignment: .center, spacing: 0) {
            DayStamp(day: day)
                .frame(width: Self.stampWidth, alignment: .leading)
                .padding(.leading, Lockup.screenPadding)
            ScrollView(.horizontal) {
                LazyHStack(spacing: Lockup.shelfSpacing) {
                    ForEach(episodes) { episode in
                        AgendaCard(episode: episode)
                            .focused($focused, equals: episode.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, Lockup.shelfVerticalPadding)
            }
            .scrollClipDisabled()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(UpcomingSchedule.heading(for: day))
    }

    private func reload() async {
        guard let client = session.jellyfin else { return }
        await model.load(client: client)
    }

    #if os(tvOS)
    private static let stampWidth: CGFloat = 220
    private static let daySpacing: CGFloat = 12
    #else
    private static let stampWidth: CGFloat = 96
    private static let daySpacing: CGFloat = 4
    #endif
}

/// A day as a desk calendar shows it: "THU", "14", "November", "Tomorrow".
private struct DayStamp: View {
    let day: Date

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        VStack(alignment: .leading, spacing: 0) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.caption.weight(.heavy))
                .tracking(2)
                .foregroundStyle(isToday ? Color.accentColor : .white.opacity(0.7))
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: Self.dateSize, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(day.formatted(.dateTime.month(.wide)))
                .font(.callout.weight(.medium))
            Text(UpcomingSchedule.countdown(to: day))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    #if os(tvOS)
    private static let dateSize: CGFloat = 86
    #else
    private static let dateSize: CGFloat = 40
    #endif
}

/// An episode on the way, as a wide picture of its show: the logo (or
/// name), which episode, and "Available" when it's out early.
private struct AgendaCard: View {
    let episode: BaseItem

    @Environment(AppSession.self) private var session

    private var title: String { episode.seriesName ?? episode.displayTitle }

    var body: some View {
        NavigationLink(value: UpcomingSchedule.destination(for: episode)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: session.jellyfin?.backdropURL(for: episode, width: 1000), systemImage: "tv")
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: UnitPoint(x: 0.5, y: 0.4), endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    if let logo = session.jellyfin?.logoURL(for: episode, width: 500) {
                        RemoteImage(url: logo, contentMode: .fit) {
                            Text(title).font(.title3.weight(.bold))
                        }
                        .frame(maxWidth: Self.width * 0.5, maxHeight: Self.height * 0.26, alignment: .bottomLeading)
                    } else {
                        Text(title)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                    }
                    Text(UpcomingSchedule.episodeLine(for: episode))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(Self.inset)
            }
            .frame(width: Self.width, height: Self.height)
            .overlay(alignment: .topTrailing) {
                if UpcomingSchedule.isAvailable(episode) {
                    Label("Available", systemImage: "play.fill")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .padding(14)
                }
            }
        }
        .cardButtonStyle()
        .accessibilityLabel([title, UpcomingSchedule.episodeLine(for: episode), UpcomingSchedule.isAvailable(episode) ? "Available" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    #if os(tvOS)
    static let width: CGFloat = 560
    static let height: CGFloat = 315
    private static let inset: CGFloat = 22
    #else
    static let width: CGFloat = 260
    static let height: CGFloat = 146
    private static let inset: CGFloat = 12
    #endif
}
