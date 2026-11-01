//
//  SeerrViews.swift
//  AsterFIN
//
//  Settings › Requests (the Seerr address and sign-in), the Request shelf
//  under Search's results, and Discover's rows; each title opens its page
//  (SeerrTitlePage).
//

import SwiftUI

// MARK: - Settings

struct SeerrSettingsView: View {
    @Environment(AppSession.self) private var session
    private let accounts = TrackerAccounts.shared
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var options: SeerrClient.Sign?
    @State private var working = false
    @State private var problem: String?

    private var account: SeerrAccount? { accounts.secrets.seerr }

    var body: some View {
        Form {
            if let account, !accounts.needsSignIn.contains("Seerr") {
                Section {
                    LabeledContent("Server", value: account.url.absoluteString)
                    LabeledContent("Signed in as", value: account.name)
                    Button("Sign Out", role: .destructive) { accounts.signOutOfSeerr() }
                } footer: {
                    Text("Search shows titles your server hasn't got yet, to request from Seerr. The sign-in reaches your other devices using this server account.")
                }
            } else {
                Section {
                    TextField("Seerr address", text: $address, prompt: Text("192.168.1.10:5055"))
                        .textContentType(.URL)
                        #if !os(macOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit { Task { await findServer() } }
                    if options == nil {
                        Button("Continue") { Task { await findServer() } }
                            .disabled(working || SeerrClient.address(address) == nil)
                    }
                } footer: {
                    Text("Seerr (or Overseerr, or Jellyseerr) asks your media server's helpers for films and shows it hasn't got. Aster shows nothing of it until you sign in here.")
                }
                if let options {
                    Section {
                        if options.signsInWithPlex, session.serverKind == .plex {
                            Button("Sign In with Plex") { Task { await signInWithPlex() } }
                        } else {
                            TextField(options.signsInWithJellyfinOrEmby ? "User name" : "Email", text: $username)
                                .textContentType(.username)
                                #if !os(macOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .autocorrectionDisabled()
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .onSubmit { Task { await signIn() } }
                            Button("Sign In") { Task { await signIn() } }
                                .disabled(working || username.isEmpty)
                        }
                    } footer: {
                        Text(options.signsInWithJellyfinOrEmby
                             ? "Your \(options.mediaServerType == 3 ? "Emby" : "Jellyfin") user name and password, as on Seerr's own site."
                             : options.signsInWithPlex ? "Your Plex account, as on Seerr's own site." : "Your Seerr account.")
                    }
                }
            }
            if working {
                Section { ProgressView() }
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Requests")
        .onAppear {
            if address.isEmpty { address = account?.url.absoluteString ?? "" }
            if username.isEmpty { username = session.userName ?? "" }
        }
    }

    private func findServer() async {
        guard let base = SeerrClient.address(address) else { return }
        working = true
        defer { working = false }
        do {
            options = try await SeerrClient.signInOptions(base)
            problem = nil
        } catch {
            problem = "No Seerr server answered at \(base.absoluteString)."
        }
    }

    private func signIn() async {
        guard let base = SeerrClient.address(address), let options else { return }
        working = true
        defer { working = false }
        do {
            let account = options.signsInWithJellyfinOrEmby
                ? try await SeerrClient.signIn(base, username: username, password: password)
                : try await SeerrClient.signIn(base, email: username, password: password)
            accounts.signedInToSeerr(account)
            password = ""
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func signInWithPlex() async {
        guard let base = SeerrClient.address(address), let token = session.plexAccountToken else { return }
        working = true
        defer { working = false }
        do {
            accounts.signedInToSeerr(try await SeerrClient.signIn(base, plexToken: token))
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Search

/// Titles Seerr knows that the server hasn't got: each opens its title page.
struct SeerrSearchShelf: View {
    let query: String

    private let accounts = TrackerAccounts.shared
    @State private var titles: [SeerrTitle] = []

    var body: some View {
        // A stack, not a Group: a Group's modifiers go on its contents, and
        // with no titles yet there are none, so the search never ran.
        VStack(alignment: .leading, spacing: 0) {
            if !titles.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Request")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, Lockup.screenPadding)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Lockup.shelfSpacing) {
                            ForEach(titles) { title in
                                SeerrTitleLockup(title: title)
                            }
                        }
                        .padding(.horizontal, Lockup.screenPadding)
                        .padding(.vertical, Lockup.shelfVerticalPadding)
                    }
                    .scrollClipDisabled()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, let account = accounts.secrets.seerr, !accounts.needsSignIn.contains("Seerr") else {
                titles = []
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            do {
                // What the server has already shows above, from the library.
                titles = Array(try await SeerrClient.search(term, account: account).filter { $0.status != .available }.prefix(20))
            } catch SeerrError.signedOut {
                accounts.seerrSignedOut()
                titles = []
            } catch {
                #if DEBUG
                print("DEBUG seerr: search failed: \(error)")
                #endif
                titles = []
            }
        }
    }
}

/// A title to request, as a library item looks; it opens its title page.
struct SeerrTitleLockup: View {
    let title: SeerrTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: title) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(url: title.posterURL, systemImage: title.isMovie ? "film" : "tv")
                        .frame(width: Lockup.posterWidth, height: Lockup.posterHeight)
                    if let label = title.status.label {
                        Text(label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(8)
                    }
                }
                .frame(width: Lockup.posterWidth, height: Lockup.posterHeight)
            }
            .cardButtonStyle()
            .accessibilityLabel([title.displayTitle, title.year, title.status.label].compactMap { $0 }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                Text([title.year, title.isMovie ? "Film" : "Series"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: Lockup.posterWidth, alignment: .leading)
        }
    }
}

// MARK: - Discover

/// A row of titles from Seerr to request, as library items look: Upcoming
/// Anime on the Anime tab. Each opens its title page (details, seasons,
/// Request). Nothing shows without a Seerr sign-in, or with nothing found.
struct SeerrDiscoverShelf: View {
    let title: String
    let load: @Sendable (SeerrAccount) async throws -> [SeerrTitle]

    private let accounts = TrackerAccounts.shared
    @State private var titles: [SeerrTitle] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Shelf(title: title, items: titles) { item in
                SeerrTitleLockup(title: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: accounts.secrets.seerr?.cookie) {
            guard let account = accounts.secrets.seerr, !accounts.needsSignIn.contains("Seerr") else {
                titles = []
                return
            }
            do {
                titles = try await load(account)
            } catch SeerrError.signedOut {
                accounts.seerrSignedOut()
            } catch {
                #if DEBUG
                print("DEBUG seerr: \(title) failed: \(error)")
                #endif
            }
        }
    }
}
