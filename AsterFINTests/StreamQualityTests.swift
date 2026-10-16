//
//  StreamQualityTests.swift
//  AsterFINTests
//
//  When the player offers a lower quality: after one stall that lasts, or
//  stalls that keep coming back, never for a short blip, and not again for
//  a while once "Keep Trying" has been chosen.
//

import Foundation
import Testing
@testable import AsterFIN

struct StreamQualityTests {
    /// Feeds the watch (stalling or not, at seconds from the start) and
    /// returns its answers in order.
    private func answers(_ samples: [(stalling: Bool, at: TimeInterval)], declineAt: TimeInterval? = nil, watch: StallWatch = StallWatch()) -> [Bool] {
        var watch = watch
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var results: [Bool] = []
        for sample in samples {
            let now = start.addingTimeInterval(sample.at)
            results.append(watch.note(stalling: sample.stalling, at: now))
            if let declineAt, sample.at == declineAt {
                watch.declined(at: now)
            }
        }
        return results
    }

    @Test func aShortBlipIsLeftAlone() {
        let result = answers([(true, 0), (true, 2), (false, 3)])
        #expect(result == [false, false, false])
    }

    @Test func oneLongStallBringsTheOffer() {
        let result = answers([(true, 0), (true, 4.9), (true, 5)])
        #expect(result == [false, false, true])
    }

    @Test func stallsThatKeepComingBackBringTheOffer() {
        // The third stall inside a minute.
        let result = answers([(true, 0), (false, 1), (true, 20), (false, 21), (true, 45)])
        #expect(result == [false, false, false, false, true])
    }

    @Test func oldStallsStopCounting() {
        let result = answers([(true, 0), (false, 1), (true, 70), (false, 71), (true, 140), (false, 141)])
        #expect(!result.contains(true))
    }

    @Test func keepTryingHoldsTheOfferOff() {
        let result = answers(
            [
                (true, 0), (true, 6),        // offered, then Keep Trying
                (true, 60), (false, 61),     // still bad, but inside the quiet two minutes
                (true, 130), (true, 136),    // after it, a fresh long stall offers again
            ],
            declineAt: 6
        )
        #expect(result == [false, true, false, false, false, true])
    }

    @Test func qualitiesReadAsMegabits() {
        #expect(StreamQuality.caps.map(StreamQuality.title) == ["20 Mbps", "10 Mbps", "4 Mbps"])
        #expect(StreamQuality.caps == StreamQuality.caps.sorted(by: >))
    }
}
