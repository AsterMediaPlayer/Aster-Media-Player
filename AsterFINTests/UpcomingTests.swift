//
//  UpcomingTests.swift
//  AsterFINTests
//
//  The Upcoming tab's dates and wording: air dates (local midnight sent in
//  UTC) land on the right day, days are grouped in order, and the countdown
//  and episode lines read naturally.
//

import Foundation
import Testing
@testable import AsterFIN

@MainActor
struct UpcomingTests {
    /// Central time, where the server's dates were checked (05:00Z is midnight).
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private static func episode(_ id: String, series: String, season: Int, number: Int, name: String, airs: String, location: String = "Virtual") -> BaseItem {
        var item = BaseItem(id: id, name: name, type: ItemKind.episode.rawValue)
        item.seriesName = series
        item.seriesId = "series-\(series)"
        item.parentIndexNumber = season
        item.indexNumber = number
        item.premiereDate = airs
        item.locationType = location
        return item
    }

    private static func day(_ text: String) -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    @Test func airDateReadsJellyfinsSevenDecimals() throws {
        let item = Self.episode("a", series: "Blue Box", season: 2, number: 3, name: "Episode 3", airs: "2026-10-18T05:00:00.0000000Z")
        let date = try #require(UpcomingSchedule.airDate(of: item))
        #expect(Self.calendar.startOfDay(for: date) == Self.day("2026-10-18"))
    }

    @Test func groupsByLocalDayInOrder() {
        let items = [
            Self.episode("c", series: "Blue Box", season: 2, number: 3, name: "Episode 3", airs: "2026-10-18T05:00:00.0000000Z"),
            Self.episode("b", series: "Reincarnated as a Sword", season: 2, number: 3, name: "Episode 3", airs: "2026-10-15T05:00:00.0000000Z"),
            Self.episode("a", series: "Reincarnated as a Sword", season: 2, number: 2, name: "Jean du Vix Knows His Stuff", airs: "2026-10-15T05:00:00.0000000Z"),
            Self.episode("d", series: "Ranma1/2 (2024)", season: 3, number: 3, name: "Episode 3", airs: "2026-10-18T05:00:00.0000000Z"),
        ]
        let days = UpcomingSchedule.days(of: items, calendar: Self.calendar)
        #expect(days.map(\.day) == [Self.day("2026-10-15"), Self.day("2026-10-18")])
        #expect(days[0].episodes.map(\.id) == ["a", "b"])
        #expect(days[1].episodes.map(\.id) == ["c", "d"])
    }

    @Test func countdownWording() {
        let now = Self.day("2026-10-13").addingTimeInterval(10 * 3600)
        #expect(UpcomingSchedule.countdown(to: Self.day("2026-10-13"), from: now, calendar: Self.calendar) == "Today")
        #expect(UpcomingSchedule.countdown(to: Self.day("2026-10-14"), from: now, calendar: Self.calendar) == "Tomorrow")
        #expect(UpcomingSchedule.countdown(to: Self.day("2026-10-15"), from: now, calendar: Self.calendar) == "In 2 days")
        #expect(UpcomingSchedule.countdown(to: Self.day("2026-10-20"), from: now, calendar: Self.calendar) == "In 1 week")
        #expect(UpcomingSchedule.countdown(to: Self.day("2026-10-27"), from: now, calendar: Self.calendar) == "In 2 weeks")
    }

    @Test func episodeLineDropsPlaceholderTitles() {
        let placeholder = Self.episode("a", series: "Blue Box", season: 2, number: 3, name: "Episode 3", airs: "")
        let named = Self.episode("b", series: "Bleach", season: 3, number: 9, name: "The Blade", airs: "")
        #expect(UpcomingSchedule.episodeLine(for: placeholder) == "S2 · E3")
        #expect(UpcomingSchedule.episodeLine(for: named) == "S3 · E9 · The Blade")
    }

    @Test func availableEpisodesOpenThemselvesOthersTheirShow() {
        let early = Self.episode("a", series: "Sword", season: 2, number: 2, name: "Jean", airs: "", location: "FileSystem")
        let placeholder = Self.episode("b", series: "Sword", season: 2, number: 3, name: "Episode 3", airs: "")
        #expect(UpcomingSchedule.destination(for: early).id == "a")
        #expect(UpcomingSchedule.destination(for: placeholder).id == "series-Sword")
        #expect(UpcomingSchedule.destination(for: placeholder).kind == .series)
    }

    /// Not out yet, but with a title or a summary: its own page.
    @Test func episodesWithDetailsOpenThemselves() {
        let named = Self.episode("a", series: "Sword", season: 2, number: 4, name: "The Guild's Test", airs: "")
        var summarized = Self.episode("b", series: "Sword", season: 2, number: 5, name: "Episode 5", airs: "")
        summarized.overview = "Fran faces the guild master."
        let tba = Self.episode("c", series: "Sword", season: 2, number: 6, name: "TBA", airs: "")
        #expect(UpcomingSchedule.destination(for: named).id == "a")
        #expect(UpcomingSchedule.destination(for: summarized).id == "b")
        #expect(UpcomingSchedule.destination(for: tba).kind == .series)
    }

    @Test func airsLineWording() {
        let now = Self.day("2026-10-13").addingTimeInterval(10 * 3600)
        let tomorrow = Self.episode("a", series: "Sword", season: 2, number: 4, name: "x", airs: "2026-10-14T05:00:00.0000000Z")
        let later = Self.episode("b", series: "Sword", season: 2, number: 5, name: "y", airs: "2026-10-22T05:00:00.0000000Z")
        #expect(UpcomingSchedule.airsLine(for: tomorrow, now: now, calendar: Self.calendar) == "Airs Tomorrow")
        #expect(UpcomingSchedule.airsLine(for: later, now: now, calendar: Self.calendar)?.hasPrefix("Airs ") == true)
        #expect(UpcomingSchedule.airsLine(for: later, now: now, calendar: Self.calendar) != "Airs In 1 week")
    }
}
