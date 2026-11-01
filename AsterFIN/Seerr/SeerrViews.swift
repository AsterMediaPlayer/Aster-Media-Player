//
//  SeerrViews.swift
//  AsterFIN
//
//  Settings › Requests (the Seerr address and sign-in), the Request shelf
//  under Search's results, and the sheet that asks for a film or seasons.
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

/// Titles Seerr knows that the server hasn't got: each opens the request sheet.
struct SeerrSearchShelf: View {
    let query: String

    private let accounts = TrackerAccounts.shared
    @State private var titles: [SeerrTitle] = []
    @State private var requesting: SeerrTitle?

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
                                SeerrTitleLockup(title: title) { requesting = title }
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
        .sheet(item: $requesting) { title in
            SeerrRequestSheet(title: title) { updated in
                if let index = titles.firstIndex(where: { $0.id == updated.id }) { titles[index] = updated }
            }
        }
    }
}

struct SeerrTitleLockup: View {
    let title: SeerrTitle
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: action) {
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
            .keyboardTarget(action: action)
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

// MARK: - Requesting

struct SeerrRequestSheet: View {
    let title: SeerrTitle
    /// The title as it stands after a request.
    var requested: (SeerrTitle) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    private let accounts = TrackerAccounts.shared
    @State private var seasons: [(number: Int, episodes: Int?, status: SeerrStatus)] = []
    @State private var chosen: Set<Int> = []
    @State private var working = false
    @State private var problem: String?
    @State private var done = false

    /// Seasons nobody's asked for yet, which can be.
    private var open: [Int] { seasons.filter { $0.status == .unknown || $0.status == .deleted }.map(\.number) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        RemoteImage(url: title.posterURL, systemImage: title.isMovie ? "film" : "tv")
                            .frame(width: 90, height: 135)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title.displayTitle).font(.headline)
                            if let year = title.year { Text(year).foregroundStyle(.secondary) }
                            if let overview = title.overview {
                                Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(6)
                            }
                        }
                    }
                }
                if !title.isMovie {
                    Section("Seasons") {
                        if seasons.isEmpty {
                            ProgressView()
                        }
                        ForEach(seasons, id: \.number) { season in
                            let free = open.contains(season.number)
                            Toggle(isOn: Binding(get: { chosen.contains(season.number) || !free },
                                                 set: { on in if on { chosen.insert(season.number) } else { chosen.remove(season.number) } })) {
                                VStack(alignment: .leading) {
                                    Text("Season \(season.number)")
                                    Text([season.episodes.map { "\($0) episodes" }, season.status.label].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!free)
                        }
                    }
                }
                Section {
                    if done {
                        Label("Requested", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(title.isMovie ? "Request Film" : chosen.count == open.count && !open.isEmpty ? "Request All Seasons" : "Request \(chosen.count) Season\(chosen.count == 1 ? "" : "s")") {
                            Task { await request() }
                        }
                        .disabled(working || (!title.isMovie && chosen.isEmpty) || !title.status.canRequest && title.isMovie)
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                } footer: {
                    if title.isMovie, let label = title.status.label, !title.status.canRequest {
                        Text("Already \(label.lowercased()).")
                    }
                }
            }
            .navigationTitle("Request")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done ? "Done" : "Cancel") { dismiss() } }
            }
        }
        .task {
            guard !title.isMovie, let account = accounts.secrets.seerr,
                  let show = try? await SeerrClient.show(title.id, account: account) else { return }
            seasons = show.seasonStatus()
            chosen = Set(open)
        }
    }

    private func request() async {
        guard let account = accounts.secrets.seerr else { return }
        working = true
        defer { working = false }
        do {
            try await SeerrClient.request(title, seasons: chosen.sorted(), account: account)
            var updated = title
            updated.mediaInfo = SeerrTitle.MediaInfo(status: .pending)
            requested(updated)
            done = true
            problem = nil
        } catch SeerrError.signedOut {
            accounts.seerrSignedOut()
            problem = SeerrError.signedOut.localizedDescription
        } catch {
            problem = error.localizedDescription
        }
    }
}
