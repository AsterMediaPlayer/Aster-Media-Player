//
//  AudiobookDownloads.swift
//  AsterFIN
//
//  Audiobooks saved for listening offline on iPhone and iPad. A book's
//  files are saved as they are on the server (an .m4b, or each part of a
//  book kept as a folder of files) in the background, with the cover, and
//  play from the device from then on. Listening done offline is kept here
//  and handed to Jellyfin once the server can be reached, so another device
//  picks up from the same place.
//
//  Video downloads (`DownloadStore`) are HLS streams saved by AVFoundation;
//  these are plain files, so they have their own store. They share its
//  settings: whether downloads are on, the space limit and cellular use.
//

#if os(iOS)
import Foundation
import Observation

/// Where listening got to in one part, on this device.
nonisolated struct AudiobookLocalProgress: Codable, Hashable, Sendable {
    var ticks: Int64
    var played: Bool
    var updated: Date
}

/// One downloaded (or downloading) book.
nonisolated struct AudiobookDownload: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case downloading, finished, failed
    }

    /// The book's id.
    var id: String
    var title: String
    var author: String?
    var series: String?
    var seriesIndex: Int?
    var parts: [BaseItem]
    var state: State
    /// Each part's saved file name, once it's in.
    var files: [String: String] = [:]
    var expectedBytes: Int64
    var bytesOnDisk: Int64 = 0
    var added: Date
    var errorMessage: String?
    /// Listening on this device, by part id.
    var progress: [String: AudiobookLocalProgress] = [:]

    var fraction: Double {
        guard !parts.isEmpty else { return 0 }
        return Double(files.count) / Double(parts.count)
    }
}

@Observable
final class AudiobookDownloads: NSObject {
    static let shared = AudiobookDownloads()

    static let wifiSessionID = "app.asterfin.audiobooks"
    static let cellularSessionID = "app.asterfin.audiobooks.cellular"

    /// Newest first.
    private(set) var records: [AudiobookDownload] = []
    /// Bytes come in for the parts downloading now, by task, for progress.
    private(set) var bytesWritten: [String: Int64] = [:]

    @ObservationIgnored private var wifiSession: URLSession?
    @ObservationIgnored private var cellularSession: URLSession?
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var backgroundEventsDelivered = false
    @ObservationIgnored private var client: JellyfinClient?

    override private init() {
        super.init()
        records = Self.loadIndex()
        wifiSession = makeSession(Self.wifiSessionID, cellular: false)
        cellularSession = makeSession(Self.cellularSessionID, cellular: true)
        Task { await reattach() }
    }

    private func makeSession(_ identifier: String, cellular: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.allowsCellularAccess = cellular
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    /// Picks up downloads still running from an earlier launch; books the
    /// system no longer has tasks for were interrupted.
    private func reattach() async {
        for session in [wifiSession, cellularSession].compactMap({ $0 }) {
            for task in await session.allTasks {
                if let task = task as? URLSessionDownloadTask, let key = task.taskDescription {
                    tasks[key] = task
                }
            }
        }
        var changed = false
        for index in records.indices where records[index].state == .downloading {
            let id = records[index].id
            if !tasks.keys.contains(where: { Self.parse($0)?.bookId == id }) {
                records[index].state = .failed
                records[index].errorMessage = "The download was interrupted."
                changed = true
            }
        }
        if changed { saveIndex() }
    }

    // MARK: Looking up

    func record(for bookId: String) -> AudiobookDownload? {
        records.first { $0.id == bookId }
    }

    /// The saved file for a part, when its book has finished downloading.
    func fileURL(forPart partId: String) -> URL? {
        guard let record = records.first(where: { $0.state == .finished && $0.files[partId] != nil }),
              let name = record.files[partId] else { return nil }
        let url = Self.folder(for: record.id).appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func coverURL(for bookId: String) -> URL? {
        let url = Self.folder(for: bookId).appending(path: "cover.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A downloaded book, with listening done here where it's newer.
    func book(_ record: AudiobookDownload) -> Audiobook {
        withLocalProgress(Audiobook(id: record.id, title: record.title, author: record.author, series: record.series, seriesIndex: record.seriesIndex, parts: record.parts))
    }

    /// `book` with this device's listening in place of the server's, part
    /// by part, where it's more recent.
    func withLocalProgress(_ book: Audiobook) -> Audiobook {
        guard let record = record(for: book.id), !record.progress.isEmpty else { return book }
        let parts = book.parts.map { part -> BaseItem in
            guard let local = record.progress[part.id] else { return part }
            if let server = Self.date(part.userData?.lastPlayedDate), server >= local.updated { return part }
            var updated = part
            var data = part.userData ?? UserItemData()
            data.playbackPositionTicks = local.played ? 0 : local.ticks
            data.played = local.played
            data.lastPlayedDate = Self.isoFormatter.string(from: local.updated)
            updated.userData = data
            return updated
        }
        return Audiobook(id: book.id, title: book.title, author: book.author, series: book.series, seriesIndex: book.seriesIndex, parts: parts)
    }

    // MARK: Listening

    /// Notes where listening got to in a part of a downloaded book.
    func noteProgress(bookId: String, partId: String, ticks: Int64, played: Bool = false) {
        guard let index = records.firstIndex(where: { $0.id == bookId }) else { return }
        records[index].progress[partId] = AudiobookLocalProgress(ticks: ticks, played: played, updated: Date())
        saveIndex()
    }

    /// Hands listening done here to the server where it's newer than what
    /// the server has (`books` holds what it has), so every device agrees.
    /// It goes as a short playback session at the saved place, which is
    /// how Jellyfin records a position.
    func sync(with books: [Audiobook], client: JellyfinClient) async {
        let serverParts = Dictionary(books.flatMap(\.parts).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records {
            for (partId, local) in record.progress {
                guard let server = serverParts[partId] else { continue }
                // A minute's grace: online, the server heard as it happened.
                if let heard = Self.date(server.userData?.lastPlayedDate), heard.addingTimeInterval(60) >= local.updated { continue }
                let ticks = local.played ? (server.runTimeTicks ?? local.ticks) : local.ticks
                let session = UUID().uuidString
                await client.reportStart(PlaybackReport(itemId: partId, playSessionId: session, positionTicks: ticks, isPaused: true, playMethod: "DirectPlay"))
                await client.reportStopped(PlaybackReport(itemId: partId, playSessionId: session, positionTicks: ticks, isPaused: true, playMethod: "DirectPlay"))
            }
        }
    }

    // MARK: Space

    /// What books take, counting the rest of those still coming.
    var reservedBytes: Int64 {
        records.reduce(0) { total, record in
            switch record.state {
            case .finished: total + record.bytesOnDisk
            case .downloading: total + record.expectedBytes
            case .failed: total
            }
        }
    }

    var usedBytes: Int64 {
        records.reduce(0) { total, record in
            switch record.state {
            case .finished: total + record.bytesOnDisk
            case .downloading: total + bytesSoFar(record)
            case .failed: total
            }
        }
    }

    func bytesSoFar(_ record: AudiobookDownload) -> Int64 {
        let saved = record.parts.filter { record.files[$0.id] != nil }.reduce(Int64(0)) { $0 + Self.partBytes($1) }
        let coming = bytesWritten.filter { Self.parse($0.key)?.bookId == record.id }.values.reduce(0, +)
        return saved + coming
    }

    /// How far a download has got, 0 to 1.
    func progress(_ record: AudiobookDownload) -> Double {
        guard record.state == .downloading, record.expectedBytes > 0 else { return record.state == .finished ? 1 : record.fraction }
        return min(Double(bytesSoFar(record)) / Double(record.expectedBytes), 1)
    }

    private func checkRoom(for bytes: Int64) throws {
        if let free = DownloadStore.freeBytes, bytes > free - 500_000_000 {
            throw DownloadError.noRoom(needed: bytes, available: max(free, 0))
        }
        let reserved = DownloadStore.shared.reservedBytes + reservedBytes
        if let limit = DownloadSettings.storageLimit, reserved + bytes > limit {
            throw DownloadError.overLimit(needed: bytes, remaining: max(limit - reserved, 0))
        }
    }

    // MARK: Downloading

    /// Saves a book's files and cover.
    func start(_ book: Audiobook, client: JellyfinClient, canDownload: Bool) async throws {
        guard DownloadSettings.enabled else { throw DownloadError.disabled }
        guard canDownload else { throw DownloadError.notAllowed }
        if let existing = record(for: book.id), existing.state != .failed { return }
        self.client = client

        // The files' sizes, from the server, for the space check.
        var parts = book.parts
        if let detailed = try? await client.items([
            "ids": parts.map(\.id).joined(separator: ","),
            "fields": AudiobookLibrary.fields + ",MediaSources",
        ]).items {
            let byId = Dictionary(detailed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            parts = parts.map { byId[$0.id] ?? $0 }
        }
        let expected = parts.reduce(Int64(0)) { $0 + Self.partBytes($1) }
        try checkRoom(for: expected)

        remove(book.id)
        let folder = Self.folder(for: book.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        records.insert(AudiobookDownload(
            id: book.id,
            title: book.title,
            author: book.author,
            series: book.series,
            seriesIndex: book.seriesIndex,
            parts: parts,
            state: .downloading,
            expectedBytes: expected,
            added: Date()
        ), at: 0)
        saveIndex()

        if let cover = client.posterURL(for: book.cover, width: 800), let data = try? await client.data(from: cover) {
            try? data.write(to: folder.appending(path: "cover.jpg"))
        }
        for part in parts {
            startTask(bookId: book.id, partId: part.id, url: client.downloadURL(itemId: part.id), fallback: false)
        }
    }

    /// Downloads one part. `fallback` is the second try, through the plain
    /// file stream, for a server that won't serve the download itself.
    private func startTask(bookId: String, partId: String, url: URL, fallback: Bool) {
        guard let session = DownloadSettings.useCellular ? cellularSession : wifiSession else { return }
        let key = Self.key(bookId: bookId, partId: partId, fallback: fallback)
        let task = session.downloadTask(with: url)
        task.taskDescription = key
        tasks[key] = task
        task.resume()
    }

    func retry(_ bookId: String, client: JellyfinClient, canDownload: Bool) async throws {
        guard let record = record(for: bookId) else { return }
        try await start(book(record), client: client, canDownload: canDownload)
    }

    func remove(_ bookId: String) {
        remove([bookId])
    }

    func removeAll() {
        remove(Set(records.map(\.id)))
    }

    /// Takes books off the list and deletes their files. Ids that aren't
    /// books are ignored, so a mixed selection can be passed.
    func remove(_ bookIds: Set<String>) {
        let ids = bookIds.intersection(records.map(\.id))
        guard !ids.isEmpty else { return }
        for (key, task) in tasks where ids.contains(Self.parse(key)?.bookId ?? "") {
            task.cancel()
            tasks[key] = nil
            bytesWritten[key] = nil
        }
        records.removeAll { ids.contains($0.id) }
        saveIndex()
        for id in ids {
            try? FileManager.default.removeItem(at: Self.folder(for: id))
        }
    }

    // MARK: Finishing

    /// Keeps a part's file, which the system deletes once this returns.
    private func keep(_ location: URL, response: URLResponse?, key: String) {
        guard let parsed = Self.parse(key) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            if !parsed.fallback, let client = client ?? AppSession.shared.client {
                // The download endpoint refused it; try the file stream.
                startTask(bookId: parsed.bookId, partId: parsed.partId, url: client.audioStreamURL(itemId: parsed.partId), fallback: true)
            } else {
                fail(parsed.bookId, message: "The server wouldn't send this book (\(status)).")
            }
            return
        }
        var ext = (response?.suggestedFilename as NSString?)?.pathExtension ?? ""
        if ext.isEmpty { ext = "m4b" }
        let name = "\(parsed.partId).\(ext)"
        let destination = Self.folder(for: parsed.bookId).appending(path: name)
        try? FileManager.default.createDirectory(at: Self.folder(for: parsed.bookId), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            fail(parsed.bookId, message: error.localizedDescription)
            return
        }
        guard let index = records.firstIndex(where: { $0.id == parsed.bookId }) else {
            try? FileManager.default.removeItem(at: destination)
            return
        }
        records[index].files[parsed.partId] = name
        if records[index].files.count == records[index].parts.count {
            records[index].state = .finished
            records[index].errorMessage = nil
            records[index].bytesOnDisk = Self.size(of: Self.folder(for: parsed.bookId))
        }
        saveIndex()
    }

    private func completed(_ key: String, error: (any Error)?) {
        tasks[key] = nil
        bytesWritten[key] = nil
        guard let error, let parsed = Self.parse(key) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail(parsed.bookId, message: error.localizedDescription)
    }

    private func fail(_ bookId: String, message: String) {
        guard let index = records.firstIndex(where: { $0.id == bookId }), records[index].state == .downloading else { return }
        records[index].state = .failed
        records[index].errorMessage = message
        for (key, task) in tasks where Self.parse(key)?.bookId == bookId {
            task.cancel()
            tasks[key] = nil
            bytesWritten[key] = nil
        }
        saveIndex()
    }

    // MARK: Background relaunch

    func waitForBackgroundEvents() async {
        if backgroundEventsDelivered {
            backgroundEventsDelivered = false
            return
        }
        await withCheckedContinuation { backgroundWaiters.append($0) }
    }

    // MARK: Files

    private static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Audiobooks", directoryHint: .isDirectory)
    }

    static func folder(for bookId: String) -> URL {
        root.appending(path: bookId, directoryHint: .isDirectory)
    }

    private static var indexURL: URL { root.appending(path: "index.json") }

    private static func loadIndex() -> [AudiobookDownload] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([AudiobookDownload].self, from: data)) ?? []
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    private static func size(of folder: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// A part's size from the server, else a guess from its length at a
    /// typical audiobook bitrate (64 kbps).
    private static func partBytes(_ part: BaseItem) -> Int64 {
        if let size = part.mediaSources?.first?.size, size > 0 { return size }
        return (part.runTimeTicks ?? 0) / 10_000_000 * 8_000
    }

    /// A task's description: the book, the part, and whether it's the
    /// file-stream retry.
    private static func key(bookId: String, partId: String, fallback: Bool) -> String {
        "\(bookId)|\(partId)|\(fallback ? "stream" : "download")"
    }

    private static func parse(_ key: String) -> (bookId: String, partId: String, fallback: Bool)? {
        let pieces = key.split(separator: "|").map(String.init)
        guard pieces.count == 3 else { return nil }
        return (pieces[0], pieces[1], pieces[2] == "stream")
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Jellyfin's dates carry seven decimal places, which the ISO 8601
    /// formatter won't read, so the fraction is dropped.
    private static func date(_ text: String?) -> Date? {
        guard let text, text.count >= 19 else { return nil }
        return isoFormatter.date(from: String(text.prefix(19)) + "Z")
    }
}

// The sessions deliver on the main queue, so each callback is on the main actor.
extension AudiobookDownloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        let response = downloadTask.response
        MainActor.assumeIsolated { keep(location, response: response, key: key) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated { self.bytesWritten[key] = totalBytesWritten }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let key = task.taskDescription else { return }
        MainActor.assumeIsolated { completed(key, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            if backgroundWaiters.isEmpty {
                backgroundEventsDelivered = true
            }
            for waiter in backgroundWaiters { waiter.resume() }
            backgroundWaiters = []
        }
    }
}
#endif
