//
//  AudioAccessory.swift
//  AsterFIN
//
//  The song or audiobook playing, on every tab: under the tab bar on iPhone
//  and iPad, at the foot of the sidebar on the Mac. Play/pause right there,
//  and a tap on the rest opens the full player. Apple TV has no place for
//  it beside the tabs, so there the remote's Play/Pause works anywhere and
//  the Music and Audiobooks tabs keep their own bars.
//

import SwiftUI

extension AppSession {
    /// Whether a song or a book is loaded (playing or paused).
    var isAudioLoaded: Bool { music.current != nil || audiobooks.book != nil }

    var isAudioPlaying: Bool { music.isPlaying || audiobooks.isPlaying }

    /// Pauses or resumes whichever is loaded; only one ever is.
    func toggleAudio() {
        if audiobooks.book != nil {
            audiobooks.togglePlayPause()
        } else if music.current != nil {
            music.togglePlayPause()
        }
    }

    /// Opens the full player for whichever is loaded.
    func showAudioPlayer() {
        if audiobooks.book != nil {
            audiobooks.isNowPlayingPresented = true
        } else if music.current != nil {
            music.isNowPlayingPresented = true
        }
    }
}

struct AudioAccessory: View {
    @Environment(AppSession.self) private var session
    #if os(iOS)
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    #endif

    #if os(macOS)
    private static let artworkSize: CGFloat = 36
    #else
    private static let artworkSize: CGFloat = 32
    #endif

    /// What to show: title, the line under it, the cover, and its fallback.
    private var summary: (title: String, detail: String?, artwork: URL?, symbol: String)? {
        if let book = session.audiobooks.book {
            var artwork = session.client?.posterURL(for: book.cover, width: 200)
            #if os(iOS)
            if let saved = AudiobookDownloads.shared.coverURL(for: book.id) { artwork = saved }
            #endif
            let detail = session.audiobooks.currentChapter?.title ?? book.author
            return (book.title, detail, artwork, "book.closed.fill")
        }
        if let track = session.music.current {
            return (track.displayTitle, track.artistText ?? track.album, session.client?.posterURL(for: track, width: 200), "music.note")
        }
        return nil
    }

    /// Inline beside a shrunken tab bar there's room for the title alone.
    private var showsDetail: Bool {
        #if os(iOS)
        placement != .inline
        #else
        true
        #endif
    }

    var body: some View {
        if let summary {
            HStack(spacing: 10) {
                Button {
                    session.showAudioPlayer()
                } label: {
                    HStack(spacing: 10) {
                        RemoteImage(url: summary.artwork, systemImage: summary.symbol)
                            .frame(width: Self.artworkSize, height: Self.artworkSize)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(summary.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if showsDetail, let detail = summary.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(summary.title)")
                .accessibilityHint("Opens the player")

                Button {
                    session.toggleAudio()
                } label: {
                    Image(systemName: session.isAudioPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isAudioPlaying ? "Pause" : "Play")
                #if os(macOS)
                .help(session.isAudioPlaying ? "Pause (Space)" : "Play (Space)")
                #endif
            }
            .padding(.horizontal, 12)
            #if os(macOS)
            .padding(.vertical, 6)
            #endif
        }
    }
}
