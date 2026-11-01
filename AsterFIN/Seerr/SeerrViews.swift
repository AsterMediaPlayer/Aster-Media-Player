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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Seerr (or Overseerr, or Jellyseerr) asks your media server's helpers for films and shows it hasn't got. Aster shows nothing of it until you sign in here.")
                        if Self.isBareName(address) {
                            // The sign-in syncs to every device, and an Apple
                            // TV can't find a one-word name ("server") that a
                            // phone or Mac finds through the local network.
                            Text("Your other devices may not find a name without dots, the Apple TV especially. Use its IP address (192.168.1.10:5055) or its full name.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if let options, options.mediaServerType == 2, options.mediaServerLogin != false, let base = SeerrClient.address(address) {
                    Section {
                        SeerrQuickConnect(base: base) { account in
                            accounts.signedInToSeerr(account)
                            problem = nil
                        }
                    } footer: {
                        Text(session.jellyfin == nil
                             ? "Approve the code in Jellyfin, or sign in with a user name and password below."
                             : "Signs in to Seerr as your Jellyfin user, with nothing to type. Needs Quick Connect turned on in Jellyfin.")
                    }
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

    /// A one-word host such as "server", found only through the local
    /// network's search domain, which not every device uses.
    static func isBareName(_ text: String) -> Bool {
        guard let host = SeerrClient.address(text)?.host(), host != "localhost" else { return false }
        return !host.contains(".") && !host.contains(":")
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

// MARK: - Quick Connect

/// Signs in to Seerr with Jellyfin's Quick Connect. Signed in to that
/// same Jellyfin, the app approves Seerr's code itself: one press, nothing
/// to type, which suits the TV. Otherwise (Seerr uses another Jellyfin)
/// the code shows, to approve in Jellyfin's Quick Connect page.
struct SeerrQuickConnect: View {
    let base: URL
    var onSignedIn: (SeerrAccount) -> Void

    @Environment(AppSession.self) private var session
    @State private var code: String?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await signIn() }
            } label: {
                Label(session.jellyfin == nil ? "Sign In with Quick Connect" : "Sign In with Jellyfin", systemImage: "bolt.horizontal.circle")
            }
            #if os(tvOS)
            .actionButtonStyle(prominent: true)
            #endif
            .disabled(working)
            if working, code == nil {
                ProgressView()
            }
            if let code {
                Text("Approve this code in Jellyfin (Settings › Quick Connect):")
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .tracking(6)
                    .textSelectionIfAvailable()
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
    }

    private func signIn() async {
        working = true
        problem = nil
        code = nil
        defer { working = false }
        do {
            let start = try await SeerrClient.quickConnectStart(base)
            // Approved here when it's the same Jellyfin; else shown to approve.
            if let jellyfin = session.jellyfin, (try? await jellyfin.quickConnectAuthorize(code: start.code)) == true {
                // Approved; Seerr notices within a moment.
            } else {
                code = start.code
            }
            // Five minutes, as long as Jellyfin keeps a code.
            for _ in 0 ..< 150 {
                if try await SeerrClient.quickConnectApproved(base, secret: start.secret) {
                    onSignedIn(try await SeerrClient.signIn(base, quickConnectSecret: start.secret))
                    code = nil
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            code = nil
            problem = "The code ran out. Try again."
        } catch is CancellationError {
        } catch {
            code = nil
            problem = (error as? LocalizedError)?.errorDescription ?? "Seerr's Quick Connect didn't work. Is Quick Connect turned on in Jellyfin?"
        }
    }
}

private extension View {
    @ViewBuilder
    func textSelectionIfAvailable() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }
}

// MARK: - Where a request goes

/// Whether the signed-in Seerr user manages requests (an admin), asked
/// once per sign-in.
@MainActor
enum SeerrPermissions {
    private static var known: [String: Bool] = [:]

    static func managesRequests(_ account: SeerrAccount) async -> Bool {
        if let answer = known[account.cookie] { return answer }
        let answer = (try? await SeerrClient.me(account: account))?.managesRequests ?? false
        known[account.cookie] = answer
        return answer
    }
}

/// An admin's choice of where a request goes, as Seerr's own Advanced
/// panel offers it: which Sonarr or Radarr, the folder, the quality, and
/// Sonarr's language. It starts on Seerr's defaults (its anime ones for an
/// anime show), or on what a pending request already has.
struct SeerrDestinationSheet: View {
    let kind: SeerrFilter.Kind
    /// Starts on the anime folder and profile.
    var anime = false
    /// What's set already, when changing a pending request.
    var current: SeerrRequestOptions?
    /// Only the 4K servers (true), only the usual ones (false), or both.
    var fourK: Bool?
    var confirmTitle = "Request"
    /// Nil when Seerr has no server to choose (it then uses its default).
    let confirm: (SeerrRequestOptions?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    private let accounts = TrackerAccounts.shared
    @State private var services: [SeerrService] = []
    @State private var choices: [Int: SeerrServiceChoices] = [:]
    @State private var options: SeerrRequestOptions?
    @State private var loading = true
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    ProgressView()
                } else if let options {
                    if services.count > 1 {
                        Picker("Server", selection: serverBinding) {
                            ForEach(services) { server in
                                Text(server.is4k == true && !server.name.localizedCaseInsensitiveContains("4k") ? "\(server.name) (4K)" : server.name)
                                    .tag(server.id)
                            }
                        }
                        .destinationPickerStyle()
                    }
                    if let found = choices[options.serverId] {
                        if let folders = found.rootFolders, !folders.isEmpty {
                            Picker("Folder", selection: binding(\.rootFolder)) {
                                ForEach(folders, id: \.path) { folder in
                                    Text(folderLabel(folder)).tag(Optional(folder.path))
                                }
                            }
                            .destinationPickerStyle()
                        }
                        if let profiles = found.profiles, !profiles.isEmpty {
                            Picker("Quality", selection: binding(\.profileId)) {
                                ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .destinationPickerStyle()
                        }
                        if let languages = found.languageProfiles, !languages.isEmpty {
                            Picker("Language", selection: binding(\.languageProfileId)) {
                                ForEach(languages) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .destinationPickerStyle()
                        }
                    } else {
                        ProgressView()
                    }
                } else {
                    Text("Seerr has no \(kind == .tv ? "Sonarr" : "Radarr") server to choose; it uses its own setting.")
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            #if os(tvOS)
            // A TV sheet shows no toolbar, so its buttons sit below, in the
            // app's own style (a list row's focus read white on white).
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 40) {
                    ActionButton(title: confirmTitle, systemImage: "checkmark", prominent: true) {
                        Task { await finish() }
                    }
                    .disabled(loading || working)
                    ActionButton(title: "Cancel", systemImage: "xmark") { dismiss() }
                }
                .padding(.vertical, 24)
            }
            #endif
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(kind == .tv ? "Where the Series Goes" : "Where the Movie Goes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { Task { await finish() } }
                        .disabled(loading || working)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 300)
        #endif
        .task { await load() }
    }

    /// "/data/anime (2.1 TB free)".
    private func folderLabel(_ folder: SeerrServiceChoices.Folder) -> String {
        guard let free = folder.freeSpace else { return folder.path }
        return "\(folder.path) (\(free.formatted(.byteCount(style: .file))) free)"
    }

    private var serverBinding: Binding<Int> {
        Binding(get: { options?.serverId ?? 0 }, set: { id in
            guard let server = services.first(where: { $0.id == id }) else { return }
            options = SeerrRequestOptions(server: server, anime: anime)
            Task { await loadChoices(for: id) }
        })
    }

    private func binding<Value>(_ path: WritableKeyPath<SeerrRequestOptions, Value>) -> Binding<Value> {
        Binding(get: { options![keyPath: path] }, set: { options?[keyPath: path] = $0 })
    }

    private func load() async {
        defer { loading = false }
        guard let account = accounts.secrets.seerr else { return }
        do {
            services = try await SeerrClient.services(kind, fourK: fourK, account: account)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        // The request's own server; else the default (the usual copy's,
        // unless only 4K ones are offered).
        let start = current.flatMap { current in services.first { $0.id == current.serverId && ($0.is4k ?? false) == current.is4k } }
            ?? services.first { $0.isDefault == true && ($0.is4k ?? false) == (fourK ?? false) }
            ?? services.first
        guard let start else { return }
        options = current?.serverId == start.id ? current : SeerrRequestOptions(server: start, anime: anime)
        await loadChoices(for: start.id)
    }

    private func loadChoices(for server: Int) async {
        guard choices[server] == nil, let account = accounts.secrets.seerr else { return }
        do {
            choices[server] = try await SeerrClient.serviceChoices(kind, server: server, account: account)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func finish() async {
        working = true
        defer { working = false }
        do {
            try await confirm(options)
            dismiss()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}


private extension View {
    /// Menus on the TV, where a sheet's list-style pickers showed blank;
    /// the platform's own style elsewhere.
    @ViewBuilder
    func destinationPickerStyle() -> some View {
        #if os(tvOS)
        pickerStyle(.menu)
        #else
        self
        #endif
    }
}
