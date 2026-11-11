//
//  StreamingSettingsView.swift
//  AsterFIN
//
//  Settings ▸ Streaming & Data: video's streaming quality.
//

import SwiftUI

/// Settings ▸ Streaming & Data: how high a quality videos stream at. Music
/// and audiobooks have their own, under Music.
struct StreamingSettingsView: View {
    @AppStorage(AppSettings.maxBitrateKey) private var maxBitrate = 120_000_000
    #if os(iOS)
    @AppStorage(AppSettings.cellularMaxBitrateKey) private var cellularMaxBitrate = AppSettings.defaultCellularMaxBitrate
    #endif

    var body: some View {
        SettingsPage(title: "Streaming & Data") {
            Section {
                #if os(iOS)
                Picker("On Wi-Fi", selection: $maxBitrate) {
                    ForEach(AppSettings.videoBitrateChoices, id: \.value) { Text($0.name).tag($0.value) }
                }
                Picker("On cellular", selection: $cellularMaxBitrate) {
                    ForEach(AppSettings.cellularVideoBitrateChoices, id: \.value) { Text($0.name).tag($0.value) }
                }
                #else
                Picker("Maximum streaming quality", selection: $maxBitrate) {
                    ForEach(AppSettings.videoBitrateChoices, id: \.value) { Text($0.name).tag($0.value) }
                }
                #endif
            } header: {
                Text("Video Quality")
            } footer: {
                #if os(iOS)
                SettingsNote("Videos and Live TV stream at no more than this, converted down by the server when a file is over it. On cellular data, or a Personal Hotspot, the cellular choice applies, so they use less data. Downloads have their own quality. Music and audiobooks have their own, under Music.")
                #else
                SettingsNote("Videos and Live TV stream at no more than this, converted down by the server when a file is over it. Music and audiobooks have their own quality, under Music.")
                #endif
            }
        }
        // A choice from an older version that's no longer offered (it showed
        // as nothing chosen) goes back to the default, as it's played.
        .onAppear {
            if !AppSettings.videoBitrateChoices.contains(where: { $0.value == maxBitrate }) { maxBitrate = 120_000_000 }
            #if os(iOS)
            if !AppSettings.cellularVideoBitrateChoices.contains(where: { $0.value == cellularMaxBitrate }) {
                cellularMaxBitrate = AppSettings.defaultCellularMaxBitrate
            }
            #endif
        }
    }
}
