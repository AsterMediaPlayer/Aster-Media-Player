//
//  DeepLinkRouter.swift
//  AsterFIN
//
//  Links into the app, from the Top Shelf: `aster://item/{id}` opens a
//  title's page and `aster://play/{id}` starts playing it; `aster://channel/{id}` tunes in a
//  Channels-tab channel (from the On Now widget); `aster://downloads` opens
//  the Downloads tab (from the downloads Live Activity). A link that
//  arrives before the main screen exists is held until it can be used.
//

import Foundation
import Observation

@Observable
final class DeepLinkRouter {
    private(set) var pendingItemId: String?
    private(set) var pendingPlayItemId: String?
    /// A Channels-tab channel to tune in, from the On Now widget.
    private(set) var pendingChannelId: String?
    /// The Downloads tab, from the downloads Live Activity.
    private(set) var pendingDownloads = false
    /// Playback asked for from inside the app, such as a lockup's long-press
    /// menu, played by the main screen so any tab can start it.
    private(set) var pendingPlayback: PlaybackRequest?

    func play(_ request: PlaybackRequest) {
        pendingPlayback = request
    }

    /// Hands over the in-app playback request, once.
    func takePlayback() -> PlaybackRequest? {
        defer { pendingPlayback = nil }
        return pendingPlayback
    }

    func handle(_ url: URL) {
        // asterfin:// is the app's earlier name, still followed.
        guard ["aster", "asterfin"].contains(url.scheme?.lowercased() ?? "") else { return }
        let id = url.lastPathComponent
        if url.host()?.lowercased() == "downloads" {
            pendingDownloads = true
            return
        }
        guard !id.isEmpty, id != "/" else { return }
        switch url.host()?.lowercased() {
        case "play":
            pendingPlayItemId = id
        case "item":
            pendingItemId = id
        case "channel":
            pendingChannelId = id
        default:
            break
        }
    }

    func clear() {
        pendingItemId = nil
        pendingPlayItemId = nil
        pendingChannelId = nil
        pendingDownloads = false
        pendingPlayback = nil
    }
}
