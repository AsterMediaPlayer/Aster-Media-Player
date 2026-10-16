//
//  StreamQuality.swift
//  AsterFIN
//
//  Lower qualities for when the original file is too much for the
//  connection, and when to offer them. AetherEngine always plays the
//  original; picking one of these hands the title to the system player
//  with that cap, so the server converts it down to fit.
//

import Foundation

nonisolated enum StreamQuality {
    /// The caps offered, in bits per second, highest first.
    static let caps = [20_000_000, 10_000_000, 4_000_000]

    /// "20 Mbps".
    static func title(_ cap: Int) -> String {
        "\(cap / 1_000_000) Mbps"
    }
}

/// Decides when stalling has gone on long enough to offer a lower quality:
/// one stall that lasts, or stalls that keep coming back. Turning the offer
/// down leaves it alone for a while.
nonisolated struct StallWatch {
    /// A single stall this long brings the offer up.
    var longStall: TimeInterval = 5
    /// So does this many stalls inside `window`.
    var repeats = 3
    var window: TimeInterval = 60
    /// How long "Keep trying" holds the offer off.
    var quietAfterDecline: TimeInterval = 120

    private var stallStart: Date?
    private var stalls: [Date] = []
    private var quietUntil: Date?

    /// Takes whether playback is held up right now; true when it's time to
    /// offer a lower quality.
    mutating func note(stalling: Bool, at now: Date) -> Bool {
        guard stalling else {
            stallStart = nil
            return false
        }
        if stallStart == nil {
            stallStart = now
            stalls.append(now)
        }
        stalls.removeAll { now.timeIntervalSince($0) > window }
        if let quietUntil, now < quietUntil { return false }
        let lasting = stallStart.map { now.timeIntervalSince($0) >= longStall } ?? false
        return lasting || stalls.count >= repeats
    }

    /// The offer was turned down: hold it off for a while, then count afresh.
    mutating func declined(at now: Date) {
        quietUntil = now.addingTimeInterval(quietAfterDecline)
        stalls = []
        if stallStart != nil { stallStart = now }
    }
}
