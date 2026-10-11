//
//  DiscMenuRules.swift
//  AsterFIN
//
//  The screen-independent rules of the JellyDisc format (CLIENT_GUIDE §4):
//  paging, grid cells, settings inheritance, directional focus, chapter time
//  text and what to accept from untrusted data. Every function here is pure
//  and is checked against the plugin's conformance vectors by AsterFINTests.
//

import Foundation
import CoreGraphics

nonisolated enum DiscMenuRules {

    // MARK: Anchors and placement

    /// Shift of the element, as a fraction of its own size, for each anchor name.
    static func anchorShift(_ anchor: String?) -> (x: Double, y: Double) {
        switch anchor ?? "top-left" {
        case "top": return (-0.5, 0)
        case "top-right": return (-1, 0)
        case "left": return (0, -0.5)
        case "center": return (-0.5, -0.5)
        case "right": return (-1, -0.5)
        case "bottom-left": return (0, -1)
        case "bottom": return (-0.5, -1)
        case "bottom-right": return (-1, -1)
        default: return (0, 0)
        }
    }

    // MARK: Paging

    nonisolated struct Page: Equatable, Sendable {
        var items: [DiscMenuEntry]
        var backs: [DiscMenuEntry]
        var prev: Bool
        var more: Bool
    }

    /// Splits a screen's entries over the pages of a `slots`-cell grid. The first
    /// `back` and the first `home` entry are pinned to every page.
    static func paginate(_ entries: [DiscMenuEntry], slots: Int, maxPerPage: Int = 0) -> [Page] {
        let maxPer = maxPerPage > 0 ? maxPerPage : Int.max
        let firstBack = entries.firstIndex { $0.action == "back" }
        let firstHome = entries.firstIndex { $0.action == "home" }
        var backs: [DiscMenuEntry] = []
        var content: [DiscMenuEntry] = []
        for (index, entry) in entries.enumerated() {
            if index == firstBack || index == firstHome {
                backs.append(entry)
            } else {
                content.append(entry)
            }
        }
        var pages: [Page] = []
        var taken = 0
        while true {
            let prev = !pages.isEmpty
            let room = slots - (backs.count + (prev ? 1 : 0))
            let left = content.count - taken
            if left <= min(room, maxPer) {
                pages.append(Page(items: Array(content[taken...]), backs: backs, prev: prev, more: false))
                return pages
            }
            let cap = min(max(1, room - 1), maxPer)
            pages.append(Page(items: Array(content[taken..<(taken + cap)]), backs: backs, prev: prev, more: true))
            taken += cap
        }
    }

    /// The on-screen position of grid cell `slot` (row-major from 0) of a flow.
    static func cellPosition(_ flow: DiscFlow, slot: Int, tall: Bool) -> DiscPosition {
        let region = flow.region
        let shift = anchorShift(region.anchor)
        let width = region.w ?? 0
        let height = region.h ?? 0
        let left = region.x + shift.x * width
        let top = region.y + shift.y * height
        let columns = max(1, flow.columns)
        let rows = max(1, flow.rows)
        let cellW = width / Double(columns)
        let cellH = height / Double(rows)
        return DiscPosition(
            x: left + (Double(slot % columns) + 0.5) * cellW,
            y: top + (Double(slot / columns) + 0.5) * cellH,
            w: cellW * 0.94,
            h: tall ? cellH * 0.94 : nil,
            anchor: "center"
        )
    }

    // MARK: Inheritance

    /// Document layout, then the screen's, key by key. A missing or null key is skipped.
    static func effectiveLayout(document: DiscLayout?, screen: DiscLayout?) -> DiscLayout {
        DiscLayout(
            titlePosition: screen?.titlePosition ?? document?.titlePosition,
            hideTitle: screen?.hideTitle ?? document?.hideTitle,
            buttonStyle: screen?.buttonStyle ?? document?.buttonStyle,
            flow: screen?.flow ?? document?.flow,
            transition: screen?.transition ?? document?.transition,
            layers: screen?.layers ?? document?.layers
        )
    }

    /// Theme and background are whole-object: the screen's, else the document's.
    static func effectiveTheme(document: DiscTheme?, screen: DiscTheme?) -> DiscTheme {
        screen ?? document ?? DiscTheme()
    }

    static func effectiveBackground(document: DiscBackground?, screen: DiscBackground?) -> DiscBackground? {
        screen ?? document
    }

    /// Audio merges per part: Music and Sounds each fall back separately.
    static func effectiveAudio(document: DiscAudio?, screen: DiscAudio?) -> DiscAudio? {
        guard document != nil || screen != nil else { return nil }
        return DiscAudio(music: screen?.music ?? document?.music, sounds: screen?.sounds ?? document?.sounds)
    }

    // MARK: Entries for a page

    nonisolated struct PageLayout: Sendable {
        var entries: [DiscMenuEntry]
        var pageCount: Int
        var page: Int
        var positioned: Bool
    }

    /// The buttons to draw on `page` of a screen, in drawing order, with their
    /// final positions (nil = the default column).
    static func entriesForPage(document: DiscMenuDocument, screen: DiscMenuScreenSpec, page requested: Int) -> PageLayout {
        let layout = effectiveLayout(document: document.layout, screen: screen.layout)
        guard let flow = layout.flow else {
            let positioned = !screen.entries.isEmpty && screen.entries.allSatisfy { $0.position != nil }
            return PageLayout(entries: screen.entries, pageCount: 1, page: 0, positioned: positioned)
        }
        let slots = max(1, flow.columns) * max(1, flow.rows)
        let pages = paginate(screen.entries, slots: slots, maxPerPage: screen.maxPerPage ?? 0)
        let page = max(0, min(requested, pages.count - 1))
        let current = pages[page]
        var nav = current.backs
        if current.prev {
            nav.append(DiscMenuEntry(action: DiscAction.pagePrev.rawValue, label: flow.previousLabel ?? "Previous"))
        }
        if current.more {
            nav.append(DiscMenuEntry(action: DiscAction.pageNext.rawValue, label: flow.moreLabel ?? "More"))
        }
        var placed: [DiscMenuEntry] = []
        for (index, var entry) in current.items.enumerated() {
            entry.position = cellPosition(flow, slot: index, tall: entry.isTall)
            placed.append(entry)
        }
        for (index, var entry) in nav.enumerated() {
            entry.position = cellPosition(flow, slot: slots - nav.count + index, tall: !(entry.image ?? "").isEmpty)
            placed.append(entry)
        }
        return PageLayout(entries: placed, pageCount: pages.count, page: page, positioned: true)
    }

    // MARK: Scene selection

    /// The grid used for a scene-selection screen when neither the styling
    /// screen nor the document declares a `Flow`.
    static func defaultChapterFlow(perPage: Int) -> DiscFlow {
        let slots = perPage + 3
        let columns: Int
        if perPage <= 3 {
            columns = max(1, perPage)
        } else if perPage <= 8 {
            columns = 3
        } else {
            columns = 4
        }
        let rows = Int((Double(slots) / Double(columns)).rounded(.up))
        return DiscFlow(region: DiscPosition(x: 50, y: 52, w: 86, h: 68, anchor: "center"), columns: columns, rows: rows)
    }

    // MARK: Focus

    /// Index of the button that takes focus when (dx, dy) is pressed on
    /// `current`, or `current` when nothing moves. Rectangles are the buttons'
    /// on-screen frames in drawing order.
    static func moveFocus(rects: [CGRect], current: Int, dx: Int, dy: Int) -> Int {
        guard rects.indices.contains(current) else { return current }
        let from = rects[current]
        var best: Int?
        var bestKey: (Int, Double)?
        var wrap: Int?
        var wrapKey: (Double, Double)?

        for (index, rect) in rects.enumerated() where index != current {
            let across = acrossDistance(from: from, to: rect, dx: dx)
            if let ahead = distanceAlong(from: from, to: rect, dx: dx, dy: dy) {
                let key: (Int, Double) = overlapsAcross(from: from, to: rect, dx: dx) ? (0, ahead) : (1, ahead + 2 * across)
                if let currentBest = bestKey {
                    if key.0 < currentBest.0 || (key.0 == currentBest.0 && key.1 < currentBest.1) {
                        best = index
                        bestKey = key
                    }
                } else {
                    best = index
                    bestKey = key
                }
                continue
            }
            guard let behind = distanceAlong(from: from, to: rect, dx: -dx, dy: -dy) else { continue }
            let far = -behind
            if let currentWrap = wrapKey {
                if far < currentWrap.0 - 20 || (far < currentWrap.0 + 20 && across < currentWrap.1) {
                    wrap = index
                    wrapKey = (far, across)
                }
            } else {
                wrap = index
                wrapKey = (far, across)
            }
        }
        return best ?? wrap ?? current
    }

    private static func distanceAlong(from: CGRect, to rect: CGRect, dx: Int, dy: Int) -> Double? {
        let tolerance = 0.25 * Double(dx != 0 ? from.width : from.height)
        let gap: Double
        if dx == 1 {
            gap = Double(rect.minX - from.maxX)
        } else if dx == -1 {
            gap = Double(from.minX - rect.maxX)
        } else if dy == 1 {
            gap = Double(rect.minY - from.maxY)
        } else {
            gap = Double(from.minY - rect.maxY)
        }
        if gap < -tolerance { return nil }
        let cx = Double(rect.midX - from.midX)
        let cy = Double(rect.midY - from.midY)
        return cx * Double(dx) + cy * Double(dy)
    }

    private static func overlapsAcross(from: CGRect, to rect: CGRect, dx: Int) -> Bool {
        if dx != 0 {
            return from.minY < rect.maxY && rect.minY < from.maxY
        }
        return from.minX < rect.maxX && rect.minX < from.maxX
    }

    private static func acrossDistance(from: CGRect, to rect: CGRect, dx: Int) -> Double {
        let cx = Double(rect.midX - from.midX)
        let cy = Double(rect.midY - from.midY)
        return abs(dx != 0 ? cy : cx)
    }

    // MARK: Time

    /// Chapter start time: h:mm:ss from one hour, otherwise m:ss (minutes not padded).
    static func formatTicks(_ ticks: Int64) -> String {
        let total = Int(max(0, ticks) / 10_000_000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let secondsText = String(format: "%02d", seconds)
        if hours > 0 {
            return "\(hours):" + String(format: "%02d", minutes) + ":" + secondsText
        }
        return "\(minutes):" + secondsText
    }

    // MARK: Untrusted data

    private static let segment = "[A-Za-z0-9][A-Za-z0-9._-]{0,63}"
    private static let https = "https://[^\\s\"'()<>\\\\]+"
    private static let assetReference = "asset:\(segment)(?:/\(segment)){0,3}"

    static let safeImagePattern = "^(?:\(https)|data:image/(?:png|jpeg|webp);base64,[A-Za-z0-9+/=]+|\(assetReference))$"
    static let safeAudioPattern = "^(?:\(https)|asset:\(segment)(?:/\(segment)){0,3}\\.(?:mp3|ogg|opus|m4a|wav))$"
    static let hexColorPattern = "^#[0-9a-fA-F]{6}$"
    static let tmdbPathPattern = "^/[A-Za-z0-9_-]+\\.(?:jpg|png)$"
    static let fanartIdPattern = "^[0-9]{1,12}$"
    static let itemIdPattern = "^[0-9a-fA-F-]{32,36}$"

    private static func matchesWhole(_ pattern: String, _ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [.anchored], range: range) else { return false }
        return match.range.location == 0 && match.range.length == range.length
    }

    static func isSafeImage(_ value: String?) -> Bool {
        guard let value else { return false }
        return matchesWhole(safeImagePattern, value)
    }

    static func isSafeAudio(_ value: String?) -> Bool {
        guard let value else { return false }
        return matchesWhole(safeAudioPattern, value)
    }

    static func isHexColor(_ value: String?) -> Bool {
        guard let value else { return false }
        return matchesWhole(hexColorPattern, value)
    }

    static func isTmdbPath(_ value: String?) -> Bool {
        guard let value else { return false }
        return matchesWhole(tmdbPathPattern, value)
    }

    static func isFanartId(_ value: String?) -> Bool {
        guard let value else { return false }
        return matchesWhole(fanartIdPattern, value)
    }

    static func isItemId(_ value: String?) -> Bool {
        guard let value else { return false }
        return matchesWhole(itemIdPattern, value)
    }

    /// Clamps a number into a range, treating non-finite values as the default.
    static func clamp(_ value: Double?, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
