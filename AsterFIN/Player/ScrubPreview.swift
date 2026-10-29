//
//  ScrubPreview.swift
//  AsterFIN
//
//  The picture shown above the timeline while scrubbing. Jellyfin's
//  trickplay images when the server has made them (sheets of small frames,
//  one every few seconds, for the whole title), or Emby's BIF thumbnails,
//  else a still the engine cuts from what it has already downloaded, else
//  just the time.
//

import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One resolution of a title's trickplay images, as Jellyfin lists them.
nonisolated struct TrickplayInfo: Codable, Sendable, Hashable {
    /// Each frame's size in pixels.
    var width: Int
    var height: Int
    /// Frames across and down one sheet.
    var tileWidth: Int
    var tileHeight: Int
    var thumbnailCount: Int
    /// Milliseconds between frames.
    var interval: Int

    enum CodingKeys: String, CodingKey {
        case width = "Width"
        case height = "Height"
        case tileWidth = "TileWidth"
        case tileHeight = "TileHeight"
        case thumbnailCount = "ThumbnailCount"
        case interval = "Interval"
    }

    /// Where the frame for `seconds` is: which sheet, and its cell there.
    struct Cell: Equatable {
        var sheet: Int
        var column: Int
        var row: Int
    }

    func cell(at seconds: Double) -> Cell? {
        guard interval > 0, tileWidth > 0, tileHeight > 0, thumbnailCount > 0, seconds.isFinite else { return nil }
        let frame = min(max(Int(seconds * 1000) / interval, 0), thumbnailCount - 1)
        let perSheet = tileWidth * tileHeight
        let inSheet = frame % perSheet
        return Cell(sheet: frame / perSheet, column: inSheet % tileWidth, row: inSheet / tileWidth)
    }

    /// The cell's rectangle in its sheet, in pixels.
    func rect(of cell: Cell) -> CGRect {
        CGRect(x: cell.column * width, y: cell.row * height, width: width, height: height)
    }

    /// The resolution closest to `width` among a source's, for a preview
    /// that size.
    static func best(in resolutions: [String: TrickplayInfo], near width: Int) -> TrickplayInfo? {
        resolutions.values.min { abs($0.width - width) < abs($1.width - width) }
    }
}

/// Emby's preview frames: one BIF file per title, an index of times and
/// offsets followed by the JPEG frames themselves (Roku's format), made when
/// the library has thumbnail extraction turned on.
nonisolated struct BIFIndex: Sendable, Equatable {
    /// Each frame's start in seconds, with its bytes in the file.
    var frames: [(seconds: Double, range: Range<Int>)]

    static func == (lhs: BIFIndex, rhs: BIFIndex) -> Bool {
        lhs.frames.elementsEqual(rhs.frames) { $0.seconds == $1.seconds && $0.range == $1.range }
    }

    private static let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Nil when `data` isn't a BIF file.
    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 64, Array(bytes[0..<8]) == Self.magic else { return nil }
        func word(_ at: Int) -> UInt32? {
            guard at + 4 <= bytes.count else { return nil }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard let count = word(12), let multiplier = word(16) else { return nil }
        // Milliseconds per timestamp unit; 0 means 1000.
        let unit = Double(multiplier == 0 ? 1000 : multiplier) / 1000
        // The index: a time and an offset per frame, then an end entry whose
        // offset is where the last frame stops.
        var entries: [(time: UInt32, offset: Int)] = []
        for index in 0...Int(count) {
            guard let time = word(64 + index * 8), let offset = word(68 + index * 8) else { return nil }
            entries.append((time, Int(offset)))
        }
        var frames: [(seconds: Double, range: Range<Int>)] = []
        for (entry, next) in zip(entries, entries.dropFirst()) where entry.time != .max {
            guard entry.offset < next.offset, next.offset <= bytes.count else { return nil }
            frames.append((Double(entry.time) * unit, entry.offset..<next.offset))
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
    }

    /// The frame shown at `seconds`: the last one starting at or before it.
    func range(at seconds: Double) -> Range<Int>? {
        guard seconds.isFinite else { return nil }
        let after = frames.firstIndex { $0.seconds > seconds } ?? frames.endIndex
        return frames[max(after - 1, 0)].range
    }
}

/// Fetches and cuts preview frames for one title, keeping the sheets it
/// has fetched so dragging along the timeline doesn't fetch them again.
final class ScrubPreviewSource {
    static let previewWidth = 320

    private enum Frames {
        /// Jellyfin's sheets of frames.
        case sheets(TrickplayInfo, mediaSourceId: String)
        /// Emby's BIF file, fetched whole on first use.
        case bif(URL)
    }

    private let client: any MediaServer
    private let itemId: String
    private let frames: Frames
    private var sheets: [Int: CGImage] = [:]
    private var loading: [Int: Task<CGImage?, Never>] = [:]
    private var bif: Task<(BIFIndex, Data)?, Never>?

    /// Nil when the item has no trickplay images for this file.
    init?(client: any MediaServer, item: BaseItem, mediaSourceId: String?) {
        self.client = client
        self.itemId = item.id
        if let emby = client as? JellyfinClient, emby.kind == .emby {
            // Emby lists no trickplay; whether it has a BIF shows on fetching it.
            frames = .bif(emby.thumbnailsURL(itemId: item.id, mediaSourceId: mediaSourceId, width: Self.previewWidth))
            return
        }
        guard let trickplay = item.trickplay, !trickplay.isEmpty else { return nil }
        let sourceId = mediaSourceId.flatMap { trickplay[$0] != nil ? $0 : nil } ?? trickplay.keys.sorted().first
        guard let sourceId, let resolutions = trickplay[sourceId], let info = TrickplayInfo.best(in: resolutions, near: Self.previewWidth) else { return nil }
        frames = .sheets(info, mediaSourceId: sourceId)
    }

    func frame(at seconds: Double) async -> CGImage? {
        switch frames {
        case .sheets(let info, let mediaSourceId):
            guard let cell = info.cell(at: seconds), let sheet = await sheet(cell.sheet, info: info, mediaSourceId: mediaSourceId) else { return nil }
            return sheet.cropping(to: info.rect(of: cell))
        case .bif(let url):
            guard let (index, data) = await bifFile(url), let range = index.range(at: seconds) else { return nil }
            return PlatformImage(data: data.subdata(in: range))?.platformCGImage
        }
    }

    private func bifFile(_ url: URL) async -> (BIFIndex, Data)? {
        if let bif { return await bif.value }
        let client = client
        let task = Task<(BIFIndex, Data)?, Never> {
            guard let data = try? await client.data(from: url), let index = BIFIndex(data) else { return nil }
            return (index, data)
        }
        bif = task
        return await task.value
    }

    private func sheet(_ index: Int, info: TrickplayInfo, mediaSourceId: String) async -> CGImage? {
        if let sheet = sheets[index] { return sheet }
        if let task = loading[index] { return await task.value }
        let url = client.trickplayTileURL(itemId: itemId, width: info.width, index: index, mediaSourceId: mediaSourceId)
        let client = client
        let task = Task<CGImage?, Never> {
            guard let data = try? await client.data(from: url) else { return nil }
            return PlatformImage(data: data)?.platformCGImage
        }
        loading[index] = task
        let sheet = await task.value
        loading[index] = nil
        if let sheet { sheets[index] = sheet }
        return sheet
    }
}
