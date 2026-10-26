//
//  MatroskaFonts.swift
//  AsterFIN
//
//  The fonts an MKV carries for its styled subtitles, read straight from
//  the file: Plex hands out neither a file's attachments nor its embedded
//  subtitle tracks, so the fonts libass needs come from the file itself.
//  Only the file's index and its attachments are fetched (a few ranged
//  requests near the start), never the video.
//

import Foundation

nonisolated enum MatroskaFonts {
    struct Font: Sendable, Equatable {
        var name: String
        var data: Data
    }

    // Matroska element ids, marker bits kept.
    private static let ebmlHeader: UInt32 = 0x1A45_DFA3
    private static let segment: UInt32 = 0x1853_8067
    private static let seekHead: UInt32 = 0x114D_9B74
    private static let seek: UInt32 = 0x4DBB
    private static let seekID: UInt32 = 0x53AB
    private static let seekPosition: UInt32 = 0x53AC
    private static let attachments: UInt32 = 0x1941_A469
    private static let attachedFile: UInt32 = 0x61A7
    private static let fileName: UInt32 = 0x466E
    private static let fileMimeType: UInt32 = 0x4660
    private static let fileData: UInt32 = 0x465C
    private static let cluster: UInt32 = 0x1F43_B675

    /// The fonts attached to the MKV at `url`; empty when it has none or
    /// can't be read.
    static func fonts(at url: URL, session: URLSession = .shared) async -> [Font] {
        do {
            let head = try await range(url, 0, 256 * 1024, session: session)
            var found = try attachmentsPosition(in: head)
            if found == nil { found = await scanForAttachments(url, head: head, session: session) }
            guard let position = found else { return [] }
            // The element's own header, then all of it.
            let header = try await range(url, position, 16, session: session)
            var cursor = 0
            guard let (id, size) = elementHeader(header, &cursor), id == attachments, let size, size < 200 * 1024 * 1024 else { return [] }
            let body = try await range(url, position + cursor, Int(size), session: session)
            return parseAttachments(body)
        } catch {
            #if DEBUG
            print("DEBUG subtitles: couldn't read the file's fonts: \(error)")
            #endif
            return []
        }
    }

    /// The fonts among an Attachments element's files.
    static func parseAttachments(_ body: Data) -> [Font] {
        var fonts: [Font] = []
        forEachChild(of: body) { id, child in
            guard id == attachedFile else { return }
            var name: String?
            var mime = ""
            var data: Data?
            forEachChild(of: child) { id, value in
                switch id {
                case fileName: name = String(decoding: value, as: UTF8.self)
                case fileMimeType: mime = String(decoding: value, as: UTF8.self).lowercased()
                case fileData: data = value
                default: break
                }
            }
            guard let name, let data, isFont(name: name, mime: mime) else { return }
            fonts.append(Font(name: name, data: data))
        }
        return fonts
    }

    static func isFont(name: String, mime: String) -> Bool {
        let fontTypes = ["font/", "application/x-truetype-font", "application/vnd.ms-opentype", "application/x-font"]
        if fontTypes.contains(where: mime.hasPrefix) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["ttf", "otf", "ttc", "otc"].contains(ext)
    }

    // MARK: Finding the attachments

    /// Where the Attachments element starts, from the segment's SeekHead.
    static func attachmentsPosition(in head: Data) throws -> Int? {
        var cursor = 0
        guard let (first, firstSize) = elementHeader(head, &cursor), first == ebmlHeader, let firstSize else { return nil }
        cursor += Int(firstSize)
        guard let (id, _) = elementHeader(head, &cursor), id == segment else { return nil }
        let segmentStart = cursor
        // The SeekHead is the segment's first child in files muxers write.
        while cursor < head.count {
            guard let (child, size) = elementHeader(head, &cursor), let size else { return nil }
            if child == seekHead {
                let end = min(head.count, cursor + Int(size))
                guard end > cursor else { return nil }
                var found: Int?
                forEachChild(of: head.subdata(in: cursor..<end)) { id, entry in
                    guard id == seek else { return }
                    var target: UInt32?
                    var position: UInt64?
                    forEachChild(of: entry) { id, value in
                        if id == seekID { target = UInt32(truncatingIfNeeded: unsigned(value)) }
                        if id == seekPosition { position = unsigned(value) }
                    }
                    if target == attachments, let position { found = segmentStart + Int(position) }
                }
                return found
            }
            if child == cluster { return nil }
            cursor += Int(size)
        }
        return nil
    }

    /// Without a SeekHead entry: the segment's top-level elements walked
    /// one header at a time until the attachments, or the first cluster.
    private static func scanForAttachments(_ url: URL, head: Data, session: URLSession) async -> Int? {
        var cursor = 0
        guard let (first, firstSize) = elementHeader(head, &cursor), first == ebmlHeader, let firstSize else { return nil }
        cursor += Int(firstSize)
        guard let (id, _) = elementHeader(head, &cursor), id == segment else { return nil }
        var position = cursor
        for _ in 0..<64 {
            guard let header = try? await range(url, position, 16, session: session) else { return nil }
            var local = 0
            guard let (child, size) = elementHeader(header, &local), let size else { return nil }
            if child == attachments { return position }
            if child == cluster { return nil }
            position += local + Int(size)
        }
        return nil
    }

    // MARK: EBML

    /// Reads an element's id and size at `cursor`, moving past them. A nil
    /// size is "unknown" (all ones), which only clusters and segments use.
    static func elementHeader(_ data: Data, _ cursor: inout Int) -> (UInt32, UInt64?)? {
        guard let (idValue, idLength) = vint(data, cursor, keepMarker: true), idLength <= 4 else { return nil }
        guard let (sizeValue, sizeLength) = vint(data, cursor + idLength, keepMarker: false) else { return nil }
        cursor += idLength + sizeLength
        let allOnes = sizeLength < 8 ? (UInt64(1) << (7 * UInt64(sizeLength))) - 1 : UInt64.max >> 8
        return (UInt32(truncatingIfNeeded: idValue), sizeValue == allOnes ? nil : sizeValue)
    }

    private static func vint(_ data: Data, _ offset: Int, keepMarker: Bool) -> (UInt64, Int)? {
        guard offset < data.count else { return nil }
        let first = data[data.startIndex + offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard offset + length <= data.count else { return nil }
        var value = UInt64(keepMarker ? first : first & (0xFF >> length))
        for index in 1..<length {
            value = value << 8 | UInt64(data[data.startIndex + offset + index])
        }
        return (value, length)
    }

    private static func unsigned(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Calls `body` with each child element (id and contents) of `data`.
    private static func forEachChild(of data: Data, _ body: (UInt32, Data) -> Void) {
        let data = Data(data)
        var cursor = 0
        while cursor < data.count {
            guard let (id, size) = elementHeader(data, &cursor), let size else { return }
            let end = cursor + Int(size)
            guard end <= data.count else { return }
            body(id, data.subdata(in: cursor..<end))
            cursor = end
        }
    }

    // MARK: Fetching

    private static func range(_ url: URL, _ start: Int, _ length: Int, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        // A server that ignores Range sends the whole file from the start.
        if (response as? HTTPURLResponse)?.statusCode == 200, start > 0 {
            return data.count > start ? data.subdata(in: start..<min(data.count, start + length)) : Data()
        }
        return data
    }
}
