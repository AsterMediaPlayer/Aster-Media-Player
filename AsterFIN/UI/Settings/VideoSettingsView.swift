//
//  VideoSettingsView.swift
//  AsterFIN
//
//  Settings ▸ Video, and the pages under it: Audio & Subtitles and Disc
//  Menus.
//

import SwiftUI

// MARK: - Video

/// Settings ▸ Video: episodes and the player; Audio & Subtitles and Disc
/// Menus open from here (on the Mac they're under Video in the sidebar).
struct VideoSettingsView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.autoplayNextKey) private var autoplayNext = true
    @AppStorage(AppSettings.autoSkipIntroKey) private var autoSkipIntro = false
    @AppStorage(AppSettings.useSystemPlayerKey) private var useSystemPlayer = false
    #if os(macOS)
    @AppStorage(AppSettings.fullScreenPlaybackKey) private var fullScreenPlayback = true
    #endif

    var body: some View {
        SettingsPage(title: "Video") {
            #if !os(macOS)
            Section {
                SettingsCategory.audioSubtitles.link
                if SettingsCategory.discMenus.isAvailable(isJellyfin: session.isJellyfin) {
                    SettingsCategory.discMenus.link
                }
            }
            #endif
            Section("Episodes") {
                Toggle("Autoplay next episode", isOn: $autoplayNext)
                Toggle("Skip intros automatically", isOn: $autoSkipIntro)
                SettingsNote("Skip Intro and Skip Credits need markers on the server, from the Intro Skipper plugin or chapter markers.")
            }
            #if os(macOS)
            Section("Window") {
                Toggle("Play videos full screen", isOn: $fullScreenPlayback)
                SettingsNote("A video takes the whole screen as it starts, and the window comes back as it closes. Off, it plays inside the window.")
            }
            #endif
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

struct AudioSubtitleSettingsView: View {
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

struct DiscMenuSettingsView: View {
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
