//
//  SavedServerViews.swift
//  AsterFIN
//
//  Switching between the servers signed in to: a row per server, and the
//  password a server asks for before switching, when it's set to. A
//  household profile's "password" is its PIN, typed on the PIN pad.
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
            } else if server.asksPasswordToSwitch, server.canBeLocked {
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
                // A server that can't check a PIN doesn't ask for one.
                if server.asksPasswordToSwitch, server.canBeLocked {
                    asking = server
                } else {
                    session.switchServer(to: server)
                }
            }
            .sheet(item: $asking) { server in
                ServerPasswordSheet(
                    server: server,
                    message: "Enter \(server.session.userName)'s \(server.credentialName) to switch to this \(server.session.kind.displayName) server.",
                    buttonTitle: "Switch"
                ) { fresh in
                    session.switchServer(to: server, session: fresh)
                }
            }
    }
}

/// A change that loosens a server's lock, held until the server's password
/// or PIN is given.
struct ServerCredentialRequest: Identifiable {
    let id = UUID()
    let server: SavedServer
    /// What the sheet says it's for: "turn off the password for switching".
    let purpose: String
    let buttonTitle: String
    let onConfirmed: () -> Void
}

/// Asks for a server's password or PIN, checked by the server, before a
/// change that would let others past its lock.
struct ServerCredentialCheck: ViewModifier {
    @Binding var request: ServerCredentialRequest?

    @Environment(AppSession.self) private var session

    func body(content: Content) -> some View {
        content
            .sheet(item: $request) { request in
                ServerPasswordSheet(
                    server: request.server,
                    message: "Enter \(request.server.session.userName)'s \(request.server.credentialName) to \(request.purpose).",
                    buttonTitle: request.buttonTitle
                ) { fresh in
                    session.keepSignIn(fresh)
                    request.onConfirmed()
                }
            }
    }
}

extension View {
    func savedServerSwitcher(request: Binding<SavedServer?>) -> some View {
        modifier(SavedServerSwitcher(request: request))
    }

    func serverCredentialCheck(request: Binding<ServerCredentialRequest?>) -> some View {
        modifier(ServerCredentialCheck(request: request))
    }
}

/// The field a credential is typed in: the PIN pad for a household
/// profile, a secure field for a password or a Plex Home PIN.
private struct CredentialEntry: View {
    let server: SavedServer
    @Binding var text: String
    var errorAttempt: Int
    var isChecking: Bool
    var onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        if server.asksProfilePin {
            PinCodeEntry(pin: $text, errorAttempt: errorAttempt, isDisabled: isChecking, onSubmit: onSubmit)
        } else {
            SecureField(server.credentialName.capitalized, text: $text)
                .credentialField(isPin: server.session.kind == .plex)
                .onboardingField()
                .frame(maxWidth: Onboarding.credentialsWidth)
                .focused($focused)
                // tvOS's keyboard can submit before the field has the last
                // key typed: nothing is checked until there's something to check.
                .onSubmit { if !text.isEmpty { onSubmit() } }
                .task {
                    try? await Task.sleep(for: .milliseconds(350))
                    focused = true
                }
        }
    }

    /// Whether what's typed is worth sending: any password, or a whole PIN.
    static func isReady(_ text: String, for server: SavedServer) -> Bool {
        server.asksProfilePin ? PinCode.isComplete(text) : !text.isEmpty
    }
}

/// A household profile's picture, for the lock screen and the sheet.
private struct HouseholdProfileHeader: View {
    let server: SavedServer
    var size: CGFloat

    var body: some View {
        if let household = server.session.household {
            ProfileAvatarView(
                initial: household.avatarInitial ?? String(server.session.userName.prefix(1)).uppercased(),
                colorHex: household.avatarColor ?? Bonfire.defaultAvatarColor,
                imageURL: Self.imageURL(for: server.session, household: household),
                size: size
            )
        }
    }

    /// As `HouseholdProfile` finds it: a web address as it is, anything
    /// else through the plugin's image route.
    private static func imageURL(for session: StoredSession, household: StoredHousehold) -> URL? {
        guard let image = household.profileImage, !image.isEmpty else { return nil }
        if image.lowercased().hasPrefix("http://") || image.lowercased().hasPrefix("https://") { return URL(string: image) }
        return BonfireClient(jellyfin: JellyfinClient(baseURL: session.serverURL, kind: session.kind)).imageURL(profileUserId: session.userId)
    }
}

/// The user's own password for the server (a profile's PIN), checked by
/// the server, before switching to it or loosening its lock.
private struct ServerPasswordSheet: View {
    let server: SavedServer
    let message: String
    let buttonTitle: String
    /// Run with the fresh sign-in once the check passes, after the sheet goes.
    let onSuccess: (StoredSession) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var errorAttempt = 0

    var body: some View {
        VStack(spacing: Onboarding.controlSpacing) {
            HouseholdProfileHeader(server: server, size: 72)
            Text(server.session.serverName ?? "Server")
                .font(.title2.weight(.bold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            CredentialEntry(server: server, text: $password, errorAttempt: errorAttempt, isChecking: isChecking, onSubmit: check)
            HStack(spacing: 24) {
                Button {
                    check()
                } label: {
                    HStack {
                        if isChecking { ProgressView().controlSize(.small) }
                        Text(buttonTitle)
                    }
                }
                .onboardingPrimaryButton()
                .disabled(isChecking || !CredentialEntry.isReady(password, for: server))
                Button("Cancel", role: .cancel) { dismiss() }
                    .onboardingSecondaryButton()
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .id(errorAttempt)
            }
        }
        .padding(40)
    }

    private func check() {
        guard !isChecking, CredentialEntry.isReady(password, for: server) else { return }
        isChecking = true
        errorMessage = nil
        Task {
            defer { isChecking = false }
            do {
                let fresh = try await session.signInAgain(to: server, password: password)
                dismiss()
                onSuccess(fresh)
            } catch {
                errorAttempt += 1
                errorMessage = Self.message(for: error, server: server)
                if server.asksProfilePin { password = "" }
            }
        }
    }

    static func message(for error: any Error, server: SavedServer) -> String {
        if let plex = error as? PlexError { return plex.localizedDescription }
        if let profile = error as? ProfileSwitchError { return profile.localizedDescription }
        return "That \(server.credentialName) didn't work. \(error.localizedDescription)"
    }
}

/// The server in use after the app was away longer than its lock-after (or
/// as it opens, for a profile with a PIN): the user's password or PIN,
/// checked by the server, to carry on, or another server.
struct ServerLockView: View {
    let server: SavedServer

    @Environment(AppSession.self) private var session
    @State private var password = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var errorAttempt = 0

    #if os(tvOS)
    private static let avatarSize: CGFloat = 110
    #else
    private static let avatarSize: CGFloat = 72
    #endif

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            OnboardingLayout {
                VStack(spacing: Onboarding.sectionSpacing) {
                    VStack(spacing: 12) {
                        if server.asksProfilePin {
                            HouseholdProfileHeader(server: server, size: Self.avatarSize)
                            Text(server.session.userName)
                                .font(.system(size: Onboarding.serverNameSize, weight: .bold))
                            Text("Enter your PIN to carry on.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.system(size: Onboarding.logoSize * 0.7))
                                .foregroundStyle(.secondary)
                            Text(server.session.serverName ?? "Server")
                                .font(.system(size: Onboarding.serverNameSize, weight: .bold))
                            Text("Enter \(server.session.userName)'s \(server.credentialName) to carry on.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    VStack(spacing: Onboarding.controlSpacing) {
                        CredentialEntry(server: server, text: $password, errorAttempt: errorAttempt, isChecking: isChecking, onSubmit: check)
                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .font(.callout.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .id(errorAttempt)
                        }
                        HStack(spacing: 24) {
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
                            .disabled(isChecking || !CredentialEntry.isReady(password, for: server))
                            // In a household: someone else picks their own
                            // profile, without the locked one's PIN.
                            if server.session.household != nil {
                                Button("Switch Profile") { session.presentProfilePickerFromLock() }
                                    .onboardingSecondaryButton()
                                    .disabled(isChecking)
                            }
                            Button("Use Another Server") { session.changeServer() }
                                .onboardingSecondaryButton()
                        }
                        .tvFocusSection()
                    }
                    .frame(maxWidth: .infinity)
                    .tvFocusSection()
                }
                #if os(tvOS)
                .padding(.vertical, 60)
                #endif
            }
        }
    }

    private func check() {
        guard !isChecking, CredentialEntry.isReady(password, for: server) else { return }
        isChecking = true
        errorMessage = nil
        Task {
            defer { isChecking = false }
            do {
                session.unlock(with: try await session.signInAgain(to: server, password: password))
            } catch {
                errorAttempt += 1
                errorMessage = ServerPasswordSheet.message(for: error, server: server)
                if server.asksProfilePin { password = "" }
            }
        }
    }
}

extension View {
    /// A password field, or a PIN's (Plex Home's, a household profile's):
    /// digits, and nothing to autofill. On Apple TV the number keyboard,
    /// rather than the whole alphabet to scrub along.
    @ViewBuilder
    func credentialField(isPin: Bool) -> some View {
        if isPin {
            #if os(iOS) || os(tvOS)
            keyboardType(.numberPad)
            #else
            self
            #endif
        } else {
            textContentType(.password)
        }
    }
}
