//
//  UpcomingAgenda.swift
//  AsterFIN
//
//  Upcoming as Discover shows it: an agenda. Each day down the side, big,
//  as a desk calendar shows it (weekday, date, how far off), with that
//  day's episodes beside it as wide pictures. The page takes the focused
//  show's picture, softly, behind everything. No hero: every row is plain
//  to move through, up to Discover's sections and back. Anime and other
//  shows can each be turned off at the top.
//

import SwiftUI

struct UpcomingAgenda: View {
    /// Discover's title and sections, across the top of the page.
    var header: AnyView = AnyView(EmptyView())

    /// One thing on a day: an episode, or a film the viewer asked for.
    enum Entry: Identifiable, Hashable {
        case episode(BaseItem)
        case film(SeerrComingFilm)

        var id: String {
            switch self {
            case .episode(let episode): episode.id
            case .film(let film): "film-\(film.id)"
            }
        }
    }

    @Environment(AppSession.self) private var session
    @State private var model = UpcomingModel()
    /// Films the viewer asked for (with Seerr), approved, not out yet.
    @State private var films: [SeerrComingFilm] = []
    /// What has focus, whose picture fills the page.
    @FocusState private var focused: String?
    @State private var backdropEntry: Entry?
    /// Which kinds to list; each can be turned off at the top.
    @AppStorage("AsterFIN.upcomingAnime") private var showsAnime = true
    @AppStorage("AsterFIN.upcomingShows") private var showsTV = true
    @AppStorage("AsterFIN.upcomingFilms") private var showsFilms = true

    /// Whether an episode's show is anime (from the anime libraries found).
    private func isAnime(_ episode: BaseItem) -> Bool {
        session.animeItemIds.contains(episode.seriesId ?? "")
    }

    /// The days with their episodes and films, less the kinds turned off,
    /// and days left empty by that.
    private var days: [(day: Date, entries: [Entry])] {
        let calendar = Calendar.current
        var byDay: [Date: [Entry]] = [:]
        for entry in model.days {
            byDay[entry.day, default: []] += entry.episodes
                .filter { isAnime($0) ? showsAnime : showsTV }
                .map(Entry.episode)
        }
        if showsFilms {
            for film in films {
                byDay[calendar.startOfDay(for: film.date), default: []].append(.film(film))
            }
        }
        return byDay.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The library has both kinds of show, so their switches are worth
    /// showing (even when only one kind has episodes coming this week).
    private var hasBothKinds: Bool {
        let anime = Set(session.animeLibraries.map(\.id))
        return !anime.isEmpty && session.showLibraries.contains { !anime.contains($0.id) }
    }

    private var hasAnything: Bool { !model.days.isEmpty || !films.isEmpty }

    var body: some View {
        ZStack {
            backdrop
            if hasAnything {
                agenda
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let error = model.errorMessage {
                        MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error) {
                            Task { await reload() }
                        }
                    } else if model.hasLoaded {
                        MessageView(systemImage: "calendar", title: "Nothing coming up", detail: "Episodes of shows in your library that air soon show up here, and films you've asked for until they're out.")
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .task {
            await reload()
            #if DEBUG
            let all = model.days.flatMap(\.episodes)
            print("DEBUG upcoming: \(all.count) episodes, \(all.filter(isAnime).count) anime, \(films.count) requested films; anime libraries \(session.animeLibraries.count), TV libraries \(session.showLibraries.count)")
            #endif
        }
        .onChange(of: session.userDataRevision) { _, _ in
            Task { await reload() }
        }
        .onChange(of: focused) { _, id in
            guard let id, let entry = days.lazy.flatMap(\.entries).first(where: { $0.id == id }) else { return }
            withAnimation(.easeInOut(duration: 0.6)) { backdropEntry = entry }
        }
    }

    /// The focused picture, blurred and darkened, behind the page.
    private var backdrop: some View {
        ZStack {
            Color.black
            if let entry = backdropEntry ?? days.first?.entries.first {
                RemoteImage(url: backdropURL(entry)) { Color.black }
                    .blur(radius: 50)
                    .scaleEffect(1.15)
                    .opacity(0.55)
                    .id(backdropKey(entry))
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func backdropURL(_ entry: Entry) -> URL? {
        switch entry {
        case .episode(let episode): session.jellyfin?.backdropURL(for: episode, width: 1280)
        case .film(let film): SeerrClient.image(film.title.backdropPath, width: "w1280")
        }
    }

    /// Episodes of one show share a picture, so moving between them doesn't
    /// fade it out and in again.
    private func backdropKey(_ entry: Entry) -> String {
        switch entry {
        case .episode(let episode): episode.seriesId ?? episode.id
        case .film(let film): "film-\(film.id)"
        }
    }

    private var agenda: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Self.daySpacing) {
                header
                    .padding(.bottom, 12)
                if hasBothKinds || !films.isEmpty {
                    kindSwitches
                }
                if days.isEmpty {
                    Text("Everything's turned off above. Turn something on to see what's coming.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Lockup.screenPadding)
                        .padding(.vertical, 60)
                }
                ForEach(days, id: \.day) { entry in
                    day(entry.day, entry.entries)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
    }

    /// Anime, TV Shows and Movies, each on or off.
    private var kindSwitches: some View {
        HStack(spacing: 16) {
            if hasBothKinds {
                kindSwitch("Anime", systemImage: "sparkles", isOn: $showsAnime)
                kindSwitch("TV Shows", systemImage: "tv", isOn: $showsTV)
            }
            if !films.isEmpty {
                kindSwitch("Movies", systemImage: "film", isOn: $showsFilms)
            }
        }
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.bottom, 8)
    }

    private func kindSwitch(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { isOn.wrappedValue.toggle() }
        } label: {
            Label(title, systemImage: isOn.wrappedValue ? "checkmark" : systemImage)
        }
        .chipStyle(selected: isOn.wrappedValue)
        .keyboardTarget(capsule: true) {
            withAnimation(.easeInOut(duration: 0.3)) { isOn.wrappedValue.toggle() }
        }
        .accessibilityValue(isOn.wrappedValue ? "Shown" : "Hidden")
    }

    private func day(_ day: Date, _ entries: [Entry]) -> some View {
        HStack(alignment: .center, spacing: 0) {
            DayStamp(day: day)
                .frame(width: Self.stampWidth, alignment: .leading)
                .padding(.leading, Lockup.screenPadding)
            ScrollView(.horizontal) {
                LazyHStack(spacing: Lockup.shelfSpacing) {
                    ForEach(entries) { entry in
                        Group {
                            switch entry {
                            case .episode(let episode): AgendaCard(episode: episode)
                            case .film(let film): AgendaFilmCard(film: film)
                            }
                        }
                        .focused($focused, equals: entry.id)
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
        async let comingFilms: [SeerrComingFilm] = loadFilms()
        if let client = session.jellyfin {
            await model.load(client: client)
        }
        films = await comingFilms
    }

    /// The viewer's approved film requests not out yet, with Seerr set up.
    private func loadFilms() async -> [SeerrComingFilm] {
        guard let account = AsterTracking.shared.seerr else { return [] }
        do {
            return try await SeerrClient.comingFilms(account: account)
        } catch {
            #if DEBUG
            print("DEBUG upcoming: requested films failed: \(error)")
            #endif
            return films
        }
    }

    #if os(tvOS)
    private static let stampWidth: CGFloat = 220
    private static let daySpacing: CGFloat = 12
    #else
    private static let stampWidth: CGFloat = 96
    private static let daySpacing: CGFloat = 4
    #endif
}

/// A film the viewer asked for, on the day it arrives: its picture, its
/// name, and how ("Digital Release", "In Theaters"). Opens its Seerr page.
private struct AgendaFilmCard: View {
    let film: SeerrComingFilm

    var body: some View {
        NavigationLink(value: film.title) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: SeerrClient.image(film.title.backdropPath, width: "w780") ?? film.title.posterURL, systemImage: "film")
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: UnitPoint(x: 0.5, y: 0.4), endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(film.title.displayTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    Text(film.how)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(AgendaCard.inset)
            }
            .frame(width: AgendaCard.width, height: AgendaCard.height)
            .overlay(alignment: .topTrailing) {
                Label("Requested", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(14)
            }
        }
        .cardButtonStyle()
        // A stop for the Mac's arrow keys; Return opens it.
        .keyboardTarget(opening: film.title)
        .accessibilityLabel("\(film.title.displayTitle), \(film.how), requested")
    }
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
        // A stop for the Mac's arrow keys; Return opens it.
        .keyboardTarget(opening: UpcomingSchedule.destination(for: episode))
        .accessibilityLabel([title, UpcomingSchedule.episodeLine(for: episode), UpcomingSchedule.isAvailable(episode) ? "Available" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    #if os(tvOS)
    static let width: CGFloat = 560
    static let height: CGFloat = 315
    static let inset: CGFloat = 22
    #else
    static let width: CGFloat = 260
    static let height: CGFloat = 146
    static let inset: CGFloat = 12
    #endif
}
