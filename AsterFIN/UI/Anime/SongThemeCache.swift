//
//  SongThemeCache.swift
//  AsterFIN
//
//  What a show's page has already found, kept in one small JSON file so it
//  isn't looked up again, on a server with no OP/ED plugin to ask (Plex,
//  Emby, and Jellyfin without the plugin): the openings and endings read
//  from a show's episode chapters, and the songs AnimeThemes names for each
//  show's name, which takes seconds a time (and is asked of it fifty shows
//  to a request, in the background). An entry belongs to the server it was
//  found on, and a show's clips to how many episodes it had, so new
//  episodes read the chapters again. Nothing here is a credential.
//

import Foundation

/// One kept thing: a show's clips, or what AnimeThemes said about a name.
nonisolated struct SongThemeEntry: Codable, Sendable {
    var at: Date
    /// "Nothing found" may only be that AnimeThemes or a scan hasn't caught
    /// up, so it's asked again sooner.
    var empty: Bool
    var clips: [ThemeClip]?
    var shows: [ShowCandidate]?
}

nonisolated private struct SongThemeFile: Codable, Sendable {
    var version: Int
    var entries: [String: SongThemeEntry]
}

actor SongThemeCache {
    static let shared = SongThemeCache(file: URL.applicationSupportDirectory.appending(path: "song-themes.json"))

    private let file: URL
    private let now: @Sendable () -> Date
    private var entries: [String: SongThemeEntry]?

    // 1: as the Android app's version 3 (Emby's Intro Start clips end at
    // Intro End; Plex clips keep their chapter's picture).
    private static let version = 1
    private static let maxEntries = 1500
    private static let life: TimeInterval = 30 * 24 * 60 * 60
    private static let emptyLife: TimeInterval = 3 * 24 * 60 * 60

    init(file: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
    }

    // MARK: Clips

    /// A show's clips as last read, when it still had `version` episodes.
    func clips(server: String, seriesId: String, version: Int?) -> [ThemeClip]? {
        read(Self.clipsKey(server, seriesId, version))?.clips
    }

    func putClips(server: String, seriesId: String, version: Int?, clips: [ThemeClip]) {
        write([Self.clipsKey(server, seriesId, version): SongThemeEntry(at: now(), empty: clips.isEmpty, clips: clips.map(Self.slim))])
    }

    // MARK: Shows

    /// What AnimeThemes said about `name`: every season of the show with its themes.
    func shows(server: String, name: String) -> [ShowCandidate]? {
        read(Self.showsKey(server, name))?.shows
    }

    /// Several names at once, in one write of the file.
    func putShows(server: String, _ found: [String: [ShowCandidate]]) {
        guard !found.isEmpty else { return }
        let at = now()
        var add: [String: SongThemeEntry] = [:]
        for (name, shows) in found {
            add[Self.showsKey(server, name)] = SongThemeEntry(at: at, empty: shows.isEmpty, shows: shows)
        }
        write(add)
    }

    /// Forgets everything kept for `server`, so the next visit finds it all again.
    func clear(server: String) {
        var all = load()
        for key in all.keys where key.hasPrefix(server + "|") { all[key] = nil }
        entries = all
        save()
    }

    // MARK: The file

    private static func clipsKey(_ server: String, _ seriesId: String, _ version: Int?) -> String {
        "\(server)|clips|\(seriesId)|\(version ?? 0)"
    }

    private static func showsKey(_ server: String, _ name: String) -> String {
        "\(server)|shows|\(AnimeThemesLookup.nameKey(name))"
    }

    /// An episode as a clip's card needs it (names, numbers, pictures). Its
    /// streams and chapters are most of what a server sends, and are asked
    /// for again when the clip plays. The song is named afresh each time.
    private static func slim(_ clip: ThemeClip) -> ThemeClip {
        var slim = clip
        slim.song = nil
        slim.episode.mediaSources = nil
        slim.episode.mediaStreams = nil
        slim.episode.chapters = nil
        slim.episode.people = nil
        slim.episode.userData = nil
        return slim
    }

    private func read(_ key: String) -> SongThemeEntry? {
        guard let entry = load()[key] else { return nil }
        let age = now().timeIntervalSince(entry.at)
        guard age <= (entry.empty ? Self.emptyLife : Self.life) else { return nil }
        return entry
    }

    private func write(_ add: [String: SongThemeEntry]) {
        var all = load()
        for (key, entry) in add { all[key] = entry }
        // The oldest go first, so the file stays small.
        if all.count > Self.maxEntries {
            let oldest = all.sorted { $0.value.at < $1.value.at }.prefix(all.count - Self.maxEntries)
            for (key, _) in oldest { all[key] = nil }
        }
        entries = all
        save()
    }

    private func load() -> [String: SongThemeEntry] {
        if let entries { return entries }
        let loaded: [String: SongThemeEntry]
        // An entry this version can't read (the models changed) is just not there.
        if let data = try? Data(contentsOf: file),
           let root = try? JSONDecoder().decode(SongThemeFile.self, from: data),
           root.version == Self.version {
            loaded = root.entries
        } else {
            loaded = [:]
        }
        entries = loaded
        return loaded
    }

    private func save() {
        guard let entries else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SongThemeFile(version: Self.version, entries: entries))
            try data.write(to: file, options: .atomic)
        } catch {
            #if DEBUG
            print("DEBUG songs: couldn't save \(file.lastPathComponent): \(error)")
            #endif
        }
    }
}

// MARK: - Warming

/// Asks AnimeThemes about every show in the anime libraries in the
/// background, fifty to a request, so a show's page finds its songs kept
/// (see `AnimeThemesLookup.prefetch`). Only on a server with no OP/ED
/// plugin, which names them itself, and only what isn't kept yet is asked,
/// so it's quick after the first time. Settings › Playback › Anime turns the
/// lookups off and asks for everything again.
@MainActor
@Observable
final class SongWarmer {
    static let shared = SongWarmer()

    enum Refresh: Equatable {
        case idle, refreshing, done, failed
    }

    /// How Refresh Songs is going, for Settings.
    private(set) var refresh: Refresh = .idle

    /// The servers warmed this launch, by address.
    private var warmed: Set<String> = []
    private var client: (any MediaServer)?
    private var libraries: [BaseItem] = []
    private var task: Task<Void, Never>?

    /// Warms `libraries` on `client` in the background, once for each
    /// server a launch signs in to. With no libraries it uses the ones last
    /// given, which is how switching the setting back on starts it.
    func warmInBackground(client: any MediaServer, libraries: [BaseItem]? = nil) {
        self.client = client
        if let libraries { self.libraries = libraries }
        guard AppSettings.songLookups, !self.libraries.isEmpty else { return }
        let server = AnimeThemesLookup.serverKey(client)
        guard warmed.insert(server).inserted else { return }
        let given = self.libraries
        task?.cancel()
        task = Task.detached(priority: .utility) {
            _ = await Self.warm(client: client, libraries: given)
        }
    }

    /// Forgets what's kept for the server (and this launch's answers) and
    /// asks AnimeThemes again for every show. False when AnimeThemes
    /// couldn't be reached all the way through; the rest is kept.
    func refreshSongs() async -> Bool {
        guard let client else { return true }
        refresh = .refreshing
        let server = AnimeThemesLookup.serverKey(client)
        await SongThemeCache.shared.clear(server: server)
        AnimeThemesLookup.reset()
        warmed.insert(server)
        task?.cancel()
        let complete: Bool
        if AppSettings.songLookups, !libraries.isEmpty {
            let given = libraries
            complete = await Task.detached(priority: .utility) { await Self.warm(client: client, libraries: given) }.value
        } else {
            complete = true
        }
        refresh = complete ? .done : .failed
        return complete
    }

    nonisolated private static func warm(client: any MediaServer, libraries: [BaseItem]) async -> Bool {
        // The OP/ED plugin names the songs itself.
        if let jellyfin = client as? JellyfinClient, await jellyfin.opEdLibraries() != nil { return true }
        var names: [String] = []
        for library in libraries where library.collectionType == "tvshows" {
            var query = ItemQuery(parentId: library.id, kinds: [.series], recursive: true, sort: .name, descending: false)
            var start = 0
            while !Task.isCancelled {
                query.startIndex = start
                query.limit = 300
                guard let page = try? await client.items(query), !page.items.isEmpty else { break }
                names += page.items.compactMap(\.name)
                start += page.items.count
                if start >= (page.totalRecordCount ?? 0) { break }
            }
        }
        let warmed = await AnimeThemesLookup.prefetch(names: names, server: AnimeThemesLookup.serverKey(client))
        #if DEBUG
        print("DEBUG songs: AnimeThemes warmed: \(names.count) shows, \(warmed.asked) asked\(warmed.complete ? "" : ", stopped early")")
        #endif
        return warmed.complete
    }
}
