//
//  SeerrViews.swift
//  AsterFIN
//
//  The Request shelf under Search's results, and Discover's rows; each
//  title opens its page (SeerrTitlePage).
//

import SwiftUI

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
            guard !term.isEmpty, let account = AsterTracking.shared.seerr else {
                titles = []
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            do {
                // What the server has already shows above, from the library.
                titles = Array(try await SeerrClient.search(term, account: account).filter { $0.status != .available }.prefix(20))
            } catch SeerrError.signedOut {
                AsterTracking.shared.noteRefused()
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
            // A stop for the Mac's arrow keys; Return opens it.
            .keyboardTarget(opening: title)
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
        .task(id: AsterTracking.shared.seerr?.authorization) {
            guard let account = AsterTracking.shared.seerr else {
                titles = []
                return
            }
            do {
                titles = try await load(account)
            } catch SeerrError.signedOut {
                AsterTracking.shared.noteRefused()
            } catch {
                #if DEBUG
                print("DEBUG seerr: \(title) failed: \(error)")
                #endif
            }
        }
    }
}

// MARK: - Where a request goes

/// Whether the signed-in Seerr user manages requests (an admin), asked
/// once per sign-in.
@MainActor
enum SeerrPermissions {
    private static var known: [String: Bool] = [:]

    static func managesRequests(_ account: SeerrAccount) async -> Bool {
        if let answer = known[account.authorization] { return answer }
        let answer = (try? await SeerrClient.me(account: account))?.managesRequests ?? false
        known[account.authorization] = answer
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
        guard let account = AsterTracking.shared.seerr else { return }
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
        guard choices[server] == nil, let account = AsterTracking.shared.seerr else { return }
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
