//
//  ChannelScheduleTests.swift
//  AsterFINTests
//
//  Channels' schedules: the same on every run, back to back with no gaps,
//  tuning in lands on the right movie and spot, a movie at midnight runs
//  on into the next day, and each day gets its own order. TV shows play
//  their episodes in order across days, take turns one at a time (Rotation)
//  or two to four at a time (Blocks), and leave specials out.
//

import Foundation
import Testing
@testable import AsterFIN

@MainActor
struct ChannelScheduleTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private static func movie(_ id: String, minutes: Double?) -> BaseItem {
        var item = BaseItem(id: id, name: "Movie \(id)", type: ItemKind.movie.rawValue)
        item.runTimeTicks = minutes.map { Int64($0 * 60 * 10_000_000) }
        return item
    }

    /// Eight movies of different lengths, 85 to 155 minutes.
    private static let movies = (0..<8).map { movie("m\($0)", minutes: 85 + Double($0) * 10) }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func programs(from: Date, to: Date, movies: [BaseItem]? = nil) -> [ScheduledProgram] {
        ChannelSchedule.programs(channelId: "channel-a", items: movies ?? Self.movies, from: from, to: to, calendar: calendar)
    }

    @Test func sameScheduleEveryTime() {
        let from = Self.date(2026, 10, 15, 18)
        let to = Self.date(2026, 10, 16, 6)
        let first = Self.programs(from: from, to: to)
        let second = Self.programs(from: from, to: to)
        #expect(!first.isEmpty)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.item.id) == second.map(\.item.id))
    }

    @Test func listOrderDoesNotMatter() {
        let from = Self.date(2026, 10, 15, 18)
        let to = Self.date(2026, 10, 16, 6)
        let forward = Self.programs(from: from, to: to)
        let reversed = Self.programs(from: from, to: to, movies: Self.movies.reversed())
        #expect(forward.map(\.item.id) == reversed.map(\.item.id))
    }

    @Test func programsRunBackToBackAcrossTheWindow() throws {
        let from = Self.date(2026, 10, 15, 8)
        let to = Self.date(2026, 10, 17, 8)
        let programs = Self.programs(from: from, to: to)
        let first = try #require(programs.first)
        let last = try #require(programs.last)
        #expect(first.start <= from)
        #expect(last.end >= to)
        for (earlier, later) in zip(programs, programs.dropFirst()) {
            #expect(earlier.end == later.start)
        }
    }

    @Test func tuningInFindsTheMovieAndTheSpot() throws {
        let now = Self.date(2026, 10, 15, 21, 17)
        let airing = try #require(ChannelSchedule.airing(channelId: "channel-a", items: Self.movies, at: now, calendar: Self.calendar))
        #expect(airing.contains(now))
        #expect(airing.offset(at: now) == now.timeIntervalSince(airing.start))
        let window = Self.programs(from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(6 * 3600))
        #expect(window.first { $0.contains(now) }?.id == airing.id)
    }

    @Test func aMovieAtMidnightRunsIntoTheNextDay() throws {
        let midnight = Self.date(2026, 10, 16)
        let programs = Self.programs(from: midnight.addingTimeInterval(-4 * 3600), to: midnight.addingTimeInterval(4 * 3600))
        let crossing = try #require(programs.first { $0.start < midnight && $0.end > midnight })
        let next = try #require(programs.first { $0.start == crossing.end })
        // The new day doesn't open with the movie that was on at midnight.
        #expect(next.item.id != crossing.item.id)
    }

    @Test func eachDayHasItsOwnOrder() {
        // The first three movies after each midnight-crossing movie, a week of days.
        var openings: [[String]] = []
        for day in 1...7 {
            let midnight = Self.date(2026, 10, day)
            let programs = Self.programs(from: midnight, to: midnight.addingTimeInterval(12 * 3600))
            openings.append(Array(programs.dropFirst().prefix(3).map(\.item.id)))
        }
        #expect(Set(openings).count > 1)
    }

    @Test func moviesWithoutARuntimeAreLeftOut() {
        let movies = [Self.movie("short", minutes: 0.5), Self.movie("none", minutes: nil), Self.movie("real", minutes: 100)]
        let programs = Self.programs(from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 16), movies: movies)
        #expect(!programs.isEmpty)
        #expect(programs.allSatisfy { $0.item.id == "real" })
    }

    @Test func noMoviesNoSchedule() {
        #expect(Self.programs(from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 16), movies: []).isEmpty)
    }

    @Test func otherChannelsShuffleDifferently() {
        let from = Self.date(2026, 10, 15, 6)
        let to = Self.date(2026, 10, 15, 22)
        let a = ChannelSchedule.programs(channelId: "channel-a", items: Self.movies, from: from, to: to, calendar: Self.calendar)
        let b = ChannelSchedule.programs(channelId: "channel-b", items: Self.movies, from: from, to: to, calendar: Self.calendar)
        #expect(a.map(\.item.id) != b.map(\.item.id))
    }

    // MARK: TV

    private static func episode(_ series: String, season: Int, _ number: Int, minutes: Double = 22) -> BaseItem {
        var item = BaseItem(id: "\(series)-s\(season)e\(number)", name: "\(series) \(season)x\(number)", type: ItemKind.episode.rawValue)
        item.seriesId = series
        item.seriesName = series.capitalized
        item.parentIndexNumber = season
        item.indexNumber = number
        item.runTimeTicks = Int64(minutes * 60 * 10_000_000)
        return item
    }

    /// Three shows of two seasons each, listed out of order, with a special.
    private static let shows: [BaseItem] = {
        var items: [BaseItem] = []
        for series in ["alpha", "bravo", "charlie"] {
            for season in 1...2 {
                for number in 1...6 { items.append(episode(series, season: season, number)) }
            }
            items.append(episode(series, season: 0, 1))
        }
        return items.reversed()
    }()

    private static func tv(_ mode: ChannelMode, items: [BaseItem]? = nil, channel: String = "tv", from: Date, to: Date) -> [ScheduledProgram] {
        ChannelSchedule.programs(channelId: channel, items: items ?? shows, mode: mode, from: from, to: to, calendar: calendar)
    }

    /// Where an episode falls in its show, counting from 0.
    private static func position(_ item: BaseItem) -> Int {
        ((item.parentIndexNumber ?? 1) - 1) * 6 + (item.indexNumber ?? 1) - 1
    }

    @Test(arguments: [ChannelMode.rotation, .blocks])
    func episodesComeInOrderAcrossDays(mode: ChannelMode) {
        let programs = Self.tv(mode, from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 18))
        for series in ["alpha", "bravo", "charlie"] {
            let positions = programs.filter { $0.item.seriesId == series }.map { Self.position($0.item) }
            #expect(positions.count > 12)
            for (earlier, later) in zip(positions, positions.dropFirst()) {
                #expect(later == (earlier + 1) % 12, "\(series) went from \(earlier) to \(later)")
            }
        }
    }

    @Test(arguments: [ChannelMode.rotation, .blocks])
    func specialsAreLeftOut(mode: ChannelMode) {
        let programs = Self.tv(mode, from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 17))
        #expect(!programs.isEmpty)
        #expect(programs.allSatisfy { $0.item.parentIndexNumber != 0 })
    }

    @Test func rotationNeverRepeatsAShowBackToBack() {
        let programs = Self.tv(.rotation, from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 18))
        for (earlier, later) in zip(programs, programs.dropFirst()) {
            #expect(earlier.item.seriesId != later.item.seriesId)
        }
    }

    @Test func blocksRunTwoToFourEpisodes() {
        let midnight = Self.date(2026, 10, 16)
        let programs = Self.tv(.blocks, from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 17))
        var runs: [(count: Int, crossesMidnight: Bool)] = []
        for (index, program) in programs.enumerated() {
            let touchesMidnight = program.start <= midnight && program.end >= midnight
            if index > 0, programs[index - 1].item.seriesId == program.item.seriesId {
                runs[runs.count - 1].count += 1
                runs[runs.count - 1].crossesMidnight = runs[runs.count - 1].crossesMidnight || touchesMidnight
            } else {
                runs.append((1, touchesMidnight))
            }
        }
        // The window's ends and midnight can cut a block short.
        let inner = runs.dropFirst().dropLast().filter { !$0.crossesMidnight }
        #expect(inner.count > 10)
        #expect(inner.allSatisfy { (2...4).contains($0.count) }, "runs: \(inner.map(\.count))")
        #expect(Set(inner.map(\.count)).count > 1)
    }

    @Test func moviesTakeTurnsWithShows() {
        let mixed = Self.shows + Self.movies
        let programs = Self.tv(.rotation, items: mixed, from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 17))
        #expect(programs.contains { $0.item.kind == .movie })
        #expect(programs.contains { $0.item.kind == .episode })
    }

    @Test(arguments: [ChannelMode.rotation, .blocks])
    func tvScheduleIsTheSameEveryTime(mode: ChannelMode) {
        let from = Self.date(2026, 10, 15, 18)
        let to = Self.date(2026, 10, 16, 6)
        let shuffledList = Self.shows.shuffled()
        #expect(Self.tv(mode, from: from, to: to).map(\.id) == Self.tv(mode, items: shuffledList, from: from, to: to).map(\.id))
        #expect(Self.tv(mode, from: from, to: to).map(\.item.id) == Self.tv(mode, items: shuffledList, from: from, to: to).map(\.item.id))
    }

    @Test func resumingFromACheckpointMatchesAFullWalk() {
        // A channel no other test uses, so the first call walks from the epoch
        // and the second resumes from the day it saved.
        let from = Self.date(2027, 6, 1, 20)
        let to = Self.date(2027, 6, 2, 2)
        let clock = ContinuousClock()
        var first: [ScheduledProgram] = []
        let full = clock.measure { first = Self.tv(.blocks, channel: "checkpoint", from: from, to: to) }
        var second: [ScheduledProgram] = []
        let resumed = clock.measure { second = Self.tv(.blocks, channel: "checkpoint", from: from, to: to) }
        #expect(!first.isEmpty)
        #expect(first.map(\.item.id) == second.map(\.item.id))
        #expect(first.map(\.id) == second.map(\.id))
        #expect(full < .seconds(1))
        #expect(resumed < full)
    }

    // MARK: Shuffle and In Order

    @Test func inOrderFollowsThePlaylistAndWraps() {
        // The playlist's own order (here the reverse of the episode order),
        // specials included, round and round across days.
        let order = Self.shows.map(\.id)
        let programs = Self.tv(.sequential, from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 18))
        #expect(programs.count > order.count)
        for (earlier, later) in zip(programs, programs.dropFirst()) {
            let index = order.firstIndex(of: earlier.item.id)!
            #expect(later.item.id == order[(index + 1) % order.count])
        }
    }

    @Test func inOrderDependsOnThePlaylistOrder() {
        let from = Self.date(2026, 10, 15, 18)
        let to = Self.date(2026, 10, 16, 6)
        let asListed = Self.tv(.sequential, from: from, to: to).map(\.item.id)
        let reversed = Self.tv(.sequential, items: Self.shows.reversed(), from: from, to: to).map(\.item.id)
        #expect(asListed != reversed)
    }

    @Test func shuffleMixesSeriesAndLeavesSpecialsOut() {
        let programs = Self.tv(.shuffle, from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 17))
        #expect(programs.allSatisfy { $0.item.parentIndexNumber != 0 })
        // Not each show's episodes in order, as Rotation would play them.
        let alpha = programs.filter { $0.item.seriesId == "alpha" }.map { Self.position($0.item) }
        let inOrder = zip(alpha, alpha.dropFirst()).allSatisfy { $1 == ($0 + 1) % 12 }
        #expect(!inOrder)
    }

    @Test func shuffleIsTheSameEveryTime() {
        let from = Self.date(2026, 10, 15, 18)
        let to = Self.date(2026, 10, 16, 6)
        #expect(Self.tv(.shuffle, from: from, to: to).map(\.item.id) == Self.tv(.shuffle, items: Self.shows.shuffled(), from: from, to: to).map(\.item.id))
    }

    // MARK: Reshuffle, seed and block lengths

    private static func lineup(_ lineup: ChannelLineup, items: [BaseItem]? = nil, channel: String = "channel-a", from: Date, to: Date) -> [ScheduledProgram] {
        ChannelSchedule.programs(channelId: channel, items: items ?? movies, lineup: lineup, from: from, to: to, calendar: calendar)
    }

    /// A channel without the newer tags keeps the schedule it had before
    /// them, across the end of daylight saving time. Worked out separately
    /// from the original code, so a change that moves every channel's
    /// lineup shows up here.
    @Test func untaggedChannelsKeepTheirSchedule() {
        let movies = Self.programs(from: Self.date(2026, 10, 31, 18), to: Self.date(2026, 11, 2, 6)).map(\.item.id)
        #expect(movies == [
            "m1", "m3", "m0", "m2", "m1", "m3", "m0", "m7", "m5", "m4", "m2", "m6", "m1", "m3", "m0", "m7",
            "m5", "m0", "m5", "m3"
        ])

        let series = ["s0", "s1", "s2"].flatMap { name in (1...6).map { Self.episode(name, season: 1, $0) } }
        let blocks = Self.tv(.blocks, items: series, channel: "channel-b", from: Self.date(2026, 10, 31, 18), to: Self.date(2026, 11, 1, 6)).map(\.item.id)
        #expect(blocks == [
            "s2-s1e4", "s1-s1e5", "s1-s1e6", "s0-s1e1", "s0-s1e2", "s0-s1e3", "s2-s1e5", "s2-s1e6",
            "s1-s1e1", "s1-s1e2", "s0-s1e4", "s0-s1e5", "s0-s1e6", "s0-s1e1", "s2-s1e1", "s2-s1e2",
            "s2-s1e3", "s1-s1e3", "s1-s1e4", "s1-s1e5", "s1-s1e6", "s2-s1e4", "s2-s1e5", "s0-s1e2",
            "s0-s1e3", "s0-s1e4", "s1-s1e1", "s1-s1e2", "s1-s1e3", "s2-s1e6", "s2-s1e1", "s0-s1e5",
            "s0-s1e6", "s0-s1e1", "s1-s1e4", "s1-s1e5"
        ])
    }

    /// Within one period the shows go round a single order, so the lineup
    /// repeats every eight programs (one per movie), midnight or not.
    @Test(arguments: [
        (ChannelReshuffle.week, 2026, 10, 13, 2026, 10, 18),
        (ChannelReshuffle.month, 2026, 10, 2, 2026, 10, 30),
    ])
    func aWeekOrMonthKeepsOneOrder(reshuffle: ChannelReshuffle, y1: Int, m1: Int, d1: Int, y2: Int, m2: Int, d2: Int) {
        let ids = Self.lineup(ChannelLineup(reshuffle: reshuffle), from: Self.date(y1, m1, d1), to: Self.date(y2, m2, d2)).map(\.item.id)
        #expect(ids.count > 30)
        for index in 0..<(ids.count - 8) {
            #expect(ids[index] == ids[index + 8], "program \(index) broke the order")
        }
        // A daily channel doesn't: its order changes at midnight.
        let daily = Self.lineup(ChannelLineup(), from: Self.date(y1, m1, d1), to: Self.date(y2, m2, d2)).map(\.item.id)
        #expect((0..<(daily.count - 8)).contains { daily[$0] != daily[$0 + 8] })
    }

    @Test func theNextWeekDealsANewOrder() {
        /// The week's order, starting from m0 so where the window starts doesn't matter.
        func order(from: Date) -> [String] {
            let ids = Self.lineup(ChannelLineup(reshuffle: .week), from: from, to: from.addingTimeInterval(24 * 3600)).map(\.item.id)
            let cycle = Array(ids.prefix(8))
            let start = cycle.firstIndex(of: "m0") ?? 0
            return Array(cycle[start...] + cycle[..<start])
        }
        #expect(order(from: Self.date(2026, 10, 14)) != order(from: Self.date(2026, 10, 21)))
    }

    @Test func aSeedDealsAFreshLineup() {
        let from = Self.date(2026, 10, 15, 18)
        let to = Self.date(2026, 10, 16, 6)
        let original = Self.lineup(ChannelLineup(), from: from, to: to).map(\.item.id)
        #expect(Self.lineup(ChannelLineup(seed: 0), from: from, to: to).map(\.item.id) == original)
        let reshuffled = Self.lineup(ChannelLineup(seed: 1), from: from, to: to).map(\.item.id)
        #expect(reshuffled != original)
        #expect(Self.lineup(ChannelLineup(seed: 1), from: from, to: to).map(\.item.id) == reshuffled)
        #expect(Self.lineup(ChannelLineup(seed: 2), from: from, to: to).map(\.item.id) != reshuffled)
    }

    @Test func blocksFollowTheirLength() {
        let midnight = Self.date(2026, 10, 16)
        let programs = Self.lineup(ChannelLineup(mode: .blocks, blocks: 3...6), items: Self.shows, channel: "tv", from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 17))
        var runs: [(count: Int, crossesMidnight: Bool)] = []
        for (index, program) in programs.enumerated() {
            let touchesMidnight = program.start <= midnight && program.end >= midnight
            if index > 0, programs[index - 1].item.seriesId == program.item.seriesId {
                runs[runs.count - 1].count += 1
                runs[runs.count - 1].crossesMidnight = runs[runs.count - 1].crossesMidnight || touchesMidnight
            } else {
                runs.append((1, touchesMidnight))
            }
        }
        // The window's ends and midnight can cut a block short.
        let inner = runs.dropFirst().dropLast().filter { !$0.crossesMidnight }
        #expect(inner.count > 5)
        #expect(inner.allSatisfy { (3...6).contains($0.count) }, "runs: \(inner.map(\.count))")
        #expect(inner.contains { $0.count > 4 }, "runs: \(inner.map(\.count))")
    }

    // MARK: Weights, lengths and air date

    @Test func aWeightedShowPlaysMoreOftenButNotBackToBack() {
        let programs = Self.lineup(ChannelLineup(weights: ["alpha": 2]), items: Self.shows, channel: "tv", from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 18))
        let counts = Dictionary(grouping: programs, by: { $0.item.seriesId ?? "" }).mapValues(\.count)
        let alpha = Double(counts["alpha"] ?? 0)
        let others = Double((counts["bravo"] ?? 0) + (counts["charlie"] ?? 0)) / 2
        #expect(alpha > others * 1.6, "counts: \(counts)")
        #expect(alpha < others * 2.4, "counts: \(counts)")
        // Three shows, one of them twice: a round can always be spread out.
        // Only where two rounds meet (or a new day starts) can alpha repeat.
        let repeats = zip(programs, programs.dropFirst()).filter { $0.item.seriesId == $1.item.seriesId }.count
        #expect(Double(repeats) < Double(programs.count) * 0.15, "repeats: \(repeats) of \(programs.count)")
        // Episodes still come in order.
        let alphas = programs.filter { $0.item.seriesId == "alpha" }.map { Self.position($0.item) }
        for (a, b) in zip(alphas, alphas.dropFirst()) { #expect(b == (a + 1) % 12) }
    }

    @Test func weightsOfOneChangeNothing() {
        let from = Self.date(2026, 10, 15, 18)
        let to = Self.date(2026, 10, 16, 6)
        let plain = Self.lineup(ChannelLineup(), items: Self.shows, channel: "tv", from: from, to: to).map(\.item.id)
        let weighted = Self.lineup(ChannelLineup(weights: ["alpha": 1, "nobody": 3]), items: Self.shows, channel: "tv", from: from, to: to).map(\.item.id)
        #expect(plain == weighted)
    }

    @Test func lengthLimitsLeaveTitlesOut() {
        let programs = Self.lineup(ChannelLineup(minLength: 100 * 60, maxLength: 130 * 60), from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 16))
        // m2 to m4 are 105, 115 and 125 minutes.
        #expect(Set(programs.map(\.item.id)) == ["m2", "m3", "m4"])
        #expect(Self.lineup(ChannelLineup(maxLength: 60), from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 16)).isEmpty)
    }

    @Test func airDatePlaysEverythingInTheOrderItAired() throws {
        var items: [BaseItem] = []
        for (series, season, number, aired) in [
            ("bravo", 1, 1, "1990-09-10T00:00:00.0000000Z"),
            ("alpha", 1, 2, "1989-02-01T00:00:00.0000000Z"),
            ("alpha", 1, 1, "1989-01-01T00:00:00.0000000Z"),
            ("bravo", 1, 2, "1990-09-17T00:00:00.0000000Z"),
        ] {
            var item = Self.episode(series, season: season, number)
            item.premiereDate = aired
            items.append(item)
        }
        var movie = Self.movie("film", minutes: 90)
        movie.premiereDate = "1990-01-01T00:00:00.0000000Z"
        items.append(movie)
        let ids = Self.lineup(ChannelLineup(mode: .airdate), items: items, channel: "tv", from: Self.date(2026, 10, 15), to: Self.date(2026, 10, 15, 12)).map(\.item.id)
        let cycle = ["alpha-s1e1", "alpha-s1e2", "film", "bravo-s1e1", "bravo-s1e2"]
        let start = try #require(ids.firstIndex(of: "alpha-s1e1"))
        #expect(Array(ids[start...].prefix(5)) == cycle)
    }

    // MARK: Breaks

    nonisolated private static func clip(_ id: String, seconds: Double) -> BaseItem {
        var item = BaseItem(id: id, name: id, type: "Video")
        item.runTimeTicks = Int64(seconds * 10_000_000)
        return item
    }

    /// Three 5-second bumpers, two 15-second promos, four 30-second
    /// commercials and three 20-second interstitials.
    nonisolated private static let clips = ChannelBreakClips(
        bumpers: (0..<3).map { clip("bumper\($0)", seconds: 5) },
        promos: (0..<2).map { clip("promo\($0)", seconds: 15) },
        commercials: (0..<4).map { clip("ad\($0)", seconds: 30) },
        interstitials: (0..<3).map { clip("short\($0)", seconds: 20) }
    )

    private static func segments(_ lineup: ChannelLineup, clips: ChannelBreakClips = clips, from: Date, to: Date) -> [ScheduledProgram] {
        ChannelSchedule.segments(channelId: "channel-a", items: movies, lineup: lineup, breaks: clips, from: from, to: to, calendar: calendar)
    }

    /// The breaks in `segments`, as their clips' roles, between programmes.
    private static func breaks(in segments: [ScheduledProgram]) -> [[ProgramRole]] {
        var breaks: [[ProgramRole]] = []
        var current: [ProgramRole]?
        for segment in segments {
            if segment.role == .programme {
                if let current { breaks.append(current) }
                current = []
            } else {
                current?.append(segment.role)
            }
        }
        return breaks
    }

    @Test func aBreakFollowsEachProgramme() {
        let segments = Self.segments(ChannelLineup(), from: Self.date(2026, 10, 15, 8), to: Self.date(2026, 10, 15, 20))
        let breaks = Self.breaks(in: segments)
        #expect(breaks.count > 3)
        // Bumper out, two minutes of commercials, a promo, an interstitial, bumper back.
        #expect(breaks.allSatisfy { $0 == [.bumper, .commercial, .commercial, .commercial, .commercial, .promo, .interstitial, .bumper] }, "\(breaks)")
        for (a, b) in zip(segments, segments.dropFirst()) { #expect(a.end == b.start) }
        // Whole clips, at their own lengths.
        for segment in segments where segment.role.isBreak {
            #expect(abs(segment.duration - TimeInterval(segment.item.runTimeTicks ?? 0) / 10_000_000) < 0.001)
        }
    }

    @Test func breaksAreTheSameEveryTime() {
        let from = Self.date(2026, 10, 15, 8), to = Self.date(2026, 10, 15, 20)
        let first = Self.segments(ChannelLineup(), from: from, to: to).map(\.item.id)
        #expect(first == Self.segments(ChannelLineup(), from: from, to: to).map(\.item.id))
        // And from a later start, the same clips at the same times.
        let later = Self.segments(ChannelLineup(), from: Self.date(2026, 10, 15, 14), to: to)
        let all = Self.segments(ChannelLineup(), from: from, to: to)
        for segment in later {
            #expect(all.contains { $0.start == segment.start && $0.item.id == segment.item.id })
        }
    }

    @Test func noClipsNoBreaks() {
        let from = Self.date(2026, 10, 15, 8), to = Self.date(2026, 10, 15, 20)
        let plain = Self.lineup(ChannelLineup(), from: from, to: to).map(\.item.id)
        #expect(Self.segments(ChannelLineup(breaks: ChannelBreaks(align: 30)), clips: .none, from: from, to: to).map(\.item.id) == plain)
    }

    @Test(arguments: [30, 15, 60])
    func linedUpProgrammesStartOnTheMark(minutes: Int) {
        let segments = Self.segments(ChannelLineup(breaks: ChannelBreaks(align: minutes)), from: Self.date(2026, 10, 15, 8), to: Self.date(2026, 10, 16, 8))
        let programmes = segments.filter { $0.role == .programme }
        #expect(programmes.count > 5)
        for programme in programmes.dropFirst() {
            let parts = Self.calendar.dateComponents([.minute, .second, .nanosecond], from: programme.start)
            #expect((parts.minute ?? 0) % minutes == 0 && parts.second == 0 && (parts.nanosecond ?? 0) < 1_000_000, "\(programme.start)")
        }
        for (a, b) in zip(segments, segments.dropFirst()) { #expect(abs(a.end.timeIntervalSince(b.start)) < 0.001) }
        // The gap is filled with interstitials, the last cut short; the
        // bumper still closes the break.
        for breakRoles in Self.breaks(in: segments) {
            #expect(breakRoles.first == .bumper && breakRoles.last == .bumper)
            #expect(breakRoles.contains(.interstitial))
        }
    }

    @Test func linedUpWithoutInterstitialsFillsWithCommercials() {
        var clips = Self.clips
        clips.interstitials = []
        let segments = Self.segments(ChannelLineup(breaks: ChannelBreaks(align: 30)), clips: clips, from: Self.date(2026, 10, 15, 8), to: Self.date(2026, 10, 15, 20))
        for programme in segments.filter({ $0.role == .programme }).dropFirst() {
            #expect(Self.calendar.component(.minute, from: programme.start) % 30 == 0)
        }
        #expect(!segments.contains { $0.role == .interstitial })
    }

    @Test func breaksCanComeLessOften() {
        let from = Self.date(2026, 10, 15, 8), to = Self.date(2026, 10, 16, 8)
        let segments = Self.segments(ChannelLineup(breaks: ChannelBreaks(every: 2)), from: from, to: to)
        var run = 0
        var runs: [Int] = []
        for segment in segments {
            if segment.role == .programme { run += 1 } else if run > 0 { runs.append(run); run = 0 }
        }
        #expect(runs.dropFirst().allSatisfy { $0 == 2 }, "\(runs)")
    }

    @Test func bumpersCanGoOnOneSideOnly() {
        let from = Self.date(2026, 10, 15, 8), to = Self.date(2026, 10, 15, 20)
        let out = Self.breaks(in: Self.segments(ChannelLineup(breaks: ChannelBreaks(bumpersAt: .out)), from: from, to: to))
        #expect(out.allSatisfy { $0.first == .bumper && $0.last != .bumper })
        let back = Self.breaks(in: Self.segments(ChannelLineup(breaks: ChannelBreaks(bumpersAt: .in)), from: from, to: to))
        #expect(back.allSatisfy { $0.first != .bumper && $0.last == .bumper })
    }

    @Test func trailersPlayAfterThePromosAndAreNeverCut() {
        var clips = Self.clips
        clips.trailers = (0..<3).map { Self.clip("trailer\($0)", seconds: 150) }
        let from = Self.date(2026, 10, 15, 8), to = Self.date(2026, 10, 15, 20)
        let breaks = Self.breaks(in: Self.segments(ChannelLineup(breaks: ChannelBreaks(trailerCount: 2)), clips: clips, from: from, to: to))
        #expect(!breaks.isEmpty)
        #expect(breaks.allSatisfy { $0 == [.bumper, .commercial, .commercial, .commercial, .commercial, .promo, .trailer, .trailer, .interstitial, .bumper] }, "\(breaks)")
        // Lined up, the interstitials still do the filling, and every trailer plays whole.
        let lined = Self.segments(ChannelLineup(breaks: ChannelBreaks(align: 30)), clips: clips, from: from, to: to)
        for segment in lined where segment.role == .trailer {
            #expect(abs(segment.duration - 150) < 0.001)
        }
        for programme in lined.filter({ $0.role == .programme }).dropFirst() {
            #expect(Self.calendar.component(.minute, from: programme.start) % 30 == 0)
        }
    }

    @Test func aBumperTaggedForOneEndStaysThere() {
        var countdown = Self.clip("countdown", seconds: 10)
        countdown.tags = ["aster:bumper-in"]
        var rightBack = Self.clip("right-back", seconds: 5)
        rightBack.tags = ["aster:bumper-out"]
        let from = Self.date(2026, 10, 15, 8), to = Self.date(2026, 10, 15, 20)
        // Only the countdown: it closes every break, and nothing opens one.
        let alone = Self.segments(ChannelLineup(), clips: ChannelBreakClips(bumpers: [countdown]), from: from, to: to)
        let breaks = Self.breaks(in: alone)
        #expect(!breaks.isEmpty && breaks.allSatisfy { $0 == [.bumper] })
        #expect(alone.filter { $0.role == .bumper }.allSatisfy { $0.item.id == "countdown" })
        // With both, each keeps to its end, right before the programme for the countdown.
        let both = Self.segments(ChannelLineup(), clips: ChannelBreakClips(bumpers: [countdown, rightBack], commercials: Self.clips.commercials), from: from, to: to)
        for (index, segment) in both.enumerated() where segment.role == .bumper {
            if segment.item.id == "countdown" {
                #expect(both.indices.contains(index + 1) == false || both[index + 1].role == .programme)
            } else {
                #expect(both[index - 1].role == .programme)
            }
        }
        #expect(ChannelTags.bumperSide(["aster:BUMPER-OUT"]) == .out)
        #expect(ChannelTags.bumperSide(["Family"]) == .both)
    }

    @Test func theGuideFoldsEachBreakIntoItsProgramme() {
        let from = Self.date(2026, 10, 15, 8), to = Self.date(2026, 10, 15, 20)
        let lineup = ChannelLineup(breaks: ChannelBreaks(align: 30))
        let guide = ChannelSchedule.programs(channelId: "channel-a", items: Self.movies, lineup: lineup, breaks: Self.clips, from: from, to: to, calendar: Self.calendar)
        let programmes = Self.segments(lineup, from: from.addingTimeInterval(-ChannelSchedule.longestBreak), to: to).filter { $0.role == .programme }
        #expect(guide.allSatisfy { $0.role == .programme })
        for (a, b) in zip(guide, guide.dropFirst()) { #expect(a.end == b.start) }
        for programme in guide {
            #expect(programmes.contains { $0.start == programme.start && $0.item.id == programme.item.id })
        }
        #expect(guide.first.map { $0.start <= from && $0.end > from } == true)
    }
}
