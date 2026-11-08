//
//  TrailerPlayer.swift
//  AsterFIN
//
//  A trailer from YouTube played in the app, in YouTube's own embedded
//  player (its privacy-enhanced youtube-nocookie.com one), as YouTube's
//  terms allow, rather than leaving for the YouTube app. iPhone, iPad and
//  Mac; the Apple TV has no web view and hands off to the YouTube app.
//

#if !os(tvOS)
import SwiftUI
import WebKit

struct TrailerPlayer: View {
    struct Video: Identifiable, Hashable {
        /// YouTube's id for it.
        var id: String
        var title: String
    }

    let video: Video
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            YouTubeEmbed(videoID: video.id)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .navigationTitle(video.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 500)
        #endif
        .presentationBackground(.black)
    }
}

/// YouTube's embedded player for one video, starting at once.
private struct YouTubeEmbed {
    let videoID: String

    /// The page holding the player. YouTube wants to know which site embeds
    /// it (it refuses to play without), so the page is given Aster's own.
    private var html: String {
        let id = videoID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? videoID
        return """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&playsinline=1&rel=0&modestbranding=1&origin=\(Self.origin.absoluteString)"
                allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
                referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
    }

    private static let origin = URL(string: "https://astermediaplayer.com")!

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: configuration)
        #if os(iOS)
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .black
        #endif
        view.loadHTMLString(html, baseURL: Self.origin)
        return view
    }
}

#if os(iOS)
extension YouTubeEmbed: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
extension YouTubeEmbed: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
#endif
