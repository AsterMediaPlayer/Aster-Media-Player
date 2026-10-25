//
//  ScrubPreview.swift
//  AsterFIN
//
//  The picture shown above the timeline while scrubbing. Jellyfin's
//  trickplay images when the server has made them (sheets of small frames,
//  one every few seconds, for the whole title), else a still the engine
//  cuts from what it has already downloaded, else just the time.
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

/// Fetches and cuts preview frames for one title, keeping the sheets it
/// has fetched so dragging along the timeline doesn't fetch them again.
final class ScrubPreviewSource {
    static let previewWidth = 320

    private let client: any MediaServer
    private let itemId: String
    private let mediaSourceId: String
    private let info: TrickplayInfo
    private var sheets: [Int: CGImage] = [:]
    private var loading: [Int: Task<CGImage?, Never>] = [:]

    /// Nil when the item has no trickplay images for this file.
    init?(client: any MediaServer, item: BaseItem, mediaSourceId: String?) {
        guard let trickplay = item.trickplay, !trickplay.isEmpty else { return nil }
        let sourceId = mediaSourceId.flatMap { trickplay[$0] != nil ? $0 : nil } ?? trickplay.keys.sorted().first
        guard let sourceId, let resolutions = trickplay[sourceId], let info = TrickplayInfo.best(in: resolutions, near: Self.previewWidth) else { return nil }
        self.client = client
        self.itemId = item.id
        self.mediaSourceId = sourceId
        self.info = info
    }

    func frame(at seconds: Double) async -> CGImage? {
        guard let cell = info.cell(at: seconds), let sheet = await sheet(cell.sheet) else { return nil }
        return sheet.cropping(to: info.rect(of: cell))
    }

    private func sheet(_ index: Int) async -> CGImage? {
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
