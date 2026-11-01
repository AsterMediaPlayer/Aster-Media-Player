//
//  TrackingSettingsView.swift
//  AsterFIN
//
//  Settings › Tracking: AniList and MyAnimeList, signed in to on the
//  service's own page (iPhone, iPad, Mac), and on a TV, which can't show
//  one, who's signed in through the other apps.
//

import CoreImage.CIFilterBuiltins
import SwiftUI
#if !os(tvOS)
import AuthenticationServices
#endif

struct TrackingSettingsView: View {
    @AppStorage(AppSettings.trackWatchingKey) private var trackWatching = true
    private let accounts = TrackerAccounts.shared
    @State private var working: String?
    @State private var problem: String?
    /// The code sign-in showing (Trakt, Simkl), by service.
    @State private var codeSignIn: String?
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
                Text("Anime")
            } footer: {
                #if os(tvOS)
                Text("Sign in with Aster on your iPhone, iPad or Mac, or on Windows or Linux. It's quicker there, and the sign-in reaches every device using this server account, this Apple TV included.")
                #else
                Text("Signed in here, an account reaches every Aster app using this server account, the Apple TV included: it's kept on your server, scrambled, and on this device.")
                #endif
            }
            if TrackerKeys.hasTrakt || TrackerKeys.hasSimkl {
                Section {
                    if TrackerKeys.hasTrakt {
                        accountRow("Trakt", name: accounts.secrets.trakt?.name, byCode: true, signIn: { codeSignIn = "Trakt" }, signOut: accounts.signOutOfTrakt)
                    }
                    if TrackerKeys.hasSimkl {
                        accountRow("Simkl", name: accounts.secrets.simkl?.name, byCode: true, signIn: { codeSignIn = "Simkl" }, signOut: accounts.signOutOfSimkl)
                    }
                } header: {
                    Text("Films and Shows")
                } footer: {
                    Text("Everything you watch, films and every show, anime included, goes into your history there. Sign in with a code on any phone or computer; it reaches your other devices too.")
                }
            }
            Section {
                Toggle("Update when I watch", isOn: $trackWatching)
            } footer: {
                Text("A film or episode watched past 85% goes to each account: on AniList and MyAnimeList, anime only, setting your progress and marking the show Watching, or Completed after its last episode; on Trakt and Simkl, everything, into your history. Titles are matched by the ids your server has (TMDB, IMDb, TVDB, and for anime AniList, MyAnimeList or AniDB), else by name.")
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
        .sheet(item: Binding(get: { codeSignIn.map(CodeService.init) }, set: { codeSignIn = $0?.id })) { service in
            DeviceCodeSignIn(service: service.id)
        }
    }

    private struct CodeService: Identifiable { var id: String }

    @ViewBuilder
    private func accountRow(_ service: String, name: String?, byCode: Bool = false, signIn: @escaping () async -> Void, signOut: @escaping () -> Void) -> some View {
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
            if name != nil, !accounts.needsSignIn.contains(service) {
                Button("Sign Out", role: .destructive, action: signOut)
            } else if byCode {
                // A code sign-in works on the TV too.
                Button("Sign In") { Task { await signIn() } }
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

/// Signing in with a code: the code, where to enter it, and a QR code of
/// the address for a phone's camera, while the app waits for the service to
/// say it's been entered (Trakt and Simkl).
struct DeviceCodeSignIn: View {
    let service: String

    @Environment(\.dismiss) private var dismiss
    @State private var code: DeviceCode?
    @State private var problem: String?
    private let accounts = TrackerAccounts.shared

    var body: some View {
        VStack(spacing: 24) {
            Text("Sign in to \(service)")
                .font(.title2.weight(.bold))
            if let code {
                HStack(alignment: .center, spacing: 40) {
                    if let qr = QRCode.image(for: code.verificationURL.absoluteString) {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: Self.qrSize, height: Self.qrSize)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("On a phone or computer, go to")
                            .foregroundStyle(.secondary)
                        #if os(tvOS)
                        Text(code.verificationURL.absoluteString).font(.headline)
                        #else
                        Link(code.verificationURL.absoluteString, destination: code.verificationURL).font(.headline)
                        #endif
                        Text("and enter")
                            .foregroundStyle(.secondary)
                        Text(code.userCode)
                            .font(.system(size: Self.codeSize, weight: .bold, design: .monospaced))
                            #if !os(tvOS)
                            .textSelection(.enabled)
                            #endif
                    }
                }
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for \(service)…").foregroundStyle(.secondary)
                }
            } else if let problem {
                Text(problem).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            Button("Cancel", role: .cancel) { dismiss() }
        }
        .padding(40)
        .task { await run() }
    }

    #if os(tvOS)
    private static let qrSize: CGFloat = 320
    private static let codeSize: CGFloat = 64
    #else
    private static let qrSize: CGFloat = 180
    private static let codeSize: CGFloat = 34
    #endif

    /// Asks for a code, then whether it's been entered every few seconds,
    /// with a fresh code when one runs out.
    private func run() async {
        while !Task.isCancelled {
            do {
                let fresh = service == "Trakt" ? try await Trakt.startSignIn() : try await Simkl.startSignIn()
                code = fresh
                problem = nil
                while !Task.isCancelled, Date() < fresh.expires {
                    try await Task.sleep(for: .seconds(max(fresh.interval, 3)))
                    if service == "Trakt" {
                        if let tokens = try await Trakt.poll(fresh) {
                            try await accounts.signedInToTrakt(tokens)
                            dismiss()
                            return
                        }
                    } else if let token = try await Simkl.poll(fresh) {
                        try await accounts.signedInToSimkl(token: token)
                        dismiss()
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                code = nil
                problem = error.localizedDescription
                return
            }
        }
    }
}

nonisolated enum QRCode {
    /// `text` as a QR code, a pixel to a module.
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
