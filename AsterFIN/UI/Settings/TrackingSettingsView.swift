//
//  TrackingSettingsView.swift
//  AsterFIN
//
//  Settings › Tracking: AniList and MyAnimeList, signed in to on the
//  service's own page (iPhone, iPad, Mac), and on a TV, which can't show
//  one, who's signed in through the other apps.
//

import SwiftUI
#if !os(tvOS)
import AuthenticationServices
#endif

struct TrackingSettingsView: View {
    @AppStorage(AppSettings.trackWatchingKey) private var trackWatching = true
    private let accounts = TrackerAccounts.shared
    @State private var working: String?
    @State private var problem: String?
    #if !os(tvOS)
    @Environment(\.webAuthenticationSession) private var webAuthentication
    #endif

    var body: some View {
        Form {
            Section {
                if !TrackerKeys.aniListClientId.isEmpty {
                    accountRow("AniList", name: accounts.secrets.aniList?.name, signIn: signInToAniList, signOut: accounts.signOutOfAniList)
                }
                if !TrackerKeys.myAnimeListClientId.isEmpty {
                    accountRow("MyAnimeList", name: accounts.secrets.myAnimeList?.name, signIn: signInToMyAnimeList, signOut: accounts.signOutOfMyAnimeList)
                }
            } header: {
                Text("Accounts")
            } footer: {
                #if os(tvOS)
                Text("Sign in with Aster on your iPhone, iPad or Mac, or on Windows or Linux. It's quicker there, and the sign-in reaches every device using this server account, this Apple TV included.")
                #else
                Text("Signed in here, an account reaches every Aster app using this server account, the Apple TV included: it's kept on your server, scrambled, and on this device.")
                #endif
            }
            Section {
                Toggle("Update when I watch", isOn: $trackWatching)
            } footer: {
                Text("An anime episode or film watched past 85% sets your progress on each account, marking the show Watching, or Completed after its last episode. Shows are matched by the AniList, MyAnimeList or AniDB ids your server has, else by name.")
            }
            if let last = accounts.lastUpdate {
                Section("Last Update") { Text(last) }
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Tracking")
    }

    @ViewBuilder
    private func accountRow(_ service: String, name: String?, signIn: @escaping () async -> Void, signOut: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(service)
                if accounts.needsSignIn.contains(service) {
                    Text("Sign in again").font(.caption).foregroundStyle(.orange)
                } else if let name {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not signed in").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            #if os(tvOS)
            if name != nil {
                Button("Sign Out", role: .destructive, action: signOut)
            }
            #else
            if working == service {
                ProgressView()
            } else if name != nil, !accounts.needsSignIn.contains(service) {
                Button("Sign Out", role: .destructive, action: signOut)
            } else {
                Button("Sign In") { Task { await signIn() } }
            }
            #endif
        }
    }

    private func signInToAniList() async {
        #if !os(tvOS)
        guard let url = AniList.signInURL else { return }
        working = "AniList"
        defer { working = nil }
        do {
            let back = try await webAuthentication.authenticate(using: url, callbackURLScheme: "aster", preferredBrowserSession: .shared)
            guard let found = AniList.token(fromRedirect: back) else { throw TrackerError.badReply }
            try await accounts.signedInToAniList(token: found.token, expires: found.expires)
            problem = nil
        } catch {
            note(error)
        }
        #endif
    }

    private func signInToMyAnimeList() async {
        #if !os(tvOS)
        guard let start = MyAnimeList.signIn() else { return }
        working = "MyAnimeList"
        defer { working = nil }
        do {
            let back = try await webAuthentication.authenticate(using: start.url, callbackURLScheme: "aster", preferredBrowserSession: .shared)
            guard let code = MyAnimeList.code(fromRedirect: back, state: start.state) else { throw TrackerError.badReply }
            try await accounts.signedInToMyAnimeList(try await MyAnimeList.tokens(code: code, verifier: start.verifier))
            problem = nil
        } catch {
            note(error)
        }
        #endif
    }

    private func note(_ error: Error) {
        #if !os(tvOS)
        // Closing the sign-in page isn't a problem.
        if let auth = error as? ASWebAuthenticationSessionError, auth.code == .canceledLogin { return }
        #endif
        problem = error.localizedDescription
    }
}
