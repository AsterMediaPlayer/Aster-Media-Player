//
//  SettingsView.swift
//  AsterFIN
//

import SwiftUI

/// The pages the Settings root opens.
private enum SettingsDestination: Hashable {
    case playback, audioSubtitles, discMenus, titlePages, tabBar, account, about
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
                #if !os(tvOS)
                NavigationLink(value: SettingsDestination.tabBar) {
                    Label("Tab Bar", systemImage: "rectangle.bottomhalf.inset.filled")
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
            case .tabBar:
                #if os(tvOS)
                EmptyView()
                #else
                TabBarSettingsView()
                #endif
            case .account: AccountSettingsView()
            case .about: AboutSettingsView()
            }
        }
    }
}

/// A settings form with the large page title as its first row, like the
/// in-page titles elsewhere. (A navigation bar title would add a second bar
/// under iPhone's More tab.)
private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form {
            Section {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
            }
            content()
        }
    }
}

/// What to call this device in settings notes: "Apple TV", "iPhone" or "iPad".
private var deviceName: String {
    #if os(tvOS)
    "Apple TV"
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
        NavigationLink {
            SettingsChoicePage(title: title, options: options, selection: selection)
        } label: {
            LabeledContent(title, value: options.first { $0.value == selection.wrappedValue }?.name ?? "")
        }
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
            Section("Episodes") {
                Toggle("Autoplay next episode", isOn: $autoplayNext)
                Toggle("Skip intros automatically", isOn: $autoSkipIntro)
                SettingsNote("Skip Intro and Skip Credits need markers on the server, from the Intro Skipper plugin or chapter markers.")
            }
        }
    }
}

// MARK: - Audio & Subtitles

private struct AudioSubtitleSettingsView: View {
    @Environment(AppSession.self) private var session

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

#if !os(tvOS)
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
                LabeledContent("AsterFIN", value: "1.0")
                    .focusable()
                SettingsNote("A Jellyfin client for Apple TV, iPhone and iPad with DVD and Blu-ray style menus powered by the JellyDisc plugin.")
                    .focusable()
            }
        }
    }
}
