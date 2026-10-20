//
//  ChannelDialTests.swift
//  AsterFINTests
//

import CoreGraphics
import Testing
@testable import AsterFIN

struct ChannelDialTests {
    private let detent = ChannelDialMath.detent

    @Test func dragUpGoesToHigherChannels() {
        #expect(ChannelDialMath.steps(from: -detent) == 1)
        #expect(ChannelDialMath.steps(from: -detent * 2.1) == 2)
        #expect(ChannelDialMath.steps(from: detent * 2.5) == -2)
    }

    @Test func lessThanADetentPassesNothing() {
        #expect(ChannelDialMath.steps(from: -(detent - 1)) == 0)
        #expect(ChannelDialMath.steps(from: detent - 1) == 0)
        #expect(ChannelDialMath.steps(from: 0) == 0)
    }

    @Test func flingCarriesOnByThePredictedDistance() {
        // Let go at 1 channel up, heading for 4.
        #expect(ChannelDialMath.flingSteps(predicted: -detent * 4, actual: -detent, velocity: -1500) == 3)
    }

    @Test func liftingSlowlyAddsNothing() {
        #expect(ChannelDialMath.flingSteps(predicted: -detent * 3, actual: -detent, velocity: -400) == 0)
    }

    @Test func flingIsCapped() {
        #expect(ChannelDialMath.flingSteps(predicted: -5000, actual: 0, velocity: -4000) == ChannelDialMath.flingCap)
        #expect(ChannelDialMath.flingSteps(predicted: 5000, actual: 0, velocity: 4000) == -ChannelDialMath.flingCap)
    }

    @Test func flingSlowsDown() {
        let delays = ChannelDialMath.flingDelays(count: 5)
        #expect(delays.count == 5)
        #expect(delays.first == 40)
        #expect(delays.last == 140)
        #expect(delays == delays.sorted())
        #expect(ChannelDialMath.flingDelays(count: 0).isEmpty)
    }
}
