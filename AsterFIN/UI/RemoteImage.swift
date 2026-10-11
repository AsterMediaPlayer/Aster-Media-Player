//
//  RemoteImage.swift
//  AsterFIN
//
//  Authenticated image loading with an in-memory cache, used for every
//  Jellyfin picture in the app and for disc-menu artwork.
//

import SwiftUI
import UIKit

/// Decoded images shared across the app. Network responses are also cached on
/// disk by the client's image URLSession.
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        cache.totalCostLimit = 300 * 1024 * 1024
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL, client: JellyfinClient?) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = inFlight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            let data: Data?
            if url.scheme == "data" {
                data = try? Data(contentsOf: url)
            } else if let client {
                data = try? await client.data(from: url)
            } else if let (body, response) = try? await JellyfinClient.imageSession.data(from: url),
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                // An error page decoded as a picture logs "possibly corrupt".
                data = body
            } else {
                data = nil
            }
            guard let data, let image = UIImage(data: data) else {
                #if DEBUG
                if let data {
                    let head = data.prefix(12).map { String(format: "%02x", $0) }.joined()
                    print("DEBUG images: couldn't decode \(data.count) bytes (starts \(head)) from \(url.path())")
                }
                #endif
                return nil
            }
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result {
            let cost = Int(result.size.width * result.size.height * result.scale * result.scale * 4)
            cache.setObject(result, forKey: url as NSURL, cost: cost)
        }
        return result
    }

    func prefetch(_ urls: [URL], client: JellyfinClient?) {
        for url in urls where cache.object(forKey: url as NSURL) == nil {
            Task { _ = await image(for: url, client: client) }
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
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                if stretch {
                    Image(uiImage: image)
                        .resizable()
                        .transition(.opacity)
                } else if contentMode == .fill {
                    // A cover-fitted picture must not grow the view it sits in:
                    // size to the proposal and crop the overflow.
                    Color.clear
                        .overlay {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                        .transition(.opacity)
                } else {
                    Image(uiImage: image)
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
