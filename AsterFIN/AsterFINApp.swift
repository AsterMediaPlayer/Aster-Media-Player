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
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
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
        #if !os(tvOS)
        // Downloads finish in the background; the system relaunches the app
        // to hand over their results.
        .backgroundTask(.urlSession(DownloadStore.wifiSessionID)) {
            await DownloadStore.shared.waitForBackgroundEvents()
        }
        .backgroundTask(.urlSession(DownloadStore.cellularSessionID)) {
            await DownloadStore.shared.waitForBackgroundEvents()
        }
        #endif
    }
}
