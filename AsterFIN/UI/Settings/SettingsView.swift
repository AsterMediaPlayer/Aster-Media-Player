//
//  SettingsView.swift
//  AsterFIN
//

import SwiftUI

/// The pages the Settings root opens.
private enum SettingsDestination: Hashable {
    case playback, audioSubtitles, discMenus, titlePages, channels, tabBar, downloads, account, about
}

/// The Settings root: one row per category, each opening its own page.
/// The pages go on the tab's navigation path, as browsing pages do, so the
/// tab knows a page is open (iPhone's More tab then hides its own back
/// button; see `MoreBarHider`).
struct SettingsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        SettingsPage(title: "Settings") {
            Section {
                NavigationLink(value: SettingsDestination.playback) {
                    Label("Playback", systemImage: "play.rectangle")
                }
                NavigationLink(value: SettingsDestination.audioSubtitles) {
                    Label("Audio & Subtitles", systemImage: "captions.bubble")
                }
                NavigationLink(value: SettingsDestination.discMenus) {
                    Label("Disc Menus", systemImage: "opticaldisc")
                }
                NavigationLink(value: SettingsDestination.titlePages) {
                    Label("Title Pages", systemImage: "music.note.tv")
                }
                NavigationLink(value: SettingsDestination.channels) {
                    Label("Channels (Beta)", systemImage: "tv.and.mediabox")
                }
                #if os(iOS)
                NavigationLink(value: SettingsDestination.tabBar) {
                    Label("Tab Bar", systemImage: "rectangle.bottomhalf.inset.filled")
                }
                NavigationLink(value: SettingsDestination.downloads) {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                #endif
            }
            Section {
                NavigationLink(value: SettingsDestination.account) {
                    LabeledContent {
                        Text(session.userName ?? "")
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
                NavigationLink(value: SettingsDestination.about) {
                    Label("About", systemImage: "info.circle")
                }
            }
        }
        .navigationDestination(for: SettingsDestination.self) { destination in
            switch destination {
            case .playback: PlaybackSettingsView()
            case .audioSubtitles: AudioSubtitleSettingsView()
            case .discMenus: DiscMenuSettingsView()
            case .titlePages: TitlePageSettingsView()
            case .channels: ChannelSettingsView()
            case .tabBar:
                #if os(iOS)
                TabBarSettingsView()
                #else
                EmptyView()
                #endif
            case .downloads:
                #if os(iOS)
                DownloadSettingsView()
                #else
                EmptyView()
                #endif
            case .account: AccountSettingsView()
            case .about: AboutSettingsView()
            }
        }
        // Settings that follow the user come from their server on opening.
        .task {
            if let client = session.client { await SettingsSync.pull(client: client) }
        }
    }
}

#if os(macOS)
/// The Mac's Settings window (Aster › Settings…, ⌘,): a pane per section,
/// as Mac apps do, in place of the Settings tab the other platforms have.
struct MacSettingsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        TabView {
            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            AudioSubtitleSettingsView()
                .tabItem { Label("Audio & Subtitles", systemImage: "captions.bubble") }
            DiscMenuSettingsView()
                .tabItem { Label("Disc Menus", systemImage: "opticaldisc") }
            TitlePageSettingsView()
                .tabItem { Label("Title Pages", systemImage: "music.note.tv") }
            ChannelSettingsView()
                .tabItem { Label("Channels (Beta)", systemImage: "tv.and.mediabox") }
            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560)
        .frame(minHeight: 380)
        .task {
            if let client = session.client { await SettingsSync.pull(client: client) }
        }
    }
}
#endif

/// A settings form with the large page title as its first row, like the
/// in-page titles elsewhere. (A navigation bar title would add a second bar
/// under iPhone's More tab.)
private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(macOS)
        // A pane of the Settings window, whose tab names it.
        Form {
            content()
        }
        .formStyle(.grouped)
        #else
        Form {
            Section {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
            }
            content()
        }
        #endif
    }
}

/// What to call this device in settings notes: "Apple TV", "iPhone" or "iPad".
private var deviceName: String {
    #if os(tvOS)
    "Apple TV"
    #elseif os(macOS)
    "Mac"
    #else
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    #endif
}

/// The small grey explanation under a group of settings.
private struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A row showing the current choice that opens a page of options. Stands in
/// for a navigation-style Picker, whose pushed list hangs on tvOS when the
/// picker sits on a page that was itself pushed and uses a computed binding.
private struct SettingsChoiceRow<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, name: String)]
    let selection: Binding<Value>

    var body: some View {
        #if os(macOS)
        // The Settings window has no pages to push: a pop-up menu.
        Picker(title, selection: selection) {
            ForEach(options, id: \.value) { option in
                Text(option.name).tag(option.value)
            }
        }
        .pickerStyle(.menu)
        #else
        NavigationLink {
            SettingsChoicePage(title: title, options: options, selection: selection)
        } label: {
            LabeledContent(title, value: options.first { $0.value == selection.wrappedValue }?.name ?? "")
        }
        #endif
    }
}

/// The options list: picking one saves it and goes back.
private struct SettingsChoicePage<Value: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let options: [(value: Value, name: String)]
    let selection: Binding<Value>
    @State private var current: Value

    init(title: String, options: [(value: Value, name: String)], selection: Binding<Value>) {
        self.title = title
        self.options = options
        self.selection = selection
        _current = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        SettingsPage(title: title) {
            Section {
                ForEach(options, id: \.value) { option in
                    Button {
                        current = option.value
                        selection.wrappedValue = option.value
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.name)
                            Spacer()
                            if option.value == current {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Playback

private struct PlaybackSettingsView: View {
    @AppStorage(AppSettings.maxBitrateKey) private var maxBitrate = 120_000_000
    @AppStorage(AppSettings.autoplayNextKey) private var autoplayNext = true
    @AppStorage(AppSettings.autoSkipIntroKey) private var autoSkipIntro = false
    @AppStorage(AppSettings.themeCardsKey) private var themeCards = true
    @AppStorage(AppSettings.useSystemPlayerKey) private var useSystemPlayer = false
    #if os(iOS)
    @AppStorage(AppSettings.listenAheadKey) private var listenAhead = 30
    #endif
    #if os(macOS)
    @AppStorage(AppSettings.fullScreenPlaybackKey) private var fullScreenPlayback = true
    #endif

    private let bitrates: [(String, Int)] = [
        ("Auto (120 Mbps)", 120_000_000),
        ("60 Mbps", 60_000_000),
        ("40 Mbps", 40_000_000),
        ("20 Mbps", 20_000_000),
        ("10 Mbps", 10_000_000),
        ("4 Mbps", 4_000_000),
    ]

    var body: some View {
        SettingsPage(title: "Playback") {
            Section("Streaming") {
                Picker("Maximum streaming quality", selection: $maxBitrate) {
                    ForEach(bitrates, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
            }
            #if os(iOS)
            Section {
                Picker("Listen Ahead", selection: $listenAhead) {
                    Text("Off").tag(0)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
            } header: {
                Text("Audiobooks")
            } footer: {
                SettingsNote("Saves what's coming up in an audiobook as it plays, so it carries on through a spot with no signal. It's kept in the cache, and let go once heard. Downloaded books don't need it.")
            }
            #endif
            #if os(macOS)
            Section("Window") {
                Toggle("Play videos full screen", isOn: $fullScreenPlayback)
                SettingsNote("A video takes the whole screen as it starts, and the window comes back as it closes. Off, it plays inside the window.")
            }
            #endif
            Section("Episodes") {
                Toggle("Autoplay next episode", isOn: $autoplayNext)
                Toggle("Skip intros automatically", isOn: $autoSkipIntro)
                SettingsNote("Skip Intro and Skip Credits need markers on the server, from the Intro Skipper plugin or chapter markers.")
            }
            Section("Anime") {
                Toggle("Song card at openings and endings", isOn: $themeCards)
                SettingsNote("As an episode's opening or ending starts, and again as it finishes, the song and artist show in the corner, like a music channel. Found from the episode's OP and ED chapters, with the song named by the OP/ED plugin when the server has it.")
            }
            #if canImport(AetherEngine)
            Section("Player") {
                Toggle("Use the system player", isOn: $useSystemPlayer)
                SettingsNote("Videos and Live TV play in AetherEngine, from the original file, with every audio and subtitle track switchable right away. A file that's too much for this device or the connection is converted by the server, and anything the engine can't play moves to the system player by itself. Turn this on to use the system player for everything. Playlists, downloads and opening and ending clips use the system player either way.")
            }
            #endif
        }
    }
}

// MARK: - Audio & Subtitles

private struct AudioSubtitleSettingsView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.styledSubtitlesKey) private var styledSubtitles = true

    /// ISO 639-2 codes as Jellyfin stores them, with an "Any" entry.
    private static let languages: [(code: String, name: String)] = [
        ("", "Any"), ("eng", "English"), ("spa", "Spanish"), ("fre", "French"), ("ger", "German"),
        ("ita", "Italian"), ("por", "Portuguese"), ("jpn", "Japanese"), ("kor", "Korean"), ("chi", "Chinese"),
        ("rus", "Russian"), ("ara", "Arabic"), ("hin", "Hindi"), ("dut", "Dutch"), ("swe", "Swedish"),
        ("nor", "Norwegian"), ("dan", "Danish"), ("fin", "Finnish"), ("pol", "Polish"), ("tur", "Turkish"),
        ("heb", "Hebrew"), ("tha", "Thai"), ("vie", "Vietnamese"), ("gre", "Greek"), ("cze", "Czech"), ("hun", "Hungarian"),
    ]

    /// The language list, plus the current value if the server uses a code
    /// that is not in the list, so the picker never shows nothing.
    private func languageOptions(including current: String) -> [(code: String, name: String)] {
        if current.isEmpty || Self.languages.contains(where: { $0.code == current }) { return Self.languages }
        return Self.languages + [(current, current.uppercased())]
    }

    // Each preference writes through to the Jellyfin profile when it is known,
    // and always to this device as a fallback.
    private var audioLanguage: Binding<String> {
        Binding(
            get: { session.userConfiguration?.audioLanguagePreference ?? UserDefaults.standard.string(forKey: AppSettings.audioLanguageKey) ?? "" },
            set: { value in
                UserDefaults.standard.set(value, forKey: AppSettings.audioLanguageKey)
                Task { await session.updateUserConfiguration { $0.audioLanguagePreference = value } }
            }
        )
    }

    private var subtitleLanguage: Binding<String> {
        Binding(
            get: { session.userConfiguration?.subtitleLanguagePreference ?? UserDefaults.standard.string(forKey: AppSettings.subtitleLanguageKey) ?? "" },
            set: { value in
                UserDefaults.standard.set(value, forKey: AppSettings.subtitleLanguageKey)
                Task { await session.updateUserConfiguration { $0.subtitleLanguagePreference = value } }
            }
        )
    }

    private var subtitleMode: Binding<SubtitleMode> {
        Binding(
            get: {
                let stored = session.userConfiguration?.subtitleMode ?? UserDefaults.standard.string(forKey: AppSettings.subtitleModeKey)
                return SubtitleMode(rawValue: stored ?? "") ?? .default
            },
            set: { mode in
                UserDefaults.standard.set(mode.rawValue, forKey: AppSettings.subtitleModeKey)
                Task { await session.updateUserConfiguration { $0.subtitleMode = mode.rawValue } }
            }
        )
    }

    var body: some View {
        SettingsPage(title: "Audio & Subtitles") {
            Section("Audio") {
                SettingsChoiceRow(
                    title: "Preferred audio language",
                    options: languageOptions(including: audioLanguage.wrappedValue).map { ($0.code, $0.name) },
                    selection: audioLanguage
                )
            }
            Section("Subtitles") {
                SettingsChoiceRow(
                    title: "Preferred subtitle language",
                    options: languageOptions(including: subtitleLanguage.wrappedValue).map { ($0.code, $0.name) },
                    selection: subtitleLanguage
                )
                SettingsChoiceRow(
                    title: "Subtitles",
                    options: SubtitleMode.allCases.map { ($0, $0.title) },
                    selection: subtitleMode
                )
                SettingsNote(session.userConfiguration == nil
                     ? "Saved on this \(deviceName). These sync with your Jellyfin profile once the server settings load."
                     : "Synced with your Jellyfin profile, so the web app and this \(deviceName) make the same choices. A title's own Audio & Subtitles menu overrides them for that title.")
            }
            Section("Styled Subtitles") {
                Toggle("Draw ASS and SSA subtitles as styled", isOn: $styledSubtitles)
                SettingsNote("Draws anime subtitles as the release intended: signs where they belong on screen, their drawings, and the fonts inside the file. Turn off for plain text at the bottom, in your caption style.")
            }
        }
    }
}

// MARK: - Disc Menus

private struct DiscMenuSettingsView: View {
    @AppStorage(AppSettings.preferDiscMenuKey) private var preferDiscMenu = false
    @AppStorage(AppSettings.discMenuSoundsKey) private var discMenuSounds = true

    var body: some View {
        SettingsPage(title: "Disc Menus") {
            Section {
                Toggle("Open disc menu when pressing Play", isOn: $preferDiscMenu)
                Toggle("Menu music and sounds", isOn: $discMenuSounds)
                SettingsNote("Titles with a JellyDisc menu on the server show a Disc Menu button on their page. Turn on the first option to start those titles at their menu, like putting in the disc.")
            }
        }
    }
}

// MARK: - Title Pages

// MARK: - Channels

/// Which video playlists are Channels, and in what order. Reached from
/// Settings and from the Channels tab's Edit button.
/// Channels are playlists tagged as one in Jellyfin (see `ChannelTags`).
/// This edits those tags, which an administrator can also do in Jellyfin's
/// web interface; for anyone else it shows them, read-only.
struct ChannelSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var playlists: [BaseItem] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    /// A save the server refused; the page turns read-only.
    @State private var refused = false
    /// The channels opened to change their settings; the rest show as a
    /// line each. A playlist just turned on opens.
    @State private var expanded: Set<String> = []

    private var canEdit: Bool { session.canEditChannels && !refused }

    private var channels: [(playlist: BaseItem, tags: ChannelTags)] {
        let tagged = ChannelsModel.taggedChannels(in: playlists)
        let numbers = self.numbers
        return tagged.sorted { (numbers[$0.playlist.id] ?? 0, Self.name($0)) < (numbers[$1.playlist.id] ?? 0, Self.name($1)) }
    }

    /// The channel's own name, else its playlist's.
    nonisolated private static func name(_ channel: (playlist: BaseItem, tags: ChannelTags)) -> String {
        channel.tags.name ?? channel.playlist.displayTitle
    }

    /// How long the bug can stay up, in seconds; 0 for always.
    private static let bugHideChoices = [0, 10, 30, 60, 120, 300]

    /// Bug sizes offered, in percent of the usual.
    private static let bugSizeChoices = [50, 75, 100, 125, 150, 200, 250, 300]

    /// Block lengths offered for Blocks mode, the usual first.
    private static let blockChoices: [ClosedRange<Int>] = [ChannelLineup.defaultBlocks, 1...2, 1...3, 2...3, 3...4, 3...5, 3...6, 4...6, 4...8, 6...10]

    private var others: [BaseItem] {
        playlists.filter { !ChannelTags(tags: $0.tags).isChannel }
    }

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
        SettingsPage(title: "Channels (Beta)") {
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
            } else {
                if !canEdit {
                    Section {
                        SettingsNote("Only your server's administrator can set up channels. Ask them to, here or in Jellyfin.")
                    }
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
                    SettingsNote("Rotation plays one episode of each show in turn, and Blocks a few in a row; either way a show's episodes come in order and pick up where they left off, each movie takes a turn of its own, and specials are left out. Shuffle plays everything in its own order. These three deal a new order every day, week or month, as Reshuffle says, and Shuffle Again deals a different one. In Order plays the playlist as it's arranged, round and round.")
                    SettingsNote("Channels are saved as tags on the playlists in Jellyfin, so every device finds them. You can set them there too, in the playlist's Edit Metadata ▸ Tags: aster:channel, aster:number=3, aster:mode=blocks (or rotation, shuffle, sequential), aster:reshuffle=week (or day, month), aster:blocks=3-6, aster:seed=2, aster:logo=on, aster:bug=on (with aster:bug-location=top-left, top-right, bottom-left or bottom-right, aster:bug-size=150% and aster:bug-hide=30) and aster:channel-name=Your Name.")
                    SettingsNote("Other people on your server see a channel only if its playlist is shared with them, or public.")
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

    /// "Blocks · Weekly · 120 titles · Logo · Bug" for a closed channel.
    private func summary(of playlist: BaseItem, tags: ChannelTags) -> String {
        var parts = [tags.mode.title]
        if tags.mode != .sequential, tags.reshuffle != .day { parts.append(tags.reshuffle.title) }
        if let count = playlist.childCount { parts.append(count == 1 ? "1 title" : "\(count) titles") }
        if tags.showsLogo { parts.append("Logo") }
        if tags.showsBug { parts.append("Bug") }
        return parts.joined(separator: " · ")
    }

    /// An open channel's settings.
    @ViewBuilder
    private func channelSettings(_ playlist: BaseItem, tags: ChannelTags) -> some View {
        Toggle(isOn: Binding(
            get: { true },
            set: { on in if !on { save(playlist, tags.with { $0.isChannel = false }) } }
        )) {
            playlistLabel(playlist)
        }
        ChannelNameField(playlistName: playlist.displayTitle, name: tags.name) { name in
            save(playlist, tags.with { $0.name = name })
        }
        SettingsChoiceRow(
            title: "Number",
            options: (1...max(99, numbers[playlist.id] ?? 0)).map { ($0, "\($0)") },
            selection: Binding(
                get: { tags.number ?? numbers[playlist.id] ?? 1 },
                set: { number in save(playlist, tags.with { $0.number = number }) }
            )
        )
        SettingsChoiceRow(
            title: "Mode",
            options: ChannelMode.allCases.map { ($0, $0.title) },
            selection: Binding(
                get: { tags.mode },
                set: { mode in save(playlist, tags.with { $0.mode = mode }) }
            )
        )
        if tags.mode == .blocks {
            SettingsChoiceRow(
                title: "Episodes in a Row",
                options: (Self.blockChoices + (Self.blockChoices.contains(tags.blocks) ? [] : [tags.blocks])).map { range in
                    (range, range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound) to \(range.upperBound)")
                },
                selection: Binding(
                    get: { tags.blocks },
                    set: { blocks in save(playlist, tags.with { $0.blocks = blocks }) }
                )
            )
        }
        if tags.mode != .sequential {
            SettingsChoiceRow(
                title: "Reshuffle",
                options: ChannelReshuffle.allCases.map { ($0, $0.title) },
                selection: Binding(
                    get: { tags.reshuffle },
                    set: { reshuffle in save(playlist, tags.with { $0.reshuffle = reshuffle }) }
                )
            )
            Button("Shuffle Again") {
                save(playlist, tags.with { $0.seed += 1 })
            }
        }
        Toggle("Playlist Picture as Logo", isOn: Binding(
            get: { tags.showsLogo },
            set: { on in save(playlist, tags.with { $0.showsLogo = on }) }
        ))
        Toggle("Logo in the Corner While Playing", isOn: Binding(
            get: { tags.showsBug },
            set: { on in save(playlist, tags.with { $0.showsBug = on }) }
        ))
        if tags.showsBug {
            SettingsChoiceRow(
                title: "Corner",
                options: BugCorner.allCases.map { ($0, $0.title) },
                selection: Binding(
                    get: { tags.bugCorner },
                    set: { corner in save(playlist, tags.with { $0.bugCorner = corner }) }
                )
            )
            SettingsChoiceRow(
                title: "Hide After",
                options: (Self.bugHideChoices + (Self.bugHideChoices.contains(tags.bugHideAfter) ? [] : [tags.bugHideAfter])).sorted().map { seconds in
                    (seconds, seconds == 0 ? "Never" : Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                },
                selection: Binding(
                    get: { tags.bugHideAfter },
                    set: { seconds in save(playlist, tags.with { $0.bugHideAfter = seconds }) }
                )
            )
            SettingsChoiceRow(
                title: "Logo Size",
                options: (Self.bugSizeChoices + (Self.bugSizeChoices.contains(tags.bugSize) ? [] : [tags.bugSize])).sorted().map { ($0, "\($0)%") },
                selection: Binding(
                    get: { tags.bugSize },
                    set: { size in save(playlist, tags.with { $0.bugSize = size }) }
                )
            )
        }
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

    /// Writes the playlist's tags with these channel settings, every one of
    /// them, keeping its other tags; the page shows the change at once, and
    /// the Channels tab picks it up. A channel numbered automatically keeps
    /// the number it has now, so later channels don't move it.
    private func save(_ playlist: BaseItem, _ tags: ChannelTags) {
        var tags = tags
        if tags.number == nil { tags.number = numbers[playlist.id] }
        guard canEdit, let client = session.client, let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
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

    private func load() async {
        guard let client = session.client else { return }
        do {
            playlists = try await client.playlists(mediaType: "Video")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loaded = true
    }
}

/// A channel's own name, saved when editing ends; empty goes back to the
/// playlist's name.
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

private struct TitlePageSettingsView: View {
    @AppStorage(AppSettings.themeMusicKey) private var themeMusic = false
    @AppStorage(AppSettings.themeVideosKey) private var themeVideos = false
    @AppStorage(AppSettings.openingSoundKey) private var openingSound = false

    var body: some View {
        SettingsPage(title: "Title Pages") {
            Section {
                Toggle("Theme music", isOn: $themeMusic)
                Toggle("Theme videos", isOn: $themeVideos)
                SettingsNote("Plays a title's theme song quietly, or loops its theme video behind the page, when your library has them. Theme music stays off while you are listening to music.")
            }
            Section("Anime") {
                Toggle("Opening plays with sound", isOn: $openingSound)
                    .disabled(!themeVideos)
                SettingsNote("Anime with no theme video of its own loops its first opening behind the series page, when Theme videos is on. With sound, it plays quietly, like theme music.")
            }
        }
    }
}

// MARK: - Tab Bar

#if os(iOS)
/// Which tabs show on iPhone and iPad, and in what order. The list is
/// always in edit mode, so each row can be dragged; the switch hides it.
private struct TabBarSettingsView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.tabOrderKey) private var tabOrder = ""
    @AppStorage(AppSettings.hiddenTabsKey) private var hiddenTabs = ""

    /// Every tab in its chosen order, less those this server has nothing for.
    private var tabs: [AppTab] {
        TabLayout.order(from: tabOrder).filter { session.hasContent(for: $0) }
    }

    var body: some View {
        let hidden = TabLayout.hidden(from: hiddenTabs)
        SettingsPage(title: "Tab Bar") {
            Section {
                ForEach(tabs, id: \.self) { tab in
                    Toggle(isOn: Binding(
                        get: { !hidden.contains(tab) },
                        set: { shown in
                            var updated = hidden
                            if shown { updated.remove(tab) } else { updated.insert(tab) }
                            hiddenTabs = TabLayout.encode(AppTab.allCases.filter(updated.contains))
                        }
                    )) {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .disabled(TabLayout.alwaysShown.contains(tab))
                }
                .onMove(perform: move)
            } footer: {
                SettingsNote(UIDevice.current.userInterfaceIdiom == .pad
                    ? "Drag to change the order, and switch tabs off to hide them. Home and Settings always show."
                    : "Drag to change the order, and switch tabs off to hide them. The tab bar holds four tabs; the rest are under More. Home and Settings always show.")
            }
            Section {
                Button("Reset to Default") {
                    tabOrder = ""
                    hiddenTabs = ""
                }
                .disabled(tabOrder.isEmpty && hiddenTabs.isEmpty)
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    /// Moves a tab within the list shown, keeping the place of any tab the
    /// server has nothing for (and so isn't listed) in the full order.
    private func move(from source: IndexSet, to destination: Int) {
        var shown = tabs
        shown.move(fromOffsets: source, toOffset: destination)
        var remaining = shown.makeIterator()
        let full = TabLayout.order(from: tabOrder).map { tab in
            session.hasContent(for: tab) ? (remaining.next() ?? tab) : tab
        }
        tabOrder = TabLayout.encode(full)
    }
}
#endif

// MARK: - Downloads

#if os(iOS)
/// Downloads on or off, then where and how they're saved.
private struct DownloadSettingsView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.downloadsEnabledKey) private var enabled = true
    @State private var confirmRemoveAll = false

    private let store = DownloadStore.shared

    var body: some View {
        SettingsPage(title: "Downloads") {
            Section {
                Toggle("Allow downloads", isOn: $enabled)
                SettingsNote(enabled
                    ? "Download movies and episodes from the ⋯ button on their page to watch without a connection. They're in the Downloads tab."
                    : "Download is hidden and the Downloads tab is gone. Titles already downloaded stay until you remove them.")
            }
            if enabled, !session.canDownload {
                Section {
                    SettingsNote("Your Jellyfin account isn't allowed to download media. The server's administrator can allow it in the user's settings, under Allow media downloading.")
                }
            }
            if enabled {
                DownloadOptionsSections()
            }
            if !store.records.isEmpty || !AudiobookDownloads.shared.records.isEmpty {
                Section {
                    Button("Remove All Downloads", role: .destructive) { confirmRemoveAll = true }
                }
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                store.removeAll()
                AudiobookDownloads.shared.removeAll()
            }
        } message: {
            Text("This frees \(DownloadStore.format(store.usedBytes + AudiobookDownloads.shared.usedBytes)) and stops any downloads in progress.")
        }
    }
}
#endif

// MARK: - Account

private struct AccountSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var serverInfo: PublicSystemInfo?

    var body: some View {
        SettingsPage(title: "Account") {
            Section("Server") {
                LabeledContent("Server", value: session.serverName ?? session.serverURL?.host() ?? "")
                LabeledContent("Address", value: session.serverURL?.absoluteString ?? "")
                if let version = serverInfo?.version {
                    LabeledContent("Jellyfin version", value: version)
                }
                Button("Change Server") { session.changeServer() }
            }
            Section("User") {
                LabeledContent("User", value: session.userName ?? "")
                Button("Switch User") { session.signOut() }
            }
        }
        .task {
            serverInfo = try? await session.client?.publicSystemInfo()
        }
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(title: "About") {
            // Focusable rows give the page somewhere for focus to land; with
            // nothing focused, tvOS never delivers the Back press to pop it.
            Section {
                LabeledContent("Aster Media Player", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .focusable()
                SettingsNote("A Jellyfin client for Apple TV, iPhone, iPad and Mac with DVD and Blu-ray style menus powered by the JellyDisc plugin.")
                    .focusable()
            }
        }
    }
}
