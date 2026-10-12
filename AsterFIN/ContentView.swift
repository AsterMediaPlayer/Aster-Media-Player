//
//  ContentView.swift
//  AsterFIN
//
//  Routes between onboarding and the main app depending on the session.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppSession.self) private var session

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
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.phase)
        // macOS draws full-screen presentations (the player...) from here.
        .appCoverHost()
    }
}

#Preview {
    ContentView()
        .environment(AppSession())
}
