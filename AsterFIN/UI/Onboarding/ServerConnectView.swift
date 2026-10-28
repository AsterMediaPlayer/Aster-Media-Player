//
//  ServerConnectView.swift
//  AsterFIN
//
//  First launch: ask for the Jellyfin or Emby server address (which it is
//  comes from the server's own reply; see `PublicSystemInfo.kind`).
//

import SwiftUI

struct ServerConnectView: View {
    @Environment(AppSession.self) private var session
    @State private var address: String = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var switchRequest: SavedServer?
    @State private var showingPlexSignIn = false

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            OnboardingLayout {
                VStack(spacing: Onboarding.sectionSpacing) {
                    VStack(spacing: 12) {
                        Image("AsterLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: Onboarding.logoWidth)
                            .accessibilityLabel("Aster Media Player")
                        Text("Connect to your Jellyfin or Emby server")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: Onboarding.controlSpacing) {
                        TextField("https://jellyfin.example.com", text: $address)
                            #if os(macOS)
                            .textContentType(.URL)
                            #else
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .onboardingField()
                            .frame(maxWidth: Onboarding.fieldWidth)
                            .onSubmit(connect)

                        Button {
                            connect()
                        } label: {
                            HStack {
                                if isConnecting { ProgressView().controlSize(.small) }
                                Text("Connect")
                            }
                            .frame(maxWidth: Onboarding.buttonWidth)
                        }
                        .onboardingPrimaryButton()
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)

                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                        }

                        // Plex is found through plex.tv, not by its address.
                        Button {
                            showingPlexSignIn = true
                        } label: {
                            Text("Sign in with Plex")
                                .frame(maxWidth: Onboarding.buttonWidth)
                        }
                        .onboardingSecondaryButton()
                    }

                    // Servers already signed in to: back to one without typing it.
                    if !session.savedServers.isEmpty {
                        VStack(spacing: Onboarding.controlSpacing) {
                            Text("Your Servers")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(session.savedServers) { server in
                                Button {
                                    switchRequest = server
                                } label: {
                                    SavedServerLabel(server: server)
                                        .frame(maxWidth: Onboarding.fieldWidth)
                                }
                                .onboardingSecondaryButton()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .tvFocusSection()
                    }
                }
            }
        }
        .savedServerSwitcher(request: $switchRequest)
        #if os(macOS)
        .sheet(isPresented: $showingPlexSignIn) {
            PlexSignInView()
                .frame(minWidth: 520, minHeight: 560)
        }
        #else
        .fullScreenCover(isPresented: $showingPlexSignIn) {
            PlexSignInView()
        }
        #endif
    }

    private func connect() {
        guard let url = Self.normalize(address) else {
            errorMessage = JellyfinError.invalidURL.localizedDescription
            return
        }
        isConnecting = true
        errorMessage = nil
        Task {
            defer { isConnecting = false }
            do {
                let info = try await JellyfinClient(baseURL: url).publicSystemInfo()
                session.useServer(url, info: info)
            } catch {
                // Retry over plain HTTP for LAN servers typed without a scheme.
                if url.scheme == "https", !address.lowercased().hasPrefix("https"),
                   var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    components.scheme = "http"
                    if components.port == nil { components.port = 8096 }
                    if let fallback = components.url, let info = try? await JellyfinClient(baseURL: fallback).publicSystemInfo() {
                        session.useServer(fallback, info: info)
                        return
                    }
                }
                errorMessage = "Could not reach a Jellyfin or Emby server at that address. \(error.localizedDescription)"
            }
        }
    }

    static func normalize(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }
}

/// Whether an address sends everything in the clear over the internet:
/// plain http:// to a host that isn't on the home network. Aster allows it
/// (many self-hosted servers are reached that way), and warns before a
/// password is sent.
nonisolated enum ServerAddress {
    static func isUnencryptedRemote(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        return !isLocal(host)
    }

    /// A name or address only the home network (or a private overlay such
    /// as Tailscale) reaches.
    static func isLocal(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || !host.contains(".") && !host.contains(":") { return true }
        if [".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain"].contains(where: host.hasSuffix) { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")
        }
        return false
    }
}

struct OnboardingBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.08, green: 0.09, blue: 0.14), Color.black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Sizes for the server and sign-in screens: TV-sized on tvOS, phone-sized
/// elsewhere. Widths are maximums, so fields and buttons shrink to fit.
enum Onboarding {
    #if os(tvOS)
    static let logoSize: CGFloat = 96
    static let logoWidth: CGFloat = 720
    static let titleSize: CGFloat = 64
    static let serverNameSize: CGFloat = 54
    static let fieldWidth: CGFloat = 900
    static let credentialsWidth: CGFloat = 700
    static let buttonWidth: CGFloat = 400
    static let signInButtonWidth: CGFloat = 300
    static let avatarSize: CGFloat = 180
    static let avatarInitialSize: CGFloat = 72
    static let avatarSpacing: CGFloat = 40
    static let avatarRowPadding: CGFloat = 60
    static let quickConnectCodeSize: CGFloat = 72
    static let sectionSpacing: CGFloat = 40
    static let controlSpacing: CGFloat = 24
    #else
    static let logoSize: CGFloat = 56
    static let logoWidth: CGFloat = 300
    static let titleSize: CGFloat = 36
    static let serverNameSize: CGFloat = 30
    static let fieldWidth: CGFloat = 420
    static let credentialsWidth: CGFloat = 420
    static let buttonWidth: CGFloat = 420
    static let signInButtonWidth: CGFloat = 420
    static let avatarSize: CGFloat = 72
    static let avatarInitialSize: CGFloat = 30
    static let avatarSpacing: CGFloat = 16
    static let avatarRowPadding: CGFloat = 0
    static let quickConnectCodeSize: CGFloat = 40
    static let sectionSpacing: CGFloat = 28
    static let controlSpacing: CGFloat = 14
    #endif
}

/// Centres the onboarding content. On iOS it scrolls inside the space above
/// the keyboard, so a focused field moves up to sit just above it, and a
/// downward drag puts the keyboard away.
struct OnboardingLayout<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(tvOS)
        content
        #else
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        #endif
    }
}

extension View {
    /// iOS text fields have no outline of their own; give them a filled
    /// rounded box. tvOS draws its own focused field. Use on a single text
    /// or secure field.
    @ViewBuilder
    func onboardingField() -> some View {
        #if os(tvOS)
        self
        #else
        modifier(OnboardingFieldBox())
        #endif
    }

    /// A filled, full-width button on iOS; the standard platter on tvOS.
    @ViewBuilder
    func onboardingPrimaryButton() -> some View {
        #if os(tvOS)
        self
        #else
        buttonStyle(.borderedProminent).controlSize(.large)
        #endif
    }

    /// An outlined button on iOS; the standard platter on tvOS.
    @ViewBuilder
    func onboardingSecondaryButton() -> some View {
        #if os(tvOS)
        self
        #else
        buttonStyle(.bordered).controlSize(.large)
        #endif
    }
}

#if !os(tvOS)
/// The filled box around an onboarding field, all of it tappable. Only the
/// field's line of text takes a tap by itself, so a tap in the box's padding
/// did nothing and the field took a few tries to get into.
private struct OnboardingFieldBox: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { isFocused = true }
    }
}
#endif
