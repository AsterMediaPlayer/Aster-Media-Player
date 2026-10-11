//
//  ProgramDetailView.swift
//  AsterFIN
//
//  One programme from the guide: what it is, when it airs, and Watch or
//  Record actions.
//

import SwiftUI

struct ProgramDetailView: View {
    let program: BaseItem
    /// Whether the programme's channel is a favorite, when the presenter knows.
    var isChannelFavorite: Bool? = nil
    var onToggleChannelFavorite: (() -> Void)? = nil
    /// Hands Watch to the presenter, so the channel plays in Live TV's own
    /// player and can carry on in the mini player. Plays here when nil.
    var watchChannel: ((String) -> Void)? = nil
    /// Called with the server's refreshed programme after a recording is
    /// scheduled or cancelled, so the presenting screen can update at once.
    var onUpdate: (BaseItem) -> Void = { _ in }

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var detail: BaseItem?
    @State private var playback: PlaybackRequest?
    @State private var isWorking = false
    @State private var message: String?
    @State private var showSeriesOptions = false
    @State private var channelFavorite = false

    private var current: BaseItem { detail ?? program }

    /// The record to take artwork from: the fetched detail can omit image tags
    /// the listing had, which would swap the backdrop for the channel logo.
    private var artwork: BaseItem { (detail?.imageTags?.isEmpty ?? true) ? program : current }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: session.client?.programImageURL(artwork, width: 1920)) { Color(white: 0.08) }
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75), .black.opacity(0.97)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text([current.channelNumber, current.channelName].compactMap { $0 }.joined(separator: " "))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(current.displayTitle)
                    .font(.system(size: Self.titleSize, weight: .bold))
                    .lineLimit(2)

                if let episode = current.episodeTitle {
                    Text(episode)
                        .font(.title3.weight(.semibold))
                }

                #if os(tvOS)
                HStack(spacing: 14) {
                    airingText
                    badges
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                #else
                // Too much for one line on a phone: the time, then the badges.
                VStack(alignment: .leading, spacing: 8) {
                    airingText
                    HStack(spacing: 8) { badges }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                #endif

                if let overview = current.overview {
                    Text(overview)
                        .font(.callout)
                        .lineLimit(5)
                        .frame(maxWidth: 1000, alignment: .leading)
                }

                if let fraction = current.airedFraction {
                    ProgressBar(progress: fraction)
                        .frame(maxWidth: 600)
                }

                // On a phone held upright: what to do with this showing, then
                // the series and the channel.
                ActionRows {
                    programActions
                } second: {
                    seriesAndChannelActions
                }
                .disabled(isWorking)
                .padding(.top, 8)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.bottom, Self.bottomPadding)
        }
        #if !os(tvOS)
        // There's no remote Back button: give the page a way to close.
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.white)
            .accessibilityLabel("Close")
            .padding(Lockup.screenPadding)
        }
        #endif
        .task {
            channelFavorite = isChannelFavorite ?? false
            guard let client = session.client else { return }
            detail = try? await client.program(program.id)
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request) { playback = nil }
        }
        .fullScreenCover(isPresented: $showSeriesOptions) {
            if let seriesTimerId = current.seriesTimerId {
                SeriesTimerOptionsView(timerId: seriesTimerId) {
                    Task {
                        guard let client = session.client else { return }
                        if let refreshed = try? await client.program(program.id) {
                            detail = refreshed
                            onUpdate(refreshed)
                        }
                    }
                }
            }
        }
        .alert("Live TV", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    #if os(tvOS)
    private static let titleSize: CGFloat = 60
    private static let horizontalPadding: CGFloat = 90
    private static let bottomPadding: CGFloat = 80
    #else
    private static let titleSize: CGFloat = 30
    private static let horizontalPadding: CGFloat = Lockup.screenPadding
    private static let bottomPadding: CGFloat = 32
    #endif

    private var airingText: some View {
        Text(LiveTVFormat.airing(start: current.start, end: current.end))
    }

    @ViewBuilder
    private var badges: some View {
        if current.isAiringNow { Badge(text: "ON NOW") }
        if current.isLive == true { Badge(text: "LIVE") }
        if current.isPremiere == true { Badge(text: "NEW") }
        if current.isRepeat == true { Badge(text: "REPEAT") }
        if let rating = current.officialRating { Badge(text: rating) }
        if let genres = current.genres, !genres.isEmpty {
            Text(genres.prefix(2).joined(separator: ", "))
                .lineLimit(1)
        }
    }

    private func watch(_ channelId: String) {
        if let watchChannel {
            watchChannel(channelId)
        } else {
            playback = PlaybackRequest(itemId: channelId)
        }
    }

    /// Watching and recording this showing. Watch (on now) and Watch Channel
    /// (later) are never both shown.
    @ViewBuilder
    private var programActions: some View {
        if current.isAiringNow, let channel = current.channelId {
            ActionButton(title: "Watch", systemImage: "play.fill", prominent: true) {
                watch(channel)
            }
        }
        if !current.isAiringNow, let channel = current.channelId {
            ActionButton(title: "Watch Channel", systemImage: "tv") {
                watch(channel)
            }
        }
        if let end = current.end, end > Date() {
            if let timer = current.timerId {
                ActionButton(title: "Cancel Recording", systemImage: "xmark.circle") {
                    perform { try await $0.cancelTimer(timer) }
                }
            } else {
                ActionButton(title: "Record", systemImage: "record.circle", prominent: !current.isAiringNow) {
                    perform { try await $0.recordProgram(current.id) }
                }
            }
        }
    }

    /// Recording the whole series, and favoriting the channel.
    @ViewBuilder
    private var seriesAndChannelActions: some View {
        if let end = current.end, end > Date(), current.isSeries == true {
            if current.seriesTimerId != nil {
                ActionButton(title: "Series Options", systemImage: "slider.horizontal.3") {
                    showSeriesOptions = true
                }
            } else {
                ActionButton(title: "Record Series", systemImage: "record.circle.fill") {
                    perform { try await $0.recordSeries(programId: current.id) }
                }
            }
        }
        if let toggle = onToggleChannelFavorite {
            IconButton(systemImage: channelFavorite ? "heart.fill" : "heart", accessibilityLabel: channelFavorite ? "Remove channel from favorites" : "Favorite channel") {
                channelFavorite.toggle()
                toggle()
            }
        }
        if isWorking {
            ProgressView().controlSize(.small)
        }
    }

    private func perform(_ work: @escaping (JellyfinClient) async throws -> Void) {
        guard let client = session.client else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await work(client)
                let refreshed = try await client.program(program.id)
                detail = refreshed
                onUpdate(refreshed)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
