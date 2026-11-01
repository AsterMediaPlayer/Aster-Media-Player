//
//  UpcomingView.swift
//  AsterFIN
//
//  The Upcoming tab: episodes of shows in the library that air soon. The
//  next to air fills a hero with a countdown; below, a row of cards for
//  each day. Most upcoming episodes are placeholders Jellyfin makes from the
//  show's schedule, with no picture or description of their own and a date
//  but no real air time, so the page uses the show's artwork and speaks in
//  days ("Tomorrow", "Thursday"), never clock times.
//

import SwiftUI

/// Dates and wording for upcoming episodes, kept apart from the views so
/// they can be tested. Plain calculations, used from any context.
nonisolated enum UpcomingSchedule {
    /// The day an episode airs, in the viewer's time zone. Jellyfin gives the
    /// air date as local midnight in UTC with seven decimal places, which
    /// the ISO 8601 parser won't read, so the fraction is dropped.
    static func airDate(of episode: BaseItem) -> Date? {
        guard let text = episode.premiereDate, text.count >= 19 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: String(text.prefix(19)) + "Z")
    }

    /// Episodes in airing order, gathered by the local day they air.
    static func days(of episodes: [BaseItem], calendar: Calendar = .current) -> [(day: Date, episodes: [BaseItem])] {
        let dated = episodes.compactMap { episode in airDate(of: episode).map { (date: $0, episode: episode) } }
            .sorted { lhs, rhs in
                (lhs.date, lhs.episode.seriesName ?? "", lhs.episode.parentIndexNumber ?? 0, lhs.episode.indexNumber ?? 0)
                    < (rhs.date, rhs.episode.seriesName ?? "", rhs.episode.parentIndexNumber ?? 0, rhs.episode.indexNumber ?? 0)
            }
        var days: [(day: Date, episodes: [BaseItem])] = []
        for entry in dated {
            let day = calendar.startOfDay(for: entry.date)
            if let last = days.indices.last, days[last].day == day {
                days[last].episodes.append(entry.episode)
            } else {
                days.append((day, [entry.episode]))
            }
        }
        return days
    }

    /// "Today", "Tomorrow", "In 3 days", then "In 2 weeks".
    static func countdown(to day: Date, from now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return "In \(days) days"
        default:
            let weeks = days / 7
            return weeks == 1 ? "In 1 week" : "In \(weeks) weeks"
        }
    }

    /// A day's heading: "Tomorrow · Thursday, October 15", or just the
    /// weekday and date further out.
    static func heading(for day: Date, from now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if calendar.isDate(day, inSameDayAs: now) { return "Today · \(date)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) {
            return "Tomorrow · \(date)"
        }
        return date
    }

    /// "S2 · E3 · The Blade". A placeholder's title ("Episode 3") only
    /// repeats the number, so it's left out.
    static func episodeLine(for episode: BaseItem) -> String {
        var parts: [String] = []
        if let season = episode.parentIndexNumber { parts.append("S\(season)") }
        if let number = episode.indexNumber { parts.append("E\(number)") }
        if let name = episode.name, !name.isEmpty, name != "Episode \(episode.indexNumber ?? -1)" {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }

    /// Whether the episode's file is already on the server (out early).
    static func isAvailable(_ episode: BaseItem) -> Bool {
        episode.locationType == "FileSystem"
    }

    /// What a card or the hero opens: the episode when it can be watched,
    /// else its show.
    static func destination(for episode: BaseItem) -> BaseItem {
        if isAvailable(episode) { return episode }
        guard let seriesId = episode.seriesId else { return episode }
        return BaseItem(id: seriesId, name: episode.seriesName, type: ItemKind.series.rawValue)
    }
}

@Observable
final class UpcomingModel {
    private(set) var days: [(day: Date, episodes: [BaseItem])] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    /// The hero's pages: every upcoming episode, soonest first. Episodes of
    /// one show share its backdrop, so the hero holds a picture per show.
    var featured: [BaseItem] { days.flatMap(\.episodes) }

    func load(client: JellyfinClient) async {
        isLoading = days.isEmpty
        errorMessage = nil
        do {
            days = UpcomingSchedule.days(of: try await client.upcoming())
        } catch {
            if days.isEmpty { errorMessage = error.localizedDescription }
        }
        isLoading = false
        hasLoaded = true
    }
}

struct UpcomingView: View {
    /// The tab it's shown in, for the Mac keyboard.
    var keyboardTab: AppTab = .upcoming

    @Environment(AppSession.self) private var session
    @State private var model = UpcomingModel()
    /// Where focus goes on pressing down from the hero: the first card.
    @FocusState private var focusedCard: String?
    /// Whether the hero has focus, so a press down lands on the first card.
    @State private var heroFocused = false
    #if os(macOS)
    @Environment(\.openItem) private var openItem
    @Environment(KeyboardNavigation.self) private var keyboard
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// Whether the keyboard is paging the hero or moving through the days.
    @State private var keyboardOnHero = true
    @State private var heroPage = 0
    @State private var atTop = true
    #endif

    private static let firstRowID = "upcoming-first-day"

    var body: some View {
        Group {
            if !model.days.isEmpty {
                schedule
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
    }

    private var schedule: some View {
        ScrollView(.vertical) {
            // A plain VStack, as on Home: the days sit below a full-screen
            // hero, and focus can only move to a card that exists.
            VStack(alignment: .leading, spacing: Lockup.sectionSpacing) {
                HeroCarousel(items: model.featured, moveDown: {
                    #if os(macOS)
                    enterDays()
                    #else
                    focusedCard = model.days.first?.episodes.first?.id
                    #endif
                }, focusChanged: { focused in
                    if focused { focusedCard = nil }
                    heroFocused = focused
                }, keyboardPage: heroKeyboardPage, pageChanged: { page in
                    #if os(macOS)
                    heroPage = page
                    #endif
                }, tag: { episode in
                    UpcomingSchedule.airDate(of: episode).map { UpcomingSchedule.countdown(to: $0) }
                }, action: { episode in
                    UpcomingSchedule.isAvailable(episode)
                        ? HeroCard.Action(title: "Watch Now", systemImage: "play.fill")
                        : HeroCard.Action(title: "Go to Show", systemImage: "tv")
                }, destination: UpcomingSchedule.destination(for:))

                ForEach(Array(model.days.enumerated()), id: \.element.day) { position, entry in
                    Shelf(title: UpcomingSchedule.heading(for: entry.day), items: entry.episodes) { episode in
                        UpcomingCard(episode: episode, focus: position == 0 ? $focusedCard : nil)
                    }
                    .id(position == 0 ? Self.firstRowID : "upcoming-\(position)")
                    .heroLanding($focusedCard, on: position == 0 ? entry.episodes.first?.id : nil, fromHero: heroFocused)
                }
            }
            .padding(.bottom, Lockup.pageBottomPadding)
        }
        .scrollClipDisabled()
        // Full-bleed like Home: the hero runs to the edges.
        .ignoresSafeArea()
        #if os(macOS)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < 40
        } action: { _, top in
            atTop = top
            if top { keyboardOnHero = true }
        }
        .onAppear {
            keyboardOnHero = atTop
            keyboard.register(keyboardTab) { key in handleKey(key) }
        }
        .onDisappear { keyboard.unregister(keyboardTab) }
        #endif
    }

    /// The hero page the Mac keyboard asks for; nil elsewhere.
    private var heroKeyboardPage: Int? {
        #if os(macOS)
        heroPage
        #else
        nil
        #endif
    }

    #if os(macOS)
    /// As on the Anime tab: at the top the arrows page the hero, Return
    /// opens it and down goes on to the days; there the nearest card that
    /// way is chosen, and up from the first day goes back to the hero.
    private func handleKey(_ key: KeyboardNavigation.Key) -> KeyPress.Result {
        if key == .exit { return .ignored }
        let featured = model.featured
        guard keyboardOnHero, !featured.isEmpty else {
            let result = KeyboardTargets.shared.handle(key, on: keyboardTab)
            if result == .ignored, key == .up, !featured.isEmpty {
                keyboardOnHero = true
                KeyboardTargets.shared.clearSelection()
                withAnimation(.easeInOut(duration: 0.4)) {
                    scrollPosition.scrollTo(edge: .top)
                }
                return .handled
            }
            return result
        }
        switch key {
        case .select:
            guard featured.indices.contains(heroPage) else { return .ignored }
            keyboardOnHero = false
            openItem?(UpcomingSchedule.destination(for: featured[heroPage]))
        case .down:
            enterDays()
        case .left, .right:
            let step = key == .left ? -1 : 1
            if step < 0, heroPage == 0 { return .ignored }
            heroPage = min(max(heroPage + step, 0), featured.count - 1)
        case .up, .exit:
            return .ignored
        }
        return .handled
    }

    /// Down from the hero: brings the first day up, then chooses its first
    /// card once it's on screen.
    private func enterDays() {
        keyboardOnHero = false
        KeyboardTargets.shared.clearSelection()
        withAnimation(.easeInOut(duration: 0.3)) {
            scrollPosition.scrollTo(id: Self.firstRowID, anchor: .center)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            _ = KeyboardTargets.shared.handle(.down, on: keyboardTab)
        }
    }
    #endif

    private func reload() async {
        guard let client = session.jellyfin else { return }
        await model.load(client: client)
    }
}

/// One upcoming episode: the show's picture, its logo or name, and the
/// episode, marked when its file is already on the server.
private struct UpcomingCard: View {
    let episode: BaseItem
    /// Lets the page move focus here (by episode id), down from the hero.
    var focus: FocusState<String?>.Binding? = nil

    @Environment(AppSession.self) private var session

    private var title: String { episode.seriesName ?? episode.displayTitle }

    var body: some View {
        let destination = UpcomingSchedule.destination(for: episode)
        NavigationLink(value: destination) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: session.jellyfin?.backdropURL(for: episode, width: 800), systemImage: "tv")
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: UnitPoint(x: 0.5, y: 0.35), endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    if let logo = session.jellyfin?.logoURL(for: episode, width: 400) {
                        RemoteImage(url: logo, contentMode: .fit) {
                            Text(title).font(.headline)
                        }
                        .frame(maxWidth: Lockup.landscapeWidth * 0.55, maxHeight: Lockup.landscapeHeight * 0.28, alignment: .bottomLeading)
                    } else {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Text(UpcomingSchedule.episodeLine(for: episode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(Lockup.landscapeWidth > 300 ? 18 : 10)
            }
            .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
            .overlay(alignment: .topTrailing) {
                if UpcomingSchedule.isAvailable(episode) {
                    Text("Available")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor, in: Capsule())
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Lockup.cornerRadius))
        }
        .cardButtonStyle()
        .optionallyFocused(focus, equals: episode.id)
        .keyboardTarget(opening: destination)
        .accessibilityLabel([title, UpcomingSchedule.episodeLine(for: episode), UpcomingSchedule.isAvailable(episode) ? "Available" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}
