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
//
//  "asterfin:" and the keys and values are read whatever their case. A tag
//  that isn't understood is left alone, and a value that doesn't make sense
//  falls back to the default rather than stopping the channel playing.
//

import Foundation

nonisolated struct ChannelTags: Equatable, Sendable {
    static let prefix = "asterfin:"
    /// The keys this reads and writes; other `asterfin:` tags are kept as they are.
    private static let keys: Set<String> = ["channel", "number", "mode", "logo"]

    var isChannel = false
    var number: Int?
    var mode: ChannelMode = .rotation
    var showsLogo = false

    init(isChannel: Bool = false, number: Int? = nil, mode: ChannelMode = .rotation, showsLogo: Bool = false) {
        self.isChannel = isChannel
        self.number = number
        self.mode = mode
        self.showsLogo = showsLogo
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
            default:
                break
            }
        }
    }

    /// `tags` with AsterFIN's own replaced by these settings; every other
    /// tag is kept, in its place. A playlist that stops being a channel
    /// keeps its number, mode and logo, so turning it back on restores them.
    func applied(to tags: [String]?) -> [String] {
        var result = (tags ?? []).filter { tag in
            guard let (key, _) = Self.parse(tag) else { return true }
            return !Self.keys.contains(key)
        }
        if isChannel { result.append(Self.prefix + "channel") }
        if let number { result.append(Self.prefix + "number=\(number)") }
        if mode != .rotation { result.append(Self.prefix + "mode=\(mode.rawValue)") }
        if showsLogo { result.append(Self.prefix + "logo=on") }
        return result
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

extension ChannelTags {
    /// A copy with `change` made, for editing one setting at a time.
    func with(_ change: (inout ChannelTags) -> Void) -> ChannelTags {
        var copy = self
        change(&copy)
        return copy
    }
}
