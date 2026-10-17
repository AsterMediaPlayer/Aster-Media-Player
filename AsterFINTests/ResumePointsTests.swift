//
//  ResumePointsTests.swift
//  AsterFINTests
//
//  The app's direct resume-point saves follow Jellyfin's default rules: none
//  in the first 5%, none past 90% (the server counts that watched), none in
//  a title under five minutes, and any position past the start when the
//  running time isn't known.
//

import Testing
@testable import AsterFIN

struct ResumePointsTests {
    private static let minute: Int64 = 60 * 10_000_000
    private static let movie = 160 * minute

    @Test func aMovieKeepsItsPlaceBetweenFiveAndNinetyPercent() {
        #expect(ResumePoints.keepsResumePoint(at: 80 * Self.minute, runTime: Self.movie))
        #expect(ResumePoints.keepsResumePoint(at: 8 * Self.minute, runTime: Self.movie))
        #expect(ResumePoints.keepsResumePoint(at: 144 * Self.minute, runTime: Self.movie))
    }

    @Test func theStartAndTheEndAreLeftToTheServer() {
        #expect(!ResumePoints.keepsResumePoint(at: 0, runTime: Self.movie))
        #expect(!ResumePoints.keepsResumePoint(at: 7 * Self.minute, runTime: Self.movie))
        #expect(!ResumePoints.keepsResumePoint(at: 150 * Self.minute, runTime: Self.movie))
    }

    @Test func aShortClipNeverKeepsAPlace() {
        #expect(!ResumePoints.keepsResumePoint(at: 2 * Self.minute, runTime: 4 * Self.minute))
    }

    @Test func withoutARunningTimeAnyPositionPastTheStartCounts() {
        #expect(ResumePoints.keepsResumePoint(at: 1, runTime: nil))
        #expect(!ResumePoints.keepsResumePoint(at: 0, runTime: nil))
    }
}
