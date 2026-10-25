//
//  ResumePoints.swift
//  AsterFIN
//
//  Keeps the server's resume point current while something plays. Jellyfin
//  follows the progress reports sent every ten seconds, but saves the
//  position as the user's resume point only when playback starts and when
//  it's told playback stopped. When the app never gets to say it stopped
//  (it crashed, was closed from the app switcher, or was ended while in the
//  background) the resume point would fall back to where that viewing
//  started. So the position is also saved directly: every 30 seconds, as
//  soon as it's paused somewhere new, and when the app leaves the screen.
//
//  A direct save skips the server's own rules, so they're followed here,
//  with Jellyfin's defaults: no resume point in a title's first 5%, nor in
//  one under five minutes long, and past 90% it's left to the server, which
//  counts it watched.
//

import Foundation

nonisolated struct ResumePositionUpdate: Encodable, Sendable {
    let playbackPositionTicks: Int64

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
    }
}

actor ResumePoints {
    static let shared = ResumePoints()

    enum Saving: Sendable {
        case whenDue, now, never
    }

    /// How often a playing item's resume point is saved.
    static let interval: TimeInterval = 30

    /// Jellyfin's defaults for where a resume point is kept: from 5% in to
    /// 90%, in a title at least five minutes long.
    static let minimumPercent = 5.0
    static let maximumPercent = 90.0
    static let minimumRunTime: Int64 = 5 * 60 * 10_000_000

    /// Whether `ticks` into a title `runTime` long makes a resume point;
    /// without a running time, any position past the start does.
    static func keepsResumePoint(at ticks: Int64, runTime: Int64?) -> Bool {
        guard ticks > 0 else { return false }
        guard let runTime, runTime > 0 else { return true }
        guard runTime >= minimumRunTime else { return false }
        let percent = Double(ticks) / Double(runTime) * 100
        return percent >= minimumPercent && percent <= maximumPercent
    }

    private var lastSaved: [String: (date: Date, ticks: Int64)] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Saves the report's position as the resume point when it's due, or
    /// at once with `force`. Live streams, which can't resume, are skipped,
    /// and so is a position outside the resume rules.
    func progress(_ report: PlaybackReport, client: any MediaServer, force: Bool) async {
        guard report.canSeek, Self.keepsResumePoint(at: report.positionTicks, runTime: report.runTimeTicks) else { return }
        let itemId = report.itemId
        let ticks = report.positionTicks
        if !force, let last = lastSaved[itemId] {
            let due = Date().timeIntervalSince(last.date) >= Self.interval
            let pausedSomewhereNew = report.isPaused && last.ticks != ticks
            guard due || pausedSomewhereNew else { return }
        }
        lastSaved[itemId] = (Date(), ticks)
        await inFlight[itemId]?.value
        let save = Task { _ = try? await client.saveResumePosition(itemId: itemId, ticks: ticks) }
        inFlight[itemId] = save
        await save.value
    }

    /// Playback of the item is ending: waits for a save still on its way, so
    /// the stop report (which may mark it watched) is the last word.
    func stopping(_ itemId: String) async {
        await inFlight[itemId]?.value
        inFlight[itemId] = nil
        lastSaved[itemId] = nil
    }
}
