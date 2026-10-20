//
//  GuideView.swift
//  AsterFIN
//
//  The programme guide: channels down the side, time across the top, and a
//  cell for every programme. Focus drives the visible time window.
//

import SwiftUI

/// Where the guide's listings come from: Jellyfin's Live TV (`GuideModel`),
/// or a schedule worked out on the device (`ChannelGuideSource`).
protocol GuideSource: AnyObject {
    var guideStart: Date { get }
    var guideEnd: Date { get }
    /// Each channel's programmes, keyed by channel id; a channel is missing
    /// until its row has loaded.
    var programs: [String: [BaseItem]] { get }
    func program(withId id: String) -> BaseItem?
    func channelId(forProgram id: String) -> String?
    func airingProgram(for channelId: String) -> BaseItem?
    func detail(for program: BaseItem) -> BaseItem
    func hasDetail(for programId: String) -> Bool
    func ensureDetail(for programId: String, client: JellyfinClient)
    func ensurePrograms(for channelId: String, client: JellyfinClient)
    func programImageURL(_ program: BaseItem, width: Int, client: JellyfinClient) -> URL?
    func channelLogoURL(_ channel: BaseItem, width: Int, client: JellyfinClient) -> URL?
}

extension GuideSource {
    func programImageURL(_ program: BaseItem, width: Int, client: JellyfinClient) -> URL? {
        client.programImageURL(program, width: width)
    }

    func channelLogoURL(_ channel: BaseItem, width: Int, client: JellyfinClient) -> URL? {
        client.channelLogoURL(channel, width: width)
    }
}

@Observable
final class GuideModel: GuideSource {
    let guideStart: Date
    let guideEnd: Date

    private(set) var programs: [String: [BaseItem]] = [:]
    private var programIndex: [String: BaseItem] = [:]
    private var programChannel: [String: String] = [:]
    private var loading: [String: Task<Void, Never>] = [:]
    private var details: [String: BaseItem] = [:]
    private var detailLoading: Set<String> = []

    init() {
        let now = Date()
        let floored = GuideModel.floorToHalfHour(now)
        guideStart = floored
        guideEnd = floored.addingTimeInterval(24 * 3600)
    }

    static func floorToHalfHour(_ date: Date) -> Date {
        let interval = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (interval / 1800).rounded(.down) * 1800)
    }

    func program(withId id: String) -> BaseItem? {
        programIndex[id]
    }

    /// The channel a loaded programme belongs to.
    func channelId(forProgram id: String) -> String? {
        programChannel[id]
    }

    /// The programme on the air right now on a channel, once its row has loaded.
    func airingProgram(for channelId: String) -> BaseItem? {
        programs[channelId]?.first { $0.isAiringNow }
    }

    /// The full record for a programme (artwork, overview, episode numbers),
    /// which the lightweight guide listing leaves out. Falls back to the listing.
    func detail(for program: BaseItem) -> BaseItem {
        guard var detail = details[program.id] else { return program }
        // The detail endpoint can omit image tags that the listing included.
        // Keep the listing's so the picture's URL, and so the picture itself,
        // does not change once the detail arrives.
        if detail.imageTags?.isEmpty ?? true {
            detail.imageTags = program.imageTags
        }
        if detail.channelPrimaryImageTag == nil {
            detail.channelPrimaryImageTag = program.channelPrimaryImageTag
        }
        return detail
    }

    func hasDetail(for programId: String) -> Bool {
        details[programId] != nil
    }

    func ensureDetail(for programId: String, client: JellyfinClient) {
        guard details[programId] == nil, !detailLoading.contains(programId) else { return }
        detailLoading.insert(programId)
        Task { [weak self] in
            guard let self else { return }
            defer { self.detailLoading.remove(programId) }
            if let detail = try? await client.program(programId) {
                self.details[programId] = detail
            }
        }
    }

    /// Starts loading a channel's programmes. The request runs in its own task
    /// so a row scrolling off screen cannot cancel it, and a failed request is
    /// not cached, so the next appearance retries.
    func ensurePrograms(for channelId: String, client: JellyfinClient) {
        guard programs[channelId] == nil, loading[channelId] == nil else { return }
        loading[channelId] = Task { [weak self] in
            guard let self else { return }
            defer { self.loading[channelId] = nil }
            if let kept = await self.fetchPrograms(for: channelId, client: client) {
                self.store(kept, for: channelId)
            }
        }
    }

    /// Puts a programme returned by the server (after recording or cancelling)
    /// into the guide at once, then reloads its channel's row so other airings
    /// of the same series show the change too.
    func apply(_ updated: BaseItem, client: JellyfinClient) async {
        programIndex[updated.id] = updated
        details[updated.id] = updated
        guard let channelId = updated.channelId ?? programChannel[updated.id] else { return }
        if var row = programs[channelId], let index = row.firstIndex(where: { $0.id == updated.id }) {
            row[index] = updated
            programs[channelId] = row
        }
        if let kept = await fetchPrograms(for: channelId, client: client) {
            store(kept, for: channelId)
        }
    }

    /// The channel's programmes for the guide's span, dropping any that ended
    /// before the guide starts. Nil when the request fails.
    private func fetchPrograms(for channelId: String, client: JellyfinClient) async -> [BaseItem]? {
        guard let loaded = try? await client.programs(channelId: channelId, from: guideStart, to: guideEnd) else { return nil }
        return loaded.filter { program in
            guard let end = program.end else { return false }
            return end > guideStart.addingTimeInterval(60)
        }
    }

    private func store(_ kept: [BaseItem], for channelId: String) {
        programs[channelId] = kept
        for program in kept {
            programIndex[program.id] = program
            programChannel[program.id] = channelId
        }
    }
}

struct GuideView: View {
    /// Owned by the Live TV screen so recording changes made from the programme
    /// sheet can be pushed straight into the guide.
    let model: any GuideSource
    let channels: [BaseItem]
    var select: (BaseItem) -> Void
    var playChannel: (String) -> Void
    /// What Select on a channel cell does, when it isn't tuning in (the
    /// Channels tab's opens the channel's settings for an administrator).
    var openChannel: ((String) -> Void)? = nil
    /// Nil leaves the favourites menu off the channel cells.
    var toggleFavorite: ((String) -> Void)? = nil
    var emptyDetail = "Add a tuner or M3U source in the Jellyfin dashboard."

    @Environment(AppSession.self) private var session
    @State private var windowStart = GuideModel.floorToHalfHour(Date())
    @State private var timelineWidth: CGFloat = 1418
    @FocusState private var focusedProgram: String?
    @FocusState private var focusedChannel: String?
    /// A row's loading or "no data" placeholder, keyed by channel id.
    @FocusState private var focusedPlaceholder: String?
    /// The channel whose row last had focus; it keeps its panel while focus is
    /// up in the section picker.
    @State private var highlightedChannelId: String?
    /// The programme cell that last had focus; nil when a channel cell did.
    @State private var highlightedProgramId: String?
    @Namespace private var gridFocus

    private enum FocusKind { case program, channel, placeholder }
    @State private var lastFocusKind: FocusKind?
    /// A channel cell that focus fell onto from another row's programme column,
    /// because that row had no cells yet. Focus is nudged into the row once its
    /// listings arrive.
    @State private var pendingNudgeChannelId: String?

    private var pendingNudgeLoaded: Bool {
        guard let id = pendingNudgeChannelId else { return false }
        return model.programs[id] != nil
    }

    /// The leftmost programme in the visible window on a channel, if loaded.
    private func firstVisibleProgram(in channelId: String) -> BaseItem? {
        guard let programs = model.programs[channelId] else { return nil }
        let windowEnd = windowStart.addingTimeInterval(visibleMinutes * 60)
        return programs.first { program in
            guard let start = program.start, let end = program.end else { return false }
            return end > windowStart && start < windowEnd
        } ?? programs.first
    }

    /// Warms the image cache for the programmes in the visible window on this
    /// row and its neighbours, so the panel's picture is ready before focus
    /// arrives there.
    private func prefetchArtwork(around channelId: String) {
        guard let client = session.client, let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        let windowEnd = windowStart.addingTimeInterval(visibleMinutes * 60)
        var urls: [URL] = []
        for offset in -1...2 {
            let row = index + offset
            guard channels.indices.contains(row), let programs = model.programs[channels[row].id] else { continue }
            for program in programs {
                guard let start = program.start, let end = program.end, end > windowStart, start < windowEnd else { continue }
                if let url = model.programImageURL(program, width: GuideNowPlayingPanel.imageWidth, client: client) {
                    urls.append(url)
                }
            }
        }
        ImageStore.shared.prefetch(urls, client: client)
    }

    /// Where focus goes on entering the grid: the programme at the start of
    /// the window (on now, unless the window has moved) on the row last
    /// highlighted, else the first.
    private var entryProgramId: String? {
        guard let channelId = highlightedChannelId ?? channels.first?.id else { return nil }
        return firstVisibleProgram(in: channelId)?.id
    }

    private func nudgeIntoRow(_ channelId: String) {
        pendingNudgeChannelId = nil
        if let target = firstVisibleProgram(in: channelId) {
            focusedProgram = target.id
        } else {
            focusedPlaceholder = channelId
        }
    }

    private var highlightedChannel: BaseItem? {
        if let id = highlightedChannelId, let channel = channels.first(where: { $0.id == id }) {
            return channel
        }
        return channels.first
    }

    /// The focused programme, or what is airing on the focused channel, with
    /// its full record once fetched.
    private var highlightedProgram: BaseItem? {
        if let id = highlightedProgramId, let program = model.program(withId: id) {
            return model.detail(for: program)
        }
        guard let channel = highlightedChannel, let airing = model.airingProgram(for: channel.id) else { return nil }
        return model.detail(for: airing)
    }

    #if os(tvOS)
    static let channelColumnWidth: CGFloat = 250
    static let rowHeight: CGFloat = 96
    static let pointsPerMinute: CGFloat = 8
    static let columnGap: CGFloat = 12
    /// Space between neighbouring programme cells in a row.
    static let cellGap: CGFloat = 6
    static let cellPadding = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    static let cornerRadius: CGFloat = 12
    /// A cell keeps at least this much of itself readable when its start is
    /// scrolled out of view to the left.
    static let minimumVisibleCell: CGFloat = 160
    /// The narrowest a cell is drawn, however short the programme.
    static let minimumCellWidth: CGFloat = 40
    static let titleFont: Font = .callout.weight(.semibold)
    static let subtitleFont: Font = .caption
    #else
    // About an hour of guide across a phone held upright, three on its side.
    static let channelColumnWidth: CGFloat = 88
    static let rowHeight: CGFloat = 60
    static let pointsPerMinute: CGFloat = 4
    static let columnGap: CGFloat = 6
    static let cellGap: CGFloat = 4
    static let cellPadding = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
    static let cornerRadius: CGFloat = 8
    static let minimumVisibleCell: CGFloat = 80
    static let minimumCellWidth: CGFloat = 20
    static let titleFont: Font = .footnote.weight(.semibold)
    static let subtitleFont: Font = .caption2
    #endif
    static let horizontalPadding: CGFloat = Lockup.screenPadding

    /// Minutes that fit in the timeline at its measured width.
    private var visibleMinutes: Double {
        Double(timelineWidth / Self.pointsPerMinute)
    }

    var body: some View {
        VStack(spacing: 8) {
            #if os(tvOS)
            // The panel follows the remote's focus. A phone has no focus to
            // follow, and tapping a programme opens its page instead.
            if let channel = highlightedChannel {
                GuideNowPlayingPanel(
                    source: model,
                    channel: channel,
                    program: highlightedProgram,
                    detailLoaded: highlightedProgram.map { model.hasDetail(for: $0.id) } ?? false
                )
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.top, 4)
            }
            #endif

            GuideHeader(guideStart: model.guideStart, guideEnd: model.guideEnd, windowStart: windowStart, visibleMinutes: visibleMinutes, jumpToNow: jumpToNow, days: days, jumpToDay: jump(toDay:)) { width in
                if width > 0, abs(width - timelineWidth) > 1 { timelineWidth = width }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, 10)
            #if !os(tvOS)
            // The whole strip, padding included, takes the drag; the day
            // picker and Now still take taps.
            .contentShape(Rectangle())
            .gesture(timeDrag)
            #endif

            if channels.isEmpty {
                MessageView(systemImage: "antenna.radiowaves.left.and.right", title: "No channels", detail: emptyDetail)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 10) {
                            ForEach(channels) { channel in
                                GuideRow(
                                    channel: channel,
                                    logoURL: session.client.flatMap { model.channelLogoURL(channel, width: 200, client: $0) },
                                    programs: model.programs[channel.id],
                                    guideStart: model.guideStart,
                                    windowStart: windowStart,
                                    visibleMinutes: visibleMinutes,
                                    isFirstRow: channel.id == channels.first?.id,
                                    focusNamespace: gridFocus,
                                    focus: $focusedProgram,
                                    channelFocus: $focusedChannel,
                                    placeholderFocus: $focusedPlaceholder,
                                    playChannel: { playChannel(channel.id) },
                                    openChannel: openChannel.map { open in { open(channel.id) } },
                                    toggleFavorite: toggleFavorite.map { toggle in { toggle(channel.id) } },
                                    select: select
                                )
                                .id(channel.id)
                                .onAppear {
                                    guard let client = session.client else { return }
                                    model.ensurePrograms(for: channel.id, client: client)
                                    // Fetch a stretch of rows ahead too, so a held
                                    // button rarely reaches a row that is still loading.
                                    if let index = channels.firstIndex(where: { $0.id == channel.id }) {
                                        for next in channels.dropFirst(index + 1).prefix(10) {
                                            model.ensurePrograms(for: next.id, client: client)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, Self.horizontalPadding)
                        .padding(.vertical, 20)
                        .padding(.bottom, 60)
                    }
                    .tvFocusSection()
                    #if os(tvOS)
                    .focusScope(gridFocus)
                    // Coming down into the grid (from the day picker, say)
                    // lands on what's on in view on the current row, rather
                    // than whichever cell happens to sit under the button.
                    .defaultFocus($focusedProgram, entryProgramId, priority: .userInitiated)
                    #endif
                    // The lazy stack builds a row or two past the bottom edge, so
                    // focus can reach them before the system's animated scroll
                    // catches up, and a held button repeats faster than that
                    // animation. Jump to the highlighted row without animating so
                    // the focused row is always on screen the moment focus lands.
                    .onChange(of: highlightedChannelId) { _, id in
                        guard let id else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
        }
        .onChange(of: focusedProgram) { _, id in
            guard let id, let program = model.program(withId: id) else { return }
            lastFocusKind = .program
            pendingNudgeChannelId = nil
            highlightedProgramId = id
            if let channelId = program.channelId ?? model.channelId(forProgram: id) {
                highlightedChannelId = channelId
            }
            reveal(program)
        }
        .onChange(of: focusedChannel) { _, id in
            guard let id else { return }
            // Coming from a programme cell or placeholder in a *different* row
            // means focus fell here only because this row had no cells yet. A
            // sideways move within the same row is a deliberate visit.
            let fellFromAnotherRow = (lastFocusKind == .program || lastFocusKind == .placeholder) && id != highlightedChannelId
            lastFocusKind = .channel
            highlightedChannelId = id
            highlightedProgramId = nil
            guard fellFromAnotherRow else { return }
            if model.programs[id] != nil {
                nudgeIntoRow(id)
            } else {
                pendingNudgeChannelId = id
            }
        }
        .onChange(of: focusedPlaceholder) { _, id in
            guard let id else { return }
            lastFocusKind = .placeholder
            pendingNudgeChannelId = nil
            highlightedChannelId = id
            highlightedProgramId = nil
        }
        .onChange(of: pendingNudgeLoaded) { _, loaded in
            guard loaded, let id = pendingNudgeChannelId, focusedChannel == id else {
                pendingNudgeChannelId = nil
                return
            }
            nudgeIntoRow(id)
        }
        .task(id: highlightedProgram?.id) {
            guard let id = highlightedProgram?.id, let client = session.client else { return }
            model.ensureDetail(for: id, client: client)
            if let channelId = highlightedChannelId ?? channels.first?.id {
                prefetchArtwork(around: channelId)
            }
        }
    }

    /// The earliest and latest the window can start, so it stays inside the guide.
    private func clampedWindow(_ start: Date) -> Date {
        let latest = max(model.guideStart, model.guideEnd.addingTimeInterval(-visibleMinutes * 60))
        return min(max(start, model.guideStart), latest)
    }

    /// The start of each day the guide reaches into, when it covers several;
    /// a guide of a day (Live TV's) has no day picker.
    private var days: [Date] {
        guard model.guideEnd.timeIntervalSince(model.guideStart) > 26 * 3600 else { return [] }
        let calendar = Calendar.current
        var result: [Date] = []
        var day = calendar.startOfDay(for: model.guideStart)
        while day < model.guideEnd {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// Moves the window to `day` at the time of day it is now; today means now.
    private func jump(toDay day: Date) {
        let calendar = Calendar.current
        let now = Date()
        let time = calendar.dateComponents([.hour, .minute], from: now)
        let target = calendar.isDate(day, inSameDayAs: now)
            ? now
            : calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day
        // The panel goes back to what's on the channel, as the highlighted
        // programme is no longer in view.
        highlightedProgramId = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            windowStart = clampedWindow(GuideModel.floorToHalfHour(target))
        }
    }

    /// Back to the current half hour, offered once the window has moved on.
    private var jumpToNow: (() -> Void)? {
        #if os(tvOS)
        return nil
        #else
        let now = clampedWindow(GuideModel.floorToHalfHour(Date()))
        guard abs(windowStart.timeIntervalSince(now)) >= 60 else { return nil }
        return {
            withAnimation(.easeInOut(duration: 0.25)) { windowStart = now }
        }
        #endif
    }

    #if !os(tvOS)
    /// Where the window started when the drag began.
    @State private var dragOrigin: Date?

    /// On a touch screen the time strip is dragged sideways through time.
    /// It has nothing to tap, so the drag can't be taken for a tap on a
    /// programme or a scroll up or down the grid, as it was there. The
    /// window follows the finger, a flick carries on, and it settles on the
    /// nearest quarter hour.
    private var timeDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = windowStart }
                guard let origin = dragOrigin else { return }
                windowStart = clampedWindow(origin.addingTimeInterval(minutes(for: value.translation.width) * 60))
            }
            .onEnded { value in
                defer { dragOrigin = nil }
                guard let origin = dragOrigin else { return }
                let coasted = origin.addingTimeInterval(minutes(for: value.predictedEndTranslation.width) * 60)
                let quarter: TimeInterval = 900
                let snapped = Date(timeIntervalSinceReferenceDate: (coasted.timeIntervalSinceReferenceDate / quarter).rounded() * quarter)
                withAnimation(.easeOut(duration: 0.35)) {
                    windowStart = clampedWindow(snapped)
                }
            }
    }

    /// Minutes the window moves for a sideways drag: dragging left goes later.
    private func minutes(for width: CGFloat) -> Double {
        -Double(width / Self.pointsPerMinute)
    }
    #endif

    /// Shifts the time window so the focused programme is in view.
    private func reveal(_ program: BaseItem) {
        guard let start = program.start, let end = program.end else { return }
        let visibleStart = max(start, model.guideStart)
        let windowEnd = windowStart.addingTimeInterval(visibleMinutes * 60)
        let needed = min(end, visibleStart.addingTimeInterval(1800))
        guard visibleStart < windowStart || needed > windowEnd else { return }
        var target = GuideModel.floorToHalfHour(visibleStart)
        let latest = model.guideEnd.addingTimeInterval(-visibleMinutes * 60)
        target = min(max(target, model.guideStart), max(model.guideStart, latest))
        withAnimation(.easeInOut(duration: 0.25)) {
            windowStart = target
        }
    }
}

// MARK: - Time-based layout

/// A span of time a child occupies in the timeline.
nonisolated struct GuideSlot: Equatable {
    var start: Date
    var end: Date
}

nonisolated struct GuideSlotKey: LayoutValueKey {
    static let defaultValue: GuideSlot? = nil
}

/// Places each child at the horizontal position of its time slot relative to
/// the visible window. Children get real frames, so focus moves between them
/// geometrically and the container never grows past its proposed width.
struct GuideTimelineLayout: Layout {
    let windowStart: Date
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            guard let slot = subview[GuideSlotKey.self] else {
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: nil, height: bounds.height))
                continue
            }
            let x = CGFloat(slot.start.timeIntervalSince(windowStart) / 60) * GuideView.pointsPerMinute
            let width = CGFloat(slot.end.timeIntervalSince(slot.start) / 60) * GuideView.pointsPerMinute
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: max(GuideView.minimumCellWidth, width - GuideView.cellGap), height: bounds.height)
            )
        }
    }
}

// MARK: - Header

struct GuideHeader: View {
    let guideStart: Date
    let guideEnd: Date
    let windowStart: Date
    let visibleMinutes: Double
    /// Shown in place of the day label when the window has moved off the
    /// current time; nil keeps the label.
    var jumpToNow: (() -> Void)? = nil
    /// The start of each day a guide of several days reaches into; with
    /// any, a day picker takes the day label's place.
    var days: [Date] = []
    var jumpToDay: (Date) -> Void = { _ in }
    var onMeasure: (CGFloat) -> Void

    /// "Today", "Tomorrow" or "Sat 18": short enough for the channel column.
    private var shortDayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(windowStart) || calendar.isDateInTomorrow(windowStart) {
            return LiveTVFormat.dayLabel(windowStart)
        }
        return windowStart.formatted(.dateTime.weekday(.abbreviated).day())
    }

    private var slots: [Date] {
        var result: [Date] = []
        let lower = windowStart.addingTimeInterval(-1800)
        let upper = windowStart.addingTimeInterval(visibleMinutes * 60 + 1800)
        var cursor = guideStart
        while cursor < guideEnd {
            if cursor >= lower, cursor <= upper { result.append(cursor) }
            cursor = cursor.addingTimeInterval(1800)
        }
        return result
    }

    var body: some View {
        HStack(spacing: GuideView.columnGap) {
            Group {
                if !days.isEmpty {
                    // Today goes back to now; another day opens at the same
                    // time of day, as a TV guide's day buttons do.
                    Menu {
                        ForEach(days, id: \.self) { day in
                            Button(LiveTVFormat.dayLabel(day)) { jumpToDay(day) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(shortDayLabel)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Image(systemName: "chevron.down")
                                .imageScale(.small)
                        }
                        #if os(tvOS)
                        .font(.headline)
                        #else
                        .font(.subheadline.weight(.semibold))
                        #endif
                    }
                    #if !os(tvOS)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    #endif
                } else if let jumpToNow {
                    Button(action: jumpToNow) {
                        Label("Now", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text(LiveTVFormat.dayLabel(windowStart))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: GuideView.channelColumnWidth, alignment: .leading)

            GuideTimelineLayout(windowStart: windowStart, height: 32) {
                ForEach(slots, id: \.timeIntervalSinceReferenceDate) { slot in
                    Text(slot.formatted(date: .omitted, time: .shortened))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutValue(key: GuideSlotKey.self, value: GuideSlot(start: slot, end: slot.addingTimeInterval(1800)))
                }
                let now = Date()
                if now >= windowStart {
                    Rectangle()
                        .fill(.red)
                        .frame(width: 3, height: 28)
                        .accessibilityHidden(true)
                        .layoutValue(key: GuideSlotKey.self, value: GuideSlot(start: now, end: now.addingTimeInterval(60)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 32, alignment: .leading)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                onMeasure(width)
            }
        }
        // Its own section, so pressing up anywhere in the grid can reach the
        // day picker rather than whatever sits above it.
        .tvFocusSection()
        .accessibilityElement(children: days.isEmpty ? .combine : .contain)
    }
}

// MARK: - Now playing

/// What is on the air right now on the highlighted channel, shown in the top
/// right above the grid. Uses the guide's programme when the row has loaded,
/// else the channel's own current-programme summary.
struct GuideNowPlayingPanel: View {
    let source: any GuideSource
    let channel: BaseItem
    let program: BaseItem?
    /// Whether the programme's full record has arrived.
    var detailLoaded = false

    @Environment(AppSession.self) private var session

    /// Requested width; a 16:9 picture shows at exactly this size, so the same
    /// URL is used for prefetching and display and hits the cache.
    static let imageWidth = 400

    /// The programme's own picture, else its channel's logo.
    private var imageURL: URL? {
        guard let client = session.client else { return nil }
        if let program {
            let hasOwnPicture = program.imageTags?["Primary"] != nil || program.imageTags?["Thumb"] != nil
            // Without a picture of its own, wait for the full record before
            // falling back to the channel logo, so a logo is never shown and
            // then replaced a moment later.
            guard hasOwnPicture || detailLoaded else { return nil }
            return source.programImageURL(program, width: Self.imageWidth, client: client)
        }
        if let current = channel.currentProgram, let tag = current.imageTags?["Primary"] {
            return client.imageURL(itemId: current.id, kind: .primary, tag: tag, maxWidth: Self.imageWidth)
        }
        return source.channelLogoURL(channel, width: Self.imageWidth, client: client)
    }

    // The channel's own current-programme summary is only used when no guide
    // programme is highlighted, so a focused cell never shows another show's text.
    private var title: String? { program != nil ? program?.name : channel.currentProgram?.name }
    private var overview: String? { program != nil ? program?.overview : channel.currentProgram?.overview }
    private var episodeTitle: String? { program != nil ? program?.episodeTitle : channel.currentProgram?.episodeTitle }

    /// "S3, E12 · Episode Name", or whichever parts the listing has. Programmes
    /// are typed "Program" rather than "Episode", so this does not use episodeCode.
    private var episodeLine: String? {
        var parts: [String] = []
        if let episode = program?.indexNumber {
            if let season = program?.parentIndexNumber {
                parts.append("S\(season), E\(episode)")
            } else {
                parts.append("Episode \(episode)")
            }
        }
        if let episodeTitle, episodeTitle != title {
            parts.append(episodeTitle)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            // The picture takes whatever is left of the row and fits to the
            // panel's height, so a 16:9 still grows to 400 wide while a poster
            // stays 150 wide.
            if let imageURL {
                RemoteImage(url: imageURL, contentMode: .fit) { EmptyView() }
                    .frame(maxHeight: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                Spacer()
            }

            // The text box lines up under the section picker, which is 980 wide.
            VStack(alignment: .leading, spacing: 10) {
                if let title {
                    // A step above the callout (31pt) detail lines beneath it.
                    Text(title)
                        .font(.system(size: 34, weight: .semibold))
                        .lineLimit(2)
                    if let episodeLine {
                        Text(episodeLine)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                    }
                    if let overview {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                } else {
                    Text("No programme information")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 980, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 225, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows and cells

struct GuideRow: View {
    let channel: BaseItem
    let logoURL: URL?
    let programs: [BaseItem]?
    let guideStart: Date
    let windowStart: Date
    let visibleMinutes: Double
    let isFirstRow: Bool
    let focusNamespace: Namespace.ID
    let focus: FocusState<String?>.Binding
    let channelFocus: FocusState<String?>.Binding
    let placeholderFocus: FocusState<String?>.Binding
    var playChannel: () -> Void
    /// Select on the channel cell, in place of tuning in.
    var openChannel: (() -> Void)? = nil
    var toggleFavorite: (() -> Void)? = nil
    var select: (BaseItem) -> Void

    /// Programmes near the window, including one hour either side so focus can
    /// move to them before they scroll into view.
    private var nearby: [BaseItem] {
        guard let programs else { return [] }
        let margin: TimeInterval = 3600
        let lower = windowStart.addingTimeInterval(-margin)
        let upper = windowStart.addingTimeInterval(visibleMinutes * 60 + margin)
        return programs.filter { program in
            guard let start = program.start, let end = program.end else { return false }
            return end > lower && start < upper && end > guideStart
        }
    }

    var body: some View {
        HStack(spacing: GuideView.columnGap) {
            ChannelCell(channel: channel, logoURL: logoURL, isFocused: channelFocus.wrappedValue == channel.id, isFavorite: channel.userData?.isFavorite == true, toggleFavorite: toggleFavorite, action: openChannel ?? playChannel)
                .frame(width: GuideView.channelColumnWidth, height: GuideView.rowHeight)
                .focused(channelFocus, equals: channel.id)

            GuideTimelineLayout(windowStart: windowStart, height: GuideView.rowHeight) {
                // Placeholders are focusable so a row without cells is never
                // skipped: a down press always lands one row lower, never on a
                // loaded row several screens away.
                if programs == nil {
                    GuidePlaceholderCell(text: nil, isFocused: placeholderFocus.wrappedValue == channel.id) {}
                        .focused(placeholderFocus, equals: channel.id)
                        .layoutValue(key: GuideSlotKey.self, value: GuideSlot(start: windowStart, end: windowStart.addingTimeInterval(5400)))
                } else if nearby.isEmpty {
                    GuidePlaceholderCell(text: "No guide data", isFocused: placeholderFocus.wrappedValue == channel.id, action: playChannel)
                        .focused(placeholderFocus, equals: channel.id)
                        .layoutValue(key: GuideSlotKey.self, value: GuideSlot(start: windowStart, end: windowStart.addingTimeInterval(5400)))
                }
                ForEach(nearby) { program in
                    let slot = self.slot(for: program)
                    let cellWidth = CGFloat(slot.end.timeIntervalSince(slot.start) / 60) * GuideView.pointsPerMinute - GuideView.cellGap
                    let hidden = max(0, CGFloat(windowStart.timeIntervalSince(slot.start) / 60) * GuideView.pointsPerMinute)
                    ProgramCell(
                        program: program,
                        visibleStart: slot.start,
                        leadingInset: min(hidden, max(0, cellWidth - GuideView.minimumVisibleCell)),
                        isFocused: focus.wrappedValue == program.id
                    ) {
                        select(program)
                    }
                    .focused(focus, equals: program.id)
                    #if os(tvOS)
                    .prefersDefaultFocus(isFirstRow && program.isAiringNow, in: focusNamespace)
                    #endif
                    .layoutValue(key: GuideSlotKey.self, value: slot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: GuideView.rowHeight, alignment: .topLeading)
            .clipped()
        }
        .frame(height: GuideView.rowHeight)
        // When data lands while the loading placeholder has focus, move focus to
        // the leftmost visible programme so the highlight stays on this row.
        .onChange(of: programs == nil) { wasLoading, isLoading in
            guard wasLoading, !isLoading, placeholderFocus.wrappedValue == channel.id else { return }
            if let target = nearby.first(where: { ($0.end ?? .distantPast) > windowStart }) ?? nearby.first {
                focus.wrappedValue = target.id
            }
        }
    }

    /// The programme's time span, clipped to the start of the guide.
    private func slot(for program: BaseItem) -> GuideSlot {
        let start = max(program.start ?? guideStart, guideStart)
        let end = max(program.end ?? start.addingTimeInterval(1800), start.addingTimeInterval(300))
        return GuideSlot(start: start, end: end)
    }
}

/// Stands in for a row's programme cells while they load, or when the channel
/// has no listings. Focusable so rows are never skipped over.
struct GuidePlaceholderCell: View {
    /// The message to show; nil shows a spinner.
    let text: String?
    let isFocused: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: GuideView.cornerRadius)
                .fill(isFocused ? Color.white : Color(white: 0.12))
                .overlay {
                    if let text {
                        Text(text)
                            .font(.callout)
                            .foregroundStyle(isFocused ? Color.black.opacity(0.7) : .secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(isFocused ? .black : .white)
                    }
                }
        }
        .buttonStyle(GuideCellButtonStyle())
        .accessibilityLabel(text ?? "Loading guide")
    }
}

struct ChannelCell: View {
    let channel: BaseItem
    /// The channel's logo; nil shows its name.
    let logoURL: URL?
    /// Highlighted as the programme cells are: white, with dark text.
    var isFocused = false
    var isFavorite = false
    var toggleFavorite: (() -> Void)? = nil
    var action: () -> Void

    #if os(tvOS)
    private static let spacing: CGFloat = 12
    private static let numberWidth: CGFloat = 56
    private static let numberFont: Font = .callout.weight(.bold)
    #else
    private static let spacing: CGFloat = 4
    private static let numberWidth: CGFloat = 26
    private static let numberFont: Font = .caption2.weight(.bold)
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: Self.spacing) {
                Text(channel.channelNumber ?? "")
                    .font(Self.numberFont)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.7) : .secondary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(width: Self.numberWidth, alignment: .leading)
                if let logo = logoURL {
                    RemoteImage(url: logo, contentMode: .fit) {
                        Text(channel.displayTitle).font(GuideView.titleFont).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(channel.displayTitle)
                        .font(GuideView.titleFont)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, GuideView.cellPadding.leading)
            .padding(.vertical, GuideView.cellPadding.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(isFocused ? .black : .white)
            .background(RoundedRectangle(cornerRadius: GuideView.cornerRadius).fill(isFocused ? Color.white : Color(white: 0.16)))
        }
        .buttonStyle(GuideCellButtonStyle())
        .channelFavoriteMenu(isFavorite: isFavorite, toggle: toggleFavorite)
        .accessibilityLabel("Watch \([channel.channelNumber, channel.displayTitle].compactMap { $0 }.joined(separator: " "))")
    }
}

struct ProgramCell: View {
    let program: BaseItem
    /// Where the cell begins on screen (the programme's start, or the guide's).
    let visibleStart: Date
    /// How far the cell's left edge is scrolled out of view, so the text stays visible.
    let leadingInset: CGFloat
    let isFocused: Bool
    var action: () -> Void

    /// Share of the visible cell that has already aired.
    private var airedFraction: Double? {
        guard let end = program.end, program.isAiringNow, end > visibleStart else { return nil }
        return min(1, max(0, Date().timeIntervalSince(visibleStart) / end.timeIntervalSince(visibleStart)))
    }

    private var subtitle: String {
        if let episode = program.episodeTitle, episode != program.name {
            return episode
        }
        return LiveTVFormat.timeRange(start: program.start, end: program.end)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if program.timerId != nil || program.seriesTimerId != nil {
                        Image(systemName: "record.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                    }
                    Text(program.displayTitle)
                        .font(GuideView.titleFont)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(GuideView.subtitleFont)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.7) : .secondary)
                    .lineLimit(1)
            }
            .padding(.leading, GuideView.cellPadding.leading + leadingInset)
            .padding(.trailing, GuideView.cellPadding.trailing)
            .padding(.vertical, GuideView.cellPadding.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(isFocused ? .black : .white)
            .background(alignment: .leading) {
                if let fraction = airedFraction {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(isFocused ? Color.black.opacity(0.12) : Color.white.opacity(0.12))
                            .frame(width: geo.size.width * fraction)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: GuideView.cornerRadius).fill(isFocused ? Color.white : Color(white: program.isAiringNow ? 0.22 : 0.16)))
            .clipShape(RoundedRectangle(cornerRadius: GuideView.cornerRadius))
        }
        .buttonStyle(GuideCellButtonStyle())
        .accessibilityLabel([program.name, program.episodeTitle, LiveTVFormat.timeRange(start: program.start, end: program.end)].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Cells draw their own focus look so the grid stays flat and aligned.
struct GuideCellButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.03 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
