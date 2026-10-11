//
//  LiveTVView.swift
//  AsterFIN
//
//  Live TV: what's on now, the programme guide, the channel list and
//  recordings.
//

import SwiftUI

@Observable
final class LiveTVModel {
    private(set) var channels: [BaseItem] = []
    private(set) var onNow: [BaseItem] = []
    private(set) var movies: [BaseItem] = []
    private(set) var sports: [BaseItem] = []
    private(set) var kids: [BaseItem] = []
    private(set) var news: [BaseItem] = []
    private(set) var recordings: [BaseItem] = []
    private(set) var timers: [TimerInfo] = []
    private(set) var seriesTimers: [SeriesTimerInfo] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func load(client: JellyfinClient) async {
        isLoading = channels.isEmpty
        errorMessage = nil
        do {
            async let channelList = client.channels()
            async let recommended = client.recommendedPrograms(limit: 30)
            async let movieList = client.recommendedPrograms(limit: 20, isMovie: true)
            async let sportsList = client.recommendedPrograms(limit: 20, isSports: true)
            async let kidsList = client.recommendedPrograms(limit: 20, isKids: true)
            async let newsList = client.recommendedPrograms(limit: 20, isNews: true)
            let loaded = try await channelList
            channels = loaded.sorted { lhs, rhs in
                let lf = lhs.userData?.isFavorite ?? false
                let rf = rhs.userData?.isFavorite ?? false
                if lf != rf { return lf }
                return Self.channelOrder(lhs) < Self.channelOrder(rhs)
            }
            onNow = (try? await recommended) ?? []
            movies = (try? await movieList) ?? []
            sports = (try? await sportsList) ?? []
            kids = (try? await kidsList) ?? []
            news = (try? await newsList) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        await refreshRecordings(client: client)
    }

    func refreshRecordings(client: JellyfinClient) async {
        recordings = (try? await client.recordings()) ?? []
        timers = ((try? await client.timers()) ?? []).sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        seriesTimers = (try? await client.seriesTimers()) ?? []
    }

    /// Flips a channel's favorite flag in place, without re-sorting so the
    /// guide does not jump under the viewer, and tells the server.
    func toggleFavorite(channelId: String, client: JellyfinClient) async {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        let newValue = !(channels[index].userData?.isFavorite ?? false)
        if channels[index].userData != nil {
            channels[index].userData?.isFavorite = newValue
        }
        try? await client.setFavorite(channelId, newValue)
    }

    func isFavorite(channelId: String?) -> Bool {
        guard let channelId else { return false }
        return channels.first { $0.id == channelId }?.userData?.isFavorite == true
    }

    private static func channelOrder(_ channel: BaseItem) -> (Double, String) {
        let number = Double(channel.channelNumber ?? "") ?? .greatestFiniteMagnitude
        return (number, channel.displayTitle)
    }
}

nonisolated extension TimerInfo {
    var start: Date? { JellyfinDate.parse(startDate) }
    var end: Date? { JellyfinDate.parse(endDate) }
}

enum LiveTVSection: String, CaseIterable, Identifiable {
    case onNow = "On Now"
    case guide = "Guide"
    case channels = "Channels"
    case recordings = "Recordings"

    var id: String { rawValue }
}

struct LiveTVView: View {
    @Environment(AppSession.self) private var session
    @State private var model = LiveTVModel()
    @State private var guideModel = GuideModel()
    @State private var section: LiveTVSection = .onNow
    @State private var selectedProgram: BaseItem?
    /// The channel playing, full screen or in the mini player. It outlives
    /// the full-screen player so Back can leave it running in the header.
    @State private var live: PlaybackCoordinator?
    @State private var liveFullScreen = false
    /// A channel chosen on a programme page, started once that page closes.
    @State private var pendingChannel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.top, 40)
            .padding(.bottom, 10)
            .tvFocusSection()

            if model.isLoading && model.channels.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.channels.isEmpty {
                MessageView(systemImage: "antenna.radiowaves.left.and.right.slash", title: "Live TV isn't available", detail: error) {
                    Task { await reload() }
                }
            } else {
                switch section {
                case .onNow:
                    OnNowView(model: model, select: { selectedProgram = $0 }, playChannel: play(channelId:), toggleFavorite: toggleFavorite(channelId:))
                case .guide:
                    GuideView(model: guideModel, channels: model.channels, select: { selectedProgram = $0 }, playChannel: play(channelId:), toggleFavorite: toggleFavorite(channelId:))
                case .channels:
                    ChannelsGrid(channels: model.channels, playChannel: play(channelId:), toggleFavorite: toggleFavorite(channelId:))
                case .recordings:
                    RecordingsView(model: model, select: { selectedProgram = $0 })
                }
            }
        }
        .task { await reload() }
        // Back on Live TV closes the mini player before leaving the screen.
        .tvExitCommand(perform: closeMiniPlayer)
        .onDisappear {
            // Leaving the Live TV tab ends the channel; covers don't count.
            if !liveFullScreen && selectedProgram == nil { stopLive() }
        }
        .fullScreenCover(isPresented: $liveFullScreen, onDismiss: {
            // Back from full screen: keep the channel going in the header.
            live?.resume()
        }) {
            if let live {
                PlayerView(coordinator: live) { stopLive() }
            }
        }
        .fullScreenCover(item: $selectedProgram, onDismiss: {
            Task { if let client = session.client { await model.refreshRecordings(client: client) } }
            if let channel = pendingChannel {
                pendingChannel = nil
                play(channelId: channel)
            }
        }) { program in
            ProgramDetailView(
                program: program,
                isChannelFavorite: program.channelId.map { model.isFavorite(channelId: $0) },
                onToggleChannelFavorite: program.channelId.map { id in { toggleFavorite(channelId: id) } },
                watchChannel: { channel in
                    pendingChannel = channel
                    selectedProgram = nil
                }
            ) { updated in
                // Reflect a new or cancelled recording in the guide right away.
                Task { if let client = session.client { await guideModel.apply(updated, client: client) } }
            }
        }
    }

    private func reload() async {
        guard let client = session.client else { return }
        await model.load(client: client)
    }

    private var miniPlayerShowing: Bool { live != nil && !liveFullScreen }

    /// Back's action while the mini player shows; nil leaves Back to the system.
    private var closeMiniPlayer: (() -> Void)? {
        miniPlayerShowing ? { stopLive() } : nil
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 40) {
            Text("Live TV")
                .font(.largeTitle.weight(.bold))
            Spacer()
            Picker("Section", selection: $section) {
                ForEach(LiveTVSection.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            // Narrower while the mini player shares the header.
            .frame(width: miniPlayerShowing ? 900 : 980)
            if let live, miniPlayerShowing {
                LiveMiniPlayer(coordinator: live) {
                    liveFullScreen = true
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: miniPlayerShowing)
    }

    /// Opens the channel full screen. With the mini player up, its player
    /// switches to the channel (if different) and goes full screen.
    private func play(channelId: String) {
        if let live {
            live.tune(channelId)
            liveFullScreen = true
            return
        }
        guard let client = session.client else { return }
        let created = PlaybackCoordinator(
            client: client,
            request: PlaybackRequest(itemId: channelId),
            autoplayNext: AppSettings.autoplayNext,
            autoSkipIntro: AppSettings.autoSkipIntro,
            preferences: session.playbackPreferences
        )
        live = created
        created.start()
        liveFullScreen = true
    }

    /// Ends the channel and closes the full-screen player and mini player.
    private func stopLive() {
        live?.stop()
        live = nil
        liveFullScreen = false
    }

    private func toggleFavorite(channelId: String) {
        guard let client = session.client else { return }
        Task { await model.toggleFavorite(channelId: channelId, client: client) }
    }
}

extension View {
    /// A long-press menu to favorite or unfavorite a channel, when a toggle is supplied.
    @ViewBuilder
    func channelFavoriteMenu(isFavorite: Bool, toggle: (() -> Void)?) -> some View {
        if let toggle {
            contextMenu {
                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "heart.slash" : "heart", action: toggle)
            }
        } else {
            self
        }
    }
}

// MARK: - Shared pieces

extension JellyfinClient {
    /// A programme's own picture, else its channel's logo.
    func programImageURL(_ program: BaseItem, width: Int = 800) -> URL? {
        if let tag = program.imageTags?["Primary"] {
            return imageURL(itemId: program.id, kind: .primary, tag: tag, maxWidth: width)
        }
        if let tag = program.imageTags?["Thumb"] {
            return imageURL(itemId: program.id, kind: .thumb, tag: tag, maxWidth: width)
        }
        if let channel = program.channelId, let tag = program.channelPrimaryImageTag {
            return imageURL(itemId: channel, kind: .primary, tag: tag, maxWidth: width)
        }
        return nil
    }

    func channelLogoURL(_ channel: BaseItem, width: Int = 400) -> URL? {
        guard let tag = channel.imageTags?["Primary"] else { return nil }
        return imageURL(itemId: channel.id, kind: .primary, tag: tag, maxWidth: width)
    }
}

enum LiveTVFormat {
    static func timeRange(start: Date?, end: Date?) -> String {
        guard let start else { return "" }
        let startText = start.formatted(date: .omitted, time: .shortened)
        guard let end else { return startText }
        return "\(startText) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    static func airing(start: Date?, end: Date?) -> String {
        guard let start else { return "" }
        return "\(dayLabel(start)), \(timeRange(start: start, end: end))"
    }
}

/// A programme that is on the air: picture, channel, title and progress.
struct ProgramCard: View {
    let program: BaseItem
    var action: () -> Void

    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: session.client?.programImageURL(program), systemImage: "tv")
                        .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    HStack {
                        if let channel = program.channelName {
                            Text([program.channelNumber, channel].compactMap { $0 }.joined(separator: " "))
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        Spacer()
                        if program.isLive == true {
                            Badge(text: "LIVE")
                        }
                    }
                    .padding(12)
                    if let fraction = program.airedFraction {
                        ProgressBar(progress: fraction)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 4)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
            }
            .cardButtonStyle()
            .accessibilityLabel([program.name, program.channelName].compactMap { $0 }.joined(separator: ", "))

            Text(program.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: Lockup.landscapeWidth, alignment: .leading)
            Text(program.episodeTitle ?? LiveTVFormat.timeRange(start: program.start, end: program.end))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Lockup.landscapeWidth, alignment: .leading)
        }
    }
}

// MARK: - On Now

struct OnNowView: View {
    let model: LiveTVModel
    var select: (BaseItem) -> Void
    var playChannel: (String) -> Void
    var toggleFavorite: (String) -> Void = { _ in }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 20) {
                if model.onNow.isEmpty && model.movies.isEmpty && model.sports.isEmpty {
                    MessageView(systemImage: "tv", title: "Nothing on right now", detail: "The guide has no programmes airing at the moment. Check the Channels section to tune in directly.")
                        .frame(height: 500)
                }
                Shelf(title: "On Now", items: model.onNow) { program in
                    ProgramCard(program: program) { select(program) }
                }
                Shelf(title: "Movies", items: model.movies) { program in
                    ProgramCard(program: program) { select(program) }
                }
                Shelf(title: "Sports", items: model.sports) { program in
                    ProgramCard(program: program) { select(program) }
                }
                Shelf(title: "Kids", items: model.kids) { program in
                    ProgramCard(program: program) { select(program) }
                }
                Shelf(title: "News", items: model.news) { program in
                    ProgramCard(program: program) { select(program) }
                }
                let favorites = model.channels.filter { $0.userData?.isFavorite == true }
                Shelf(title: "Favorite Channels", items: favorites) { channel in
                    ChannelTile(channel: channel, isFavorite: true, toggleFavorite: { toggleFavorite(channel.id) }) { playChannel(channel.id) }
                }
            }
            .padding(.vertical, 10)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Channels

struct ChannelTile: View {
    let channel: BaseItem
    var isFavorite = false
    var toggleFavorite: (() -> Void)? = nil
    var action: () -> Void

    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    if let logo = session.client?.channelLogoURL(channel) {
                        RemoteImage(url: logo, contentMode: .fit) { EmptyView() }
                            .padding(30)
                    } else {
                        Text(channel.channelNumber ?? channel.displayTitle)
                            .font(.system(size: 40, weight: .bold))
                    }
                    if let fraction = channel.currentProgram?.airedFraction {
                        ProgressBar(progress: fraction)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .frame(width: 280, height: 158)
            }
            .cardButtonStyle()
            .channelFavoriteMenu(isFavorite: isFavorite, toggle: toggleFavorite)
            .accessibilityLabel([channel.channelNumber, channel.displayTitle, channel.currentProgram?.name].compactMap { $0 }.joined(separator: ", "))

            Text([channel.channelNumber, channel.displayTitle].compactMap { $0 }.joined(separator: "  "))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: 280, alignment: .leading)
            if let now = channel.currentProgram?.name {
                Text(now)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 280, alignment: .leading)
            }
        }
    }
}

struct ChannelsGrid: View {
    let channels: [BaseItem]
    var playChannel: (String) -> Void
    var toggleFavorite: (String) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: Lockup.channelWidth, maximum: Lockup.channelWidth), spacing: Lockup.gridSpacing, alignment: .top)]

    var body: some View {
        ScrollView(.vertical) {
            if channels.isEmpty {
                MessageView(systemImage: "antenna.radiowaves.left.and.right", title: "No channels", detail: "Add a tuner or M3U source in the Jellyfin dashboard.")
                    .frame(height: 500)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Lockup.gridRowSpacing) {
                    ForEach(channels) { channel in
                        ChannelTile(channel: channel, isFavorite: channel.userData?.isFavorite == true, toggleFavorite: { toggleFavorite(channel.id) }) { playChannel(channel.id) }
                    }
                }
                .padding(.horizontal, Lockup.screenPadding)
                .padding(.vertical, 40)
            }
        }
        .scrollClipDisabled()
    }
}

// MARK: - Recordings

struct RecordingsView: View {
    let model: LiveTVModel
    var select: (BaseItem) -> Void

    @Environment(AppSession.self) private var session
    @State private var editingRule: SeriesTimerInfo?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 20) {
                if model.recordings.isEmpty && model.timers.isEmpty && model.seriesTimers.isEmpty {
                    MessageView(systemImage: "record.circle", title: "No recordings", detail: "Open a programme from the guide and choose Record to schedule one.")
                        .frame(height: 500)
                }
                Shelf(title: "Recorded", items: model.recordings) { recording in
                    LandscapeLockup(item: recording)
                }
                Shelf(title: "Scheduled", items: model.timers) { timer in
                    TimerCard(timer: timer) {
                        if let program = timer.programInfo { select(program) }
                    }
                }
                Shelf(title: "Series Rules", items: model.seriesTimers) { rule in
                    SeriesTimerCard(rule: rule) { editingRule = rule }
                }
            }
            .padding(.vertical, 10)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        // Deleting a recording happens on its own page, so refresh on return.
        .task { if let client = session.client { await model.refreshRecordings(client: client) } }
        .fullScreenCover(item: $editingRule) { rule in
            SeriesTimerOptionsView(timerId: rule.id) {
                Task { if let client = session.client { await model.refreshRecordings(client: client) } }
            }
        }
    }
}

/// One series recording rule: artwork, name, channel and the gist of its options.
struct SeriesTimerCard: View {
    let rule: SeriesTimerInfo
    var action: () -> Void

    @Environment(AppSession.self) private var session

    private var imageURL: URL? {
        guard let client = session.client else { return nil }
        if let tag = rule.imageTags?["Primary"], let program = rule.programId {
            return client.imageURL(itemId: program, kind: .primary, tag: tag, maxWidth: 800)
        }
        if let parent = rule.parentPrimaryImageItemId, let tag = rule.parentPrimaryImageTag {
            return client.imageURL(itemId: parent, kind: .primary, tag: tag, maxWidth: 800)
        }
        if let channel = rule.channelId, let tag = rule.channelPrimaryImageTag {
            return client.imageURL(itemId: channel, kind: .primary, tag: tag, maxWidth: 800)
        }
        return nil
    }

    private var summary: String {
        var parts: [String] = []
        if let channel = rule.channelName, rule.recordAnyChannel != true { parts.append(channel) }
        parts.append(rule.recordNewOnly == true ? "New episodes" : "All episodes")
        if let keep = rule.keepUpTo, keep > 0 { parts.append("Keep \(keep)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(url: imageURL, systemImage: "record.circle.fill")
                        .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
                    Image(systemName: "repeat")
                        .font(.title3)
                        .padding(12)
                        .accessibilityHidden(true)
                }
                .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
            }
            .cardButtonStyle()
            .accessibilityLabel("\(rule.name ?? "Series rule"), \(summary)")

            Text(rule.name ?? "Series Recording")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: Lockup.landscapeWidth, alignment: .leading)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Lockup.landscapeWidth, alignment: .leading)
        }
    }
}

struct TimerCard: View {
    let timer: TimerInfo
    var action: () -> Void

    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(url: timer.programInfo.flatMap { session.client?.programImageURL($0) }, systemImage: "record.circle")
                        .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
                    Image(systemName: timer.status == "InProgress" ? "record.circle.fill" : "clock.badge")
                        .font(.title3)
                        .foregroundStyle(timer.status == "InProgress" ? .red : .white)
                        .padding(12)
                        .accessibilityHidden(true)
                }
                .frame(width: Lockup.landscapeWidth, height: Lockup.landscapeHeight)
            }
            .cardButtonStyle()
            .accessibilityLabel(timer.name ?? "Recording")

            Text(timer.name ?? "Recording")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: Lockup.landscapeWidth, alignment: .leading)
            Text([timer.channelName, timer.start.map { LiveTVFormat.airing(start: $0, end: timer.end) }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Lockup.landscapeWidth, alignment: .leading)
        }
    }
}
