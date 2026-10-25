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
                VStack(spacing: Welcome.sectionSpacing) {
                    header

                    WelcomeSection(title: "Ready the moment you sign in") {
                        WelcomeGrid {
                            WelcomeCard(systemImage: "play.rectangle.fill", title: "Plays it all, as it was meant to be",
                                        text: "Dolby Vision, HDR, and TrueHD and DTS:X sound, straight from your files. Even fancy anime subtitles look exactly as their makers styled them.")
                                .welcomeFocusable()
                            WelcomeCard(systemImage: "tv", title: "Your own TV channels",
                                        text: "Turn any playlist into a channel that's always on, then flip through them like cable, with a guide that shows what's on now and next.")
                                .welcomeFocusable()
                            WelcomeCard(systemImage: "music.note.list", title: "Music and audiobooks",
                                        text: "Albums keep playing while you browse, and every audiobook picks up right where you left off, chapter and all.")
                                .welcomeFocusable()
                        }
                    }

                    WelcomeSection(title: "Unlock even more",
                                   subtitle: model.isAdministrator == false
                                       ? "Free add-ons for your Jellyfin server that light up new parts of Aster."
                                       : "Free add-ons for your Jellyfin server that light up new parts of Aster. Switch one on and Aster installs it for you.") {
                        if model.isAdministrator == nil {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            WelcomeGrid {
                                ForEach(AsterPlugin.allCases) { plugin in
                                    PluginCard(plugin: plugin, model: model)
                                }
                            }
                        }
                        ServerRestartControls(model: model)
                        if let error = model.errorMessage {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                        WelcomeGrid(minimumWidth: Welcome.wideCardMinWidth) {
                            WelcomeCard(systemImage: "sparkles.tv", eyebrow: "Aster Aurora · for the web",
                                        title: "Love the look? Take it to your browser",
                                        text: "Aurora brings as much of Aster as it can to Jellyfin on the web: big hero banners, trailers playing behind titles, and more. Once Aster's repository is on your server, you'll find it in the plugin catalogue in Jellyfin's dashboard.")
                                .welcomeFocusable()
                            if model.isAdministrator == false {
                                WelcomeCard(systemImage: "person.badge.key", title: "Want these? Ask whoever runs your server",
                                            text: "They can switch them on from Aster in a few seconds, or add this repository under Plugins ▸ Repositories in Jellyfin's dashboard:") {
                                    RepositoryAddress()
                                }
                                .welcomeFocusable()
                            }
                        }
                    }

                    Button {
                        session.markWelcomeSeen()
                    } label: {
                        Text("Start Watching")
                            .frame(maxWidth: Onboarding.buttonWidth)
                    }
                    .onboardingPrimaryButton()
                    // Not while the server restarts: the app needs it back.
                    .disabled(model.restart == .restarting)
                }
                .padding(.horizontal, Welcome.sidePadding)
                .padding(.vertical, Welcome.verticalPadding)
                .frame(maxWidth: .infinity)
            }
            .scrollClipDisabled()
        }
        .task { await model.load(session) }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("AsterLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: Onboarding.logoWidth)
                .accessibilityLabel("Aster Media Player")
            Text("Welcome to Aster")
                .font(.largeTitle.weight(.bold))
            Text("Here's everything that's waiting for you on \(session.serverName ?? "your server").")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private enum Welcome {
    #if os(tvOS)
    static let sidePadding: CGFloat = Lockup.screenPadding
    static let verticalPadding: CGFloat = 60
    static let sectionSpacing: CGFloat = 60
    static let gridSpacing: CGFloat = 40
    static let cardMinWidth: CGFloat = 480
    static let wideCardMinWidth: CGFloat = 720
    static let cardPadding: CGFloat = 36
    static let cornerRadius: CGFloat = 28
    static let iconSize: CGFloat = 52
    #else
    static let sidePadding: CGFloat = 24
    static let verticalPadding: CGFloat = 40
    static let sectionSpacing: CGFloat = 40
    static let gridSpacing: CGFloat = 18
    static let cardMinWidth: CGFloat = 280
    static let wideCardMinWidth: CGFloat = 420
    static let cardPadding: CGFloat = 22
    static let cornerRadius: CGFloat = 20
    static let iconSize: CGFloat = 30
    #endif
}

/// A titled run of cards on the welcome screen.
private struct WelcomeSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Welcome.gridSpacing / 2 + 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Cards side by side across the whole width, as many as fit, all the
/// same height in a row; one above the other on a phone.
private struct WelcomeGrid<Content: View>: View {
    var minimumWidth: CGFloat = Welcome.cardMinWidth
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: Welcome.gridSpacing, alignment: .top)],
                  alignment: .leading, spacing: Welcome.gridSpacing) {
            content
        }
    }
}

/// A panel: an icon, an optional accessory at its top right (a switch), a
/// title and a few lines, and anything more below.
private struct WelcomeCard<Accessory: View, Detail: View>: View {
    let systemImage: String
    var eyebrow: String?
    let title: String
    let text: String
    /// A card that is a tvOS card button has that button's platter instead.
    var framed = true
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: systemImage)
                    .font(.system(size: Welcome.iconSize, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Spacer()
                accessory
            }
            VStack(alignment: .leading, spacing: 8) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                detail
            }
        }
        .padding(Welcome.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if framed {
                RoundedRectangle(cornerRadius: Welcome.cornerRadius, style: .continuous)
                    .fill(.white.opacity(0.07))
            }
        }
    }
}

extension WelcomeCard where Accessory == EmptyView, Detail == EmptyView {
    init(systemImage: String, eyebrow: String? = nil, title: String, text: String) {
        self.init(systemImage: systemImage, eyebrow: eyebrow, title: title, text: text) { EmptyView() } detail: { EmptyView() }
    }
}

extension WelcomeCard where Accessory == EmptyView {
    init(systemImage: String, eyebrow: String? = nil, title: String, text: String, @ViewBuilder detail: () -> Detail) {
        self.init(systemImage: systemImage, eyebrow: eyebrow, title: title, text: text, accessory: { EmptyView() }, detail: detail)
    }
}

/// A companion plugin as a card. An administrator switches it on and off
/// (on Apple TV, the whole card is the switch); anyone else sees whether
/// it's on the server.
private struct PluginCard: View {
    let plugin: AsterPlugin
    let model: ServerPluginsModel

    @Environment(AppSession.self) private var session

    var body: some View {
        let state = model.state(of: plugin)
        let canSwitch = model.isAdministrator == true && state.canSwitch && model.restart != .restarting
        if model.isAdministrator == true {
            #if os(tvOS)
            Button {
                Task { await model.set(plugin, on: !state.isOn, session: session) }
            } label: {
                card(state, framed: false) { OnOffBadge(isOn: state.isOn) }
            }
            .buttonStyle(.card)
            .disabled(!canSwitch)
            #else
            card(state, framed: true) {
                Toggle(plugin.packageName, isOn: Binding(
                    get: { state.isOn },
                    set: { on in Task { await model.set(plugin, on: on, session: session) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!canSwitch)
            }
            #endif
        } else {
            card(state, framed: true) { EmptyView() }
                .welcomeFocusable()
        }
    }

    private func card<Accessory: View>(_ state: PluginState, framed: Bool, @ViewBuilder accessory: () -> Accessory) -> some View {
        WelcomeCard(systemImage: plugin.systemImage, eyebrow: plugin.packageName, title: plugin.headline,
                    text: plugin.summary, framed: framed, accessory: accessory) {
            PluginStatusLine(state: state)
                .padding(.top, 4)
        }
    }
}

/// Apple TV's stand-in for a switch on a card that is itself the button.
private struct OnOffBadge: View {
    let isOn: Bool

    var body: some View {
        Text(isOn ? "On" : "Off")
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(isOn ? AnyShapeStyle(Color.green.opacity(0.85)) : AnyShapeStyle(.white.opacity(0.15)), in: Capsule())
    }
}

/// Where a plugin stands, under its description.
struct PluginStatusLine: View {
    let state: PluginState

    var body: some View {
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
        }
    }
}

/// The repository's address, to copy into Jellyfin's dashboard.
private struct RepositoryAddress: View {
    var body: some View {
        Text(AsterPlugin.repositoryURL)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            #if !os(tvOS)
            .textSelection(.enabled)
            #endif
            .padding(.top, 4)
    }
}

// MARK: - Settings ▸ Server Plugins

/// An icon beside a title and a line or two about it, for a settings row.
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
                .frame(width: 44)
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

/// One companion plugin as a settings row: a switch for an administrator,
/// else whether it's on the server.
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
        }
    }

    private func label(_ state: PluginState) -> some View {
        FeatureLabel(systemImage: plugin.systemImage, title: "\(plugin.headline) · \(plugin.packageName)", text: plugin.summary) {
            PluginStatusLine(state: state)
                .padding(.top, 2)
        }
    }
}

/// Aurora is for Jellyfin's web client, not this app: no switch.
struct AuroraNote: View {
    var body: some View {
        FeatureLabel(systemImage: "sparkles.tv", title: "Aster Aurora, for the web",
                     text: "Brings as much of Aster as it can to Jellyfin in your browser: big hero banners, trailers playing behind titles, and more. Once Aster's repository is on your server, you'll find it in the plugin catalogue in Jellyfin's dashboard.")
    }
}

/// For someone who isn't an administrator, who can't install plugins.
struct AskYourAdministratorNote: View {
    var body: some View {
        FeatureLabel(systemImage: "person.badge.key", title: "Want these? Ask whoever runs your server",
                     text: "They can switch them on from Aster in a few seconds, or add this repository under Plugins ▸ Repositories in Jellyfin's dashboard:") {
            RepositoryAddress()
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
                Text("Restarting your server. This usually takes about a minute…")
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
                        Text("Almost there. Your server needs a quick restart to finish.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Restart Server") { confirming = true }
                            .onboardingSecondaryButton()
                    }
                    .confirmationDialog("Restart your server now?", isPresented: $confirming) {
                        Button("Restart", role: .destructive) {
                            Task { await model.restartServer(session) }
                        }
                    } message: {
                        Text("Anyone watching will be paused for about a minute.")
                    }
                } else {
                    Text("Almost there. Restart Jellyfin to finish (it can't restart itself where it's running).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension View {
    /// On Apple TV a card that only informs still takes focus, so the
    /// remote can scroll the page to it.
    @ViewBuilder
    func welcomeFocusable() -> some View {
        #if os(tvOS)
        focusable()
            .hoverEffect(.highlight)
        #else
        self
        #endif
    }
}
