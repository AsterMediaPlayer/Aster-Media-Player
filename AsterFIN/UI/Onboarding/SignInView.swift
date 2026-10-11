//
//  SignInView.swift
//  AsterFIN
//
//  Pick a user and sign in with a password or Quick Connect.
//

import SwiftUI

struct SignInView: View {
    @Environment(AppSession.self) private var session

    @State private var users: [JellyfinUser] = []
    @State private var selectedUser: JellyfinUser?
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var quickConnectEnabled = false
    @State private var quickConnectCode: String?
    @State private var quickConnectTask: Task<Void, Never>?

    private var client: JellyfinClient? { session.anonymousClient }

    /// Sign In, Quick Connect and Change Server: side by side on a TV,
    /// stacked full width on a phone.
    private var buttonLayout: AnyLayout {
        #if os(tvOS)
        AnyLayout(HStackLayout(spacing: 24))
        #else
        AnyLayout(VStackLayout(spacing: 12))
        #endif
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            OnboardingLayout {
                VStack(spacing: Onboarding.sectionSpacing) {
                    VStack(spacing: 8) {
                        Text(session.serverName ?? "Jellyfin")
                            .font(.system(size: Onboarding.serverNameSize, weight: .bold))
                            .multilineTextAlignment(.center)
                        Text("Who's watching?")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    if !users.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: Onboarding.avatarSpacing) {
                                ForEach(users) { user in
                                    Button {
                                        selectedUser = user
                                        username = user.name
                                        password = ""
                                        if user.hasPassword == false {
                                            signInWithPassword()
                                        }
                                    } label: {
                                        VStack(spacing: 14) {
                                            UserAvatar(user: user, client: client)
                                                .frame(width: Onboarding.avatarSize, height: Onboarding.avatarSize)
                                            Text(user.name)
                                                .font(.headline)
                                        }
                                        .padding(16)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, Onboarding.avatarRowPadding)
                            .padding(.vertical, 20)
                        }
                        .scrollClipDisabled()
                        .tvFocusSection()
                    }

                    VStack(spacing: Onboarding.controlSpacing) {
                        TextField("User name", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onboardingField()
                            .frame(maxWidth: Onboarding.credentialsWidth)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .onboardingField()
                            .frame(maxWidth: Onboarding.credentialsWidth)
                            .onSubmit(signInWithPassword)
                        buttonLayout {
                            Button {
                                signInWithPassword()
                            } label: {
                                HStack {
                                    if isWorking { ProgressView().controlSize(.small) }
                                    Text("Sign In")
                                }
                                .frame(maxWidth: Onboarding.signInButtonWidth)
                            }
                            .onboardingPrimaryButton()
                            .disabled(username.isEmpty || isWorking)

                            if quickConnectEnabled {
                                Button {
                                    startQuickConnect()
                                } label: {
                                    Text("Quick Connect").frame(maxWidth: Onboarding.signInButtonWidth)
                                }
                                .onboardingSecondaryButton()
                            }

                            Button(role: .cancel) {
                                quickConnectTask?.cancel()
                                session.changeServer()
                            } label: {
                                Text("Change Server")
                            }
                        }
                    }
                    .tvFocusSection()

                    if let quickConnectCode {
                        VStack(spacing: 10) {
                            Text("Enter this code in Jellyfin on another device")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Text(quickConnectCode)
                                .font(.system(size: Onboarding.quickConnectCodeSize, weight: .bold, design: .monospaced))
                                .kerning(12)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                    }
                }
                #if os(tvOS)
                .padding(.vertical, 60)
                #endif
            }
        }
        .task { await load() }
        .onDisappear { quickConnectTask?.cancel() }
    }

    private func load() async {
        guard let client else { return }
        async let publicUsers = client.publicUsers()
        async let enabled = client.quickConnectEnabled()
        users = (try? await publicUsers) ?? []
        quickConnectEnabled = (try? await enabled) ?? false
    }

    private func signInWithPassword() {
        guard let client, !username.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let result = try await client.authenticate(username: username, password: password)
                quickConnectTask?.cancel()
                session.signIn(result)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startQuickConnect() {
        guard let client else { return }
        quickConnectTask?.cancel()
        errorMessage = nil
        quickConnectTask = Task {
            do {
                let initiated = try await client.quickConnectInitiate()
                quickConnectCode = initiated.code
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let state = try await client.quickConnectState(secret: initiated.secret)
                    if state.authenticated {
                        let result = try await client.authenticateWithQuickConnect(secret: initiated.secret)
                        quickConnectCode = nil
                        session.signIn(result)
                        return
                    }
                }
            } catch is CancellationError {
                quickConnectCode = nil
            } catch {
                quickConnectCode = nil
                errorMessage = "Quick Connect failed: \(error.localizedDescription)"
            }
        }
    }
}

struct UserAvatar: View {
    let user: JellyfinUser
    let client: JellyfinClient?

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.2))
            if let tag = user.primaryImageTag, let client {
                RemoteImage(url: client.userImageURL(userId: user.id, tag: tag)) {
                    Color.clear
                }
                .clipShape(Circle())
            } else {
                Text(String(user.name.prefix(1)).uppercased())
                    .font(.system(size: Onboarding.avatarInitialSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}
