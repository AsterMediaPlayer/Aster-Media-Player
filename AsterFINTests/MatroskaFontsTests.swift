//
//  MatroskaFontsTests.swift
//  AsterFINTests
//
//  The fonts an MKV carries, found through its SeekHead and read from its
//  Attachments, as for a Plex file (shaped like Zom 100's: a SeekHead
//  first, its attachments soon after, fonts as font/ttf and font/otf).
//

import Foundation
import Testing
@testable import AsterFIN

struct MatroskaFontsTests {
    /// An element: its id, an 8-byte size, then the payload.
    private func element(_ id: [UInt8], _ payload: Data) -> Data {
        var size = UInt64(payload.count)
        var sizeBytes = [UInt8](repeating: 0, count: 7)
        for index in (0..<7).reversed() {
            sizeBytes[index] = UInt8(size & 0xFF)
            size >>= 8
        }
        return Data(id) + Data([0x01] + sizeBytes) + payload
    }

    private func attachedFile(_ name: String, _ mime: String, _ bytes: Int) -> Data {
        element([0x61, 0xA7],
                element([0x46, 0x6E], Data(name.utf8))
                + element([0x46, 0x60], Data(mime.utf8))
                + element([0x46, 0x5C], Data(repeating: 7, count: bytes)))
    }

    @Test func attachmentsAreFoundAndOnlyFontsKept() throws {
        let attachments = element([0x19, 0x41, 0xA4, 0x69],
                                  attachedFile("acme.TTF", "font/ttf", 40)
                                  + attachedFile("cover.jpg", "image/jpeg", 30)
                                  + attachedFile("mythica.OTF", "application/vnd.ms-opentype", 20))
        // The SeekHead's entry points at the attachments, after itself and an Info element.
        let info = element([0x15, 0x49, 0xA9, 0x66], Data(repeating: 0, count: 10))
        func seekHead(position: Int) -> Data {
            element([0x11, 0x4D, 0x9B, 0x74],
                    element([0x4D, 0xBB],
                            element([0x53, 0xAB], Data([0x19, 0x41, 0xA4, 0x69]))
                            + element([0x53, 0xAC], Data([UInt8(position >> 8), UInt8(position & 0xFF)]))))
        }
        let headLength = seekHead(position: 0).count
        let body = seekHead(position: headLength + info.count) + info + attachments
        let file = element([0x1A, 0x45, 0xDF, 0xA3], Data([0x42, 0x86, 0x81, 0x01])) + element([0x18, 0x53, 0x80, 0x67], body)

        let position = try #require(try MatroskaFonts.attachmentsPosition(in: file))
        var cursor = position
        let header = try #require(MatroskaFonts.elementHeader(file, &cursor))
        #expect(header.0 == 0x1941_A469)
        let contents = file.subdata(in: cursor..<(cursor + Int(try #require(header.1))))
        let fonts = MatroskaFonts.parseAttachments(contents)
        #expect(fonts.map(\.name) == ["acme.TTF", "mythica.OTF"])
        #expect(fonts.first?.data.count == 40)
    }

    @Test func fontsAreKnownByTypeOrName() {
        #expect(MatroskaFonts.isFont(name: "a.bin", mime: "font/otf"))
        #expect(MatroskaFonts.isFont(name: "FiraSans.ttf", mime: "application/octet-stream"))
        #expect(!MatroskaFonts.isFont(name: "cover.jpg", mime: "image/jpeg"))
    }

    /// Raw lines the engine hands over for the styled renderer read as text
    /// when shown plainly, drawings left out.
    @Test func rawEngineLinesReadAsText() {
        #expect(SubtitleCue.engineText("0,0,Default,,0,0,0,,I'm {\\i1}late{\\i0}!") == "I'm late!")
        #expect(SubtitleCue.engineText("12,1,Sign,,0,0,0,,{\\p1}m 0 0 l 100 0 100 50{\\p0}") == nil)
        #expect(SubtitleCue.engineText("Just text, with commas, here") == "Just text, with commas, here")
    }
}
