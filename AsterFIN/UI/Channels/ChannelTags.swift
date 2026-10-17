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
//    asterfin:bug-opacity=60% how solid the bug is, 5% to 100% (45% by default)
//    asterfin:genre=Horror    also plays every title in this genre; repeat
//                             (or Horror,Thriller) for more, any of them
//    asterfin:type=movies     with genres: all (the default), movies or shows
//    asterfin:library=…       with genres or networks: only this library; repeat
//    asterfin:network=…       also plays every title from this studio/network; repeat
//    asterfin:collection=…    also plays every title in this collection; repeat
//    asterfin:years=1985-1999 with sources: only titles from these years
//    asterfin:rating=G,PG     with sources: only titles with these ratings
//    asterfin:weight=Friends:2 a show takes turns this many times as often (1-5)
//    asterfin:min-length=15   leaves out titles shorter than this, in minutes
//    asterfin:max-length=120  leaves out titles longer than this, in minutes
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
    private static let keys: Set<String> = ["channel", "number", "mode", "logo", "reshuffle", "seed", "blocks", "bug", "bug-location", "bug-size", "bug-hide", "bug-opacity", "genre", "type", "library", "network", "collection", "years", "rating", "weight", "min-length", "max-length", "channel-name"]

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
    /// How solid the bug is, in percent.
    var bugOpacity = ChannelTags.defaultBugOpacity
    /// Genres whose titles the channel plays too, any of them; none for a
    /// channel of just its playlist.
    var genres: [String] = []
    /// What a genre channel takes from its genres.
    var content: ChannelContent = .all
    /// Libraries, by name, a genre channel takes from; none for every library.
    var libraries: [String] = []
    /// Studios or networks, and collections, whose titles the channel plays
    /// too, by name.
    var networks: [String] = []
    var collections: [String] = []
    /// With sources: only titles from these years, with these ratings.
    var years: ClosedRange<Int>?
    var ratings: [String] = []
    /// Shows that take more turns, by name: "Friends" 2 plays twice as often.
    var weights: [ShowWeight] = []
    /// Titles shorter or longer than these, in minutes, are left out.
    var minLength: Int?
    var maxLength: Int?

    /// Whether the channel fills itself from genres, networks or collections.
    var hasSources: Bool { !genres.isEmpty || !networks.isEmpty || !collections.isEmpty }

    nonisolated struct ShowWeight: Equatable, Hashable, Sendable {
        let show: String
        let weight: Int
    }

    /// The most turns `weight=` can give a show.
    static let heaviestWeight = 5
    /// The lengths `min-length=` and `max-length=` can ask for, in minutes.
    static let lengths = 1...600
    /// Nil for the playlist's own name.
    var name: String?

    /// The longest block `blocks=` can ask for.
    static let longestBlock = 20
    /// The sizes `bug-size=` can ask for, in percent.
    static let bugSizes = 25...300
    /// The bug's opacity unless `bug-opacity=` says otherwise, and its range.
    static let defaultBugOpacity = 45
    static let bugOpacities = 5...100
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
        ChannelLineup(
            mode: mode, reshuffle: reshuffle, seed: seed, blocks: blocks,
            weights: Dictionary(weights.map { ($0.show.lowercased(), $0.weight) }) { first, _ in first },
            minLength: minLength.map { TimeInterval($0) * 60 },
            maxLength: maxLength.map { TimeInterval($0) * 60 }
        )
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
            case "bug-opacity":
                bugOpacity = value.flatMap(Self.percent).flatMap { Self.bugOpacities.contains($0) ? $0 : nil } ?? Self.defaultBugOpacity
            case "bug-hide":
                bugHideAfter = value.flatMap(Self.seconds).flatMap { Self.bugHideTimes.contains($0) ? $0 : nil } ?? 0
            case "genre":
                Self.collect(value, into: &genres)
            case "type":
                content = value.flatMap { ChannelContent(rawValue: $0.lowercased()) } ?? .all
            case "library":
                Self.collect(value, into: &libraries)
            case "network":
                // Studio names can have commas: one per tag.
                Self.collect(value, into: &networks, splitting: false)
            case "collection":
                Self.collect(value, into: &collections, splitting: false)
            case "years":
                years = value.flatMap(Self.yearRange)
            case "rating":
                Self.collect(value, into: &ratings)
            case "weight":
                if let weight = value.flatMap(Self.showWeight) {
                    weights.removeAll { $0.show.caseInsensitiveCompare(weight.show) == .orderedSame }
                    weights.append(weight)
                }
            case "min-length":
                minLength = value.flatMap { Int($0) }.flatMap { Self.lengths.contains($0) ? $0 : nil }
            case "max-length":
                maxLength = value.flatMap { Int($0) }.flatMap { Self.lengths.contains($0) ? $0 : nil }
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
        result.append(Self.prefix + "bug-opacity=\(bugOpacity)%")
        for genre in genres { result.append(Self.prefix + "genre=\(genre)") }
        result.append(Self.prefix + "type=\(content.rawValue)")
        for library in libraries { result.append(Self.prefix + "library=\(library)") }
        for network in networks { result.append(Self.prefix + "network=\(network)") }
        for collection in collections { result.append(Self.prefix + "collection=\(collection)") }
        if let years { result.append(Self.prefix + (years.count == 1 ? "years=\(years.lowerBound)" : "years=\(years.lowerBound)-\(years.upperBound)")) }
        for rating in ratings { result.append(Self.prefix + "rating=\(rating)") }
        for weight in weights { result.append(Self.prefix + "weight=\(weight.show):\(weight.weight)") }
        if let minLength { result.append(Self.prefix + "min-length=\(minLength)") }
        if let maxLength { result.append(Self.prefix + "max-length=\(maxLength)") }
        if let name { result.append(Self.prefix + "channel-name=\(name)") }
        return result
    }

    /// "1985-1999" → 1985...1999 (either way round), "1994" → 1994...1994;
    /// nil unless sensible.
    private static func yearRange(_ value: String) -> ClosedRange<Int>? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), let first = parts.first ?? nil, let last = parts.last ?? nil else { return nil }
        let low = min(first, last), high = max(first, last)
        guard 1880 <= low, high <= 2200 else { return nil }
        return low...high
    }

    /// "Friends:2" → Friends, 2; nil unless the show is named and the weight
    /// at least 1. A weight over 5 counts as 5.
    private static func showWeight(_ value: String) -> ShowWeight? {
        guard let colon = value.lastIndex(of: ":") else { return nil }
        let show = value[..<colon].trimmingCharacters(in: .whitespaces)
        guard !show.isEmpty, let weight = Int(value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)),
              weight >= 1 else { return nil }
        return ShowWeight(show: show, weight: min(weight, heaviestWeight))
    }

    /// "Horror, Thriller" into the list, once each whatever the case; with
    /// `splitting` off, the whole value is one name.
    private static func collect(_ value: String?, into list: inout [String], splitting: Bool = true) {
        let pieces = splitting ? (value ?? "").split(separator: ",").map(String.init) : [value ?? ""]
        for piece in pieces {
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

    /// The item types to ask the server for: movies, and series (whose
    /// episodes are fetched by series, as networks and ratings are set on
    /// the series, not each episode).
    var itemTypes: String {
        switch self {
        case .all: "Movie,Series"
        case .movies: "Movie"
        case .shows: "Series"
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
