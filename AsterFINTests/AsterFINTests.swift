//
//  AsterFINTests.swift
//  AsterFINTests
//
//  Runs the JellyDisc conformance vectors (conformance/*.json from the
//  jellydisc repository) against the app's implementation of the rules.
//

import CoreGraphics
import Foundation
import Testing
@testable import AsterFIN

@MainActor
struct DiscMenuConformanceTests {

    // MARK: Loading vectors

    /// A vector file: from the test bundle, where the build copies them
    /// (flat, documents too), since a simulator can't see the source folder;
    /// straight from the source folder where it can.
    private static func conformanceFile(_ name: String, in folder: String? = nil) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        if let bundled = Bundle.allBundles.first(where: { $0.bundleURL.pathExtension == "xctest" })?.url(forResource: base, withExtension: ext) {
            return bundled
        }
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Conformance")
        if let folder { url.appendPathComponent(folder) }
        return url.appendingPathComponent(name)
    }

    private static func loadJSON(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: conformanceFile(name))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static func cases(_ name: String) throws -> [[String: Any]] {
        try #require(try loadJSON(name)["cases"] as? [[String: Any]])
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func sameNumber(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) <= 1e-6
        default: return false
        }
    }

    private static func samePosition(_ a: DiscPosition?, _ b: DiscPosition?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            return sameNumber(x.x, y.x) && sameNumber(x.y, y.y) && sameNumber(x.w, y.w) && sameNumber(x.h, y.h) && (x.anchor ?? "top-left") == (y.anchor ?? "top-left")
        default: return false
        }
    }

    private static func contentEntries(count: Int, back: Bool, home: Bool) -> [DiscMenuEntry] {
        var entries = (0..<count).map { DiscMenuEntry(action: "playExtra", label: "E\($0 + 1)") }
        if back { entries.append(DiscMenuEntry(action: "back", label: "Back")) }
        if home { entries.append(DiscMenuEntry(action: "home", label: "Home")) }
        return entries
    }

    // MARK: paginate.json

    @Test func paginate() throws {
        var checked = 0
        for c in try Self.cases("paginate.json") {
            let entries: [DiscMenuEntry]
            if let raw = c["entries"] {
                entries = try Self.decode([DiscMenuEntry].self, from: raw)
            } else {
                entries = Self.contentEntries(count: c["n"] as? Int ?? 0, back: c["back"] as? Bool ?? false, home: c["home"] as? Bool ?? false)
            }
            let slots = try #require(c["slots"] as? Int)
            let maxPerPage = c["maxPerPage"] as? Int ?? 0
            let expected = try #require(c["pages"] as? [[String: Any]])
            let pages = DiscMenuRules.paginate(entries, slots: slots, maxPerPage: maxPerPage)
            #expect(pages.count == expected.count, "page count for \(c)")
            for (page, want) in zip(pages, expected) {
                #expect(page.items.map(\.label) == (want["items"] as? [String] ?? []), "items for \(c)")
                #expect(page.backs.map(\.label) == (want["backs"] as? [String] ?? []), "backs for \(c)")
                #expect(page.prev == (want["prev"] as? Bool ?? false), "prev for \(c)")
                #expect(page.more == (want["more"] as? Bool ?? false), "more for \(c)")
            }
            checked += 1
        }
        #expect(checked == 318)
    }

    // MARK: cells.json

    @Test func cellPositions() throws {
        var checked = 0
        for c in try Self.cases("cells.json") {
            let flow = try Self.decode(DiscFlow.self, from: try #require(c["flow"]))
            let slot = try #require(c["slot"] as? Int)
            let tall = c["tall"] as? Bool ?? false
            let expected = try Self.decode(DiscPosition.self, from: try #require(c["position"]))
            let got = DiscMenuRules.cellPosition(flow, slot: slot, tall: tall)
            #expect(Self.samePosition(got, expected), "cell \(c)")
            checked += 1
        }
        #expect(checked == 163)
    }

    // MARK: layout.json

    @Test func layouts() throws {
        var documents: [String: DiscMenuDocument] = [:]
        var checked = 0
        for c in try Self.cases("layout.json") {
            let name = try #require(c["document"] as? String)
            if documents[name] == nil {
                let data = try Data(contentsOf: Self.conformanceFile(name, in: "documents"))
                documents[name] = try JSONDecoder().decode(DiscMenuDocument.self, from: data)
            }
            let document = try #require(documents[name])
            let menuKey = try #require(c["menu"] as? String)
            let menu = try #require(document.menus[menuKey])
            let page = try #require(c["page"] as? Int)

            let expectedLayout = try Self.decode(DiscLayout.self, from: try #require(c["effectiveLayout"]))
            let merged = DiscMenuRules.effectiveLayout(document: document.layout, screen: menu.layout)
            #expect(merged == expectedLayout, "effective layout of \(name)/\(menuKey)")

            let result = DiscMenuRules.entriesForPage(document: document, screen: menu, page: page)
            #expect(result.pageCount == (c["pages"] as? Int ?? -1), "page count of \(name)/\(menuKey)")
            #expect(result.page == page, "page of \(name)/\(menuKey)")

            let expectedEntries = try #require(c["entries"] as? [[String: Any]])
            #expect(result.entries.count == expectedEntries.count, "entry count of \(name)/\(menuKey) page \(page)")
            for (entry, want) in zip(result.entries, expectedEntries) {
                #expect(entry.action == (want["Action"] as? String ?? ""), "action in \(name)/\(menuKey)")
                #expect(entry.label == (want["Label"] as? String ?? ""), "label in \(name)/\(menuKey)")
                let wantPosition: DiscPosition?
                if let raw = want["Position"], !(raw is NSNull) {
                    wantPosition = try Self.decode(DiscPosition.self, from: raw)
                } else {
                    wantPosition = nil
                }
                #expect(Self.samePosition(entry.position, wantPosition), "position of \(entry.label) in \(name)/\(menuKey) page \(page)")
            }
            checked += 1
        }
        #expect(checked == 27)
    }

    // MARK: focus.json

    @Test func focus() throws {
        let directions: [(String, Int, Int)] = [("right", 1, 0), ("left", -1, 0), ("down", 0, 1), ("up", 0, -1)]
        var checked = 0
        for c in try Self.cases("focus.json") {
            let rawRects = try #require(c["rects"] as? [[String: Any]])
            let rects = rawRects.map { r in
                CGRect(x: (r["left"] as? Double) ?? 0, y: (r["top"] as? Double) ?? 0, width: (r["width"] as? Double) ?? 0, height: (r["height"] as? Double) ?? 0)
            }
            let from = try #require(c["from"] as? Int)
            let expected = try #require(c["expected"] as? [String: Int])
            for (name, dx, dy) in directions {
                let got = DiscMenuRules.moveFocus(rects: rects, current: from, dx: dx, dy: dy)
                #expect(got == expected[name], "\(c["layout"] ?? "") from \(from) \(name)")
            }
            checked += 1
        }
        #expect(checked == 62)
    }

    // MARK: time-format.json

    @Test func timeFormat() throws {
        var checked = 0
        for c in try Self.cases("time-format.json") {
            let ticks = try #require(c["ticks"] as? NSNumber).int64Value
            #expect(DiscMenuRules.formatTicks(ticks) == (c["text"] as? String), "ticks \(ticks)")
            checked += 1
        }
        #expect(checked == 14)
    }

    // MARK: safety.json

    @Test func safety() throws {
        var checked = 0
        for c in try Self.cases("safety.json") {
            let kind = try #require(c["kind"] as? String)
            let value = try #require(c["value"] as? String)
            let accepted = try #require(c["accepted"] as? Bool)
            let got: Bool
            switch kind {
            case "image": got = DiscMenuRules.isSafeImage(value)
            case "audio": got = DiscMenuRules.isSafeAudio(value)
            case "colour": got = DiscMenuRules.isHexColor(value)
            case "tmdb": got = DiscMenuRules.isTmdbPath(value)
            case "fanartId": got = DiscMenuRules.isFanartId(value)
            case "itemId": got = DiscMenuRules.isItemId(value)
            default:
                Issue.record("unknown safety kind \(kind)")
                continue
            }
            #expect(got == accepted, "\(kind) \(value.debugDescription)")
            checked += 1
        }
        #expect(checked == 90)
    }
}
