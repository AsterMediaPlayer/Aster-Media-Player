//
//  ChannelTags.swift
//  AsterFIN
//
//  A Channel is set up with tags on its Jellyfin playlist, so the server is
//  the one place it lives: edit them in Jellyfin's web interface (the
//  playlist's Edit Metadata ▸ Tags) or in Aster's Edit Channels, and
//  every device finds the same channels.
//
//    aster:channel            this playlist is a channel
//    aster:number=101         its channel number
//    aster:mode=blocks        rotation (the default), blocks, shuffle or sequential
//    aster:logo=on            the playlist's picture is the channel's logo
//    aster:reshuffle=week     a new order every day (the default), week or month
//    aster:seed=2             deals a fresh lineup; any other number, another
//    aster:blocks=3-6         episodes in a row in Blocks mode (2-4 by default)
//    aster:bug=on             the logo in the corner while the channel plays
//    aster:bug-location=…     which corner: top-left, top-right, bottom-left, bottom-right
//    aster:bug-size=150%      the bug's size, from 25% to 300% of the usual
//    aster:bug-hide=30        the bug fades after 30 seconds (off: it stays)
//    aster:bug-opacity=60%    how solid the bug is, 5% to 100% (45% by default)
//    aster:genre=Horror       also plays every title in this genre; repeat
//                             (or Horror,Thriller) for more, any of them
//    aster:type=movies        with genres: all (the default), movies or shows
//    aster:library=…          with genres or networks: only this library; repeat
//    aster:network=…          also plays every title from this studio/network; repeat
//    aster:collection=…       also plays every title in this collection; repeat
//    aster:years=1985-1999    with sources: only titles from these years
//    aster:rating=G,PG        with sources: only titles with these ratings
//    aster:weight=Friends:2   a show takes turns this many times as often (1-5)
//    aster:min-length=15      leaves out titles shorter than this, in minutes
//    aster:max-length=120     leaves out titles longer than this, in minutes
//    aster:filler-playlists=… a filler playlist for the breaks; repeat for more
//    aster:filler-types=…     the kinds of clip to play: bumpers, promos,
//                             commercials, trailers, interstitials (all, the default)
//    aster:bumpers-at=both    a bumper opens and closes each break (or out, in)
//    aster:break-length=2     minutes of commercials in each break, 0 to 30
//    aster:promo-count=1      promos in each break, 0 to 5
//    aster:trailer-count=1    trailers in each break, 0 to 5
//    aster:interstitial-count=1 interstitials in each break without align, 0 to 5
//    aster:break-every=1      a break after every programme, or every 2nd to 10th
//    aster:align=30           programmes start on the half hour (or 5, 10, 15, 20,
//                             60 minutes), each break filling the gap; off by default
//    aster:align-fit=best     lined up, the gap filled with whole clips of every
//                             kind, as near the mark as they get (or exact: cut the
//                             last one short to land on it)
//    aster:filler             on a playlist: it's a filler playlist, of break clips
//    aster:commercial         on a clip in one: what it is (or promo, trailer,
//                             interstitial, bumper; bumper=in only closes a break,
//                             bumper=out only opens one); untagged clips aren't played
//    aster:user=peppy,jd      only these users get the channel (by Jellyfin user
//                             name; everyone without the tag); repeat for more
//    aster:channel-name=…     the channel's name, in place of the playlist's
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
    private static let keys: Set<String> = ["channel", "number", "mode", "logo", "reshuffle", "seed", "blocks", "bug", "bug-location", "bug-size", "bug-hide", "bug-opacity", "genre", "type", "library", "network", "collection", "years", "rating", "weight", "min-length", "max-length", "filler-playlists", "filler-types", "bumpers-at", "promo-count", "trailer-count", "interstitial-count", "break-length", "break-every", "align", "align-fit", "user", "channel-name"]

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

    /// Playlists, by name, of the clips the breaks between programmes play;
    /// each clip's own tag says what it is (`clipKind`), so one playlist can
    /// serve many channels.
    var fillerPlaylists: [String] = []
    /// The kinds of clip the breaks play from them: all four unless it says.
    var fillerTypes = Set(BreakKind.allCases)
    /// How each break is made up, and how often one comes.
    var breaks = ChannelBreaks()

    /// Whether the channel has breaks between its programmes.
    var hasBreaks: Bool { !fillerPlaylists.isEmpty && !fillerTypes.isEmpty }

    /// The most promos `promo-count=` (or interstitials
    /// `interstitial-count=`) can ask for; the longest break
    /// `break-length=` can ask for, in minutes; the most programmes
    /// `break-every=` can go between breaks.
    static let mostPromos = 5
    static let longestBreak = 30
    static let longestBreakGap = 10
    /// The marks `align=` can line programmes up on, in minutes.
    static let alignments = [5, 10, 15, 20, 30, 60]

    nonisolated struct ShowWeight: Equatable, Hashable, Sendable {
        let show: String
        let weight: Int
    }

    /// The most turns `weight=` can give a show.
    static let heaviestWeight = 5
    /// The lengths `min-length=` and `max-length=` can ask for, in minutes.
    static let lengths = 1...600
    /// The users, by Jellyfin user name, who get the channel; none for
    /// everyone. It hides the channel in Aster, nothing more: whoever the
    /// playlist is shared with can still open it in Jellyfin.
    var users: [String] = []

    /// Whether `userName` gets the channel: everyone does unless it names users.
    func isShown(to userName: String?) -> Bool {
        guard !users.isEmpty else { return true }
        guard let userName else { return false }
        return users.contains { $0.caseInsensitiveCompare(userName) == .orderedSame }
    }

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
            maxLength: maxLength.map { TimeInterval($0) * 60 },
            breaks: breaks
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
            case "filler-playlists", "filler-playlist":
                Self.collect(value, into: &fillerPlaylists, splitting: false)
            case "filler-types", "filler-type":
                // Kinds it doesn't know are ignored; none it does (or "all")
                // means all, including any added later.
                let kinds = Set((value ?? "").split(separator: ",").compactMap { Self.kind($0.trimmingCharacters(in: .whitespaces)) })
                fillerTypes = kinds.isEmpty ? Set(BreakKind.allCases) : kinds
            case "bumpers-at":
                breaks.bumpersAt = value.flatMap { BumperPlacement(rawValue: $0.lowercased()) } ?? .both
            case "promo-count":
                breaks.promoCount = value.flatMap { Int($0) }.flatMap { (0...Self.mostPromos).contains($0) ? $0 : nil } ?? 1
            case "trailer-count":
                breaks.trailerCount = value.flatMap { Int($0) }.flatMap { (0...Self.mostPromos).contains($0) ? $0 : nil } ?? 1
            case "interstitial-count":
                breaks.interstitialCount = value.flatMap { Int($0) }.flatMap { (0...Self.mostPromos).contains($0) ? $0 : nil } ?? 1
            case "break-length":
                breaks.minutes = value.flatMap(Self.minutes).flatMap { (0...Self.longestBreak).contains($0) ? $0 : nil } ?? ChannelBreaks.defaultMinutes
            case "break-every":
                breaks.every = value.flatMap { Int($0) }.flatMap { (1...Self.longestBreakGap).contains($0) ? $0 : nil } ?? 1
            case "align-fit":
                breaks.exactAlign = value?.lowercased() == "exact"
            case "align":
                breaks.align = value.flatMap(Self.minutes).flatMap { Self.alignments.contains($0) ? $0 : nil } ?? 0
            case "user", "users":
                Self.collect(value, into: &users)
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
        // The break settings only mean something with clips to play.
        if hasBreaks {
            for name in fillerPlaylists { result.append(Self.prefix + "filler-playlists=\(name)") }
            result.append(Self.prefix + "filler-types=" + (fillerTypes.count == BreakKind.allCases.count ? "all" : BreakKind.allCases.filter(fillerTypes.contains).map(\.rawValue).joined(separator: ",")))
            result.append(Self.prefix + "bumpers-at=\(breaks.bumpersAt.rawValue)")
            result.append(Self.prefix + "break-length=\(breaks.minutes)")
            result.append(Self.prefix + "promo-count=\(breaks.promoCount)")
            result.append(Self.prefix + "trailer-count=\(breaks.trailerCount)")
            result.append(Self.prefix + "interstitial-count=\(breaks.interstitialCount)")
            result.append(Self.prefix + "break-every=\(breaks.every)")
            result.append(Self.prefix + (breaks.align > 0 ? "align=\(breaks.align)" : "align=off"))
            result.append(Self.prefix + "align-fit=" + (breaks.exactAlign ? "exact" : "best"))
        }
        if !users.isEmpty { result.append(Self.prefix + "user=" + users.joined(separator: ",")) }
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

    /// "30", "30m" or ":30" → 30; "off" → 0; nil for anything else.
    private static func minutes(_ value: String) -> Int? {
        var text = value.lowercased().trimmingCharacters(in: .whitespaces)
        if isOff(text) { return 0 }
        if text.hasPrefix(":") { text.removeFirst() }
        for unit in ["minutes", "minute", "mins", "min", "m"] where text.hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return Int(text)
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

    /// Whether a playlist's tags make it a filler playlist (`aster:filler`):
    /// one of break clips, which channels can take theirs from.
    static func isFillerPlaylist(_ tags: [String]?) -> Bool {
        (tags ?? []).contains { tag in parse(tag).map { $0.key == "filler" && ($0.value.map { !isOff($0) } ?? true) } ?? false }
    }

    /// What a break clip is, from its own tag: `aster:commercial`,
    /// `aster:promo`, `aster:trailer`, `aster:interstitial`, or
    /// `aster:bumper` (`=in`, `=out`). Nil for a clip that doesn't say,
    /// which breaks leave out.
    static func clipKind(_ tags: [String]?) -> BreakKind? {
        for tag in tags ?? [] {
            if let (key, _) = parse(tag), let kind = kind(key) { return kind }
        }
        return nil
    }

    /// Where a bumper goes: `aster:bumper=in` only closes a break (a
    /// countdown into the show), `aster:bumper=out` only opens one, and a
    /// plain `aster:bumper` goes at either end.
    static func bumperSide(_ tags: [String]?) -> BumperPlacement {
        for tag in tags ?? [] {
            guard let (key, value) = parse(tag), kind(key) == .bumpers else { continue }
            return value.flatMap { BumperPlacement(rawValue: $0.lowercased()) } ?? .both
        }
        return .both
    }

    /// "bumper" or "bumpers", "commercial" or "commercials" and so on, as a kind.
    private static func kind(_ word: String) -> BreakKind? {
        let word = word.lowercased()
        return BreakKind(rawValue: word) ?? BreakKind(rawValue: word + "s")
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
