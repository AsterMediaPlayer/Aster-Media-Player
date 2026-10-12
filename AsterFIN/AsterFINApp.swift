//
//  AsterFINApp.swift
//  AsterFIN
//
//  Created by Phillip Berryman on 10/9/26.
//

import SwiftUI
import AVFoundation

@main
struct AsterFINApp: App {
    @State private var session = AppSession.shared

    init() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    session.router.handle(url)
                }
        }
        #if os(macOS)
        // View › Show/Hide Sidebar (⌃⌘S), from any page. A two-finger swipe
        // only reveals the sidebar at a tab's top page; elsewhere it goes back.
        .commands {
            SidebarCommands()
        }
        #endif
        #if os(iOS)
        // Downloads finish in the background; the system relaunches the app
        // to hand over their results.
        .backgroundTask(.urlSession(DownloadStore.wifiSessionID)) {
            await DownloadStore.shared.waitForBackgroundEvents()
        }
        .backgroundTask(.urlSession(DownloadStore.cellularSessionID)) {
            await DownloadStore.shared.waitForBackgroundEvents()
        }
        #endif
        #if os(macOS)
        // AsterFIN › Settings… (⌘,).
        Settings {
            MacSettingsView()
                .environment(session)
                .preferredColorScheme(.dark)
        }
        #endif
    }
}
