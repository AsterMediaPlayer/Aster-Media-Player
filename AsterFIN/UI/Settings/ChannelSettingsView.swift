//
//  ChannelSettingsView.swift
//  AsterFIN
//
//  Settings ▸ Channels, also opened from the Channels tab's Edit button.
//

import SwiftUI

// MARK: - Channels

/// Which video playlists are Channels, and in what order. Reached from
/// Settings and from the Channels tab's Edit button.
/// Channels are playlists tagged as one in Jellyfin (see `ChannelTags`).
/// This edits those tags, which an administrator can also do in Jellyfin's
/// web interface; for anyone else it shows them, read-only.
struct ChannelSettingsView: View {
    /// One channel's settings alone, already open, as Select on its guide
    /// cell shows them; nil for every channel and playlist.
    var only: String? = nil

    @Environment(AppSession.self) private var session
    @State private var playlists: [BaseItem] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    /// A save the server refused; the page turns read-only.
    @State private var refused = false
    /// The channels opened to change their settings; the rest show as a
    /// line each. A playlist just turned on opens.
    @State private var expanded: Set<String> = []
    /// The parts of open channels folded out: "plays|id" and "advanced|id".
    @State private var folds: Set<String> = []
    /// The server's movie and show genres, and its video libraries, by name,
    /// for genre channels.
    @State private var genreNames: [String] = []
    @State private var libraryNames: [String] = []
    /// The server's studios and networks, collections and content ratings.
    @State private var networkNames: [String] = []
    @State private var collectionNames: [String] = []
    @State private var ratingNames: [String] = []
    /// Everyone's user names on the server, for who gets a channel.
    @State private var userNames: [String] = []
    /// The server's shows, by id and name, for New Channel.
    @State private var seriesOptions: [(id: String, name: String)] = []
    /// How Channels Work, folded open.
    @State private var showsHelp = false
    @State private var isCreating = false

    private var canEdit: Bool { session.canEditChannels && !refused }

    private var channels: [(playlist: BaseItem, tags: ChannelTags)] {
        let tagged = ChannelsModel.taggedChannels(in: playlists)
        let numbers = self.numbers
        return tagged.sorted { (numbers[$0.playlist.id] ?? 0, Self.name($0)) < (numbers[$1.playlist.id] ?? 0, Self.name($1)) }
    }

    /// The groups the channels are in, A to Z, with `current` among them.
    private func groupNames(including current: String?) -> [String] {
        var names = Set(channels.compactMap(\.tags.group))
        if let current { names.insert(current) }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The channel's own name, else its playlist's.
    nonisolated private static func name(_ channel: (playlist: BaseItem, tags: ChannelTags)) -> String {
        channel.tags.name ?? channel.playlist.displayTitle
    }

    /// How long the bug can stay up, in seconds; 0 for always.
    private static let bugHideChoices = [0, 10, 30, 60, 120, 300]

    /// Bug opacities offered, in percent.
    private static let bugOpacityChoices = [25, 35, 45, 60, 75, 90, 100]

    /// Bug sizes offered, in percent of the usual.
    private static let bugSizeChoices = [50, 75, 100, 125, 150, 200, 250, 300]

    /// Year spans offered: any year, or a decade.
    private static let yearChoices: [ClosedRange<Int>?] = [nil] + stride(from: 1950, through: 2020, by: 10).map { $0...($0 + 9) }

    /// Programme length limits offered, in minutes.
    private static let lengthChoices: [Int?] = [nil, 5, 10, 15, 20, 30, 45, 60, 90, 120, 150, 180]

    /// Block lengths offered for Blocks mode, the usual first.
    private static let blockChoices: [ClosedRange<Int>] = [ChannelLineup.defaultBlocks, 1...2, 1...3, 2...3, 3...4, 3...5, 3...6, 4...6, 4...8, 6...10]

    /// Playlists that could be channels: not one already, and not a
    /// filler playlist.
    private var others: [BaseItem] {
        playlists.filter { !ChannelTags(tags: $0.tags).isChannel && !ChannelTags.isFillerPlaylist($0.tags) }
    }

    /// The filler playlists (tagged `aster:filler`) a channel can take its
    /// break clips from.
    private var fillerNames: [String] {
        playlists.filter { ChannelTags.isFillerPlaylist($0.tags) }.map(\.displayTitle)
    }

    /// Commercial time offered for each break, in minutes.
    private static let commercialChoices = [0, 1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 30]

    /// Each channel's number in the guide, its own or the next free one.
    private var numbers: [String: Int] {
        ChannelTags.numbers(for: ChannelsModel.taggedChannels(in: playlists).map { ($0.playlist.id, Self.name($0), $0.tags.number) })
    }

    /// "Tooniverse and Sitcoms are both channel 3."
    private var clashes: [String] {
        let byNumber = Dictionary(grouping: channels.filter { $0.tags.number != nil }, by: { $0.tags.number! })
        return byNumber.keys.sorted().compactMap { number in
            guard let names = byNumber[number]?.map(Self.name), names.count > 1 else { return nil }
            return "\(names.formatted(.list(type: .and))) are all channel \(number)."
        }
    }

    var body: some View {
        if let only {
            single(only)
        } else {
            everything
        }
    }

    /// One channel, opened: its settings and nothing else.
    private func single(_ id: String) -> some View {
        let channel = channels.first { $0.playlist.id == id }
        return SettingsPage(title: channel.map(Self.name) ?? "Channel") {
            if let errorMessage, playlists.isEmpty {
                Section { Text(errorMessage).foregroundStyle(.secondary) }
            } else if !loaded {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let channel {
                channelSection(channel.playlist, tags: channel.tags)
            } else {
                Section {
                    SettingsNote("This playlist isn't a channel any more. Turn it back on in Edit Channels.")
                }
            }
        }
        .task {
            expanded.insert(id)
            await load()
        }
    }

    private var everything: some View {
        SettingsPage(title: "Channels") {
            Section {
                SettingsNote("Turn video playlists into TV-style channels. Each plays its movies and episodes around the clock, the same on every device; tune in and you join whatever's on. Watching a channel doesn't touch your watch history. The Channels tab appears once there is one.")
            }
            if let errorMessage, playlists.isEmpty {
                Section { Text(errorMessage).foregroundStyle(.secondary) }
            } else if !loaded {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if playlists.isEmpty {
                Section {
                    SettingsNote("No video playlists yet. Make one in Jellyfin, or with Add to Playlist on any movie.")
                }
                if canEdit { newChannelSection }
            } else {
                if !canEdit {
                    Section {
                        SettingsNote("Only your server's administrator can set up channels. Ask them to, here or in Jellyfin.")
                    }
                } else {
                    newChannelSection
                }
                ForEach(channels, id: \.playlist.id) { channel in
                    channelSection(channel.playlist, tags: channel.tags)
                }
                if !clashes.isEmpty {
                    Section {
                        SettingsNote(clashes.joined(separator: " ") + " Give each its own number.")
                    }
                }
                if !others.isEmpty {
                    Section(channels.isEmpty ? "Video Playlists" : "More Playlists") {
                        ForEach(others) { playlist in
                            Toggle(isOn: Binding(
                                get: { false },
                                set: { on in if on { turnOn(playlist) } }
                            )) {
                                playlistLabel(playlist)
                            }
                            .disabled(!canEdit)
                        }
                    }
                }
                Section {
                    Button {
                        withAnimation { showsHelp.toggle() }
                    } label: {
                        HStack {
                            Text("How Channels Work")
                            Spacer(minLength: 0)
                            Image(systemName: showsHelp ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if showsHelp {
                        SettingsNote("Rotation plays one episode of each show in turn, and Blocks a few in a row; either way a show's episodes come in order and pick up where they left off, each movie takes a turn of its own, and specials are left out. Shuffle plays everything in its own order. These three deal a new order every day, week or month, as Reshuffle says, and Shuffle Again deals a different one. In Order plays the playlist as it's arranged, round and round.")
                        SettingsNote("Channels are saved as tags on the playlists in Jellyfin, so every device finds them. You can set them there too, in the playlist's Edit Metadata ▸ Tags: aster:channel, aster:number=3, aster:mode=blocks (or rotation, shuffle, sequential, airdate), aster:reshuffle=week (or day, month), aster:blocks=3-6, aster:seed=2, aster:logo=on, aster:bug=on (with aster:bug-location=top-left, top-right, bottom-left or bottom-right, aster:bug-size=150%, aster:bug-hide=30 and aster:bug-opacity=60%), aster:channel-name=Your Name, aster:group=Kids (channels go in the guide by group, groups in order of their lowest number), aster:min-length=20 and aster:max-length=60 (in minutes), aster:weight=Friends:2 (a show taking two turns to everyone else's one), and to fill a channel aster:genre=Horror, aster:network=NBC and aster:collection=Star Wars (once each), narrowed by aster:type=movies (or shows, all), aster:years=1980-1989, aster:rating=TV-PG,PG and aster:library=TV Shows (once per library, for genres and networks).")
                        SettingsNote("A channel with genres, networks or collections plays every movie and every episode of every show in them (any of them), as well as anything in its playlist. Air Date plays them all in the order they first aired.")
                        SettingsNote("A channel with filler playlists has a break after its programmes: a bumper, commercials, promos, trailers, interstitials, and a bumper back. Put the clips in Jellyfin as videos and tag each one with what it is: aster:commercial, aster:promo, aster:trailer, aster:interstitial or aster:bumper (aster:bumper=in only closes a break, right before the show, and aster:bumper=out only opens one); a clip without one isn't played. Put them in playlists tagged aster:filler, and pick those for a channel here, or name them with aster:filler-playlists=Its Name. aster:filler-types=commercials,bumpers keeps to some kinds; aster:bumpers-at=both (or out, in), aster:break-length=2 (minutes of commercials), aster:promo-count=1, aster:trailer-count=1, aster:interstitial-count=1 and aster:break-every=1 shape each break. With aster:align=30, programmes line up on the hour and half hour: Best Effort (aster:align-fit=best) fills each break with whole commercials, promos, trailers, interstitials and bumpers, as near the mark as they get, so a programme can start a few seconds early; Exact (aster:align-fit=exact) fills with interstitials and cuts the last one short to land right on it.")
                        SettingsNote("Other people on your server see a channel only if its playlist is shared with them, or public. Users (aster:user=peppy,jd) keeps a channel to certain people in Aster's Channels tab; it still lists every channel here, and doesn't hide the playlist in Jellyfin.")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func channelSection(_ playlist: BaseItem, tags: ChannelTags) -> some View {
        let isExpanded = expanded.contains(playlist.id)
        return Section {
            Button {
                withAnimation {
                    if isExpanded { expanded.remove(playlist.id) } else { expanded.insert(playlist.id) }
                }
            } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tags.name ?? playlist.displayTitle)
                        Text(summary(of: playlist, tags: tags))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            if isExpanded {
                channelSettings(playlist, tags: tags)
                    .disabled(!canEdit)
            }
        } header: {
            Text("Channel \(numbers[playlist.id] ?? 0)")
        }
    }

    /// New Channel: what to make it from, then which one; picking it makes
    /// the channel and comes back here with it open.
    private var newChannelSection: some View {
        Section {
            ForEach(NewChannelSource.allCases) { source in
                #if os(macOS)
                // The Settings window has no pages to push: a pop-up menu.
                Menu {
                    ForEach(newChannelOptions(source), id: \.id) { option in
                        Button(option.name) { createChannel(from: source, id: option.id, name: option.name) }
                    }
                } label: {
                    Label(source.title, systemImage: source.systemImage)
                }
                .disabled(isCreating || newChannelOptions(source).isEmpty)
                #else
                NavigationLink {
                    NewChannelPicker(source: source, options: newChannelOptions(source), isCreating: isCreating) { id, name in
                        createChannel(from: source, id: id, name: name)
                    }
                } label: {
                    Label(source.title, systemImage: source.systemImage)
                }
                #endif
            }
        } header: {
            Text("New Channel")
        } footer: {
            SettingsNote("A show plays its episodes in order; a genre, network or collection plays every movie and show in it. A playlist plays what you put in it. Each is shared with everyone on your server.")
        }
    }

    /// What New Channel offers for `source`, by id and name.
    private func newChannelOptions(_ source: NewChannelSource) -> [(id: String, name: String)] {
        switch source {
        case .show: seriesOptions
        case .genre: genreNames.map { ($0, $0) }
        case .network: networkNames.map { ($0, $0) }
        case .collection: collectionNames.map { ($0, $0) }
        case .playlist: others.map { ($0.id, $0.displayTitle) }
        }
    }

    /// "Horror, Thriller · Blocks · Weekly · 120 titles · Logo · Bug" for a closed channel.
    private func summary(of playlist: BaseItem, tags: ChannelTags) -> String {
        var parts = [tags.mode.title]
        let sources = tags.genres + tags.networks + tags.collections
        if !sources.isEmpty { parts.insert(sources.joined(separator: ", "), at: 0) }
        if tags.mode.reshuffles, tags.reshuffle != .day { parts.append(tags.reshuffle.title) }
        if let count = playlist.childCount { parts.append(count == 1 ? "1 title" : "\(count) titles") }
        if tags.showsLogo { parts.append("Logo") }
        if tags.showsBug { parts.append("Bug") }
        if !tags.users.isEmpty { parts.append("Only " + tags.users.formatted(.list(type: .and))) }
        if tags.hasBreaks { parts.append(tags.breaks.align > 0 ? "Breaks, \(Self.alignTitle(tags.breaks.align).lowercased())" : "Breaks") }
        return parts.joined(separator: " · ")
    }

    /// An open channel's settings: the essentials, then what it plays and
    /// the rest folded away until asked for.
    @ViewBuilder
    private func channelSettings(_ playlist: BaseItem, tags: ChannelTags) -> some View {
        Toggle(isOn: Binding(
            get: { true },
            set: { on in if !on { update(playlist) { $0.isChannel = false } } }
        )) {
            playlistLabel(playlist)
        }
        ChannelNameField(playlistName: playlist.displayTitle, name: tags.name) { name in
            update(playlist) { $0.name = name }
        }
        // The guide's group: one already in use, or a new one named here.
        SettingsChoiceRow(
            title: "Group",
            options: [("", "None")] + groupNames(including: tags.group).map { ($0, $0) },
            selection: Binding(
                get: { tags.group ?? "" },
                set: { group in update(playlist) { $0.group = group.isEmpty ? nil : group } }
            )
        )
        NewGroupField { group in
            update(playlist) { $0.group = group }
        }
        SettingsChoiceRow(
            title: "Number",
            options: (1...max(99, numbers[playlist.id] ?? 0)).map { ($0, "\($0)") },
            selection: Binding(
                get: { tags.number ?? numbers[playlist.id] ?? 1 },
                set: { number in update(playlist) { $0.number = number } }
            )
        )
        fold("What It Plays", summary: playsSummary(playlist, tags: tags), key: "plays", of: playlist)
        if folds.contains("plays|" + playlist.id) {
            SettingsMultiChoiceRow(title: "Genres", options: genreNames, selection: tags.genres) { genres in
                update(playlist) { $0.genres = genres }
            }
            SettingsMultiChoiceRow(title: "Networks", options: networkNames, selection: tags.networks) { networks in
                update(playlist) { $0.networks = networks }
            }
            SettingsMultiChoiceRow(title: "Collections", options: collectionNames, selection: tags.collections) { collections in
                update(playlist) { $0.collections = collections }
            }
            if tags.hasSources {
                SettingsChoiceRow(
                    title: "Content",
                    options: ChannelContent.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { tags.content },
                        set: { content in update(playlist) { $0.content = content } }
                    )
                )
                if !tags.genres.isEmpty || !tags.networks.isEmpty {
                    SettingsMultiChoiceRow(title: "Libraries", options: libraryNames, selection: tags.libraries, none: "All") { libraries in
                        update(playlist) { $0.libraries = libraries }
                    }
                }
                SettingsChoiceRow(
                    title: "Years",
                    options: (Self.yearChoices + (Self.yearChoices.contains(tags.years) ? [] : [tags.years])).map { ($0, Self.yearsTitle($0)) },
                    selection: Binding(
                        get: { tags.years },
                        set: { years in update(playlist) { $0.years = years } }
                    )
                )
                SettingsMultiChoiceRow(title: "Ratings", options: ratingNames, selection: tags.ratings, none: "Any") { ratings in
                    update(playlist) { $0.ratings = ratings }
                }
            }
        }
        SettingsChoiceRow(
            title: "Mode",
            options: ChannelMode.allCases.map { ($0, $0.title) },
            selection: Binding(
                get: { tags.mode },
                set: { mode in update(playlist) { $0.mode = mode } }
            )
        )
        Toggle("Playlist Picture as Logo", isOn: Binding(
            get: { tags.showsLogo },
            set: { on in update(playlist) { $0.showsLogo = on } }
        ))
        Toggle("Logo in the Corner While Playing", isOn: Binding(
            get: { tags.showsBug },
            set: { on in update(playlist) { $0.showsBug = on } }
        ))
        breaksRow(playlist, tags: tags)
        fold("Advanced", summary: nil, key: "advanced", of: playlist)
        if folds.contains("advanced|" + playlist.id) {
            if tags.mode == .blocks {
                SettingsChoiceRow(
                    title: "Episodes in a Row",
                    options: (Self.blockChoices + (Self.blockChoices.contains(tags.blocks) ? [] : [tags.blocks])).map { range in
                        (range, range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound) to \(range.upperBound)")
                    },
                    selection: Binding(
                        get: { tags.blocks },
                        set: { blocks in update(playlist) { $0.blocks = blocks } }
                    )
                )
            }
            if tags.mode.reshuffles {
                SettingsChoiceRow(
                    title: "Reshuffle",
                    options: ChannelReshuffle.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { tags.reshuffle },
                        set: { reshuffle in update(playlist) { $0.reshuffle = reshuffle } }
                    )
                )
                Button("Shuffle Again") {
                    update(playlist) { $0.seed += 1 }
                }
            }
            SettingsChoiceRow(
                title: "Shortest",
                options: (Self.lengthChoices + (Self.lengthChoices.contains(tags.minLength) ? [] : [tags.minLength])).sorted { ($0 ?? 0) < ($1 ?? 0) }.map { ($0, Self.lengthTitle($0)) },
                selection: Binding(
                    get: { tags.minLength },
                    set: { minutes in update(playlist) { $0.minLength = minutes } }
                )
            )
            SettingsChoiceRow(
                title: "Longest",
                options: (Self.lengthChoices + (Self.lengthChoices.contains(tags.maxLength) ? [] : [tags.maxLength])).sorted { ($0 ?? 0) < ($1 ?? 0) }.map { ($0, Self.lengthTitle($0)) },
                selection: Binding(
                    get: { tags.maxLength },
                    set: { minutes in update(playlist) { $0.maxLength = minutes } }
                )
            )
            if tags.showsBug {
                SettingsChoiceRow(
                    title: "Corner",
                    options: BugCorner.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { tags.bugCorner },
                        set: { corner in update(playlist) { $0.bugCorner = corner } }
                    )
                )
                SettingsChoiceRow(
                    title: "Hide After",
                    options: (Self.bugHideChoices + (Self.bugHideChoices.contains(tags.bugHideAfter) ? [] : [tags.bugHideAfter])).sorted().map { seconds in
                        (seconds, seconds == 0 ? "Never" : Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                    },
                    selection: Binding(
                        get: { tags.bugHideAfter },
                        set: { seconds in update(playlist) { $0.bugHideAfter = seconds } }
                    )
                )
                SettingsChoiceRow(
                    title: "Opacity",
                    options: (Self.bugOpacityChoices + (Self.bugOpacityChoices.contains(tags.bugOpacity) ? [] : [tags.bugOpacity])).sorted().map { ($0, "\($0)%") },
                    selection: Binding(
                        get: { tags.bugOpacity },
                        set: { opacity in update(playlist) { $0.bugOpacity = opacity } }
                    )
                )
                SettingsChoiceRow(
                    title: "Logo Size",
                    options: (Self.bugSizeChoices + (Self.bugSizeChoices.contains(tags.bugSize) ? [] : [tags.bugSize])).sorted().map { ($0, "\($0)%") },
                    selection: Binding(
                        get: { tags.bugSize },
                        set: { size in update(playlist) { $0.bugSize = size } }
                    )
                )
            }
            if !tags.fillerPlaylists.isEmpty {
                SettingsMultiChoiceRow(
                    title: "Filler Types",
                    options: BreakKind.allCases.map(\.title),
                    selection: BreakKind.allCases.filter(tags.fillerTypes.contains).map(\.title),
                    none: "All"
                ) { titles in
                    let kinds = Set(BreakKind.allCases.filter { titles.contains($0.title) })
                    update(playlist) { $0.fillerTypes = kinds.isEmpty ? Set(BreakKind.allCases) : kinds }
                }
            }
            if tags.hasBreaks {
                if tags.fillerTypes.contains(.bumpers) {
                    SettingsChoiceRow(
                        title: "Bumpers",
                        options: BumperPlacement.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { tags.breaks.bumpersAt },
                            set: { at in update(playlist) { $0.breaks.bumpersAt = at } }
                        )
                    )
                }
                if tags.fillerTypes.contains(.commercials) {
                    SettingsChoiceRow(
                        title: "Commercial Time",
                        options: (Self.commercialChoices + (Self.commercialChoices.contains(tags.breaks.minutes) ? [] : [tags.breaks.minutes])).sorted().map { ($0, $0 == 0 ? "None" : Self.lengthTitle($0)) },
                        selection: Binding(
                            get: { tags.breaks.minutes },
                            set: { minutes in update(playlist) { $0.breaks.minutes = minutes } }
                        )
                    )
                }
                if tags.fillerTypes.contains(.promos) {
                    SettingsChoiceRow(
                        title: "Promos per Break",
                        options: (0...ChannelTags.mostPromos).map { ($0, "\($0)") },
                        selection: Binding(
                            get: { tags.breaks.promoCount },
                            set: { count in update(playlist) { $0.breaks.promoCount = count } }
                        )
                    )
                }
                if tags.fillerTypes.contains(.trailers) {
                    SettingsChoiceRow(
                        title: "Trailers per Break",
                        options: (0...ChannelTags.mostPromos).map { ($0, "\($0)") },
                        selection: Binding(
                            get: { tags.breaks.trailerCount },
                            set: { count in update(playlist) { $0.breaks.trailerCount = count } }
                        )
                    )
                }
                SettingsChoiceRow(
                    title: "Line Up",
                    options: [(0, "Off")] + ChannelTags.alignments.map { ($0, Self.alignTitle($0)) },
                    selection: Binding(
                        get: { tags.breaks.align },
                        set: { align in update(playlist) { $0.breaks.align = align } }
                    )
                )
                if tags.breaks.align > 0 {
                    SettingsChoiceRow(
                        title: "Fit",
                        options: [(false, "Best Effort"), (true, "Exact")],
                        selection: Binding(
                            get: { tags.breaks.exactAlign },
                            set: { exact in update(playlist) { $0.breaks.exactAlign = exact } }
                        )
                    )
                }
                if tags.breaks.align == 0 {
                    if tags.fillerTypes.contains(.interstitials) {
                        SettingsChoiceRow(
                            title: "Interstitials per Break",
                            options: (0...ChannelTags.mostPromos).map { ($0, "\($0)") },
                            selection: Binding(
                                get: { tags.breaks.interstitialCount },
                                set: { count in update(playlist) { $0.breaks.interstitialCount = count } }
                            )
                        )
                    }
                    SettingsChoiceRow(
                        title: "Break After",
                        options: (1...ChannelTags.longestBreakGap).map { ($0, $0 == 1 ? "Every Programme" : "Every \($0) Programmes") },
                        selection: Binding(
                            get: { tags.breaks.every },
                            set: { every in update(playlist) { $0.breaks.every = every } }
                        )
                    )
                }
            }
            let users = userNames + tags.users.filter { name in !userNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            if !users.isEmpty {
                SettingsMultiChoiceRow(title: "Users", options: users, selection: tags.users, none: "Everyone") { names in
                    update(playlist) { $0.users = names }
                }
            }
            SettingsNote("Every setting is a tag on the playlist in Jellyfin, so you can change it there too: see How Channels Work below.")
        }
    }

    /// A row that opens or closes part of a channel's settings in place,
    /// with what's set there when closed.
    private func fold(_ title: String, summary: String?, key: String, of playlist: BaseItem) -> some View {
        let id = key + "|" + playlist.id
        let isOpen = folds.contains(id)
        return Button {
            withAnimation {
                if isOpen { folds.remove(id) } else { folds.insert(id) }
            }
        } label: {
            HStack(spacing: 16) {
                Text(title)
                Spacer(minLength: 0)
                if let summary, !isOpen {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "Horror, Thriller · Movies", or the playlist's own titles.
    private func playsSummary(_ playlist: BaseItem, tags: ChannelTags) -> String {
        let sources = tags.genres + tags.networks + tags.collections
        guard !sources.isEmpty else {
            return playlist.childCount.map { $0 == 1 ? "1 title" : "\($0) titles" } ?? "Its playlist"
        }
        var parts = [sources.joined(separator: ", ")]
        if tags.content != .all { parts.append(tags.content.title) }
        return parts.joined(separator: " · ")
    }

    /// Breaks: the filler playlists a channel's breaks play from; none is
    /// off. Turning breaks on lines the channel up on the half hour too,
    /// best effort, which is how a channel with breaks usually wants to run.
    @ViewBuilder
    private func breaksRow(_ playlist: BaseItem, tags: ChannelTags) -> some View {
        let options = fillerNames + tags.fillerPlaylists.filter { name in !fillerNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        if !options.isEmpty {
            SettingsMultiChoiceRow(title: "Breaks", options: options, selection: tags.fillerPlaylists, none: "Off") { names in
                update(playlist) { tags in
                    let turningOn = tags.fillerPlaylists.isEmpty && !names.isEmpty
                    tags.fillerPlaylists = names
                    if turningOn, tags.breaks.align == 0 {
                        tags.breaks.align = 30
                        tags.breaks.exactAlign = false
                    }
                }
            }
        }
    }

    /// "On the Half Hour", "On the Hour", "Every 15 Minutes".
    private static func alignTitle(_ minutes: Int) -> String {
        switch minutes {
        case 30: "On the Half Hour"
        case 60: "On the Hour"
        default: "Every \(minutes) Minutes"
        }
    }

    /// "Any Year", "1980s", "1985–1999" or "1994".
    private static func yearsTitle(_ years: ClosedRange<Int>?) -> String {
        guard let years else { return "Any Year" }
        if years.count == 1 { return "\(years.lowerBound)" }
        if years.lowerBound % 10 == 0, years.count == 10 { return "\(years.lowerBound)s" }
        return "\(years.lowerBound)–\(years.upperBound)"
    }

    /// "Any Length" or "30 min".
    private static func lengthTitle(_ minutes: Int?) -> String {
        guard let minutes else { return "Any Length" }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func playlistLabel(_ playlist: BaseItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.displayTitle)
            if let count = playlist.childCount {
                Text(count == 1 ? "1 title" : "\(count) titles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Makes a playlist a channel, with the next free number and its picture
    /// as the logo when it has one, unless its tags already say otherwise.
    private func turnOn(_ playlist: BaseItem) {
        var tags = ChannelTags(tags: playlist.tags)
        tags.isChannel = true
        if tags.number == nil { tags.number = (numbers.values.max() ?? 0) + 1 }
        if !ChannelTags.sets("logo", in: playlist.tags) { tags.showsLogo = playlist.imageTags?["Primary"] != nil }
        // Opened, as it's about to be set up.
        expanded.insert(playlist.id)
        save(playlist, tags)
    }

    /// Changes a channel's settings starting from its latest tags, so a
    /// change made a moment after another never undoes it.
    private func update(_ playlist: BaseItem, _ change: (inout ChannelTags) -> Void) {
        var tags = ChannelTags(tags: playlists.first { $0.id == playlist.id }?.tags ?? playlist.tags)
        change(&tags)
        save(playlist, tags)
    }

    /// Writes the playlist's tags with these channel settings, every one of
    /// them, keeping its other tags; the page shows the change at once, and
    /// the Channels tab picks it up. A channel numbered automatically keeps
    /// the number it has now, so later channels don't move it.
    private func save(_ playlist: BaseItem, _ tags: ChannelTags) {
        var tags = tags
        if tags.number == nil { tags.number = numbers[playlist.id] }
        guard canEdit, let client = session.jellyfin, let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        pinNumbers(except: playlist.id)
        let previous = playlists[index].tags
        let updated = tags.applied(to: previous)
        playlists[index].tags = updated
        Task {
            do {
                try await client.setTags(updated, onItem: playlist.id)
                await session.refreshChannels()
            } catch {
                if let current = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[current].tags = previous }
                if case JellyfinError.http(let code, _) = error, code == 401 || code == 403 { refused = true }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Writes each channel numbered automatically the number it has now,
    /// before a change that would move them: numbers left to the app follow
    /// the highest set one in name order, so adding a channel, turning one
    /// off, renumbering one, or saving one's number would shift the rest.
    private func pinNumbers(except id: String?) {
        guard let client = session.jellyfin else { return }
        let current = numbers
        for (playlist, tags) in ChannelsModel.taggedChannels(in: playlists) where tags.number == nil && playlist.id != id {
            guard let number = current[playlist.id], let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { continue }
            var pinned = tags
            pinned.number = number
            let updated = pinned.applied(to: playlists[index].tags)
            playlists[index].tags = updated
            Task {
                do { try await client.setTags(updated, onItem: playlist.id) } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func load() async {
        guard let client = session.jellyfin else { return }
        async let genres = client.videoGenres()
        async let views = client.userViews()
        async let studios = client.videoStudios()
        async let boxSets = client.collections()
        async let ratings = client.videoRatings()
        async let users = client.userNames()
        async let series = client.seriesList()
        do {
            playlists = try await client.playlists(mediaType: "Video")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        genreNames = ((try? await genres) ?? []).map(\.displayTitle)
        // Video libraries only: a genre channel plays movies and episodes.
        let skipped: Set<String> = ["music", "books", "livetv", "playlists", "boxsets", "musicvideos"]
        libraryNames = ((try? await views) ?? []).filter { !skipped.contains($0.collectionType?.lowercased() ?? "") }.map(\.displayTitle)
        networkNames = ((try? await studios) ?? []).map(\.displayTitle)
        // Empty collections (book series often are, to video) are left out.
        collectionNames = ((try? await boxSets) ?? []).filter { ($0.childCount ?? 1) > 0 }.map(\.displayTitle)
        ratingNames = (try? await ratings) ?? []
        userNames = (try? await users) ?? []
        seriesOptions = ((try? await series) ?? []).map { ($0.id, $0.displayTitle) }
        loaded = true
    }

    /// Makes a channel from what New Channel picked: a public video playlist
    /// of a show's episodes, or an empty one filled from a genre, network
    /// or collection, tagged with the next free number and opened; or an
    /// existing playlist turned on.
    private func createChannel(from source: NewChannelSource, id: String, name: String) {
        if source == .playlist {
            if let playlist = playlists.first(where: { $0.id == id }) { turnOn(playlist) }
            return
        }
        guard canEdit, !isCreating, let client = session.jellyfin else { return }
        isCreating = true
        pinNumbers(except: nil)
        var tags = ChannelTags(isChannel: true, number: (numbers.values.max() ?? 0) + 1)
        switch source {
        case .show: tags.showsLogo = true
        case .genre: tags.genres = [name]
        case .network: tags.networks = [name]
        case .collection: tags.collections = [name]
        case .playlist: break
        }
        let written = tags.applied(to: [])
        Task {
            defer { isCreating = false }
            do {
                let episodes = source == .show ? try await client.seriesEpisodes(id).map(\.id) : []
                let playlistId = try await client.createPlaylist(name: name, itemIds: episodes, mediaType: "Video", isPublic: true)
                try await client.setTags(written, onItem: playlistId)
                await load()
                expanded.insert(playlistId)
                await session.refreshChannels()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// What New Channel can make a channel from.
enum NewChannelSource: String, CaseIterable, Identifiable {
    case show, genre, network, collection, playlist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .show: "From a Show"
        case .genre: "From a Genre"
        case .network: "From a Network"
        case .collection: "From a Collection"
        case .playlist: "From One of Your Playlists"
        }
    }

    var systemImage: String {
        switch self {
        case .show: "tv"
        case .genre: "theatermasks"
        case .network: "antenna.radiowaves.left.and.right"
        case .collection: "square.stack"
        case .playlist: "list.bullet"
        }
    }

    /// The picker's title: "Pick a Show".
    var pickTitle: String {
        switch self {
        case .show: "Pick a Show"
        case .genre: "Pick a Genre"
        case .network: "Pick a Network"
        case .collection: "Pick a Collection"
        case .playlist: "Pick a Playlist"
        }
    }
}

/// New Channel's second step: the shows (or genres, networks, collections,
/// playlists) to pick from. Picking one makes the channel and goes back.
private struct NewChannelPicker: View {
    let source: NewChannelSource
    let options: [(id: String, name: String)]
    let isCreating: Bool
    var pick: (_ id: String, _ name: String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage(title: source.pickTitle) {
            if options.isEmpty {
                Section {
                    SettingsNote(source == .playlist ? "Every video playlist is a channel already." : "There's nothing to pick yet.")
                        .focusable()
                }
            } else {
                Section {
                    ForEach(options, id: \.id) { option in
                        Button(option.name) {
                            pick(option.id, option.name)
                            dismiss()
                        }
                        .disabled(isCreating)
                    }
                }
            }
        }
    }
}

/// A channel's own name, saved when editing ends; empty goes back to the
/// playlist's name.
/// Names a new group and puts the channel in it; empty again after.
private struct NewGroupField: View {
    var save: (String) -> Void

    @State private var draft = ""

    var body: some View {
        TextField("New Group", text: $draft, prompt: Text("New group…"))
            .onSubmit {
                let name = draft.trimmingCharacters(in: .whitespaces)
                draft = ""
                if !name.isEmpty { save(name) }
            }
    }
}

private struct ChannelNameField: View {
    let playlistName: String
    let name: String?
    var save: (String?) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Channel Name", text: $draft, prompt: Text(playlistName))
            .focused($focused)
            .onAppear { draft = name ?? "" }
            .onChange(of: name) { _, new in if !focused { draft = new ?? "" } }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        let new = trimmed.isEmpty || trimmed == playlistName ? nil : trimmed
        if new != name { save(new) }
    }
}
