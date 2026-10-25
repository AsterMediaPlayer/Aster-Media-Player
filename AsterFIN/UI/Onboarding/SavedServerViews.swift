//
//  SavedServerViews.swift
//  AsterFIN
//
//  Switching between the servers signed in to: a row per server, and the
//  password a server asks for before switching, when it's set to.
//

import SwiftUI

/// One saved server: its name, Jellyfin or Emby, and who's signed in.
struct SavedServerLabel: View {
    let server: SavedServer
    var isCurrent = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.session.serverName ?? server.session.serverURL.host() ?? "Server")
                    .font(.headline)
                Text("\(server.session.kind.displayName) · \(server.session.userName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Text("In Use")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
            } else if server.asksPasswordToSwitch {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Asks for \(server.credentialName)")
            }
        }
    }
}

/// Switches to saved servers, asking for the password first where a server
/// is set to. Put it on a view that lists servers; call `request` to switch.
struct SavedServerSwitcher: ViewModifier {
    @Binding var request: SavedServer?

    @Environment(AppSession.self) private var session
    @State private var asking: SavedServer?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, server in
                guard let server else { return }
                request = nil
                if server.asksPasswordToSwitch {
                    asking = server
                } else {
                    session.switchServer(to: server)
                }
            }
            .sheet(item: $asking) { server in
                ServerPasswordSheet(server: server)
            }
    }
}

extension View {
    func savedServerSwitcher(request: Binding<SavedServer?>) -> some View {
        modifier(SavedServerSwitcher(request: request))
    }
}

/// The user's own password for the server, checked by the server, before
/// switching to it.
private struct ServerPasswordSheet: View {
    let server: SavedServer

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Onboarding.controlSpacing) {
            Text(server.session.serverName ?? "Server")
                .font(.title2.weight(.bold))
            Text("Enter \(server.session.userName)'s \(server.credentialName) to switch to this \(server.session.kind.displayName) server.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField(server.credentialName.capitalized, text: $password)
                .credentialField(isPin: server.session.kind == .plex)
                .onboardingField()
                .frame(maxWidth: Onboarding.credentialsWidth)
                .focused($focused)
                .onSubmit(check)
            HStack(spacing: 24) {
                Button {
                    check()
                } label: {
                    HStack {
                        if isChecking { ProgressView().controlSize(.small) }
                        Text("Switch")
                    }
                }
                .onboardingPrimaryButton()
                .disabled(isChecking)
                Button("Cancel", role: .cancel) { dismiss() }
                    .onboardingSecondaryButton()
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
    }

    private func check() {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        Task {
            defer { isChecking = false }
            do {
                let fresh = try await session.signInAgain(to: server, password: password)
                dismiss()
                session.switchServer(to: server, session: fresh)
            } catch {
                errorMessage = "That \(server.credentialName) didn't work. \(error.localizedDescription)"
            }
        }
    }
}

/// The server in use after the app was away longer than its lock-after:
/// the user's password (checked by the server) to carry on, or another server.
struct ServerLockView: View {
    let server: SavedServer

    @Environment(AppSession.self) private var session
    @State private var password = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            OnboardingLayout {
                VStack(spacing: Onboarding.sectionSpacing) {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: Onboarding.logoSize * 0.7))
                            .foregroundStyle(.secondary)
                        Text(server.session.serverName ?? "Server")
                            .font(.system(size: Onboarding.serverNameSize, weight: .bold))
                        Text("Enter \(server.session.userName)'s \(server.credentialName) to carry on.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: Onboarding.controlSpacing) {
                        SecureField(server.credentialName.capitalized, text: $password)
                            .credentialField(isPin: server.session.kind == .plex)
                            .onboardingField()
                            .frame(maxWidth: Onboarding.credentialsWidth)
                            .focused($focused)
                            .onSubmit(check)
                        Button {
                            check()
                        } label: {
                            HStack {
                                if isChecking { ProgressView().controlSize(.small) }
                                Text("Unlock")
                            }
                            .frame(maxWidth: Onboarding.signInButtonWidth)
                        }
                        .onboardingPrimaryButton()
                        .disabled(isChecking)
                        Button("Use Another Server") { session.changeServer() }
                            .onboardingSecondaryButton()
                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .tvFocusSection()
                }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
    }

    private func check() {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        Task {
            defer { isChecking = false }
            do {
                session.unlock(with: try await session.signInAgain(to: server, password: password))
            } catch {
                errorMessage = "That \(server.credentialName) didn't work. \(error.localizedDescription)"
            }
        }
    }
}

extension View {
    /// A password field, or a Plex PIN's: digits, and nothing to autofill.
    @ViewBuilder
    func credentialField(isPin: Bool) -> some View {
        if isPin {
            #if os(iOS)
            keyboardType(.numberPad)
            #else
            self
            #endif
        } else {
            textContentType(.password)
        }
    }
}
