//
//  AnimeSettingsView.swift
//  AsterFIN
//
//  Settings ▸ Anime.
//

import SwiftUI

/// Settings ▸ Anime: everything anime in one place: the song card and Now
/// Playing panel, which version a show's Music tab plays, the music video
/// libraries in the Anime tab, the opening behind a show's page, and song
/// names from AnimeThemes.
struct AnimeSettingsView: View {
    private var chosenMusicVideoLibraries: [String] {
        animeMusicVideoLibraries.split(separator: "\n").map(String.init)
    }

    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.animeMusicVideoLibrariesKey) private var animeMusicVideoLibraries = ""
    @AppStorage(AppSettings.themeCardsKey) private var themeCards = true
    @AppStorage(AppSettings.themePanelKey) private var themePanel = true
    @AppStorage(AppSettings.themeCutKey) private var themeCut: ThemeCut = .tvSize
    @AppStorage(AppSettings.themeVideosKey) private var themeVideos = false
    @AppStorage(AppSettings.openingSoundKey) private var openingSound = false
    @AppStorage(AppSettings.songLookupsKey) private var songLookups = true

    var body: some View {
        SettingsPage(title: "Anime") {
            Section("Openings and Endings") {
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
            }
            Section("Show Pages") {
                Toggle("Opening plays with sound", isOn: $openingSound)
                    .disabled(!themeVideos)
                SettingsNote("Anime with no theme video of its own loops its first opening behind the series page, when Theme videos is on in Title Pages. With sound, it plays quietly, like theme music.")
            }
            Section("Song Names") {
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
            // Every music video library but the OP/ED plugin's, which the
            // Anime tab always shows.
            let choices = session.musicVideoLibraries.filter { library in
                !session.animeMusicVideoLibraries.contains { $0.id == library.id } || chosenMusicVideoLibraries.contains(library.displayTitle)
            }.map(\.displayTitle)
            if !choices.isEmpty {
                Section("Anime Tab") {
                    SettingsMultiChoiceRow(title: "Music Videos in Anime", options: choices, selection: chosenMusicVideoLibraries) { picked in
                        animeMusicVideoLibraries = picked.joined(separator: "\n")
                        session.updateAnimeMusicVideoLibraries()
                    }
                    SettingsNote("Music video libraries, such as your AMVs, that get a shelf in the Anime tab. The OP/ED plugin's Openings & Endings library is always there.")
                }
            }
        }
    }
}
