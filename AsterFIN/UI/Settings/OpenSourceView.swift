//
//  OpenSourceView.swift
//  AsterFIN
//
//  Settings ▸ About ▸ Open Source & Licenses, also reached from the welcome
//  screen: Aster's own license, then every open-source component built into
//  the app, what it does here, and its license in full. The texts ship in
//  the app (the Licenses folder), copied from each project, as their
//  licenses ask.
//

import SwiftUI

/// One open-source component in the app.
nonisolated struct OpenSourceComponent: Identifiable, Hashable, Sendable {
    var name: String
    /// What it does in Aster.
    var role: String
    var license: String
    var url: String
    /// The bundled texts (in Licenses/, without ".txt"), in order.
    var files: [String]
    /// Anything the license or its holders ask to be said.
    var note: String?

    var id: String { name }

    /// Every component built into the app, by what it's for.
    static let groups: [(title: String, components: [OpenSourceComponent])] = [
        ("Playback", [
            OpenSourceComponent(
                name: "AetherEngine", role: "Aster's video player: plays the original files and switches tracks on the device.",
                license: "LGPL-3.0, with an App Store exception", url: "https://github.com/superuser404notfound/AetherEngine",
                files: ["AetherEngine", "GPL-3.0"],
                note: "Its complete source, and that of FFmpegBuild, is published at the addresses shown, so it can be studied, changed and rebuilt."
            ),
            OpenSourceComponent(
                name: "FFmpeg", role: "Opens and decodes the files AetherEngine plays, built as FFmpegBuild.",
                license: "LGPL-2.1 or later", url: "https://github.com/superuser404notfound/FFmpegBuild",
                files: ["LGPL-2.1"],
                note: "Built without GPL parts, with a few published patches; the configuration and patches are in FFmpegBuild's build script. FFmpeg is a trademark of Fabrice Bellard."
            ),
            OpenSourceComponent(
                name: "dav1d", role: "Decodes AV1 video.",
                license: "BSD-2-Clause", url: "https://code.videolan.org/videolan/dav1d", files: ["dav1d"]
            ),
            OpenSourceComponent(
                name: "zimg", role: "Scales and converts video frames.",
                license: "WTFPL", url: "https://github.com/sekrit-twc/zimg", files: ["zimg"]
            ),
            OpenSourceComponent(
                name: "libzvbi", role: "Reads teletext and broadcast captions.",
                license: "LGPL-2.1 (ure.c under MIT)", url: "https://github.com/zapping-vbi/zvbi",
                files: ["LGPL-2.1", "zvbi-ure"],
                note: "Built without its three GPL files, replaced by LGPL stubs, as FFmpegBuild's build script shows."
            ),
            OpenSourceComponent(
                name: "libdovi", role: "Reads Dolby Vision metadata, built as LibDovi.",
                license: "MIT", url: "https://github.com/superuser404notfound/LibDovi", files: ["LibDovi"]
            ),
            OpenSourceComponent(
                name: "TrueHD decoder", role: "Decodes Dolby TrueHD and Dolby Atmos sound, built as LibTrueHD from the truehdd project.",
                license: "MIT; the truehd and oamd crates under Apache-2.0", url: "https://github.com/superuser404notfound/LibTrueHD",
                files: ["LibTrueHD", "LibTrueHD-NOTICE", "Apache-2.0"],
                note: "Dolby, Dolby Atmos and Dolby TrueHD are trademarks of Dolby Laboratories, which isn't affiliated with or endorsing this software."
            ),
            OpenSourceComponent(
                name: "DTS:X decoder", role: "Decodes DTS, DTS-HD Master Audio and DTS:X sound, built as LibDTSX.",
                license: "Apache-2.0", url: "https://github.com/superuser404notfound/LibDTSX",
                files: ["LibDTSX-NOTICE", "Apache-2.0"],
                note: "DTS, DTS-HD, DTS-HD Master Audio and DTS:X are trademarks of DTS, Inc., which isn't affiliated with or endorsing this software."
            ),
            OpenSourceComponent(
                name: "SMBClient", role: "Reads files from network shares.",
                license: "MIT", url: "https://github.com/kishikawakatsumi/SMBClient", files: ["SMBClient"]
            ),
        ]),
        ("Styled subtitles", [
            OpenSourceComponent(
                name: "libass", role: "Draws ASS/SSA subtitles as their makers styled them.",
                license: "ISC", url: "https://github.com/libass/libass", files: ["libass"]
            ),
            OpenSourceComponent(
                name: "swift-ass-renderer", role: "Puts libass's subtitles on screen.",
                license: "MIT", url: "https://github.com/mihai8804858/swift-ass-renderer", files: ["swift-ass-renderer"]
            ),
            OpenSourceComponent(
                name: "swift-libass", role: "Builds libass and the libraries below for Apple's platforms.",
                license: "MIT", url: "https://github.com/mihai8804858/swift-libass", files: ["swift-libass"]
            ),
            OpenSourceComponent(
                name: "FreeType", role: "Draws the subtitles' fonts.",
                license: "FreeType License (FTL)", url: "https://freetype.org", files: ["freetype"],
                note: "Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved."
            ),
            OpenSourceComponent(
                name: "HarfBuzz", role: "Lays out text in every script.",
                license: "MIT (\u{201C}Old MIT\u{201D})", url: "https://github.com/harfbuzz/harfbuzz", files: ["harfbuzz"]
            ),
            OpenSourceComponent(
                name: "FriBidi", role: "Lays out right-to-left text.",
                license: "LGPL-2.1 or later", url: "https://github.com/fribidi/fribidi", files: ["fribidi"]
            ),
            OpenSourceComponent(
                name: "Fontconfig", role: "Finds the fonts subtitles ask for.",
                license: "MIT-style", url: "https://gitlab.freedesktop.org/fontconfig/fontconfig", files: ["fontconfig"]
            ),
            OpenSourceComponent(
                name: "libpng", role: "Reads PNG images for libass.",
                license: "PNG Reference Library License v2", url: "https://github.com/pnggroup/libpng", files: ["libpng"]
            ),
        ]),
        ("Swift libraries", [
            OpenSourceComponent(
                name: "swift-issue-reporting", role: "Reports problems while the app is developed.",
                license: "MIT", url: "https://github.com/pointfreeco/swift-issue-reporting", files: ["swift-issue-reporting"]
            ),
            OpenSourceComponent(
                name: "swift-concurrency-extras", role: "Helpers for Swift concurrency.",
                license: "MIT", url: "https://github.com/pointfreeco/swift-concurrency-extras", files: ["swift-concurrency-extras"]
            ),
            OpenSourceComponent(
                name: "combine-schedulers", role: "Scheduling helpers used by the libraries above.",
                license: "MIT", url: "https://github.com/pointfreeco/combine-schedulers", files: ["combine-schedulers"]
            ),
        ]),
    ]

    /// Aster itself.
    static let aster = OpenSourceComponent(
        name: "Aster Media Player", role: "This app.",
        license: "Mozilla Public License 2.0", url: "https://github.com/AsterMediaPlayer/Aster-Media-Player",
        files: ["Aster-MPL-2.0"]
    )

    /// A bundled license text; nil if it's missing from the app.
    static func text(_ file: String) -> String? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

struct OpenSourceView: View {
    var body: some View {
        Form {
            #if !os(macOS)
            Section {
                Text("Open Source & Licenses")
                    .font(.largeTitle.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
            }
            #endif
            Section {
                NavigationLink(value: OpenSourceComponent.aster) {
                    ComponentRow(component: .aster)
                }
                OpenSourceNote("Aster is open source, under the Mozilla Public License 2.0. You're free to use, change and share it; changed files of Aster you share must stay under the same license. Its source is at \(OpenSourceComponent.aster.url).")
                OpenSourceNote("The Aster name and icon aren't part of the license. Aster isn't affiliated with or endorsed by Jellyfin, Emby or Plex.")
            } header: {
                Text("Aster")
            }
            ForEach(OpenSourceComponent.groups, id: \.title) { group in
                Section {
                    ForEach(group.components) { component in
                        NavigationLink(value: component) {
                            ComponentRow(component: component)
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
            Section {
                OpenSourceNote("Each component keeps its own license; select one to read it in full. Where a license is the LGPL, you may replace that component with your own build of it: the source of each, and of Aster, is at the address shown.")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .navigationTitle("Open Source & Licenses")
        #endif
        .navigationDestination(for: OpenSourceComponent.self) { component in
            LicenseTextView(component: component)
        }
    }
}

/// A component's name, what it does, and its license.
private struct ComponentRow: View {
    let component: OpenSourceComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(component.name)
                .font(.headline)
            Text(component.role)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(component.license)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Secondary text in the list; focusable on Apple TV so the remote can
/// reach every part of the page.
private struct OpenSourceNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            #if os(tvOS)
            .focusable()
            #endif
    }
}

/// A component's license in full: its address, any notice, then each text.
private struct LicenseTextView: View {
    let component: OpenSourceComponent

    /// The texts in paragraphs, so the Apple TV remote can scroll through
    /// them a paragraph at a time.
    private var paragraphs: [String] {
        component.files.flatMap { file -> [String] in
            let text = OpenSourceComponent.text(file) ?? "This license text is missing from the app; it's at \(component.url)."
            return text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .newlines) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(component.name)
                    .font(.largeTitle.weight(.bold))
                Text(component.license)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                address
                if let note = component.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Divider()
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #if os(tvOS)
                        .focusable()
                        #else
                        .textSelection(.enabled)
                        #endif
                }
            }
            .padding(LicenseMetrics.padding)
            .frame(maxWidth: LicenseMetrics.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if !os(tvOS)
        .navigationTitle(component.name)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// A link where there's a browser; the address to type in on Apple TV.
    @ViewBuilder
    private var address: some View {
        #if os(tvOS)
        Text(component.url)
            .font(.callout)
            .foregroundStyle(.secondary)
            .focusable()
        #else
        if let url = URL(string: component.url) {
            Link(component.url, destination: url)
                .font(.callout)
        }
        #endif
    }
}

private enum LicenseMetrics {
    #if os(tvOS)
    static let padding: CGFloat = 80
    static let maxWidth: CGFloat = 1500
    #else
    static let padding: CGFloat = 20
    static let maxWidth: CGFloat = 760
    #endif
}
