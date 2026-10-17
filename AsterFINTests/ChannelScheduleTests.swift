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
}
