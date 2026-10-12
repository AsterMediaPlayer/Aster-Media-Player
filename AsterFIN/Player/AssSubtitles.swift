//
//  AssSubtitles.swift
//  AsterFIN
//
//  ASS/SSA subtitles drawn as the release intended, with libass (through
//  swift-ass-renderer): signs at their positions and angles, vector
//  drawings, blur and clips, in the fonts embedded in the video's file.
//  Anime tracks lean on all of this; as plain text their signs land in the
//  dialogue spot and their drawings read as coordinates. Other formats, and
//  any track that fails to load here, use `SubtitleOverlayView`.
//

import AVFoundation
import CoreText
import SwiftUI
#if canImport(SwiftAssRenderer)
import SwiftAssRenderer
#endif

/// A loaded ASS/SSA track: its script in libass, and its fonts registered
/// for this app while it plays.
@MainActor
final class AssSubtitleTrack {
    /// Whether libass is in this build (the package is linked).
    static var isAvailable: Bool {
        #if canImport(SwiftAssRenderer)
        true
        #else
        false
        #endif
    }

    /// Whether `track` is one libass should draw.
    static func handles(_ track: MediaStream) -> Bool {
        let codec = (track.codec ?? "").lowercased()
        return codec == "ass" || codec == "ssa"
    }

    #if canImport(SwiftAssRenderer)
    let renderer: AssSubtitlesRenderer
    #endif
    private var fontURLs: [URL] = []

    #if canImport(SwiftAssRenderer)
    private init(renderer: AssSubtitlesRenderer, fontURLs: [URL]) {
        self.renderer = renderer
        self.fontURLs = fontURLs
    }
    #endif

    /// Fetches the script and the file's fonts, then loads them. Fonts are
    /// kept in Caches per title, so a second play doesn't fetch them again.
    static func load(
        itemId: String,
        mediaSourceId: String,
        streamIndex: Int,
        attachments: [MediaAttachment],
        client: JellyfinClient
    ) async throws -> AssSubtitleTrack {
        #if canImport(SwiftAssRenderer)
        async let script = client.subtitleScript(itemId: itemId, mediaSourceId: mediaSourceId, streamIndex: streamIndex)
        let fonts = await fetchFonts(attachments.filter(\.isFont), itemId: itemId, mediaSourceId: mediaSourceId, client: client)
        let content = try await script

        // CoreText finds the fonts registered here first, then the system's
        // for any the file doesn't carry ("Arial Unicode MS", say).
        register(fonts)
        let renderer = AssSubtitlesRenderer(
            fontConfig: FontConfig(
                fontsPath: fontsFolder(for: itemId),
                defaultFontFamily: "Helvetica Neue",
                fontProvider: .coreText
            )
        )
        renderer.loadTrack(content: content)
        return AssSubtitleTrack(renderer: renderer, fontURLs: fonts)
        #else
        throw JellyfinError.decoding("Styled subtitles aren't in this build")
        #endif
    }

    /// Shows the subtitles for `seconds` into the title.
    func update(seconds: Double) {
        #if canImport(SwiftAssRenderer)
        guard seconds.isFinite else { return }
        renderer.setTimeOffset(seconds)
        #endif
    }

    /// Frees the script and unregisters its fonts.
    func unload() {
        #if canImport(SwiftAssRenderer)
        renderer.freeTrack()
        #endif
        Self.unregister(fontURLs)
        fontURLs = []
    }

    // MARK: Fonts

    private static func fontsFolder(for itemId: String) -> URL {
        URL.cachesDirectory.appending(path: "ass-fonts", directoryHint: .isDirectory).appending(path: itemId, directoryHint: .isDirectory)
    }

    /// The title's fonts on disk, fetching those not already there. A font
    /// that fails to arrive is skipped; libass falls back for it.
    private static func fetchFonts(_ fonts: [MediaAttachment], itemId: String, mediaSourceId: String, client: JellyfinClient) async -> [URL] {
        let folder = fontsFolder(for: itemId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return await withTaskGroup(of: URL?.self) { group in
            for font in fonts {
                // The attachment's own name, made safe for a file name.
                let name = (font.fileName ?? "font-\(font.index)").replacingOccurrences(of: "/", with: "_")
                let file = folder.appending(path: "\(font.index)-\(name)")
                group.addTask {
                    if FileManager.default.fileExists(atPath: file.path) { return file }
                    guard let data = try? await client.attachment(itemId: itemId, mediaSourceId: mediaSourceId, index: font.index) else { return nil }
                    return (try? data.write(to: file, options: .atomic)) == nil ? nil : file
                }
            }
            var found: [URL] = []
            for await url in group {
                if let url { found.append(url) }
            }
            return found
        }
    }

    private static func register(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, false, nil)
    }

    private static func unregister(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        CTFontManagerUnregisterFontURLs(urls as CFArray, .process, nil)
    }
}

/// Draws an ASS track exactly over the picture, so the script's positions
/// (`\pos(336,172)` on a 1920×1080 canvas) land where the release put them.
struct AssSubtitleOverlay: View {
    let track: AssSubtitleTrack
    /// The video's size; 16:9 until the player knows it.
    var videoSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let aspect = videoSize.width > 0 && videoSize.height > 0 ? videoSize : CGSize(width: 16, height: 9)
            let picture = AVMakeRect(aspectRatio: aspect, insideRect: CGRect(origin: .zero, size: proxy.size))
            content
                .frame(width: picture.width, height: picture.height)
                .position(x: picture.midX, y: picture.midY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        #if canImport(SwiftAssRenderer)
        AssSubtitles(renderer: track.renderer)
        #else
        Color.clear
        #endif
    }
}
