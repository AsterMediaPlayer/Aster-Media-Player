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
//  going round it again until the next midnight. A show plays its episodes
//  in order and carries on from where it got to, like reruns.
//

import Foundation
import Synchronization

/// How a channel's shows take turns.
nonisolated enum ChannelMode: String, CaseIterable, Identifiable, Sendable {
    /// One episode per turn.
    case rotation
    /// Two to four episodes in a row per turn.
    case blocks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rotation: "Rotation"
        case .blocks: "Blocks"
        }
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
        var found: [ScheduledProgram] = []
        walk(channelId: channelId, items: items, mode: mode, from: from, until: to, calendar: calendar) { program in
            if program.end > from, program.start < to { found.append(program) }
        }
        return found
    }

    /// The program on the channel at `date`.
    static func airing(channelId: String, items: [BaseItem], mode: ChannelMode = .rotation, at date: Date, calendar: Calendar = .current) -> ScheduledProgram? {
        programs(channelId: channelId, items: items, mode: mode, from: date, to: date.addingTimeInterval(1), calendar: calendar).first
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
    }

    /// The items grouped into shows, sorted by id so devices that list the
    /// playlist in another order still shuffle the same list. Specials
    /// (season 0), missing episodes and items without a runtime are left out.
    private static func shows(from items: [BaseItem]) -> [Show] {
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

    /// Where the walk has got to at the start of a day: enough to carry on
    /// from there without going back to the epoch.
    private struct WalkState: Sendable {
        var dayStart: Date
        /// When the day's first program starts (after the one crossing midnight).
        var time: Date
        var day: UInt64
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
    private static func walk(channelId: String, items: [BaseItem], mode: ChannelMode, from: Date, until end: Date, calendar: Calendar, visit: (ScheduledProgram) -> Void) {
        let shows = shows(from: items)
        guard !shows.isEmpty else { return }

        let base = seed(of: channelId)
        let key = "\(channelId)|\(mode.rawValue)|\(calendar.timeZone.identifier)|\(seed(of: shows.flatMap { $0.episodes.map(\.item.id) }.joined(separator: ",")))"
        let fresh = WalkState(dayStart: epoch(calendar: calendar), time: epoch(calendar: calendar), day: 0, lastShow: nil, pointers: Array(repeating: 0, count: shows.count))
        let saved = checkpoints.withLock { $0[key] }
        var state = saved.flatMap { $0.time <= from ? $0 : nil } ?? fresh
        var latest: WalkState?

        while state.time < end {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: state.dayStart) else { return }
            if state.time <= from { latest = state }
            let daySeed = base ^ (state.day &* 0x9E37_79B9_7F4A_7C15)
            var order = shuffled(Array(shows.indices), seed: daySeed)
            // A new day never opens with the show that just played.
            if order.count > 1, order[0] == state.lastShow {
                order.swapAt(0, order.count - 1)
            }
            var turn = 0
            while state.time < dayEnd, state.time < end {
                let index = order[turn % order.count]
                let show = shows[index]
                let size = mode == .blocks ? min(show.episodes.count, 2 + Int(mix(daySeed ^ (UInt64(turn + 1) &* 0xD1B5_4A32_D192_ED03)) % 3)) : 1
                var played = 0
                while played < size, state.time < dayEnd, state.time < end {
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
            state.dayStart = dayEnd
            state.day += 1
            // The day's last program can run past several midnights only when
            // it's longer than a day; skip the days it covers.
            while let next = calendar.date(byAdding: .day, value: 1, to: state.dayStart), next <= state.time {
                state.dayStart = next
                state.day += 1
            }
        }

        if let latest, latest.time > (saved?.time ?? .distantPast) {
            checkpoints.withLock { $0[key] = latest }
        }
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
