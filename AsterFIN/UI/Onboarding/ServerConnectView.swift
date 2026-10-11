//
//  ServerConnectView.swift
//  AsterFIN
//
//  First launch: ask for the Jellyfin server address.
//

import SwiftUI

struct ServerConnectView: View {
    @Environment(AppSession.self) private var session
    @State private var address: String = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            OnboardingLayout {
                VStack(spacing: Onboarding.sectionSpacing) {
                    VStack(spacing: 12) {
                        Image(systemName: "opticaldisc.fill")
                            .font(.system(size: Onboarding.logoSize, weight: .thin))
                            .foregroundStyle(.white)
                        Text("AsterFIN")
                            .font(.system(size: Onboarding.titleSize, weight: .bold))
                        Text("Connect to your Jellyfin server")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: Onboarding.controlSpacing) {
                        TextField("https://jellyfin.example.com", text: $address)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
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
                    }
                }
            }
        }
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
                errorMessage = "Could not reach a Jellyfin server at that address. \(error.localizedDescription)"
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
    /// rounded box. tvOS draws its own focused field.
    @ViewBuilder
    func onboardingField() -> some View {
        #if os(tvOS)
        self
        #else
        padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
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
