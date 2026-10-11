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
            VStack(spacing: 40) {
                VStack(spacing: 12) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 96, weight: .thin))
                        .foregroundStyle(.white)
                    Text("AsterFIN")
                        .font(.system(size: 64, weight: .bold))
                    Text("Connect to your Jellyfin server")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 24) {
                    TextField("https://jellyfin.example.com", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(width: 900)
                        .onSubmit(connect)

                    Button {
                        connect()
                    } label: {
                        HStack {
                            if isConnecting { ProgressView().controlSize(.small) }
                            Text("Connect")
                        }
                        .frame(width: 400)
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
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
