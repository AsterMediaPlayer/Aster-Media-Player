//
//  RemoteImage.swift
//  AsterFIN
//
//  Authenticated image loading with an in-memory cache, used for every
//  Jellyfin picture in the app and for disc-menu artwork.
//

import SwiftUI

/// Decoded images shared across the app. Network responses are also cached on
/// disk by the client's image URLSession.
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSURL, PlatformImage>()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    init() {
        cache.totalCostLimit = 300 * 1024 * 1024
    }

    func cached(_ url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL, client: JellyfinClient?) async -> PlatformImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = inFlight[url] { return await task.value }
        let task = Task<PlatformImage?, Never> {
            var data: Data?
            var decoded: PlatformImage?
            // Inline pictures, and covers saved with downloaded audiobooks.
            if url.scheme == "data" || url.isFileURL {
                data = try? Data(contentsOf: url)
            } else if let client {
                data = try? await client.data(from: url)
                decoded = data.flatMap { PlatformImage(data: $0) }
                // A damaged copy in the disk cache (zeros, from the app
                // stopping as it was written) would come back every time:
                // drop it and fetch the picture again, once.
                if decoded == nil, data != nil {
                    data = try? await client.data(from: url, fresh: true)
                }
            } else if let (body, response) = try? await JellyfinClient.imageSession.data(from: url),
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                // An error page decoded as a picture logs "possibly corrupt".
                data = body
            } else {
                data = nil
            }
            guard let data, let image = decoded ?? PlatformImage(data: data) else {
                #if DEBUG
                if let data {
                    let head = data.prefix(12).map { String(format: "%02x", $0) }.joined()
                    print("DEBUG images: couldn't decode \(data.count) bytes (starts \(head)) from \(url.path())")
                }
                #endif
                return nil
            }
            #if canImport(UIKit)
            return await image.byPreparingForDisplay() ?? image
            #else
            return image
            #endif
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result {
            let cost = result.platformCGImage.map { $0.bytesPerRow * $0.height } ?? Int(result.size.width * result.size.height * 4)
            cache.setObject(result, forKey: url as NSURL, cost: cost)
        }
        return result
    }

    func prefetch(_ urls: [URL], client: JellyfinClient?) {
        for url in urls where cache.object(forKey: url as NSURL) == nil {
            Task { _ = await image(for: url, client: client) }
        }
    }

    /// Fetches pictures ahead into the disk cache without decoding them, a
    /// few at a time in order, so a long grid's posters are there as they
    /// scroll in without holding hundreds of them decoded in memory. Stops
    /// when the caller's task is cancelled (the grid went away). Three at a
    /// time leaves half of the session's six connections to the server for
    /// the pictures on screen, so they never wait behind the look-ahead.
    func warm(_ urls: [URL], client: JellyfinClient?, concurrently width: Int = 3) async {
        guard let client else { return }
        let pending = urls.filter { cache.object(forKey: $0 as NSURL) == nil }
        await withTaskGroup(of: Void.self) { group in
            var next = pending.makeIterator()
            for _ in 0..<width {
                guard let url = next.next() else { break }
                group.addTask { _ = try? await client.data(from: url) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let url = next.next() else { continue }
                group.addTask { _ = try? await client.data(from: url) }
            }
        }
    }
}

/// A remote picture that fills its frame. `contentMode` chooses between cover
/// and contain fitting; the placeholder shows until the picture arrives.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// Stretch to the frame, ignoring the picture's aspect ratio.
    var stretch = false
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(AppSession.self) private var session
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                if stretch {
                    Image(platformImage: image)
                        .resizable()
                        .transition(.opacity)
                } else if contentMode == .fill {
                    // A cover-fitted picture must not grow the view it sits in:
                    // size to the proposal and crop the overflow.
                    Color.clear
                        .overlay {
                            Image(platformImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                        .transition(.opacity)
                } else {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageStore.shared.cached(url) {
                image = hit
                return
            }
            image = nil
            let loaded = await ImageStore.shared.image(for: url, client: session.client ?? session.anonymousClient)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                image = loaded
            }
        }
    }
}

extension RemoteImage where Placeholder == ArtworkPlaceholder {
    init(url: URL?, contentMode: ContentMode = .fill, systemImage: String = "film") {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = { ArtworkPlaceholder(systemImage: systemImage) }
    }
}

struct ArtworkPlaceholder: View {
    var systemImage: String = "film"

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}
