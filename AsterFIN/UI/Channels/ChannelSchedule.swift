//
//  ChannelSchedule.swift
//  AsterFIN
//
//  What's on a Channel, worked out from the clock. A channel is a playlist
//  of movies and TV episodes, grouped into shows (a series, or a single
//  movie). Each day the shows take turns in a shuffled order, and every
//  device shuffles the same way, so the Apple TV and the iPhone show the
//  same thing at the same moment with nothing stored and no server involved.
//
//  The timeline runs back to back from a fixed start (local midnight, 1
//  January 2026). Each day picks up where the day before ended: whatever is
//  playing at midnight finishes first, then the new day's order begins,
//  going round it again until the next midnight. A channel can keep its
//  order for a week or a month instead (`ChannelReshuffle`). A show plays its
//  episodes in order and carries on from where it got to, like reruns.
//
//  A channel with break clips (`ChannelBreakClips`) has a break after its
//  programmes: a bumper out, commercials, promos, interstitials, a bumper
//  back in. Each
//  break's clips are dealt from the channel's seed and the break's start, so
//  it's the same everywhere too. With `align`, each break runs on to the
//  next mark (the half hour, say), the last clip cut short to land on it.
//  The guide folds a programme's break into it (`programs`); the players go
//  through the clips one by one (`segments`).
//

import Foundation
import Synchronization

/// How a channel's shows take turns.
nonisolated enum ChannelMode: String, CaseIterable, Identifiable, Sendable {
    /// Shows take turns, one episode each.
    case rotation
    /// Shows take turns, two to four episodes in a row each.
    case blocks
    /// Every movie and episode on its own, in a new order each day.
    case shuffle
    /// The playlist's own order, straight through and round again.
    case sequential
    /// Everything in the order it first aired, across every show.
    case airdate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rotation: "Rotation"
        case .blocks: "Blocks"
        case .shuffle: "Shuffle"
        case .sequential: "In Order"
        case .airdate: "Air Date"
        }
    }

    /// Whether the order is dealt again each period; the two fixed orders aren't.
    var reshuffles: Bool { self != .sequential && self != .airdate }
}

/// How long a channel keeps one shuffled order before dealing a new one.
nonisolated enum ChannelReshuffle: String, CaseIterable, Identifiable, Sendable {
    case day
    /// From Monday to Monday.
    case week
    /// From the 1st to the 1st.
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        }
    }
}

/// What a playlist of break clips holds, as its tag says (`aster:bumpers`).
nonisolated enum BreakKind: String, CaseIterable, Identifiable, Sendable {
    /// The channel's idents, opening and closing a break.
    case bumpers
    /// Ads for shows.
    case promos
    case commercials
    /// Filler: shorts, PSAs, music videos; what lines a channel up on the mark.
    case interstitials

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bumpers: "Bumpers"
        case .promos: "Promos"
        case .commercials: "Commercials"
        case .interstitials: "Interstitials"
        }
    }
}

/// Where a channel's bumpers go in its breaks.
nonisolated enum BumperPlacement: String, CaseIterable, Identifiable, Sendable {
    /// One leads into the break and one comes back out of it.
    case both
    /// Only into the break ("We'll be right back").
    case out
    /// Only out of it ("Now back to…").
    case `in`

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: "Before & After"
        case .out: "Before the Break"
        case .in: "After the Break"
        }
    }
}

/// How a channel's breaks between programmes are made up, from its tags.
nonisolated struct ChannelBreaks: Hashable, Sendable {
    static let defaultMinutes = 2

    var bumpersAt: BumperPlacement = .both
    var promoCount = 1
    /// Interstitials in each break, without `align` (which fills with them).
    var interstitialCount = 1
    /// Minutes of commercials in each break.
    var minutes = defaultMinutes
    /// A break after every this many programmes, without `align`.
    var every = 1
    /// Programmes start on a multiple of this many minutes past the hour,
    /// each break running on to the mark; 0 for off.
    var align = 0
}

/// The clips a channel's breaks play, from the playlists its `bumpers=`,
/// `promos=`, `commercials=` and `interstitials=` tags name.
nonisolated struct ChannelBreakClips: Hashable, Sendable {
    var bumpers: [BaseItem] = []
    var promos: [BaseItem] = []
    var commercials: [BaseItem] = []
    var interstitials: [BaseItem] = []

    static let none = ChannelBreakClips()

    var isEmpty: Bool { bumpers.isEmpty && promos.isEmpty && commercials.isEmpty && interstitials.isEmpty }
}

/// What a scheduled item is to its channel: a programme, or part of a break.
nonisolated enum ProgramRole: Hashable, Sendable {
    case programme, bumper, promo, commercial, interstitial

    var isBreak: Bool { self != .programme }
}

/// How a channel's lineup is dealt, from its tags.
nonisolated struct ChannelLineup: Hashable, Sendable {
    static let defaultBlocks = 2...4

    var mode: ChannelMode = .rotation
    var reshuffle: ChannelReshuffle = .day
    /// Mixed into the shuffle, so another number deals a fresh lineup;
    /// 0 is the channel's original one.
    var seed = 0
    /// How many episodes a show plays in a row in Blocks mode.
    var blocks: ClosedRange<Int> = defaultBlocks
    /// Shows, by lower-cased name, that take this many turns each round.
    var weights: [String: Int] = [:]
    /// Titles shorter or longer than these, in seconds, are left out.
    var minLength: TimeInterval?
    var maxLength: TimeInterval?
    /// How its breaks are made up, when it has clips for them.
    var breaks = ChannelBreaks()

    /// Whether `length` seconds is within the channel's limits.
    func allows(length: TimeInterval) -> Bool {
        (minLength.map { length >= $0 } ?? true) && (maxLength.map { length <= $0 } ?? true)
    }
}

nonisolated struct ScheduledProgram: Identifiable, Hashable, Sendable {
    let channelId: String
    /// The movie or episode.
    let item: BaseItem
    let start: Date
    let end: Date
    /// A programme, or a clip in a break. In the guide's view (`programs`)
    /// a programme's `end` takes in the break after it.
    var role: ProgramRole = .programme

    /// Unique even when an item comes round again.
    var id: String { "\(channelId)|\(Int(start.timeIntervalSince1970))" }

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// How far into the item `date` falls.
    func offset(at date: Date) -> TimeInterval {
        min(max(date.timeIntervalSince(start), 0), duration)
    }

    func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }
}

nonisolated enum ChannelSchedule {
    /// An item shorter than this (or with no runtime) isn't scheduled.
    static let minimumLength: TimeInterval = 60
    /// A break clip shorter than this isn't played.
    static let shortestClip: TimeInterval = 1
    /// As far as a break can run past its programme: an hour's `align`,
    /// or the longest `break-length` and its bumpers and promos.
    static let longestBreak: TimeInterval = 2 * 3600

    /// Where every channel's timeline begins: local midnight, 1 January 2026.
    static func epoch(calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    }

    /// The channel's programs overlapping `from` to `to`, in order.
    static func programs(channelId: String, items: [BaseItem], mode: ChannelMode = .rotation, from: Date, to: Date, calendar: Calendar = .current) -> [ScheduledProgram] {
        programs(channelId: channelId, items: items, lineup: ChannelLineup(mode: mode), from: from, to: to, calendar: calendar)
    }

    static func programs(channelId: String, items: [BaseItem], lineup: ChannelLineup, from: Date, to: Date, calendar: Calendar = .current) -> [ScheduledProgram] {
        segments(channelId: channelId, items: items, lineup: lineup, from: from, to: to, calendar: calendar)
    }

    /// The channel's programmes overlapping `from` to `to`, each taking in
    /// the break after it, as a guide shows them: back to back, with no
    /// row for each clip.
    static func programs(channelId: String, items: [BaseItem], lineup: ChannelLineup, breaks clips: ChannelBreakClips, from: Date, to: Date, calendar: Calendar = .current) -> [ScheduledProgram] {
        guard !clips.isEmpty else { return segments(channelId: channelId, items: items, lineup: lineup, from: from, to: to, calendar: calendar) }
        // From far enough back to catch the programme whose break is on at
        // `from`, and on far enough to find where the last one's break ends.
        let raw = segments(channelId: channelId, items: items, lineup: lineup, breaks: clips,
                           from: from.addingTimeInterval(-longestBreak), to: to.addingTimeInterval(longestBreak), calendar: calendar)
        var folded: [ScheduledProgram] = []
        for (index, segment) in raw.enumerated() where segment.role == .programme {
            let next = raw[(index + 1)...].first { $0.role == .programme }
            let end = next?.start ?? raw.last?.end ?? segment.end
            folded.append(ScheduledProgram(channelId: segment.channelId, item: segment.item, start: segment.start, end: end))
        }
        return folded.filter { $0.end > from && $0.start < to }
    }

    /// Everything the channel plays overlapping `from` to `to`, programmes
    /// and break clips alike, in order: what a player goes through.
    static func segments(channelId: String, items: [BaseItem], lineup: ChannelLineup, breaks clips: ChannelBreakClips = .none, from: Date, to: Date, calendar: Calendar = .current) -> [ScheduledProgram] {
        var found: [ScheduledProgram] = []
        walk(channelId: channelId, items: items, lineup: lineup, clips: clips, from: from, until: to, calendar: calendar) { program in
            if program.end > from, program.start < to { found.append(program) }
        }
        return found
    }

    /// The program on the channel at `date`.
    static func airing(channelId: String, items: [BaseItem], mode: ChannelMode = .rotation, at date: Date, calendar: Calendar = .current) -> ScheduledProgram? {
        airing(channelId: channelId, items: items, lineup: ChannelLineup(mode: mode), at: date, calendar: calendar)
    }

    static func airing(channelId: String, items: [BaseItem], lineup: ChannelLineup, at date: Date, calendar: Calendar = .current) -> ScheduledProgram? {
        programs(channelId: channelId, items: items, lineup: lineup, from: date, to: date.addingTimeInterval(1), calendar: calendar).first
    }

    // MARK: Shows

    /// An item with the seconds it runs for.
    private struct Entry {
        let item: BaseItem
        let length: TimeInterval
    }

    /// A series' episodes in order, or a single movie.
    private struct Show {
        let id: String
        let episodes: [Entry]

        /// The series' or movie's name, for `weight=`.
        var name: String {
            guard let item = episodes.first?.item else { return "" }
            return item.kind == .episode ? (item.seriesName ?? item.displayTitle) : item.displayTitle
        }
    }

    /// The items grouped into shows, sorted by id so devices that list the
    /// playlist in another order still shuffle the same list. Specials
    /// (season 0), missing episodes and items without a runtime are left out.
    private static func shows(from items: [BaseItem], mode: ChannelMode) -> [Show] {
        switch mode {
        case .sequential:
            // One "show": the whole playlist in its own order, specials and all,
            // as whoever arranged it chose.
            var seen = Set<String>()
            let entries = items.compactMap { item -> Entry? in
                let length = TimeInterval(item.runTimeTicks ?? 0) / 10_000_000
                guard length >= minimumLength, item.locationType != "Virtual", seen.insert(item.id).inserted else { return nil }
                return Entry(item: item, length: length)
            }
            return entries.isEmpty ? [] : [Show(id: "playlist", episodes: entries)]
        case .shuffle:
            // Every item its own "show", so episodes mix across series.
            return shows(from: items, mode: .rotation)
                .flatMap { show in show.episodes.map { Show(id: $0.item.id, episodes: [$0]) } }
                .sorted { $0.id < $1.id }
        case .airdate:
            // One "show": everything by when it first aired, specials left
            // out as in Rotation; undated titles last, in a fixed order.
            let entries = shows(from: items, mode: .rotation).flatMap(\.episodes).sorted { a, b in
                let left = a.item.premiereDate ?? "~", right = b.item.premiereDate ?? "~"
                if left != right { return left < right }
                let leftEpisode = (a.item.seriesName ?? "", a.item.parentIndexNumber ?? 0, a.item.indexNumber ?? 0)
                let rightEpisode = (b.item.seriesName ?? "", b.item.parentIndexNumber ?? 0, b.item.indexNumber ?? 0)
                if leftEpisode != rightEpisode { return leftEpisode < rightEpisode }
                return a.item.id < b.item.id
            }
            return entries.isEmpty ? [] : [Show(id: "airdate", episodes: entries)]
        case .rotation, .blocks:
            break
        }
        var seen = Set<String>()
        var series: [String: [Entry]] = [:]
        var shows: [Show] = []
        for item in items {
            let length = TimeInterval(item.runTimeTicks ?? 0) / 10_000_000
            guard length >= minimumLength, item.locationType != "Virtual", seen.insert(item.id).inserted else { continue }
            let entry = Entry(item: item, length: length)
            if item.kind == .episode, let seriesId = item.seriesId {
                guard (item.parentIndexNumber ?? 1) != 0 else { continue }
                series[seriesId, default: []].append(entry)
            } else {
                shows.append(Show(id: item.id, episodes: [entry]))
            }
        }
        for (id, episodes) in series {
            let ordered = episodes.sorted { a, b in
                let left = (a.item.parentIndexNumber ?? 1, a.item.indexNumber ?? Int.max)
                let right = (b.item.parentIndexNumber ?? 1, b.item.indexNumber ?? Int.max)
                return left != right ? left < right : a.item.id < b.item.id
            }
            shows.append(Show(id: id, episodes: ordered))
        }
        return shows.sorted { $0.id < $1.id }
    }

    // MARK: Building the timeline

    /// Where the walk has got to at the start of a period (a day, week or
    /// month, as the channel reshuffles): enough to carry on from there
    /// without going back to the epoch.
    private struct WalkState: Sendable {
        var periodStart: Date
        /// When the period's first program starts (after the one crossing into it).
        var time: Date
        /// Periods since the epoch.
        var period: UInt64
        /// The show that played last, by its place in the list.
        var lastShow: Int?
        /// The next episode of each show, counted from its first.
        var pointers: [Int]
        /// Programmes since the last break, for `break-every`.
        var sinceBreak = 0
    }

    /// The latest day-start state reached for each channel and list, so
    /// asking again later resumes there.
    private static let checkpoints = Mutex<[String: WalkState]>([:])

    /// Lays the timeline out up to `end`, handing each program to `visit`
    /// as it goes. Programs before `from` may be skipped.
    private static func walk(channelId: String, items: [BaseItem], lineup: ChannelLineup, clips: ChannelBreakClips = .none, from: Date, until end: Date, calendar local: Calendar, visit: (ScheduledProgram) -> Void) {
        let limited = lineup.minLength == nil && lineup.maxLength == nil ? items : items.filter {
            lineup.allows(length: TimeInterval($0.runTimeTicks ?? 0) / 10_000_000)
        }
        let shows = shows(from: limited, mode: lineup.mode)
        guard !shows.isEmpty else { return }
        let pool = BreakPool(clips)
        // How many turns each show takes a round: 1 unless `weight=` says.
        let turns = lineup.weights.isEmpty ? [] : shows.map { max(1, lineup.weights[$0.name.lowercased()] ?? 1) }

        // Gregorian whatever calendar the device uses, so every device
        // counts its days, weeks and months from the same start.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = local.timeZone

        let channelSeed = seed(of: channelId)
        let base = lineup.seed == 0 ? channelSeed : mix(channelSeed ^ UInt64(bitPattern: Int64(lineup.seed)))
        let blocks = lineup.blocks
        let key = [
            channelId, lineup.mode.rawValue, lineup.reshuffle.rawValue, "\(lineup.seed)",
            "\(blocks.lowerBound)-\(blocks.upperBound)", calendar.timeZone.identifier,
            lineup.weights.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
            "\(lineup.minLength ?? 0)-\(lineup.maxLength ?? 0)",
            "\(seed(of: shows.flatMap { $0.episodes.map(\.item.id) }.joined(separator: ",")))"
        ].joined(separator: "|") + (pool.isEmpty ? "" : "|" + pool.key(lineup.breaks))
        let start = epoch(calendar: calendar)
        let fresh = WalkState(periodStart: start, time: start, period: 0, lastShow: nil, pointers: Array(repeating: 0, count: shows.count))
        let saved = checkpoints.withLock { $0[key] }
        var state = saved.flatMap { $0.time <= from ? $0 : nil } ?? fresh
        var latest: WalkState?

        while state.time < end {
            guard let periodEnd = endOfPeriod(after: state.periodStart, lineup.reshuffle, calendar: calendar) else { return }
            if state.time <= from { latest = state }
            let periodSeed = base ^ (state.period &* 0x9E37_79B9_7F4A_7C15)
            var order = shuffled(Array(shows.indices), seed: periodSeed)
            if turns.contains(where: { $0 > 1 }) {
                order = weighted(order, turns: turns, seed: periodSeed)
            }
            // A new period never opens with the show that just played.
            if order.count > 1, order[0] == state.lastShow {
                order.swapAt(0, order.count - 1)
            }
            // The shows go round this order until the period ends, so in a
            // week or a month the turns carry on across midnight.
            var turn = 0
            while state.time < periodEnd, state.time < end {
                let index = order[turn % order.count]
                let show = shows[index]
                let size = lineup.mode == .blocks ? min(show.episodes.count, blocks.lowerBound + Int(mix(periodSeed ^ (UInt64(turn + 1) &* 0xD1B5_4A32_D192_ED03)) % UInt64(blocks.count))) : 1
                var played = 0
                while played < size, state.time < periodEnd, state.time < end {
                    let entry = show.episodes[state.pointers[index] % show.episodes.count]
                    let finish = state.time.addingTimeInterval(entry.length)
                    visit(ScheduledProgram(channelId: channelId, item: entry.item, start: state.time, end: finish))
                    state.time = finish
                    state.pointers[index] += 1
                    played += 1
                    if !pool.isEmpty {
                        state.sinceBreak += 1
                        // Lined up, every programme needs its break to reach the mark.
                        if lineup.breaks.align > 0 || state.sinceBreak >= lineup.breaks.every {
                            state.sinceBreak = 0
                            for clip in pool.deal(after: state.time, breaks: lineup.breaks, seed: base, calendar: calendar) {
                                visit(ScheduledProgram(channelId: channelId, item: clip.item, start: clip.start, end: clip.end, role: clip.role))
                                state.time = clip.end
                            }
                        }
                    }
                }
                state.lastShow = index
                turn += 1
            }
            state.periodStart = periodEnd
            state.period += 1
            // The period's last program can run past the next one's end only
            // when it's longer than a period; skip the periods it covers.
            while let next = endOfPeriod(after: state.periodStart, lineup.reshuffle, calendar: calendar), next <= state.time {
                state.periodStart = next
                state.period += 1
            }
        }

        if let latest, latest.time > (saved?.time ?? .distantPast) {
            checkpoints.withLock { $0[key] = latest }
        }
    }

    // MARK: Breaks

    /// A channel's break clips that can play (a second or longer, and on
    /// the server), sorted by id so every device deals from the same list.
    private struct BreakPool {
        let bumpers: [Entry]
        let promos: [Entry]
        let commercials: [Entry]
        let interstitials: [Entry]

        init(_ clips: ChannelBreakClips) {
            func playable(_ items: [BaseItem]) -> [Entry] {
                var seen = Set<String>()
                return items.compactMap { item -> Entry? in
                    let length = TimeInterval(item.runTimeTicks ?? 0) / 10_000_000
                    guard length >= ChannelSchedule.shortestClip, item.locationType != "Virtual", seen.insert(item.id).inserted else { return nil }
                    return Entry(item: item, length: length)
                }
                .sorted { $0.item.id < $1.item.id }
            }
            bumpers = playable(clips.bumpers)
            promos = playable(clips.promos)
            commercials = playable(clips.commercials)
            interstitials = playable(clips.interstitials)
        }

        var isEmpty: Bool { bumpers.isEmpty && promos.isEmpty && commercials.isEmpty && interstitials.isEmpty }

        /// For the checkpoint key: the clips and how breaks use them.
        func key(_ breaks: ChannelBreaks) -> String {
            let ids = [bumpers, promos, commercials, interstitials].map { $0.map(\.item.id).joined(separator: ",") }.joined(separator: ";")
            return "\(breaks.bumpersAt.rawValue)-\(breaks.promoCount)-\(breaks.interstitialCount)-\(breaks.minutes)-\(breaks.every)-\(breaks.align)-\(ChannelSchedule.seed(of: ids))"
        }

        struct Clip {
            let item: BaseItem
            let role: ProgramRole
            let start: Date
            let end: Date
        }

        /// The break after a programme ending at `start`: a bumper out,
        /// commercials filling `minutes` with whole clips, promos, then
        /// interstitials, and a bumper back in. Lined up on a mark, the
        /// interstitials fill to it instead (commercials, then promos, then
        /// bumpers on a channel without any), the last cut short to land on it.
        func deal(after start: Date, breaks: ChannelBreaks, seed: UInt64, calendar: Calendar) -> [Clip] {
            var random = ChannelSchedule.mix(seed ^ 0x2545_F491_4F6C_DD1D ^ UInt64(bitPattern: Int64(start.timeIntervalSince1970.rounded())))
            func next() -> UInt64 {
                random = ChannelSchedule.mix(random)
                return random
            }
            /// One of `pool`, not `avoiding` where there's a choice.
            func pick(_ pool: [Entry], avoiding: String?) -> Entry {
                let first = pool[Int(next() % UInt64(pool.count))]
                guard pool.count > 1, first.item.id == avoiding else { return first }
                return pool[(pool.firstIndex { $0.item.id == first.item.id }! + 1) % pool.count]
            }
            /// Clips of `pool` filling `seconds`: whole ones, the last cut
            /// short to fill it exactly with `cutting`; without, at least one
            /// even when none is short enough.
            func fill(_ pool: [Entry], _ role: ProgramRole, seconds: TimeInterval, cutting: Bool, after previous: String?) -> [(Entry, ProgramRole, TimeInterval)] {
                var result: [(Entry, ProgramRole, TimeInterval)] = []
                var remaining = seconds
                var previous = previous
                let shortest = pool.map(\.length).min() ?? .infinity
                while remaining >= ChannelSchedule.shortestClip, result.count < 2000 {
                    var clip = pick(pool, avoiding: previous)
                    if clip.length > remaining, shortest <= remaining {
                        // Another that fits, where one does.
                        clip = pool.first { $0.length <= remaining && $0.item.id != previous } ?? pool.first { $0.length <= remaining }!
                    }
                    if clip.length <= remaining {
                        result.append((clip, role, clip.length))
                        remaining -= clip.length
                    } else if cutting {
                        result.append((clip, role, remaining))
                        remaining = 0
                    } else {
                        if result.isEmpty { result.append((clip, role, clip.length)) }
                        break
                    }
                    previous = clip.item.id
                }
                return result
            }

            var parts: [(Entry, ProgramRole, TimeInterval)] = []
            func add(_ entry: Entry, _ role: ProgramRole) { parts.append((entry, role, entry.length)) }
            if !bumpers.isEmpty, breaks.bumpersAt != .in { add(pick(bumpers, avoiding: nil), .bumper) }
            if !commercials.isEmpty, breaks.minutes > 0 {
                parts += fill(commercials, .commercial, seconds: TimeInterval(breaks.minutes * 60), cutting: false, after: parts.last?.0.item.id)
            }
            if !promos.isEmpty {
                for _ in 0..<breaks.promoCount { add(pick(promos, avoiding: parts.last?.0.item.id), .promo) }
            }
            let closing = !bumpers.isEmpty && breaks.bumpersAt != .out ? pick(bumpers, avoiding: parts.first?.0.item.id) : nil

            var mark: Date?
            if breaks.align > 0 {
                let used = parts.reduce(0) { $0 + $1.2 } + (closing?.length ?? 0)
                let target = ChannelSchedule.nextMark(after: start.addingTimeInterval(used), every: breaks.align, calendar: calendar)
                let filler: ([Entry], ProgramRole) = !interstitials.isEmpty ? (interstitials, .interstitial)
                    : !commercials.isEmpty ? (commercials, .commercial)
                    : !promos.isEmpty ? (promos, .promo) : (bumpers, .bumper)
                parts += fill(filler.0, filler.1, seconds: target.timeIntervalSince(start) - used, cutting: true, after: parts.last?.0.item.id)
                mark = target
            } else if !interstitials.isEmpty {
                for _ in 0..<breaks.interstitialCount { add(pick(interstitials, avoiding: parts.last?.0.item.id), .interstitial) }
            }
            if let closing { add(closing, .bumper) }

            var clips: [Clip] = []
            var time = start
            for (entry, role, length) in parts {
                let end = time.addingTimeInterval(length)
                clips.append(Clip(item: entry.item, role: role, start: time, end: end))
                time = end
            }
            // Exactly on the mark, whatever the sums came to.
            if let mark, let last = clips.last, abs(last.end.timeIntervalSince(mark)) < 1 {
                clips[clips.count - 1] = Clip(item: last.item, role: last.role, start: last.start, end: mark)
            }
            return clips
        }
    }

    /// The first time at or after `date` that's a multiple of `minutes` past
    /// local midnight: :00 and :30 for 30.
    fileprivate static func nextMark(after date: Date, every minutes: Int, calendar: Calendar) -> Date {
        let midnight = calendar.startOfDay(for: date)
        let step = TimeInterval(minutes * 60)
        let steps = (date.timeIntervalSince(midnight) / step).rounded(.up)
        return midnight.addingTimeInterval(steps * step)
    }

    /// When the period starting at `start` ends: the next midnight, the
    /// next Monday's, or the next 1st's.
    private static func endOfPeriod(after start: Date, _ reshuffle: ChannelReshuffle, calendar: Calendar) -> Date? {
        switch reshuffle {
        case .day:
            calendar.date(byAdding: .day, value: 1, to: start)
        case .week:
            calendar.nextDate(after: start, matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: 2), matchingPolicy: .nextTime)
        case .month:
            calendar.nextDate(after: start, matching: DateComponents(day: 1, hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
        }
    }

    /// The round with each show as many times as its turns, shuffled again
    /// and spread so a show never follows itself where that can be helped.
    private static func weighted(_ order: [Int], turns: [Int], seed: UInt64) -> [Int] {
        var round = shuffled(order.flatMap { Array(repeating: $0, count: turns[$0]) }, seed: mix(seed ^ 0xA076_1D64_78BD_642F))
        guard round.count > 2 else { return round }
        for index in 1..<round.count where round[index] == round[index - 1] {
            if let swap = (index + 1..<round.count).first(where: { round[$0] != round[index - 1] }) {
                round.swapAt(index, swap)
            }
        }
        return round
    }

    // MARK: Shuffling the same way everywhere

    /// FNV-1a of the channel id: a seed that doesn't change between launches
    /// or devices (Swift's `Hasher` does).
    fileprivate static func seed(of text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// SplitMix64's output step: a well-mixed number from any seed.
    fileprivate static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Fisher–Yates with SplitMix64, written out so the order is the same on
    /// every OS version (`shuffled(using:)` doesn't promise its algorithm).
    private static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var result = items
        var state = seed
        func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        guard result.count > 1 else { return result }
        for i in stride(from: result.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            result.swapAt(i, j)
        }
        return result
    }
}
