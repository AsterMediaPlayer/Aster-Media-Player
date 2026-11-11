//
//  MusicSettingsView.swift
//  AsterFIN
//
//  Settings ▸ Music and Settings ▸ Audiobooks.
//

import SwiftUI

/// Settings ▸ Music: the quality songs stream at, gapless playback, and
/// saving upcoming songs. Audiobooks follow the same quality.
struct MusicSettingsView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.musicMaxBitrateKey) private var musicMaxBitrate = 0
    #if os(iOS)
    @AppStorage(AppSettings.musicCellularMaxBitrateKey) private var musicCellularMaxBitrate = 0
    #endif
    @AppStorage(AppSettings.gaplessMusicKey) private var gaplessMusic = true
    @AppStorage(AppSettings.musicAheadModeKey) private var musicAheadMode: AppSettings.MusicAheadMode = .wifi

    var body: some View {
        SettingsPage(title: "Music") {
            Section {
                #if os(iOS)
                Picker("On Wi-Fi", selection: $musicMaxBitrate) {
                    ForEach(AppSettings.musicBitrateChoices, id: \.value) { Text($0.name).tag($0.value) }
                }
                Picker("On cellular", selection: $musicCellularMaxBitrate) {
                    ForEach(AppSettings.musicBitrateChoices, id: \.value) { Text($0.name).tag($0.value) }
                }
                #else
                Picker("Streaming quality", selection: $musicMaxBitrate) {
                    ForEach(AppSettings.musicBitrateChoices, id: \.value) { Text($0.name).tag($0.value) }
                }
                #endif
            } header: {
                Text("Quality")
            } footer: {
                #if os(iOS)
                SettingsNote("Original plays songs as they are, FLAC included. A lower choice has the server convert songs over it, which uses less data. Audiobooks and title pages' theme songs follow these too.")
                #else
                SettingsNote("Original plays songs as they are, FLAC included. A lower choice has the server convert songs over it. Audiobooks and title pages' theme songs follow it too.")
                #endif
            }
            Section {
                Toggle("Gapless playback", isOn: $gaplessMusic)
                    .onChange(of: gaplessMusic) { _, _ in session.music.musicSettingsChanged() }
            } footer: {
                SettingsNote("The next song loads while one plays, so an album or a mix runs on without a pause between tracks. It follows only a song in the same format (an album, usually); after one in another, or one the server converts, there's a short gap.")
            }
            Section {
                #if os(iOS)
                Picker("Save upcoming songs", selection: $musicAheadMode) {
                    Text("Off").tag(AppSettings.MusicAheadMode.off)
                    Text("On Wi-Fi").tag(AppSettings.MusicAheadMode.wifi)
                    Text("On Wi-Fi and cellular").tag(AppSettings.MusicAheadMode.always)
                }
                .onChange(of: musicAheadMode) { _, _ in session.music.musicSettingsChanged() }
                #else
                Toggle("Save upcoming songs", isOn: Binding(
                    get: { musicAheadMode != .off },
                    set: { musicAheadMode = $0 ? .wifi : .off }
                ))
                .onChange(of: musicAheadMode) { _, _ in session.music.musicSettingsChanged() }
                #endif
            } footer: {
                #if os(iOS)
                SettingsNote("The next five songs in the queue are saved as they come up, once the song playing is under way, so they start at once and play on if the connection drops. On Wi-Fi saves only on Wi-Fi or a wired connection; with unlimited data, choose Wi-Fi and cellular. Nothing is saved in Low Data Mode. They're kept in the cache, and let go once heard.")
                #else
                SettingsNote("The next five songs in the queue are saved as they come up, once the song playing is under way, so they start at once and play on if the connection drops. Nothing is saved on a Personal Hotspot or in Low Data Mode. They're kept in the cache, and let go once heard.")
                #endif
            }
        }
        .onAppear {
            if !AppSettings.musicBitrateChoices.contains(where: { $0.value == musicMaxBitrate }) { musicMaxBitrate = 0 }
            #if os(iOS)
            if !AppSettings.musicBitrateChoices.contains(where: { $0.value == musicCellularMaxBitrate }) { musicCellularMaxBitrate = 0 }
            #endif
        }
    }
}

#if os(iOS)
/// Settings ▸ Audiobooks: Listen Ahead. Their quality follows Music's.
struct AudiobookSettingsView: View {
    @AppStorage(AppSettings.listenAheadKey) private var listenAhead = 30

    var body: some View {
        SettingsPage(title: "Audiobooks") {
            Section {
                Picker("Listen Ahead", selection: $listenAhead) {
                    Text("Off").tag(0)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
            } footer: {
                SettingsNote("Saves what's coming up in an audiobook as it plays, so it carries on through a spot with no signal. It's kept in the cache, and let go once heard. Downloaded books don't need it.")
            }
            Section {
                SettingsCategory.music.link
            } footer: {
                SettingsNote("Audiobooks stream at the quality chosen for music.")
            }
        }
    }
}
#endif
