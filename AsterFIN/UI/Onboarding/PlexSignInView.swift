//
//  PlexSignInView.swift
//  AsterFIN
//
//  Signing in with Plex: a code to enter at plex.tv/link, then who's
//  watching (a Plex Home's people, some behind a PIN), then which server,
//  then the first of its addresses that answers.
//

import SwiftUI

@Observable
final class PlexSignInModel {
    enum Step: Equatable {
        case starting
        case linking(PlexPin)
        case pickingUser([PlexHomeUser])
        case enteringPin(PlexHomeUser)
        case pickingServer([PlexResource])
        case connecting(String)
        case failed(String)
    }

    private(set) var step: Step = .starting
    private var accountToken: String?
    /// The account or Home user signing in, and their token.
    private var user: PlexAccountUser?
    private var userToken: String?
    private var linkTask: Task<Void, Never>?

    /// Shows a code and waits for it to be entered; a fresh code when one
    /// runs out.
    func start() {
        linkTask?.cancel()
        step = .starting
        linkTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let pin = try await PlexAccount.startLink()
                    self?.step = .linking(pin)
                    let expires = Date().addingTimeInterval(TimeInterval(pin.expiresIn ?? 900))
                    while Date() < expires, !Task.isCancelled {
                        try await Task.sleep(for: .seconds(2))
                        if let token = try? await PlexAccount.linkedToken(for: pin) {
                            await self?.linked(token)
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self?.step = .failed("Couldn't reach plex.tv. \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    func cancel() {
        linkTask?.cancel()
    }

    private func linked(_ token: String) async {
        accountToken = token
        let users = await PlexAccount.homeUsers(token: token)
        if users.count > 1 {
            step = .pickingUser(users)
        } else {
            do {
                user = try await PlexAccount.account(token: token)
                userToken = token
                await loadServers()
            } catch {
                step = .failed("Couldn't read your Plex account. \(error.localizedDescription)")
            }
        }
    }

    func pick(_ homeUser: PlexHomeUser) async {
        if homeUser.protected == true {
            step = .enteringPin(homeUser)
        } else {
            await switchTo(homeUser, pin: nil)
        }
    }

    /// A wrong PIN comes back to the PIN pad with a message.
    private(set) var pinError: String?

    func switchTo(_ homeUser: PlexHomeUser, pin: String?) async {
        guard let accountToken else { return }
        pinError = nil
        do {
            let switched = try await PlexAccount.switchUser(homeUser, pin: pin, token: accountToken)
            user = switched
            userToken = switched.authToken ?? accountToken
            await loadServers()
        } catch PlexError.http(let code) where code == 401 || code == 403 {
            pinError = "That PIN isn't right."
            step = .enteringPin(homeUser)
        } catch {
            step = .failed("Couldn't switch to \(homeUser.title). \(error.localizedDescription)")
        }
    }

    private func loadServers() async {
        guard let userToken else { return }
        step = .connecting("Finding your servers…")
        do {
            let servers = try await PlexAccount.servers(token: userToken)
            if servers.isEmpty {
                step = .failed(PlexError.noServers.localizedDescription)
            } else if servers.count == 1 {
                await connect(to: servers[0])
            } else {
                step = .pickingServer(servers)
            }
        } catch {
            step = .failed("Couldn't list your Plex servers. \(error.localizedDescription)")
        }
    }

    /// The signed-in session, once an address of the server answers.
    private(set) var signedIn: StoredSession?

    func connect(to server: PlexResource) async {
        guard let userToken, let user else { return }
        step = .connecting("Connecting to \(server.name)…")
        let token = server.accessToken ?? userToken
        let connections = server.rankedConnections
        // A first connection can be slow (name lookups, secure set-up for
        // every address at once): one more go before giving up.
        var reached = await PlexConnectionRace.fastest(connections, token: token)
        if reached == nil {
            reached = await PlexConnectionRace.fastest(connections, token: token)
        }
        guard let reached else {
            step = .failed(PlexError.unreachable(server.name).localizedDescription)
            return
        }
        signedIn = StoredSession(
            serverURL: reached.uri, serverName: server.name, userId: user.uuid, userName: user.displayName,
            accessToken: token, serverKind: .plex,
            plex: PlexLink(accountToken: userToken, machineId: server.clientIdentifier, connections: connections))
    }
}

struct PlexSignInView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model = PlexSignInModel()
    @State private var pin = ""

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            OnboardingLayout {
                VStack(spacing: Onboarding.sectionSpacing) {
                    Text("Sign in with Plex")
                        .font(.system(size: Onboarding.titleSize, weight: .bold))
                    content
                    Button("Cancel") {
                        model.cancel()
                        dismiss()
                    }
                    .onboardingSecondaryButton()
                }
                .frame(maxWidth: Onboarding.fieldWidth)
            }
        }
        .task { model.start() }
        .onDisappear { model.cancel() }
        .onChange(of: model.signedIn) { _, signedIn in
            guard let signedIn else { return }
            dismiss()
            session.signIn(plex: signedIn)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .starting:
            ProgressView()
        case .linking(let pin):
            VStack(spacing: Onboarding.controlSpacing) {
                Text("On your phone or computer, go to")
                    .foregroundStyle(.secondary)
                Text("plex.tv/link")
                    .font(.title2.weight(.semibold))
                Text("and enter this code:")
                    .foregroundStyle(.secondary)
                Text(pin.code)
                    .font(.system(size: Onboarding.quickConnectCodeSize, weight: .bold, design: .monospaced))
                    .tracking(8)
                    #if !os(tvOS)
                    .textSelection(.enabled)
                    #endif
                    .accessibilityLabel("Code \(pin.code.map(String.init).joined(separator: " "))")
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for the code to be entered…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
        case .pickingUser(let users):
            VStack(spacing: Onboarding.controlSpacing) {
                Text("Who's watching?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                ForEach(users) { user in
                    Button {
                        Task { await model.pick(user) }
                    } label: {
                        HStack {
                            Text(user.title)
                            Spacer()
                            if user.protected == true {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("PIN")
                            }
                        }
                        .frame(maxWidth: Onboarding.buttonWidth)
                    }
                    .onboardingSecondaryButton()
                }
            }
        case .enteringPin(let user):
            VStack(spacing: Onboarding.controlSpacing) {
                Text("Enter \(user.title)'s PIN")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                SecureField("PIN", text: $pin)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onboardingField()
                    .frame(maxWidth: Onboarding.credentialsWidth)
                    .onSubmit { submitPin(for: user) }
                if let error = model.pinError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Button("Continue") { submitPin(for: user) }
                    .onboardingPrimaryButton()
                    .disabled(pin.isEmpty)
            }
        case .pickingServer(let servers):
            VStack(spacing: Onboarding.controlSpacing) {
                Text("Choose a server")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                ForEach(servers) { server in
                    Button {
                        Task { await model.connect(to: server) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(server.owned == true ? "Your server" : "Shared with you")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: Onboarding.buttonWidth, alignment: .leading)
                    }
                    .onboardingSecondaryButton()
                }
            }
        case .connecting(let message):
            HStack(spacing: 12) {
                ProgressView()
                Text(message)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: Onboarding.controlSpacing) {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try Again") { model.start() }
                    .onboardingPrimaryButton()
            }
        }
    }

    private func submitPin(for user: PlexHomeUser) {
        let entered = pin
        pin = ""
        Task { await model.switchTo(user, pin: entered) }
    }
}
