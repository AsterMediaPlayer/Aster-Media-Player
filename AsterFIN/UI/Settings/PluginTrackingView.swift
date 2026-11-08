//
//  PluginTrackingView.swift
//  AsterFIN
//
//  Settings › Tracking when the server has the Aster Discovery and Tracking
//  plugin: each service linked once, for every app, and what's watched or
//  listened to sent by the server. Link, Unlink, and a switch for sending;
//  and the plugin's log of the last sends, which is how people see it work.
//

import SwiftUI

struct PluginTrackingSections: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var accounts: TrackedAccounts?
    @State private var loaded = false
    @State private var linking: TrackedService?
    @State private var problem: String?
    private var plugin: AsterTracking { AsterTracking.shared }

    /// The services the server offers, by group, in a fixed order.
    private var groups: [(title: String, services: [TrackedService])] {
        let offered = TrackedService.allCases.filter { plugin.serves($0.rawValue) && accounts?.account($0)?.available != false }
        return ["Anime", "Films and Shows", "Music", "Audiobooks"].compactMap { title in
            let found = offered.filter { $0.group == title }
            return found.isEmpty ? nil : (title, found)
        }
    }

    var body: some View {
        Group {
            if !loaded {
                Section { ProgressView() }
            }
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.services) { service in
                        row(service)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if group.title == groups.last?.title {
                        Text("Linked on your server, so every Aster app on this server account has them, this one included, and the server sends what you watch or listen to, from any app.")
                    }
                }
            }
            if let accounts, let log = accounts.log, !log.isEmpty {
                Section {
                    ForEach(log.prefix(8)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title ?? "Something")
                            Text([entry.service, entry.result, entry.date.map { $0.formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        #if os(tvOS)
                        .focusable()
                        #endif
                    }
                } header: {
                    Text("Recent Sends")
                } footer: {
                    if let waiting = accounts.waiting, waiting > 0 {
                        Text("\(waiting) waiting to be tried again.")
                    }
                }
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .sheet(item: $linking) { service in
            TrackingLinkSheet(service: service) {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private func row(_ service: TrackedService) -> some View {
        let account = accounts?.account(service)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.title)
                    if let account, account.isLinked {
                        Text(linkedLine(account)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Not linked").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if account?.isLinked == true {
                    Button("Unlink", role: .destructive) { Task { await unlink(service) } }
                } else {
                    #if os(tvOS)
                    // Nobody pastes a token with a remote: those link elsewhere.
                    if service.flow != .paste {
                        Button("Link") { linking = service }
                    }
                    #else
                    Button("Link") { linking = service }
                    #endif
                }
            }
            if account?.isLinked == true {
                Toggle("Send what I \(service.verb)", isOn: Binding(
                    get: { accounts?.account(service)?.scrobble ?? true },
                    set: { on in Task { await setScrobble(service, on) } }
                ))
            }
            #if os(tvOS)
            if account?.isLinked != true, service.flow == .paste {
                Text("Link it on your server's dashboard (Plugins › Aster Discovery and Tracking), or in Aster on your phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .focusable()
            }
            #endif
        }
    }

    /// "Linked as Name", and when AniList's link needs doing again.
    private func linkedLine(_ account: TrackedAccount) -> String {
        var line = account.name.map { "Linked as \($0)" } ?? "Linked"
        if let expires = account.expires.flatMap(TrackingAPI.date) {
            line += expires < Date().addingTimeInterval(30 * 24 * 3600)
                ? " · link again by \(expires.formatted(date: .abbreviated, time: .omitted))"
                : " · until \(expires.formatted(date: .abbreviated, time: .omitted))"
        }
        return line
    }

    private func load() async {
        guard let client = session.jellyfin else { return }
        do {
            accounts = try await TrackingAPI.accounts(client: client)
            problem = nil
        } catch {
            problem = "Your server's linked accounts couldn't be read (\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))."
        }
        loaded = true
    }

    private func setScrobble(_ service: TrackedService, _ on: Bool) async {
        guard let client = session.jellyfin else { return }
        do {
            try await TrackingAPI.setScrobble(service, on, client: client)
            await load()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func unlink(_ service: TrackedService) async {
        guard let client = session.jellyfin else { return }
        do {
            try await TrackingAPI.unlink(service, client: client)
            await load()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Linking one service: a code to enter on its site (with a QR code), an
/// approval to give there, or a code to paste back, while the server waits
/// on the service and the app asks every few seconds whether it's done.
struct TrackingLinkSheet: View {
    let service: TrackedService
    var onLinked: () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var link: TrackedLink?
    @State private var pasted = ""
    @State private var working = false
    @State private var problem: String?
    @State private var expired = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Link \(service.title)")
                .font(.title2.weight(.bold))
            if let link {
                content(link)
            } else if let problem {
                Text(problem).foregroundStyle(.red).multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
            if expired {
                Text("That code ran out.").foregroundStyle(.secondary)
                sheetButton("Try Again", prominent: true) { attempt += 1 }
            }
            sheetButton("Cancel") { dismiss() }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .task(id: attempt) { await run() }
        // Pages in the background stop polling: ask again on coming back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, link != nil, link?.paste != true { Task { await check() } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    @ViewBuilder
    private func content(_ link: TrackedLink) -> some View {
        if link.paste == true {
            #if !os(tvOS)
            VStack(spacing: 14) {
                Text(service == .listenbrainz
                     ? "Open ListenBrainz, copy your user token, and paste it here."
                     : "Open \(service.title), sign in and approve Aster, then paste the code it shows here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let url = URL(string: link.url) {
                    Link(destination: url) { Label("Open \(service.title)", systemImage: "safari") }
                        .buttonStyle(.borderedProminent)
                }
                TextField("Paste the code", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .frame(maxWidth: 420)
                Button("Link \(service.title)") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty || working)
                if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            }
            #endif
        } else if let code = link.code {
            HStack(alignment: .center, spacing: 40) {
                if let qr = QRCode.image(for: link.completeUrl ?? link.url) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: Self.qrSize, height: Self.qrSize)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("On a phone or computer, go to").foregroundStyle(.secondary)
                    address(link)
                    Text("and enter").foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(size: Self.codeSize, weight: .bold, design: .monospaced))
                        #if !os(tvOS)
                        .textSelection(.enabled)
                        #endif
                }
            }
            waiting
        } else {
            // Last.fm: approve Aster on its page.
            HStack(alignment: .center, spacing: 40) {
                if let qr = QRCode.image(for: link.url) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: Self.qrSize, height: Self.qrSize)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Open \(service.title) and approve Aster.").foregroundStyle(.secondary)
                    address(link)
                    Text("\(service.title) may show an error page afterwards. Ignore it and come back here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            waiting
        }
    }

    private func address(_ link: TrackedLink) -> some View {
        #if os(tvOS)
        Text(link.url.replacingOccurrences(of: "https://", with: "")).font(.headline)
        #else
        Group {
            if let url = URL(string: link.url) {
                Link(link.url.replacingOccurrences(of: "https://", with: ""), destination: url).font(.headline)
            }
        }
        #endif
    }

    private var waiting: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Waiting for \(service.title)…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sheetButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        ActionButton(title: title, systemImage: prominent ? "arrow.clockwise" : "xmark", prominent: prominent, action: action)
        #else
        if prominent {
            Button(title, action: action).buttonStyle(.borderedProminent)
        } else {
            Button(title, role: .cancel, action: action)
        }
        #endif
    }

    #if os(tvOS)
    private static let qrSize: CGFloat = 320
    private static let codeSize: CGFloat = 64
    #else
    private static let qrSize: CGFloat = 180
    private static let codeSize: CGFloat = 34
    #endif

    /// Starts linking, then (for the code and approve flows) asks every few
    /// seconds whether it's done.
    private func run() async {
        guard let client = session.jellyfin else { return }
        expired = false
        problem = nil
        link = nil
        do {
            let started = try await TrackingAPI.startLink(service, client: client)
            link = started
            guard started.paste != true else { return }
            let interval = max(started.interval ?? 5, 3)
            let deadline = Date().addingTimeInterval(TimeInterval(started.expiresIn ?? 600))
            while !Task.isCancelled, Date() < deadline {
                try await Task.sleep(for: .seconds(interval))
                if await check() { return }
            }
            if !Task.isCancelled { expired = true }
        } catch is CancellationError {
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// One check for the code and approve flows. True once linked.
    @discardableResult
    private func check() async -> Bool {
        guard let client = session.jellyfin else { return false }
        switch (try? await TrackingAPI.complete(service, client: client)) ?? .waiting {
        case .linked:
            DebugLog.note("tracking", "Linked \(service.rawValue)")
            onLinked()
            dismiss()
            return true
        case .expired:
            expired = true
            return true
        case .failed(let message):
            problem = message
            return false
        case .waiting:
            return false
        }
    }

    /// The pasted code or token, for the paste flows.
    private func submit() async {
        guard let client = session.jellyfin else { return }
        working = true
        defer { working = false }
        do {
            switch try await TrackingAPI.complete(service, pasted: pasted.trimmingCharacters(in: .whitespacesAndNewlines), client: client) {
            case .linked:
                DebugLog.note("tracking", "Linked \(service.rawValue)")
                onLinked()
                dismiss()
            case .waiting: problem = "Not linked yet. Try again."
            case .expired: expired = true
            case .failed(let message): problem = message
            }
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
