//
//  EmbyExtrasTests.swift
//  AsterFINTests
//
//  Emby's own forms of what Jellyfin has routes for: scrub previews as a BIF
//  file, and lyrics as LRC text.
//

import Foundation
import Testing
@testable import AsterFIN

struct EmbyExtrasTests {
    /// A BIF file with `frames` (time in ms, bytes) and the given multiplier.
    private func bif(_ frames: [(UInt32, [UInt8])], multiplier: UInt32 = 1000) -> Data {
        func word(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        var header: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A] + word(0) + word(UInt32(frames.count)) + word(multiplier)
        header += [UInt8](repeating: 0, count: 64 - header.count)
        var offset = UInt32(64 + (frames.count + 1) * 8)
        var index: [UInt8] = []
        for (time, bytes) in frames {
            index += word(time) + word(offset)
            offset += UInt32(bytes.count)
        }
        index += word(.max) + word(offset)
        return Data(header + index + frames.flatMap(\.1))
    }

    @Test func readsABIFIndex() throws {
        let index = try #require(BIFIndex(bif([(0, [1, 2]), (10, [3, 4, 5]), (20, [6])])))
        #expect(index.frames.map(\.seconds) == [0, 10, 20])
        let data = bif([(0, [1, 2]), (10, [3, 4, 5]), (20, [6])])
        #expect(index.range(at: 0).map { [UInt8](data.subdata(in: $0)) } == [1, 2])
        #expect(index.range(at: 14.5).map { [UInt8](data.subdata(in: $0)) } == [3, 4, 5])
        #expect(index.range(at: 999).map { [UInt8](data.subdata(in: $0)) } == [6])
    }

    @Test func aBIFMultiplierIsMillisecondsPerUnit() throws {
        // Roku's own files: one unit per frame, 10 s apart.
        let index = try #require(BIFIndex(bif([(0, [1]), (1, [2])], multiplier: 10_000)))
        #expect(index.frames.map(\.seconds) == [0, 10])
    }

    @Test func notABIFFile() {
        #expect(BIFIndex(Data("<html>not found</html>".utf8)) == nil)
    }

    @Test func readsTimedLRC() throws {
        let lyrics = try #require(Lyrics(lrc: """
            [ar:Someone]
            [ti:A Song]
            [00:12.50]First line
            [00:05.00][01:02.25]Chorus
            """))
        #expect(lyrics.isSynced)
        #expect(lyrics.lyrics.map(\.text) == ["Chorus", "First line", "Chorus"])
        #expect(lyrics.lyrics.map(\.start) == [50_000_000, 125_000_000, 622_500_000])
    }

    @Test func anLRCOffsetShowsLinesSooner() throws {
        let lyrics = try #require(Lyrics(lrc: "[offset:+500]\n[00:02.00]Line"))
        #expect(lyrics.lyrics.first?.start == 15_000_000)
    }

    @Test func plainTextIsUnsynced() throws {
        let lyrics = try #require(Lyrics(lrc: "\nOne\nTwo\n\n"))
        #expect(!lyrics.isSynced)
        #expect(lyrics.lyrics.map(\.text) == ["One", "Two"])
        #expect(Lyrics(lrc: "[ar:Only tags]\n") == nil)
    }
}
