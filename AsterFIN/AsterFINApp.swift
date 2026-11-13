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
        CrashReports.start()
        DebugLog.note("app", "Opened")
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
                #if os(macOS)
                .macWindowTypography()
                #endif
        }
        #if os(macOS)
        // View › Show/Hide Sidebar (⌃⌘S), from any page.
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button(MacSidebarState.shared.isShown ? "Hide Sidebar" : "Show Sidebar") {
                    MacSidebarState.shared.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
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
        .backgroundTask(.urlSession(AudiobookDownloads.wifiSessionID)) {
            await AudiobookDownloads.shared.waitForBackgroundEvents()
        }
        .backgroundTask(.urlSession(AudiobookDownloads.cellularSessionID)) {
            await AudiobookDownloads.shared.waitForBackgroundEvents()
        }
        #endif
        #if os(macOS)
        // Aster › Settings… (⌘,).
        Settings {
            MacSettingsView()
                .environment(session)
                .preferredColorScheme(.dark)
                .macWindowTypography()
        }
        #endif
    }
}
