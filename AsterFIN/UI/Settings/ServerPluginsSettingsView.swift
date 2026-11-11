//
//  ServerPluginsSettingsView.swift
//  AsterFIN
//
//  Settings ▸ Server Plugins: Aster's companion plugins on the server.
//

import SwiftUI

/// Aster's companion plugins on the server: the welcome screen's switches,
/// any time.
struct ServerPluginsSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var model = ServerPluginsModel()

    var body: some View {
        SettingsPage(title: "Server Plugins") {
            Section {
                if model.isAdministrator == nil {
                    ProgressView()
                } else {
                    ForEach(AsterPlugin.allCases) { plugin in
                        ServerPluginRow(plugin: plugin, model: model)
                    }
                }
            } footer: {
                if model.isAdministrator == true {
                    SettingsNote("Free plugins for Jellyfin that add more to Aster. Switching one on installs it on your server; off turns it off and keeps its settings. Either takes a server restart.")
                }
            }
            if model.isAdministrator == true, model.needsRestart || model.restart != .idle || model.errorMessage != nil {
                Section {
                    ServerRestartControls(model: model)
                    if let error = model.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section {
                AuroraNote()
                if model.isAdministrator == false {
                    AskYourAdministratorNote()
                }
            }
        }
        .task { await model.load(session) }
    }
}
