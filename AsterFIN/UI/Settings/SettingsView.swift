//
//  SettingsView.swift
//  AsterFIN
//

import SwiftUI

/// The pages the Settings root opens.
private enum SettingsDestination: Hashable {
    case playback, audioSubtitles, discMenus, titlePages, channels, serverPlugins, tabBar, downloads, account, about
    /// A saved server's page under Account, and its Lock After choices, by
    /// the server's id. Registered here at the root with the others: pages
    /// registered further in froze Apple TV when they opened one more.
    case savedServer(String), lockAfter(String)
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
                // Disc menus come from a Jellyfin plugin, and Channels from
                // playlist tags in Jellyfin's shape: neither on Emby yet.
                if session.isJellyfin {
                    NavigationLink(value: SettingsDestination.discMenus) {
                        Label("Disc Menus", systemImage: "opticaldisc")
                    }
                }
                NavigationLink(value: SettingsDestination.titlePages) {
                    Label("Title Pages", systemImage: "music.note.tv")
                }
                if session.isJellyfin {
                    NavigationLink(value: SettingsDestination.channels) {
                        Label("Channels", systemImage: "tv.and.mediabox")
                    }
                    NavigationLink(value: SettingsDestination.serverPlugins) {
                        Label("Server Plugins", systemImage: "puzzlepiece.extension")
                    }
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
            case .serverPlugins: ServerPluginsSettingsView()
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
            case .savedServer(let id): SavedServerPage(serverID: id)
            case .lockAfter(let id): LockAfterPage(serverID: id)
            }
        }
        .openSourceDestinations()
        // Settings that follow the user come from their server on opening.
        .task {
            if let client = session.jellyfin { await SettingsSync.pull(client: client) }
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
                .tabItem { Label("Channels", systemImage: "tv.and.mediabox") }
            if session.isJellyfin {
                ServerPluginsSettingsView()
                    .tabItem { Label("Server Plugins", systemImage: "puzzlepiece.extension") }
            }
            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            // A stack of its own, for Open Source & Licenses and its pages.
            NavigationStack {
                AboutSettingsView()
                    .openSourceDestinations()
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Wide enough for every pane's tab in the bar (eight on Jellyfin);
        // at 560 the last ones fell off the end.
        .frame(width: 720)
        .frame(minHeight: 380)
        .task {
            if let client = session.jellyfin { await SettingsSync.pull(client: client) }
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

/// Aster's companion plugins on the server: the welcome screen's switches,
/// any time.
private struct ServerPluginsSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var model = ServerPluginsModel()

    var body: some View {
        SettingsPage(title: "Server Plugins") {
            Section {
                if model.isAdministrator == nil {
                    ProgressView()
                } else {
                    ForEach(AsterPlugin.allCases) { plugin in
                        ServerPluginRow(plugin: plugin, model: model)
                    }
                }
            } footer: {
                if model.isAdministrator == true {
                    SettingsNote("Free plugins for Jellyfin that add more to Aster. Switching one on installs it on your server; off turns it off and keeps its settings. Either takes a server restart.")
                }
            }
            if model.isAdministrator == true, model.needsRestart || model.restart != .idle || model.errorMessage != nil {
                Section {
                    ServerRestartControls(model: model)
                    if let error = model.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section {
                AuroraNote()
                if model.isAdministrator == false {
                    AskYourAdministratorNote()
                }
            }
            Section {
                Button("Show Welcome Screen") {
                    session.showWelcomeAgain()
                }
            }
        }
        .task { await model.load(session) }
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

/// A row showing the choices made from a list, which opens a page of them to
/// tick; each tick is applied as it's made. `none` names choosing nothing.
private struct SettingsMultiChoiceRow: View {
    let title: String
    let options: [String]
    let selection: [String]
    var none = "None"
    var apply: ([String]) -> Void

    private var summary: String {
        selection.isEmpty ? none : selection.joined(separator: ", ")
    }

    var body: some View {
        #if os(macOS)
        Menu {
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { selection.contains { $0.caseInsensitiveCompare(option) == .orderedSame } },
                    set: { on in apply(SettingsMultiChoicePage.toggled(option, on: on, in: selection, order: options)) }
                ))
            }
        } label: {
            LabeledContent(title, value: summary)
        }
        #else
        NavigationLink {
            SettingsMultiChoicePage(title: title, options: options, selection: selection, apply: apply)
        } label: {
            LabeledContent(title) {
                Text(summary).lineLimit(1)
            }
        }
        #endif
    }
}

/// The page of choices to tick; it stays open, each tick applied at once.
private struct SettingsMultiChoicePage: View {
    let title: String
    let options: [String]
    var apply: ([String]) -> Void
    @State private var current: [String]

    init(title: String, options: [String], selection: [String], apply: @escaping ([String]) -> Void) {
        self.title = title
        self.options = options
        self.apply = apply
        _current = State(initialValue: selection)
    }

    var body: some View {
        SettingsPage(title: title) {
            Section {
                ForEach(options, id: \.self) { option in
                    let isOn = current.contains { $0.caseInsensitiveCompare(option) == .orderedSame }
                    Button {
                        current = Self.toggled(option, on: !isOn, in: current, order: options)
                        apply(current)
                    } label: {
                        HStack {
                            Text(option)
                            Spacer()
                            if isOn { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        }
    }

    /// `selection` with `option` ticked or not, kept in `order`.
    static func toggled(_ option: String, on: Bool, in selection: [String], order: [String]) -> [String] {
        var chosen = selection.filter { $0.caseInsensitiveCompare(option) != .orderedSame }
        if on { chosen.append(option) }
        let rank = Dictionary(order.enumerated().map { ($1.lowercased(), $0) }) { first, _ in first }
        return chosen.sorted { (rank[$0.lowercased()] ?? .max) < (rank[$1.lowercased()] ?? .max) }
    }
}

// MARK: - Playback

private struct PlaybackSettingsView: View {
    private var chosenMusicVideoLibraries: [String] {
        animeMusicVideoLibraries.split(separator: "\n").map(String.init)
    }

    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.animeMusicVideoLibrariesKey) private var animeMusicVideoLibraries = ""
    @AppStorage(AppSettings.maxBitrateKey) private var maxBitrate = 120_000_000
    @AppStorage(AppSettings.cellularMaxBitrateKey) private var cellularMaxBitrate = AppSettings.defaultCellularMaxBitrate
    @AppStorage(AppSettings.autoplayNextKey) private var autoplayNext = true
    @AppStorage(AppSettings.autoSkipIntroKey) private var autoSkipIntro = false
    @AppStorage(AppSettings.themeCardsKey) private var themeCards = true
    @AppStorage(AppSettings.themePanelKey) private var themePanel = true
    @AppStorage(AppSettings.themeCutKey) private var themeCut: ThemeCut = .tvSize
    @AppStorage(AppSettings.useSystemPlayerKey) private var useSystemPlayer = false
    #if os(iOS)
    @AppStorage(AppSettings.listenAheadKey) private var listenAhead = 30
    #endif
    #if os(macOS)
    @AppStorage(AppSettings.fullScreenPlaybackKey) private var fullScreenPlayback = true
    @AppStorage(AppSettings.sidecarHintKey) private var sidecarHint = true
    #endif

    private let bitrates: [(String, Int)] = [
        ("Auto (120 Mbps)", 120_000_000),
        ("60 Mbps", 60_000_000),
        ("40 Mbps", 40_000_000),
        ("20 Mbps", 20_000_000),
        ("10 Mbps", 10_000_000),
        ("4 Mbps", 4_000_000),
    ]

    /// Lower choices for cellular data; 0 is the same as on Wi-Fi.
    private let cellularBitrates: [(String, Int)] = [
        ("Same as Wi-Fi", 0),
        ("20 Mbps", 20_000_000),
        ("10 Mbps", 10_000_000),
        ("8 Mbps", 8_000_000),
        ("4 Mbps", 4_000_000),
        ("2 Mbps", 2_000_000),
        ("1 Mbps", 1_000_000),
    ]

    var body: some View {
        SettingsPage(title: "Playback") {
            #if os(iOS)
            Section {
                Picker("On Wi-Fi", selection: $maxBitrate) {
                    ForEach(bitrates, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                Picker("On cellular", selection: $cellularMaxBitrate) {
                    ForEach(cellularBitrates, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
            } header: {
                Text("Maximum Streaming Quality")
            } footer: {
                SettingsNote("On cellular data, or a Personal Hotspot, videos, music and audiobooks stream at no more than the cellular choice, so they use less data. Downloads aren't affected.")
            }
            #else
            Section("Streaming") {
                Picker("Maximum streaming quality", selection: $maxBitrate) {
                    ForEach(bitrates, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
            }
            #endif
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
                Toggle("Show the two-finger scroll tip on an iPad display", isOn: $sidecarHint)
                SettingsNote("On an iPad used as a display (Sidecar), one finger doesn't move the page; two do. The tip shows once each time the app opens there, until you've scrolled that way.")
            }
            #endif
            Section("Episodes") {
                Toggle("Autoplay next episode", isOn: $autoplayNext)
                Toggle("Skip intros automatically", isOn: $autoSkipIntro)
                SettingsNote("Skip Intro and Skip Credits need markers on the server, from the Intro Skipper plugin or chapter markers.")
            }
            Section("Anime") {
                Toggle("Song card at openings and endings", isOn: $themeCards)
                SettingsNote("As an episode's opening or ending starts, and again as it finishes, the song and artist show in the corner, like a music channel. Found from the episode's OP and ED chapters, with the song named by the OP/ED plugin when the server has it. Music videos get the card too, as they start and end.")
                Toggle("Now Playing panel", isOn: $themePanel)
                    .onChange(of: themePanel) { _, on in
                        if !on { session.themeDeck.stop() }
                    }
                SettingsNote("Openings and endings picked on a show's Music tab play in a panel beside the page, and keep playing in a small one while you browse. Off, they play full screen, one at a time.")
                // Not a Picker: its pushed list hangs on tvOS on a pushed page.
                SettingsChoiceRow(
                    title: "Version to play",
                    options: ThemeCut.allCases.map { ($0, $0.settingTitle) },
                    selection: $themeCut
                )
                SettingsNote("Where the server has it, a show's Music tab plays this version of each song: the TV size, the full-length song (an OP1-Full file beside OP1 in the OP/ED plugin's folder) or its music video (OP1-MV). A song without it plays the nearest it has: a music video falls back to the full version, then the TV size. Hold a song's card to play another. Watch OP and the opening behind a show's page always use the TV size.")
                // Every music video library but the OP/ED plugin's, which
                // the Anime tab always shows.
                let choices = session.musicVideoLibraries.filter { library in
                    !session.animeMusicVideoLibraries.contains { $0.id == library.id } || chosenMusicVideoLibraries.contains(library.displayTitle)
                }.map(\.displayTitle)
                if !choices.isEmpty {
                    SettingsMultiChoiceRow(title: "Music Videos in Anime", options: choices, selection: chosenMusicVideoLibraries) { picked in
                        animeMusicVideoLibraries = picked.joined(separator: "\n")
                        session.updateAnimeMusicVideoLibraries()
                    }
                    SettingsNote("Music video libraries, such as your AMVs, that get a shelf in the Anime tab. The OP/ED plugin's Openings & Endings library is always there.")
                }
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

private struct TitlePageSettingsView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.themeMusicKey) private var themeMusic = false
    @AppStorage(AppSettings.themeVideosKey) private var themeVideos = false
    @AppStorage(AppSettings.openingSoundKey) private var openingSound = false
    @AppStorage(AppSettings.songLookupsKey) private var songLookups = true
    /// Kept in the Keychain, not in settings.
    @State private var mdbListKey = ""

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
                Toggle("Look up song names", isOn: $songLookups)
                    .onChange(of: songLookups) { _, on in
                        if on, let client = session.client { SongWarmer.shared.warmInBackground(client: client) }
                    }
                SettingsNote("Without the OP/ED plugin, the songs of a show's openings and endings are asked of AnimeThemes (animethemes.moe): in the background for every show in your anime libraries, and kept on this device so a show is looked up once. Off, Aster doesn't contact AnimeThemes, and clips are named by their season.")
                HStack {
                    Button("Refresh Songs") {
                        Task { _ = await SongWarmer.shared.refreshSongs() }
                    }
                    .disabled(!songLookups || SongWarmer.shared.refresh == .refreshing)
                    Spacer()
                    switch SongWarmer.shared.refresh {
                    case .idle: EmptyView()
                    case .refreshing: Text("Refreshing…").foregroundStyle(.secondary)
                    case .done: Text("Done").foregroundStyle(.secondary)
                    case .failed: Text("Couldn't reach AnimeThemes").foregroundStyle(.secondary)
                    }
                }
                SettingsNote("Forgets what's kept for this server and asks AnimeThemes again for every show, for songs it has named since.")
            }
            Section("Ratings") {
                SecureField("MDBList API key", text: $mdbListKey)
                    .textContentType(.password)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit { MDBList.apiKey = mdbListKey }
                    .onChange(of: mdbListKey) { _, key in MDBList.apiKey = key }
                SettingsNote(mdbListKey.isEmpty
                    ? "Title pages show the scores your server has. With a free MDBList key (from mdblist.com, under Preferences › API Access), films and shows also get IMDb, Rotten Tomatoes (critics and audience), Metacritic, Letterboxd and TMDB scores. The key stays on this device."
                    : "Films and shows get IMDb, Rotten Tomatoes, Metacritic, Letterboxd and TMDB scores from MDBList. Clear the key to stop asking it.")
            }
        }
        .onAppear { mdbListKey = MDBList.apiKey ?? "" }
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
                if let serverInfo, let version = serverInfo.version {
                    // Which server it is comes from the same reply.
                    LabeledContent("\(serverInfo.kind.displayName) version", value: version)
                }
            }
            Section("User") {
                LabeledContent("User", value: session.userName ?? "")
                Button("Switch User") { session.signOut() }
            }
            Section {
                ForEach(session.savedServers) { server in
                    NavigationLink(value: SettingsDestination.savedServer(server.id)) {
                        SavedServerLabel(server: server, isCurrent: server.id == session.currentServerID)
                    }
                }
                Button("Add Server") { session.changeServer() }
            } header: {
                Text("Servers")
            } footer: {
                SettingsNote("Servers you've signed in to stay signed in, to switch between. Add one to sign in to another Jellyfin or Emby server.")
            }
        }
        .task {
            serverInfo = try? await session.jellyfin?.publicSystemInfo()
        }
    }
}

/// One saved server: switch to it, ask for its password first, or forget it.
/// It reads the server from the saved list by id, so its settings show as
/// they change here.
private struct SavedServerPage: View {
    let serverID: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var switchRequest: SavedServer?
    @State private var credentialRequest: ServerCredentialRequest?
    @State private var signingInToPlex = false
    @State private var showsOnTopShelf = true
    @State private var confirmingRemoval = false

    var body: some View {
        if let server = session.savedServers.first(where: { $0.id == serverID }) {
            content(server)
                .onAppear { showsOnTopShelf = TopShelfServers.isShown(serverID) }
        }
    }

    private var isInUse: Bool { serverID == session.currentServerID }

    /// "Never", "5 Minutes", "1 Hour", "4 Hours".
    static func lockTitle(_ minutes: Int) -> String {
        guard minutes > 0 else { return "Never" }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide)).capitalized
    }

    private func content(_ server: SavedServer) -> some View {
        SettingsPage(title: server.session.serverName ?? "Server") {
            Section {
                LabeledContent("Server", value: server.session.kind.displayName)
                LabeledContent("Address", value: server.session.serverURL.absoluteString)
                LabeledContent("User", value: server.session.userName)
            }
            Section {
                if isInUse {
                    SettingsNote("This is the server in use.")
                } else {
                    Button("Switch to This Server") { switchRequest = server }
                }
                if server.canBeLocked {
                    Toggle("Ask for \(server.credentialName.capitalized) to Switch", isOn: Binding(
                        get: { server.asksPasswordToSwitch },
                        set: { asks in
                            // Turning it off asks for the credential, so nobody else can.
                            guard server.loosens(asksToSwitch: asks) else {
                                session.setAsksPasswordToSwitch(asks, for: serverID)
                                return
                            }
                            credentialRequest = ServerCredentialRequest(
                                server: server, purpose: "stop asking for it to switch", buttonTitle: "Turn Off"
                            ) { session.setAsksPasswordToSwitch(false, for: serverID) }
                        }
                    ))
                }
            } footer: {
                if server.canBeLocked {
                    SettingsNote(server.session.kind == .plex
                        ? "Switching to this server asks for \(server.session.userName)'s Plex Home PIN first, checked by plex.tv, so others on this device can't switch to it."
                        : "Switching to this server asks for \(server.session.userName)'s password first, checked by the server, so others on this device can't switch to it.")
                } else {
                    SettingsNote("Locking asks for \(server.session.userName)'s Plex Home PIN. Sign in with Plex again to lock this server (a profile without a PIN needs one added in Plex under Settings ▸ Plex Home first).")
                }
            }
            // A sign-in from before PINs could be checked: sign in afresh.
            // (Also the page's one control then, so the remote can leave it.)
            if server.session.kind == .plex, !server.canBeLocked {
                Section {
                    Button("Sign In with Plex Again") { signingInToPlex = true }
                }
            }
            if server.canBeLocked {
                Section {
                    #if os(macOS)
                    SettingsChoiceRow(
                        title: "Lock After",
                        options: [(0, "Never")] + SavedServer.lockChoices.map { ($0, Self.lockTitle($0)) },
                        selection: Binding(
                            get: { server.lockAfterMinutes ?? 0 },
                            set: { choice in
                                let minutes = choice > 0 ? choice : nil
                                guard server.loosens(lockAfter: minutes) else {
                                    session.setLockAfter(minutes, for: serverID)
                                    return
                                }
                                credentialRequest = ServerCredentialRequest(
                                    server: server, purpose: "change when it locks", buttonTitle: "Change"
                                ) { session.setLockAfter(minutes, for: serverID) }
                            }
                        )
                    )
                    #else
                    // Its page goes on the path by value, like this one.
                    NavigationLink(value: SettingsDestination.lockAfter(serverID)) {
                        LabeledContent("Lock After", value: Self.lockTitle(server.lockAfterMinutes ?? 0))
                    }
                    #endif
                } footer: {
                    SettingsNote("After this long away from Aster, coming back to this server asks for \(server.session.userName)'s \(server.credentialName).")
                }
            }
            #if os(tvOS)
            // The Top Shelf reads Jellyfin and Emby only, so Plex has nothing to turn off.
            if server.session.kind != .plex {
                Section {
                    Toggle("Show on Top Shelf", isOn: Binding(
                        get: { showsOnTopShelf },
                        set: {
                            showsOnTopShelf = $0
                            TopShelfServers.setShown($0, for: serverID)
                        }
                    ))
                } footer: {
                    SettingsNote("While this server is in use, the Top Shelf shows its Continue Watching, Next Up and channels. Turn it off to keep them off the Home Screen.")
                }
            }
            #endif
            Section {
                Button("Remove Server", role: .destructive) {
                    if isInUse {
                        confirmingRemoval = true
                    } else {
                        session.removeServer(serverID)
                        dismiss()
                    }
                }
            } footer: {
                if isInUse {
                    SettingsNote("This is the server in use: removing it signs you out, and Aster goes back to adding a server.")
                }
            }
        }
        .confirmationDialog("Remove this server?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove and Sign Out", role: .destructive) {
                session.removeCurrentServer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be signed out of \(server.session.serverName ?? "it"), and can add a server again.")
        }
        .savedServerSwitcher(request: $switchRequest)
        .serverCredentialCheck(request: $credentialRequest)
        #if os(macOS)
        .sheet(isPresented: $signingInToPlex) {
            PlexSignInView()
                .frame(minWidth: 520, minHeight: 560)
        }
        #else
        .fullScreenCover(isPresented: $signingInToPlex) {
            PlexSignInView()
        }
        #endif
    }
}

/// A saved server's Lock After choices: picking one saves it and goes back.
private struct LockAfterPage: View {
    let serverID: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var credentialRequest: ServerCredentialRequest?

    var body: some View {
        let server = session.savedServers.first { $0.id == serverID }
        let chosen = server?.lockAfterMinutes ?? 0
        SettingsPage(title: "Lock After") {
            Section {
                ForEach([0] + SavedServer.lockChoices, id: \.self) { minutes in
                    Button {
                        let choice = minutes > 0 ? minutes : nil
                        // Never, or a longer wait, asks for the credential first.
                        if let server, server.loosens(lockAfter: choice) {
                            credentialRequest = ServerCredentialRequest(
                                server: server, purpose: "change when it locks", buttonTitle: "Change"
                            ) {
                                session.setLockAfter(choice, for: serverID)
                                dismiss()
                            }
                        } else {
                            session.setLockAfter(choice, for: serverID)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Text(SavedServerPage.lockTitle(minutes))
                            Spacer()
                            if minutes == chosen {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
        .serverCredentialCheck(request: $credentialRequest)
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
                SettingsNote("A Jellyfin, Emby and Plex client for Apple TV, iPhone, iPad and Mac, with DVD and Blu-ray style menus on Jellyfin from the Aster Disc plugin.")
                    .focusable()
            }
            Section {
                AboutLink(title: "Help & Support", systemImage: "questionmark.circle", address: AboutLink.support)
                AboutLink(title: "Privacy Policy", systemImage: "hand.raised", address: AboutLink.privacy)
                NavigationLink(value: OpenSourceRoute.list) {
                    Label("Open Source & Licenses", systemImage: "doc.text")
                }
            }
        }
    }
}

/// One of Aster's web pages: a link where there's a browser, and the address
/// to type in on Apple TV, which has none.
private struct AboutLink: View {
    static let support = "https://astermediaplayer.com/support.html"
    static let privacy = "https://astermediaplayer.com/privacy.html"

    let title: String
    let systemImage: String
    let address: String

    var body: some View {
        #if os(tvOS)
        LabeledContent {
            Text(address.replacingOccurrences(of: "https://", with: ""))
        } label: {
            Label(title, systemImage: systemImage)
        }
        .focusable()
        #else
        if let url = URL(string: address) {
            Link(destination: url) {
                Label(title, systemImage: systemImage)
            }
        }
        #endif
    }
}
