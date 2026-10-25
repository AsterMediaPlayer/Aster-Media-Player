//
//  WelcomeView.swift
//  AsterFIN
//
//  Shown once for each Jellyfin server signed in to: what Aster does, and
//  what its companion plugins add. An administrator can switch the plugins
//  on here and restart the server; anyone else is told to ask theirs. The
//  plugin rows are also Settings ▸ Server Plugins.
//

import SwiftUI

struct WelcomeView: View {
    @Environment(AppSession.self) private var session
    @State private var model = ServerPluginsModel()

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            ScrollView {
                VStack(spacing: Onboarding.sectionSpacing) {
                    VStack(spacing: 12) {
                        Image("AsterLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: Onboarding.logoWidth)
                            .accessibilityLabel("Aster Media Player")
                        Text("Welcome to Aster")
                            .font(.title.weight(.bold))
                        Text("Here's what Aster does with \(session.serverName ?? "your server"), and what its companion plugins add.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    WelcomeGroup(title: "Built in") {
                        FeatureLabel(systemImage: "play.rectangle", title: "A player of its own",
                                     text: "Plays most files as they are, Dolby Vision and lossless audio included, with subtitles Aster draws itself, styled anime ones too.")
                            .welcomeInfoRow()
                        FeatureLabel(systemImage: "tv", title: "Channels",
                                     text: "Any video playlist can be a TV channel that's always on, with a guide.")
                            .welcomeInfoRow()
                        FeatureLabel(systemImage: "music.note.list", title: "Music and audiobooks",
                                     text: "Albums, playlists and audiobooks with chapters, playing on while you browse.")
                            .welcomeInfoRow()
                    }

                    WelcomeGroup(title: "Companion plugins") {
                        Text(model.isAdministrator == false
                             ? "Free plugins for Jellyfin that add more to Aster."
                             : "Free plugins for Jellyfin that add more to Aster. Switch them on here: Aster installs them on your server.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if model.isAdministrator == nil {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(AsterPlugin.allCases) { plugin in
                                ServerPluginRow(plugin: plugin, model: model)
                            }
                        }
                        AuroraNote()
                            .welcomeInfoRow()
                        ServerRestartControls(model: model)
                        if let error = model.errorMessage {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                        if model.isAdministrator == false {
                            AskYourAdministratorNote()
                                .welcomeInfoRow()
                        }
                    }

                    Button {
                        session.markWelcomeSeen()
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: Onboarding.buttonWidth)
                    }
                    .onboardingPrimaryButton()
                    // Not while the server restarts: the app needs it back.
                    .disabled(model.restart == .restarting)
                }
                .frame(maxWidth: Welcome.width)
                .padding(.horizontal, 24)
                .padding(.vertical, Welcome.verticalPadding)
                .frame(maxWidth: .infinity)
            }
            .scrollClipDisabled()
        }
        .task { await model.load(session) }
    }
}

private enum Welcome {
    #if os(tvOS)
    static let width: CGFloat = 1100
    static let verticalPadding: CGFloat = 60
    static let iconWidth: CGFloat = 60
    #else
    static let width: CGFloat = 560
    static let verticalPadding: CGFloat = 32
    static let iconWidth: CGFloat = 36
    #endif
}

/// A titled run of rows on the welcome screen.
private struct WelcomeGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Onboarding.controlSpacing) {
            Text(title)
                .font(.title2.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An icon beside a title and a line or two about it.
struct FeatureLabel<Detail: View>: View {
    let systemImage: String
    let title: String
    let text: String
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: Welcome.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension FeatureLabel where Detail == EmptyView {
    init(systemImage: String, title: String, text: String) {
        self.init(systemImage: systemImage, title: title, text: text) { EmptyView() }
    }
}

/// One companion plugin: a switch for an administrator, else whether it's
/// on the server.
struct ServerPluginRow: View {
    let plugin: AsterPlugin
    let model: ServerPluginsModel

    @Environment(AppSession.self) private var session

    var body: some View {
        let state = model.state(of: plugin)
        if model.isAdministrator == true {
            Toggle(isOn: Binding(
                get: { state.isOn },
                set: { on in Task { await model.set(plugin, on: on, session: session) } }
            )) {
                label(state)
            }
            #if !os(tvOS)
            .toggleStyle(.switch)
            #endif
            .disabled(!state.canSwitch || model.restart == .restarting)
        } else {
            label(state)
                .welcomeInfoRow()
        }
    }

    private func label(_ state: PluginState) -> some View {
        FeatureLabel(systemImage: plugin.systemImage, title: plugin.packageName, text: plugin.summary) {
            if !state.caption.isEmpty {
                HStack(spacing: 8) {
                    if state == .installing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(state.caption)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(state == .active || state == .present(true) ? Color.green : Color.secondary)
                }
                .padding(.top, 2)
            }
        }
    }
}

/// Aurora is for Jellyfin's web client, not this app: no switch.
struct AuroraNote: View {
    var body: some View {
        FeatureLabel(systemImage: "sparkles.tv", title: "Aster Aurora, for Jellyfin's web client",
                     text: "Does its best to bring Aster's design and features to Jellyfin in a browser. It doesn't change this app, so it isn't switched on here: once Aster's repository is on your server, it's in the Catalog under Plugins in Jellyfin's dashboard.")
    }
}

/// For someone who isn't an administrator, who can't install plugins.
struct AskYourAdministratorNote: View {
    var body: some View {
        FeatureLabel(systemImage: "person.badge.key", title: "Ask your server's administrator",
                     text: "Only an administrator can add plugins. They can switch these on from Aster when they sign in, or add this repository under Plugins ▸ Repositories in Jellyfin's dashboard:") {
            Text(AsterPlugin.repositoryURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
                .padding(.top, 2)
        }
    }
}

/// The restart a plugin change waits on, for an administrator.
struct ServerRestartControls: View {
    let model: ServerPluginsModel

    @Environment(AppSession.self) private var session
    @State private var confirming = false

    var body: some View {
        switch model.restart {
        case .restarting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Restarting your server…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        case .idle:
            if model.isAdministrator == true, model.needsRestart {
                if model.canRestart {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Jellyfin needs a restart to finish.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Restart Server Now") { confirming = true }
                            .onboardingSecondaryButton()
                    }
                    .confirmationDialog("Restart the server?", isPresented: $confirming) {
                        Button("Restart", role: .destructive) {
                            Task { await model.restartServer(session) }
                        }
                    } message: {
                        Text("Anyone watching on it will be interrupted for a minute or so.")
                    }
                } else {
                    Text("Restart Jellyfin to finish: it can't restart itself where it's running.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension View {
    /// On Apple TV a row that only informs still takes focus, so the
    /// remote can scroll the page to it.
    @ViewBuilder
    func welcomeInfoRow() -> some View {
        #if os(tvOS)
        padding(.vertical, 12)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusable()
            .hoverEffect(.highlight)
        #else
        self
        #endif
    }
}
