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

    /// Where every channel's timeline begins: local midnight, 1 January 2026.
    static func epoch(calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    }

    /// The channel's programs overlapping `from` to `to`, in order.
    static func programs(channelId: String, items: [BaseItem], mode: ChannelMode = .rotation, from: Date, to: Date, calendar: Calendar = .current) -> [ScheduledProgram] {
        programs(channelId: channelId, items: items, lineup: ChannelLineup(mode: mode), from: from, to: to, calendar: calendar)
    }

    static func programs(channelId: String, items: [BaseItem], lineup: ChannelLineup, from: Date, to: Date, calendar: Calendar = .current) -> [ScheduledProgram] {
        var found: [ScheduledProgram] = []
        walk(channelId: channelId, items: items, lineup: lineup, from: from, until: to, calendar: calendar) { program in
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
    }

    /// The latest day-start state reached for each channel and list, so
    /// asking again later resumes there.
    private static let checkpoints = Mutex<[String: WalkState]>([:])

    /// Lays the timeline out up to `end`, handing each program to `visit`
    /// as it goes. Programs before `from` may be skipped.
    private static func walk(channelId: String, items: [BaseItem], lineup: ChannelLineup, from: Date, until end: Date, calendar local: Calendar, visit: (ScheduledProgram) -> Void) {
        let limited = lineup.minLength == nil && lineup.maxLength == nil ? items : items.filter {
            lineup.allows(length: TimeInterval($0.runTimeTicks ?? 0) / 10_000_000)
        }
        let shows = shows(from: limited, mode: lineup.mode)
        guard !shows.isEmpty else { return }
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
        ].joined(separator: "|")
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
    private static func seed(of text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// SplitMix64's output step: a well-mixed number from any seed.
    private static func mix(_ value: UInt64) -> UInt64 {
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
