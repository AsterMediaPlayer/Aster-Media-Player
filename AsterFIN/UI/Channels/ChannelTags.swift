//
//  ChannelTags.swift
//  AsterFIN
//
//  A Channel is set up with tags on its Jellyfin playlist, so the server is
//  the one place it lives: edit them in Jellyfin's web interface (the
//  playlist's Edit Metadata ▸ Tags) or in AsterFIN's Edit Channels, and
//  every device finds the same channels.
//
//    asterfin:channel         this playlist is a channel
//    asterfin:number=101      its channel number
//    asterfin:mode=blocks     rotation (the default), blocks, shuffle or sequential
//    asterfin:logo=on         the playlist's picture is the channel's logo
//    asterfin:reshuffle=week  a new order every day (the default), week or month
//    asterfin:seed=2          deals a fresh lineup; any other number, another
//    asterfin:blocks=3-6      episodes in a row in Blocks mode (2-4 by default)
//    asterfin:bug=on          the logo in the corner while the channel plays
//    asterfin:bug-location=…  which corner: top-left, top-right, bottom-left, bottom-right
//    asterfin:bug-size=150%   the bug's size, from 25% to 300% of the usual
//    asterfin:bug-hide=30     the bug fades after 30 seconds (off: it stays)
//    asterfin:genre=Horror    also plays every title in this genre; repeat
//                             (or Horror,Thriller) for more, any of them
//    asterfin:type=movies     with genres: all (the default), movies or shows
//    asterfin:library=…       with genres: only this library; repeat for more
//    asterfin:channel-name=…  the channel's name, in place of the playlist's
//
//  "asterfin:" and the keys and values are read whatever their case. A tag
//  that isn't understood is left alone, and a value that doesn't make sense
//  falls back to the default rather than stopping the channel playing.
//
//  The app writes every setting out, defaults too (all but the name), so
//  whoever opens the playlist in Jellyfin sees each one there to change.
//

import Foundation

nonisolated struct ChannelTags: Equatable, Sendable {
    static let prefix = "asterfin:"
    /// The keys this reads and writes; other `asterfin:` tags are kept as they are.
    private static let keys: Set<String> = ["channel", "number", "mode", "logo", "reshuffle", "seed", "blocks", "bug", "bug-location", "bug-size", "bug-hide", "genre", "type", "library", "channel-name"]

    var isChannel = false
    var number: Int?
    var mode: ChannelMode = .rotation
    var showsLogo = false
    var reshuffle: ChannelReshuffle = .day
    var seed = 0
    var blocks = ChannelLineup.defaultBlocks
    var showsBug = false
    var bugCorner: BugCorner = .bottomRight
    /// The bug's size, as a percentage of the usual.
    var bugSize = 100
    /// Seconds the bug shows after tuning in or a programme starting; 0 for
    /// always.
    var bugHideAfter = 0
    /// Genres whose titles the channel plays too, any of them; none for a
    /// channel of just its playlist.
    var genres: [String] = []
    /// What a genre channel takes from its genres.
    var content: ChannelContent = .all
    /// Libraries, by name, a genre channel takes from; none for every library.
    var libraries: [String] = []
    /// Nil for the playlist's own name.
    var name: String?

    /// The longest block `blocks=` can ask for.
    static let longestBlock = 20
    /// The sizes `bug-size=` can ask for, in percent.
    static let bugSizes = 25...300
    /// How long `bug-hide=` can keep the bug up, in seconds.
    static let bugHideTimes = 1...3600

    init(isChannel: Bool = false, number: Int? = nil, mode: ChannelMode = .rotation, showsLogo: Bool = false) {
        self.isChannel = isChannel
        self.number = number
        self.mode = mode
        self.showsLogo = showsLogo
    }

    /// How the channel's lineup is dealt.
    var lineup: ChannelLineup {
        ChannelLineup(mode: mode, reshuffle: reshuffle, seed: seed, blocks: blocks)
    }

    init(tags: [String]?) {
        for tag in tags ?? [] {
            guard let (key, value) = Self.parse(tag) else { continue }
            switch key {
            case "channel":
                isChannel = value.map { !Self.isOff($0) } ?? true
            case "number":
                if let value, let number = Int(value), number > 0 { self.number = number }
            case "mode":
                mode = value.flatMap { ChannelMode(rawValue: $0.lowercased()) } ?? .rotation
            case "logo":
                showsLogo = value.map { !Self.isOff($0) } ?? true
            case "reshuffle":
                reshuffle = value.flatMap { ChannelReshuffle(rawValue: $0.lowercased()) } ?? .day
            case "seed":
                seed = value.flatMap { Int($0) }.map { max($0, 0) } ?? 0
            case "blocks":
                blocks = value.flatMap(Self.blockRange) ?? ChannelLineup.defaultBlocks
            case "bug":
                showsBug = value.map { !Self.isOff($0) } ?? true
            case "bug-location":
                bugCorner = value.flatMap { BugCorner(rawValue: $0.lowercased()) } ?? .bottomRight
            case "bug-size":
                bugSize = value.flatMap(Self.percent).flatMap { Self.bugSizes.contains($0) ? $0 : nil } ?? 100
            case "bug-hide":
                bugHideAfter = value.flatMap(Self.seconds).flatMap { Self.bugHideTimes.contains($0) ? $0 : nil } ?? 0
            case "genre":
                Self.collect(value, into: &genres)
            case "type":
                content = value.flatMap { ChannelContent(rawValue: $0.lowercased()) } ?? .all
            case "library":
                Self.collect(value, into: &libraries)
            case "channel-name":
                name = value.flatMap { $0.isEmpty ? nil : $0 }
            default:
                break
            }
        }
    }

    /// `tags` with AsterFIN's own replaced by every one of these settings,
    /// defaults included; every other tag is kept, in its place. A playlist
    /// that stops being a channel is marked `channel=off` and keeps the
    /// rest, so turning it back on restores them.
    func applied(to tags: [String]?) -> [String] {
        var result = (tags ?? []).filter { tag in
            guard let (key, _) = Self.parse(tag) else { return true }
            return !Self.keys.contains(key)
        }
        let on = { (flag: Bool) in flag ? "on" : "off" }
        result.append(Self.prefix + (isChannel ? "channel" : "channel=off"))
        if let number { result.append(Self.prefix + "number=\(number)") }
        result.append(Self.prefix + "mode=\(mode.rawValue)")
        result.append(Self.prefix + "reshuffle=\(reshuffle.rawValue)")
        result.append(Self.prefix + (blocks.count == 1 ? "blocks=\(blocks.lowerBound)" : "blocks=\(blocks.lowerBound)-\(blocks.upperBound)"))
        result.append(Self.prefix + "seed=\(seed)")
        result.append(Self.prefix + "logo=\(on(showsLogo))")
        result.append(Self.prefix + "bug=\(on(showsBug))")
        result.append(Self.prefix + "bug-location=\(bugCorner.rawValue)")
        result.append(Self.prefix + "bug-size=\(bugSize)%")
        result.append(Self.prefix + (bugHideAfter > 0 ? "bug-hide=\(bugHideAfter)" : "bug-hide=off"))
        for genre in genres { result.append(Self.prefix + "genre=\(genre)") }
        result.append(Self.prefix + "type=\(content.rawValue)")
        for library in libraries { result.append(Self.prefix + "library=\(library)") }
        if let name { result.append(Self.prefix + "channel-name=\(name)") }
        return result
    }

    /// "Horror, Thriller" into the list, once each whatever the case.
    private static func collect(_ value: String?, into list: inout [String]) {
        for piece in (value ?? "").split(separator: ",") {
            let name = piece.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            list.append(name)
        }
    }

    /// Whether `tags` set `key` at all, as opposed to leaving it to its default.
    static func sets(_ key: String, in tags: [String]?) -> Bool {
        (tags ?? []).contains { parse($0)?.key == key }
    }

    /// "30", "30s" → 30; nil for "off" or anything else.
    private static func seconds(_ value: String) -> Int? {
        Int(value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "s ")))
    }

    /// "150%" or "150" → 150.
    private static func percent(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    /// "3-6" → 3...6, "4" → 4...4; nil unless it's 1 to `longestBlock`, low to high.
    private static func blockRange(_ value: String) -> ClosedRange<Int>? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), let low = parts.first ?? nil, let high = parts.last ?? nil,
              1 <= low, low <= high, high <= longestBlock else { return nil }
        return low...high
    }

    /// "asterfin:Number=101" → ("number", "101"); nil for a tag that isn't AsterFIN's.
    private static func parse(_ tag: String) -> (key: String, value: String?)? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let body = trimmed.dropFirst(prefix.count)
        let parts = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.first?.lowercased(), !key.isEmpty else { return nil }
        let value = parts.count > 1 ? parts[1] : nil
        return (key, value)
    }

    private static func isOff(_ value: String) -> Bool {
        ["off", "no", "false", "0"].contains(value.lowercased())
    }

    // MARK: Numbering

    /// Channel numbers for a set of channels: their own where they have one,
    /// then the rest after the highest of those, in name order. Two channels
    /// asking for the same number both keep it (Edit Channels points it out).
    static func numbers(for channels: [(id: String, name: String, number: Int?)]) -> [String: Int] {
        var result: [String: Int] = [:]
        var next = (channels.compactMap(\.number).max() ?? 0) + 1
        for channel in channels {
            if let number = channel.number { result[channel.id] = number }
        }
        let unnumbered = channels.filter { $0.number == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for channel in unnumbered {
            result[channel.id] = next
            next += 1
        }
        return result
    }
}

/// What a genre channel takes from its genres.
nonisolated enum ChannelContent: String, CaseIterable, Identifiable, Sendable {
    case all, movies, shows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Movies & Shows"
        case .movies: "Movies"
        case .shows: "Shows"
        }
    }

    /// The item types to ask the server for.
    var itemTypes: String {
        switch self {
        case .all: "Movie,Episode"
        case .movies: "Movie"
        case .shows: "Episode"
        }
    }
}

/// Which corner of the picture a channel's bug sits in.
nonisolated enum BugCorner: String, CaseIterable, Identifiable, Sendable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

extension ChannelTags {
    /// A copy with `change` made, for editing one setting at a time.
    func with(_ change: (inout ChannelTags) -> Void) -> ChannelTags {
        var copy = self
        change(&copy)
        return copy
    }
}
