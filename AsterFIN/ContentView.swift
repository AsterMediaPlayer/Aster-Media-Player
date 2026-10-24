//
//  ContentView.swift
//  AsterFIN
//
//  Routes between onboarding and the main app depending on the session.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                ProgressView()
            case .needsServer:
                ServerConnectView()
            case .needsUser:
                SignInView()
            case .signedIn:
                if session.isLocked, let server = session.currentServer {
                    // Away past the server's lock-after: its password first.
                    ServerLockView(server: server)
                } else {
                    // A switched server gets a fresh main screen: its own
                    // tabs, libraries and pages.
                    MainTabView()
                        .id(session.serverGeneration)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.phase)
        .animation(.easeInOut(duration: 0.3), value: session.isLocked)
        // Leaving starts the lock's clock; coming back (or opening) checks it.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: session.noteLeftApp()
            case .active: session.checkLock()
            default: break
            }
        }
        // macOS draws full-screen presentations (the player...) from here.
        .appCoverHost()
    }
}

#Preview {
    ContentView()
        .environment(AppSession())
}
