//
//  MusicAhead.swift
//  AsterFIN
//
//  Saves the next few songs in the music queue as whole files while the
//  connection is a good one: Wi-Fi or wired, and not Low Data Mode (the
//  download session itself refuses cellular, a Personal Hotspot and Low
//  Data Mode, so nothing is fetched there). A saved song starts at once
//  and plays on through a spot with no signal; one not yet saved streams
//  as before. Settings ▸ Playback ▸ Music turns it off.
//
//  The files live in the system's cache folder, which the system may
//  empty when space is short. Only the song playing and the ones coming
//  up are kept: what's been heard is let go as the queue moves on.
//

import Foundation

final class MusicAhead {
    static let shared = MusicAhead()

    /// How many songs past the one playing are saved.
    static let songsAhead = 5

    private let folder: URL
    /// Saved songs by item id.
    private var saved: [String: URL] = [:]
    /// The songs wanted, in the order they'll play.
    private var wanted: [String] = []
    /// Songs that couldn't be saved (no good connection, or a format that
    /// can't be kept as a file); they stream as before.
    private var failed: Set<String> = []
    private var task: Task<Void, Never>?
    private var fetching: String?

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appending(path: "MusicAhead", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // What's still there from last time, named by item id.
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            saved[file.deletingPathExtension().lastPathComponent] = file
        }
    }

    /// The saved file for a song, if it's here.
    func savedFile(for id: String) -> URL? {
        guard let file = saved[id] else { return nil }
        guard FileManager.default.fileExists(atPath: file.path) else {
            // The system emptied the cache.
            saved[id] = nil
            return nil
        }
        return file
    }

    /// The songs coming up, in order: saves those not yet saved, one at a
    /// time, and lets go of every other file but the one playing.
    func prepare(upcoming: [BaseItem], playing: BaseItem?, client: JellyfinClient) {
        guard AppSettings.musicAhead else {
            clear()
            return
        }
        wanted = upcoming.prefix(Self.songsAhead).map(\.id)
        let keep = Set(wanted + [playing?.id].compactMap { $0 })
        for (id, file) in saved where !keep.contains(id) && id != fetching {
            try? FileManager.default.removeItem(at: file)
            saved[id] = nil
        }
        fetchNext(client: client)
    }

    /// Removes every saved song, as the setting goes off or playback stops.
    func clear() {
        task?.cancel()
        task = nil
        fetching = nil
        wanted = []
        failed = []
        for file in saved.values {
            try? FileManager.default.removeItem(at: file)
        }
        saved = [:]
    }

    private func fetchNext(client: JellyfinClient) {
        guard task == nil,
              let id = wanted.first(where: { saved[$0] == nil && !failed.contains($0) }) else { return }
        let url = client.audioFileURL(itemId: id, maxBitrate: AppSettings.maxBitrate)
        let folder = folder
        fetching = id
        task = Task { [weak self] in
            let file = await Self.fetch(url, as: id, into: folder)
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.fetching = nil
            if let file {
                if self.wanted.contains(id) {
                    self.saved[id] = file
                } else {
                    // The queue moved on while it came.
                    try? FileManager.default.removeItem(at: file)
                }
            } else {
                self.failed.insert(id)
            }
            self.fetchNext(client: client)
        }
    }

    /// Downloads a song and moves it into `folder` as `<id>.<extension>`,
    /// the extension from what the server sent, so AVPlayer knows the
    /// format. Nil when it can't be had or isn't a file AVPlayer can open.
    nonisolated private static func fetch(_ url: URL, as id: String, into folder: URL) async -> URL? {
        do {
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let fileExtension = fileExtension(for: http) else { return nil }
            let file = folder.appending(path: "\(id).\(fileExtension)")
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temporary, to: file)
            #if DEBUG
            print("DEBUG music ahead: saved \(id) as \(fileExtension)")
            #endif
            return file
        } catch {
            #if DEBUG
            print("DEBUG music ahead: \(id) not saved, \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// The file's kind from the address it came from (a direct file is
    /// redirected to stream.flac and the like), else its MIME type.
    nonisolated private static func fileExtension(for response: HTTPURLResponse) -> String? {
        let playable: Set<String> = ["mp3", "m4a", "m4b", "mp4", "aac", "flac", "wav", "aiff", "aif"]
        let fromAddress = response.url?.pathExtension.lowercased() ?? ""
        if fromAddress == "alac" { return "m4a" }
        if playable.contains(fromAddress) { return fromAddress }
        switch response.mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/aac", "audio/aacp": return "aac"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        default: return nil
        }
    }
}
