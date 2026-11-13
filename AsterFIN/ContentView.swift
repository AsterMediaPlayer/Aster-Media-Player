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
                    if session.profilePicker == .locked {
                        // Someone else at the lock: their own profile.
                        ProfilePickerView(reason: .locked)
                    } else {
                        // Away past the server's lock-after: its password first.
                        ServerLockView(server: server)
                    }
                } else if session.profilePicker == .launch {
                    // The household asks who's watching as the app opens,
                    // before anything of anyone's loads.
                    ProfilePickerView(reason: .launch)
                } else if session.needsWelcome {
                    // Once per server: what Aster and its plugins do.
                    WelcomeView()
                } else {
                    mainScreen
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.phase)
        .animation(.easeInOut(duration: 0.3), value: session.isLocked)
        .animation(.easeInOut(duration: 0.3), value: session.needsWelcome)
        .animation(.easeInOut(duration: 0.3), value: session.profilePicker)
        #if os(macOS)
        // Switching profiles: a window cover, which fades, closes with Esc
        // and keeps the keyboard from the page under it.
        .appCover(item: switcherCover) { reason in
            ProfilePickerView(reason: reason)
        }
        #endif
        // Leaving starts the lock's clock; coming back (or opening) checks it.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: session.noteLeftApp()
            case .active:
                session.checkLock()
                Task { await session.refreshPlexConnection() }
            default: break
            }
        }
        // A Plex server's address may have changed since it was saved.
        .task { await session.refreshPlexConnection() }
        // macOS draws full-screen presentations (the player...) from here.
        .appCoverHost()
    }

    /// A switched server or profile gets a fresh main screen: its own
    /// tabs, libraries and pages. On Apple TV, iPhone and iPad the profile
    /// picker lies over it, fading in and out, with the screen under it
    /// unable to take focus or touches meanwhile; the new main screen
    /// builds under the picker as it fades.
    private var mainScreen: some View {
        MainTabView()
            .id(session.serverGeneration)
            #if !os(macOS)
            .disabled(session.profilePicker == .switcher)
            .overlay {
                if session.profilePicker == .switcher {
                    ProfilePickerView(reason: .switcher)
                        .transition(.opacity)
                }
            }
            #endif
    }

    #if os(macOS)
    private var switcherCover: Binding<ProfilePickerReason?> {
        Binding(
            get: { session.profilePicker == .switcher ? .switcher : nil },
            set: { if $0 == nil { session.dismissProfilePicker() } }
        )
    }
    #endif
}

#Preview {
    ContentView()
        .environment(AppSession())
}
