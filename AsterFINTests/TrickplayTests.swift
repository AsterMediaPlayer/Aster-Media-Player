//
//  TrickplayTests.swift
//  AsterFINTests
//
//  Finding the trickplay frame for a point in a title: which sheet, which
//  cell, and the cell's rectangle, matching how Jellyfin lays them out (left
//  to right, then down, one sheet after another).
//

import CoreGraphics
import Testing
@testable import AsterFIN

struct TrickplayTests {
    /// Like the server's: 320×180 frames, 10×10 to a sheet, one every 10 s.
    private let info = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 143, interval: 10_000)

    @Test func theStartIsTheFirstCell() {
        #expect(info.cell(at: 0) == .init(sheet: 0, column: 0, row: 0))
        #expect(info.cell(at: 9.9) == .init(sheet: 0, column: 0, row: 0))
    }

    @Test func framesRunAcrossThenDown() {
        #expect(info.cell(at: 10) == .init(sheet: 0, column: 1, row: 0))
        #expect(info.cell(at: 95) == .init(sheet: 0, column: 9, row: 0))
        #expect(info.cell(at: 100) == .init(sheet: 0, column: 0, row: 1))
    }

    @Test func theHundredthFrameStartsTheNextSheet() {
        #expect(info.cell(at: 999) == .init(sheet: 0, column: 9, row: 9))
        #expect(info.cell(at: 1000) == .init(sheet: 1, column: 0, row: 0))
    }

    @Test func pastTheEndIsTheLastFrame() {
        // Frame 142 of 143: sheet 1, cell 42.
        #expect(info.cell(at: 99_999) == .init(sheet: 1, column: 2, row: 4))
        #expect(info.cell(at: -5) == .init(sheet: 0, column: 0, row: 0))
    }

    @Test func cellRectangles() {
        #expect(info.rect(of: .init(sheet: 0, column: 3, row: 2)) == CGRect(x: 960, y: 360, width: 320, height: 180))
    }

    @Test func theClosestResolutionIsChosen() {
        let small = TrickplayInfo(width: 160, height: 90, tileWidth: 10, tileHeight: 10, thumbnailCount: 10, interval: 10_000)
        let large = TrickplayInfo(width: 640, height: 360, tileWidth: 10, tileHeight: 10, thumbnailCount: 10, interval: 10_000)
        #expect(TrickplayInfo.best(in: ["160": small, "320": info, "640": large], near: 320) == info)
        #expect(TrickplayInfo.best(in: ["160": small, "640": large], near: 600) == large)
        #expect(TrickplayInfo.best(in: [:], near: 320) == nil)
    }

    @Test func missingSpacingGivesNoCell() {
        var broken = info
        broken.interval = 0
        #expect(broken.cell(at: 10) == nil)
    }
}
