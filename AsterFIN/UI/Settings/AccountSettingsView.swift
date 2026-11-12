//
//  AccountSettingsView.swift
//  AsterFIN
//
//  Settings ▸ Account: the server and user in use, and the saved servers.
//

import SwiftUI

// MARK: - Account

struct AccountSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var serverInfo: PublicSystemInfo?
    @AppStorage(AppSettings.profileGateKey) private var profileGate = ProfileGateMode.server
    @State private var credentialRequest: ServerCredentialRequest?

    private var household: HouseholdProfiles { HouseholdProfiles.shared }

    /// A Plex Home has no setting of its own to follow.
    private var gateOptions: [(value: ProfileGateMode, name: String)] {
        ProfileGateMode.allCases
            .filter { $0 != .server || household.provider?.kind == .bonfire }
            .map { ($0, $0.title) }
    }

    private var gateNote: String {
        household.provider?.kind == .bonfire
            ? "Whether Aster asks who's watching as it opens. As the Server Is Set follows the household's Ask on startup setting in Bonfire, as Jellyfin's own apps do."
            : "Whether Aster asks who's watching as it opens, like Plex's own apps."
    }

    private var lockNote: String {
        guard let current = session.currentServer, current.isHouseholdProfile, current.canBeLocked else { return "" }
        return " With Ask for PIN After set, \(current.session.userName)'s PIN is asked when Aster opens, and after that long away from it."
    }

    var body: some View {
        SettingsPage(title: "Account") {
            Section("Server") {
                LabeledContent("Server", value: session.serverName ?? session.serverURL?.host() ?? "")
                LabeledContent("Address", value: session.serverURL?.absoluteString ?? "")
                if let serverInfo, let version = serverInfo.version {
                    // Which server it is comes from the same reply.
                    LabeledContent("\(serverInfo.kind.displayName) version", value: version)
                }
            }
            Section("User") {
                LabeledContent("User", value: session.userName ?? "")
                if session.hasProfiles {
                    Button("Switch Profile") { session.presentProfilePicker() }
                }
                Button("Switch User") { session.signOut() }
            }
            if household.provider != nil {
                Section {
                    SettingsChoiceRow(title: "Ask on Opening", options: gateOptions, selection: $profileGate)
                    // A profile with a PIN: how long away before it's asked
                    // again (and on opening). The same lock as a server's,
                    // on the sign-in in use.
                    if let current = session.currentServer, current.isHouseholdProfile, current.canBeLocked {
                        #if os(macOS)
                        SettingsChoiceRow(
                            title: "Ask for PIN After",
                            options: [(0, "Never")] + SavedServer.lockChoices.map { ($0, SavedServerPage.lockTitle($0)) },
                            selection: Binding(
                                get: { current.lockAfterMinutes ?? 0 },
                                set: { choice in
                                    let minutes = choice > 0 ? choice : nil
                                    guard current.loosens(lockAfter: minutes) else {
                                        session.setLockAfter(minutes, for: current.id)
                                        return
                                    }
                                    credentialRequest = ServerCredentialRequest(
                                        server: current, purpose: "change when the PIN is asked", buttonTitle: "Change"
                                    ) { session.setLockAfter(minutes, for: current.id) }
                                }
                            )
                        )
                        #else
                        NavigationLink(value: SettingsDestination.lockAfter(current.id)) {
                            LabeledContent("Ask for PIN After", value: SavedServerPage.lockTitle(current.lockAfterMinutes ?? 0))
                        }
                        #endif
                    }
                } header: {
                    Text("Who's Watching")
                } footer: {
                    SettingsNote(gateNote + lockNote)
                }
            }
            Section {
                ForEach(session.savedServers) { server in
                    NavigationLink(value: SettingsDestination.savedServer(server.id)) {
                        SavedServerLabel(server: server, isCurrent: server.id == session.currentServerID)
                    }
                }
                Button("Add Server") { session.changeServer() }
            } header: {
                Text("Servers")
            } footer: {
                SettingsNote("Servers you've signed in to stay signed in, to switch between. Add one to sign in to another Jellyfin or Emby server.")
            }
        }
        .task {
            serverInfo = try? await session.jellyfin?.publicSystemInfo()
        }
        .serverCredentialCheck(request: $credentialRequest)
    }
}

/// One saved server: switch to it, ask for its password first, or forget it.
/// It reads the server from the saved list by id, so its settings show as
/// they change here.
struct SavedServerPage: View {
    let serverID: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var switchRequest: SavedServer?
    @State private var credentialRequest: ServerCredentialRequest?
    @State private var signingInToPlex = false
    @State private var showsOnTopShelf = true
    @State private var confirmingRemoval = false

    var body: some View {
        if let server = session.savedServers.first(where: { $0.id == serverID }) {
            content(server)
                .onAppear { showsOnTopShelf = TopShelfServers.isShown(serverID) }
        }
    }

    private var isInUse: Bool { serverID == session.currentServerID }

    /// "Never", "5 Minutes", "1 Hour", "4 Hours".
    static func lockTitle(_ minutes: Int) -> String {
        guard minutes > 0 else { return "Never" }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide)).capitalized
    }

    private func content(_ server: SavedServer) -> some View {
        SettingsPage(title: server.session.serverName ?? "Server") {
            Section {
                LabeledContent("Server", value: server.session.kind.displayName)
                LabeledContent("Address", value: server.session.serverURL.absoluteString)
                LabeledContent("User", value: server.session.userName)
            }
            Section {
                if isInUse {
                    SettingsNote("This is the server in use.")
                } else {
                    Button("Switch to This Server") { switchRequest = server }
                }
                if server.canBeLocked {
                    Toggle("Ask for \(server.credentialName.capitalized) to Switch", isOn: Binding(
                        get: { server.asksPasswordToSwitch },
                        set: { asks in
                            // Turning it off asks for the credential, so nobody else can.
                            guard server.loosens(asksToSwitch: asks) else {
                                session.setAsksPasswordToSwitch(asks, for: serverID)
                                return
                            }
                            credentialRequest = ServerCredentialRequest(
                                server: server, purpose: "stop asking for it to switch", buttonTitle: "Turn Off"
                            ) { session.setAsksPasswordToSwitch(false, for: serverID) }
                        }
                    ))
                }
            } footer: {
                if server.canBeLocked {
                    SettingsNote(server.session.kind == .plex
                        ? "Switching to this server asks for \(server.session.userName)'s Plex Home PIN first, checked by plex.tv, so others on this device can't switch to it."
                        : "Switching to this server asks for \(server.session.userName)'s password first, checked by the server, so others on this device can't switch to it.")
                } else {
                    SettingsNote("Locking asks for \(server.session.userName)'s Plex Home PIN. Sign in with Plex again to lock this server (a profile without a PIN needs one added in Plex under Settings ▸ Plex Home first).")
                }
            }
            // A sign-in from before PINs could be checked: sign in afresh.
            // (Also the page's one control then, so the remote can leave it.)
            if server.session.kind == .plex, !server.canBeLocked {
                Section {
                    Button("Sign In with Plex Again") { signingInToPlex = true }
                }
            }
            if server.canBeLocked {
                Section {
                    #if os(macOS)
                    SettingsChoiceRow(
                        title: "Lock After",
                        options: [(0, "Never")] + SavedServer.lockChoices.map { ($0, Self.lockTitle($0)) },
                        selection: Binding(
                            get: { server.lockAfterMinutes ?? 0 },
                            set: { choice in
                                let minutes = choice > 0 ? choice : nil
                                guard server.loosens(lockAfter: minutes) else {
                                    session.setLockAfter(minutes, for: serverID)
                                    return
                                }
                                credentialRequest = ServerCredentialRequest(
                                    server: server, purpose: "change when it locks", buttonTitle: "Change"
                                ) { session.setLockAfter(minutes, for: serverID) }
                            }
                        )
                    )
                    #else
                    // Its page goes on the path by value, like this one.
                    NavigationLink(value: SettingsDestination.lockAfter(serverID)) {
                        LabeledContent("Lock After", value: Self.lockTitle(server.lockAfterMinutes ?? 0))
                    }
                    #endif
                } footer: {
                    SettingsNote("After this long away from Aster, coming back to this server asks for \(server.session.userName)'s \(server.credentialName).")
                }
            }
            #if os(tvOS)
            // The Top Shelf reads Jellyfin and Emby only, so Plex has nothing to turn off.
            if server.session.kind != .plex {
                Section {
                    Toggle("Show on Top Shelf", isOn: Binding(
                        get: { showsOnTopShelf },
                        set: {
                            showsOnTopShelf = $0
                            TopShelfServers.setShown($0, for: serverID)
                        }
                    ))
                } footer: {
                    SettingsNote("While this server is in use, the Top Shelf shows its Continue Watching, Next Up and channels. Turn it off to keep them off the Home Screen.")
                }
            }
            #endif
            Section {
                Button("Remove Server", role: .destructive) {
                    if isInUse {
                        confirmingRemoval = true
                    } else {
                        session.removeServer(serverID)
                        dismiss()
                    }
                }
            } footer: {
                if isInUse {
                    SettingsNote("This is the server in use: removing it signs you out, and Aster goes back to adding a server.")
                }
            }
        }
        .confirmationDialog("Remove this server?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove and Sign Out", role: .destructive) {
                session.removeCurrentServer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be signed out of \(server.session.serverName ?? "it"), and can add a server again.")
        }
        .savedServerSwitcher(request: $switchRequest)
        .serverCredentialCheck(request: $credentialRequest)
        #if os(macOS)
        .sheet(isPresented: $signingInToPlex) {
            PlexSignInView()
                .frame(minWidth: 520, minHeight: 560)
        }
        #else
        .fullScreenCover(isPresented: $signingInToPlex) {
            PlexSignInView()
        }
        #endif
    }
}

/// A saved server's Lock After choices: picking one saves it and goes back.
struct LockAfterPage: View {
    let serverID: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var credentialRequest: ServerCredentialRequest?

    var body: some View {
        let server = session.savedServers.first { $0.id == serverID }
        let chosen = server?.lockAfterMinutes ?? 0
        SettingsPage(title: "Lock After") {
            Section {
                ForEach([0] + SavedServer.lockChoices, id: \.self) { minutes in
                    Button {
                        let choice = minutes > 0 ? minutes : nil
                        // Never, or a longer wait, asks for the credential first.
                        if let server, server.loosens(lockAfter: choice) {
                            credentialRequest = ServerCredentialRequest(
                                server: server, purpose: "change when it locks", buttonTitle: "Change"
                            ) {
                                session.setLockAfter(choice, for: serverID)
                                dismiss()
                            }
                        } else {
                            session.setLockAfter(choice, for: serverID)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Text(SavedServerPage.lockTitle(minutes))
                            Spacer()
                            if minutes == chosen {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
        .serverCredentialCheck(request: $credentialRequest)
    }
}
