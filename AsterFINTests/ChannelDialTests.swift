//
//  ChannelDialTests.swift
//  AsterFINTests
//

import CoreGraphics
import Testing
@testable import AsterFIN

struct ChannelDialTests {
    @Test func dragUpGoesToHigherChannels() {
        #expect(ChannelDialMath.steps(from: -28) == 1)
        #expect(ChannelDialMath.steps(from: -83) == 2)
        #expect(ChannelDialMath.steps(from: 60) == -2)
    }

    @Test func lessThanADetentPassesNothing() {
        #expect(ChannelDialMath.steps(from: -27) == 0)
        #expect(ChannelDialMath.steps(from: 27) == 0)
        #expect(ChannelDialMath.steps(from: 0) == 0)
    }

    @Test func flingCarriesOnByThePredictedDistance() {
        // Let go at 1 channel up, heading for 4.
        #expect(ChannelDialMath.flingSteps(predicted: -112, actual: -28) == 3)
        #expect(ChannelDialMath.flingSteps(predicted: 10, actual: 5) == 0)
    }

    @Test func flingIsCapped() {
        #expect(ChannelDialMath.flingSteps(predicted: -2000, actual: 0) == ChannelDialMath.flingCap)
        #expect(ChannelDialMath.flingSteps(predicted: 2000, actual: 0) == -ChannelDialMath.flingCap)
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
