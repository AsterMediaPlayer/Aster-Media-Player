//
//  ChannelTags.swift
//  AsterFIN
//
//  A Channel is set up with tags on its Jellyfin playlist, so the server is
//  the one place it lives: edit them in Jellyfin's web interface (the
//  playlist's Edit Metadata ▸ Tags) or in Aster's Edit Channels, and
//  every device finds the same channels.
//
//    aster:channel          this playlist is a channel
//    aster:number=101       its channel number
//    aster:mode=blocks      rotation (the default), blocks, shuffle or sequential
//    aster:logo=on          the playlist's picture is the channel's logo
//    aster:reshuffle=week   a new order every day (the default), week or month
//    aster:seed=2           deals a fresh lineup; any other number, another
//    aster:blocks=3-6       episodes in a row in Blocks mode (2-4 by default)
//    aster:bug=on           the logo in the corner while the channel plays
//    aster:bug-location=…   which corner: top-left, top-right, bottom-left, bottom-right
//    aster:bug-size=150%    the bug's size, from 25% to 300% of the usual
//    aster:bug-hide=30      the bug fades after 30 seconds (off: it stays)
//    aster:channel-name=…   the channel's name, in place of the playlist's
//
//  "aster:" and the keys and values are read whatever their case (and so
//  is "asterfin:", the app's earlier name, which `converted` rewrites). A tag
//  that isn't understood is left alone, and a value that doesn't make sense
//  falls back to the default rather than stopping the channel playing.
//
//  The app writes every setting out, defaults too (all but the name), so
//  whoever opens the playlist in Jellyfin sees each one there to change.
//

import Foundation

nonisolated struct ChannelTags: Equatable, Sendable {
    static let prefix = "aster:"
    /// What the tags began with when the app was called AsterFIN; still read,
    /// and rewritten with `converted`.
    static let oldPrefix = "asterfin:"
    /// The keys this reads and writes; other `aster:` tags are kept as they are.
    private static let keys: Set<String> = ["channel", "number", "mode", "logo", "reshuffle", "seed", "blocks", "bug", "bug-location", "bug-size", "bug-hide", "channel-name"]

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
            case "channel-name":
                name = value.flatMap { $0.isEmpty ? nil : $0 }
            default:
                break
            }
        }
    }

    /// `tags` with Aster's own replaced by every one of these settings,
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
        if let name { result.append(Self.prefix + "channel-name=\(name)") }
        return result
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

    /// "aster:Number=101" (or "asterfin:Number=101") → ("number", "101");
    /// nil for a tag that isn't Aster's.
    private static func parse(_ tag: String) -> (key: String, value: String?)? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard let start = [prefix, oldPrefix].first(where: { trimmed.lowercased().hasPrefix($0) }) else { return nil }
        let body = trimmed.dropFirst(start.count)
        let parts = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.first?.lowercased(), !key.isEmpty else { return nil }
        let value = parts.count > 1 ? parts[1] : nil
        return (key, value)
    }

    /// `tags` with every "asterfin:" tag renamed "aster:", the rest as they
    /// are; nil when there's none to rename.
    static func converted(_ tags: [String]?) -> [String]? {
        guard let tags else { return nil }
        var changed = false
        let renamed = tags.map { tag -> String in
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(oldPrefix) else { return tag }
            changed = true
            return prefix + trimmed.dropFirst(oldPrefix.count)
        }
        return changed ? renamed : nil
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
