//
//  TitlePageSettingsView.swift
//  AsterFIN
//
//  Settings ▸ Title Pages.
//

import SwiftUI

/// Settings ▸ Title Pages: theme music and videos behind a title's page,
/// and ratings from MDBList.
struct TitlePageSettingsView: View {
    @AppStorage(AppSettings.themeMusicKey) private var themeMusic = false
    @AppStorage(AppSettings.themeVideosKey) private var themeVideos = false
    /// Kept in the Keychain, not in settings.
    @State private var mdbListKey = ""

    var body: some View {
        SettingsPage(title: "Title Pages") {
            Section {
                Toggle("Theme music", isOn: $themeMusic)
                Toggle("Theme videos", isOn: $themeVideos)
                SettingsNote("Plays a title's theme song quietly, or loops its theme video behind the page, when your library has them. Theme music stays off while you are listening to music.")
            }
            Section("Ratings") {
                SecureField("MDBList API key", text: $mdbListKey)
                    .textContentType(.password)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit { MDBList.apiKey = mdbListKey }
                    .onChange(of: mdbListKey) { _, key in MDBList.apiKey = key }
                SettingsNote(mdbListKey.isEmpty
                    ? "Title pages show the scores your server has. With a free MDBList key (from mdblist.com, under Preferences › API Access), films and shows also get IMDb, Rotten Tomatoes (critics and audience), Metacritic, Letterboxd and TMDB scores. The key stays on this device."
                    : "Films and shows get IMDb, Rotten Tomatoes, Metacritic, Letterboxd and TMDB scores from MDBList. Clear the key to stop asking it.")
            }
        }
        .onAppear { mdbListKey = MDBList.apiKey ?? "" }
    }
}
