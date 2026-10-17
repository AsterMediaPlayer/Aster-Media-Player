//
//  ListenAhead.swift
//  AsterFIN
//
//  Keeps the next stretch of an audiobook on the device as it plays, so a
//  place with no signal doesn't stop it. As it's heard, the next N minutes
//  (Settings ▸ Playback ▸ Listen Ahead; 30 unless changed) are saved in
//  256 KB chunks, running on into the book's next file, and AVPlayer reads
//  the book through this loader rather than straight from the server: saved
//  chunks first, bytes still arriving as they come, anything missing fetched
//  at once. It works by position in a file, so a one-file ten-hour book is
//  covered as well as one in chapter files.
//
//  The chunks live in the system's cache folder, which iOS may empty when
//  space is short. What's been heard is let go as the book goes on, and the
//  book's cache when it finishes or another book starts. A downloaded book
//  plays from its download and never comes here; nor does a file AVPlayer
//  can't open as it is, which streams as before.
//

#if os(iOS)
import AVFoundation
import Foundation

nonisolated final class ListenAhead: NSObject, @unchecked Sendable {
    static let shared = ListenAhead()

    private static let scheme = "asterfin-listenahead"
    private static let chunkSize = 256 * 1024
    /// Heard audio kept behind the playhead, for a skip back.
    private static let keepBehind: TimeInterval = 60

    /// Everything below happens on this queue.
    private let queue = DispatchQueue(label: "app.asterfin.listen-ahead")
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private struct Part {
        let id: String
        let url: URL
        let duration: TimeInterval
        var contentType: String?
        let directory: URL
        var length: Int64?
        var chunks: Set<Int>

        func chunkCount(of length: Int64) -> Int {
            Int((length + Int64(ListenAhead.chunkSize) - 1) / Int64(ListenAhead.chunkSize))
        }
    }

    /// The one download running: a part from a chunk on, filling `buffer`
    /// until a whole chunk can be saved.
    private struct Fetch {
        let part: Int
        var chunk: Int
        var buffer = Data()
        let task: URLSessionDataTask
    }

    private var bookId: String?
    /// The book's files; nil for one AVPlayer can't open as it is.
    private var parts: [Part?] = []
    private var aheadSeconds: TimeInterval = 0
    private var playhead: (part: Int, seconds: TimeInterval) = (0, 0)
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var fetch: Fetch?
    private var retry: DispatchWorkItem?

    private static var root: URL {
        URL.cachesDirectory.appending(path: "ListenAhead", directoryHint: .isDirectory)
    }

    // MARK: The player's side

    /// The part to play through the cache, or nil when Listen Ahead is off or
    /// the file can't be opened as it is (it then streams as before).
    func asset(book: Audiobook, part: Int, client: JellyfinClient) -> AVURLAsset? {
        let minutes = AppSettings.listenAheadMinutes
        guard minutes > 0, book.parts.indices.contains(part) else { return nil }
        let id = book.id
        let durations = book.partDurations
        let files = book.parts.enumerated().map { index, item in
            let kind = Self.kind(of: item)
            return File(id: item.id, url: client.audioStreamURL(itemId: item.id), duration: durations[index], playable: kind.playable, contentType: kind.type)
        }
        let usable = queue.sync { () -> Bool in
            prepare(bookId: id, files: files)
            aheadSeconds = TimeInterval(minutes) * 60
            return parts.indices.contains(part) && parts[part] != nil
        }
        guard usable, let url = URL(string: "\(Self.scheme)://\(id)/\(part)") else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Where the book is: what's ahead is saved from here, what's well
    /// behind let go.
    func update(bookId: String, part: Int, seconds: TimeInterval, force: Bool = false) {
        queue.async { [self] in
            guard bookId == self.bookId else { return }
            let moved = force || part != playhead.part || abs(seconds - playhead.seconds) >= 5
            guard moved else { return }
            playhead = (part, seconds)
            prune()
            schedule()
        }
    }

    /// The book closed: nothing more is fetched for it.
    func pause() {
        queue.async { [self] in
            retry?.cancel()
            cancelFetch()
        }
    }

    /// The book was heard to the end: its cache goes.
    func finished(bookId: String) {
        queue.async { [self] in
            guard bookId == self.bookId else { return }
            cancelFetch()
            try? FileManager.default.removeItem(at: Self.root.appending(path: bookId, directoryHint: .isDirectory))
            self.bookId = nil
            parts = []
        }
    }

    // MARK: Setting up

    /// A file of the book, as the player hands it over.
    private struct File: Sendable {
        let id: String
        let url: URL
        let duration: TimeInterval
        /// Whether AVPlayer can open it as it is, and its type when known
        /// before asking (else the server's answer says).
        let playable: Bool
        let contentType: String?
    }

    /// The book's files, with whatever is already saved for them. Another
    /// book's cache is let go.
    private func prepare(bookId id: String, files: [File]) {
        guard id != bookId else { return }
        cancelFetch()
        for request in pending { request.finishLoading(with: CocoaError(.userCancelled)) }
        pending = []
        let fileManager = FileManager.default
        if let others = try? fileManager.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil) {
            for other in others where other.lastPathComponent != id {
                try? fileManager.removeItem(at: other)
            }
        }
        bookId = id
        playhead = (0, 0)
        parts = files.map { file in
            guard file.playable else { return nil }
            let directory = Self.root.appending(path: id, directoryHint: .isDirectory).appending(path: file.id, directoryHint: .isDirectory)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var part = Part(id: file.id, url: file.url, duration: file.duration, contentType: file.contentType, directory: directory, length: nil, chunks: [])
            if let data = try? Data(contentsOf: directory.appending(path: "length")), let text = String(data: data, encoding: .utf8) {
                part.length = Int64(text)
            }
            if part.contentType == nil, let data = try? Data(contentsOf: directory.appending(path: "type")) {
                part.contentType = String(data: data, encoding: .utf8)
            }
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            part.chunks = Set(names.compactMap { $0.hasPrefix("c") ? Int($0.dropFirst()) : nil })
            return part
        }
    }

    /// Whether AVPlayer can open the file as it is, from its container, and
    /// the type it needs. A file without a container given (an .m4b book) is
    /// tried, its type taken from the server's answer.
    private static func kind(of item: BaseItem) -> (playable: Bool, type: String?) {
        guard let container = item.container?.lowercased() else { return (true, nil) }
        let names = container.split(separator: ",").map(String.init)
        for name in names {
            if let type = type(forExtension: name) { return (true, type) }
        }
        return (false, nil)
    }

    private static func type(forExtension name: String) -> String? {
        switch name {
        case "mp3": "public.mp3"
        case "m4a", "m4b", "mp4", "mov", "alac": "com.apple.m4a-audio"
        case "aac": "public.aac-audio"
        case "flac": "org.xiph.flac"
        case "wav": "com.microsoft.waveform-audio"
        case "aif", "aiff": "public.aiff-audio"
        case "caf": "com.apple.coreaudio-format"
        default: nil
        }
    }

    /// The type for a server's Content-Type, as AVPlayer names it.
    private static func type(forMIME mime: String) -> String? {
        switch mime.lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }) ?? "" {
        case "audio/mpeg", "audio/mp3": "public.mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/m4b", "audio/x-m4b", "audio/aac", "video/mp4": "com.apple.m4a-audio"
        case "audio/aacp", "audio/x-aac": "public.aac-audio"
        case "audio/flac", "audio/x-flac": "org.xiph.flac"
        case "audio/wav", "audio/x-wav", "audio/wave": "com.microsoft.waveform-audio"
        case "audio/aiff", "audio/x-aiff": "public.aiff-audio"
        default: nil
        }
    }

    // MARK: Serving

    private func partIndex(of request: AVAssetResourceLoadingRequest) -> Int? {
        guard let url = request.request.url, url.scheme == Self.scheme, url.host() == bookId,
              let index = Int(url.lastPathComponent), parts.indices.contains(index), parts[index] != nil else { return nil }
        return index
    }

    /// Answers whatever the player is waiting for with what's on hand.
    private func serve() {
        pending.removeAll { request in
            guard let index = partIndex(of: request), let part = parts[index] else {
                request.finishLoading(with: CocoaError(.fileNoSuchFile))
                return true
            }
            guard let length = part.length, let contentType = part.contentType else { return false }
            if let info = request.contentInformationRequest, info.contentLength == 0 {
                info.contentType = contentType
                info.contentLength = length
                info.isByteRangeAccessSupported = true
            }
            guard let data = request.dataRequest else {
                request.finishLoading()
                return true
            }
            let end = data.requestsAllDataToEndOfResource ? length : min(length, data.requestedOffset + Int64(data.requestedLength))
            var offset = data.currentOffset
            while offset < end, let bytes = read(part: index, at: offset, upTo: end - offset), !bytes.isEmpty {
                data.respond(with: bytes)
                offset += Int64(bytes.count)
            }
            if offset >= end {
                request.finishLoading()
                return true
            }
            return false
        }
    }

    /// Bytes from `offset`, up to `limit` and the end of their chunk: saved,
    /// or still arriving; nil when they aren't here yet.
    private func read(part index: Int, at offset: Int64, upTo limit: Int64) -> Data? {
        guard let part = parts[index], let length = part.length else { return nil }
        let size = Int64(Self.chunkSize)
        let chunk = Int(offset / size)
        let within = Int(offset - Int64(chunk) * size)
        if part.chunks.contains(chunk) {
            guard let data = try? Data(contentsOf: part.directory.appending(path: "c\(chunk)"), options: .mappedIfSafe) else {
                parts[index]?.chunks.remove(chunk)
                return nil
            }
            guard within < data.count else { return nil }
            let count = min(data.count - within, Int(limit))
            return data.subdata(in: within..<within + count)
        }
        if let fetch, fetch.part == index, fetch.chunk == chunk, within < fetch.buffer.count {
            let count = min(fetch.buffer.count - within, Int(limit), Int(length - offset))
            return fetch.buffer.subdata(in: within..<within + count)
        }
        return nil
    }

    // MARK: Fetching

    /// Decides what to download: what the player is waiting for first, else
    /// the next missing chunk within the stretch ahead, else nothing.
    private func schedule() {
        if let wanted = wantedByPlayer() ?? wantedAhead() {
            startFetch(part: wanted.part, chunk: wanted.chunk)
        } else {
            #if DEBUG
            if fetch != nil { print("DEBUG listen ahead: \(Int(aheadSeconds / 60)) min ahead saved; waiting") }
            #endif
            cancelFetch()
        }
    }

    /// The first chunk a waiting request needs that isn't here. AVPlayer
    /// asks for everything to the end of a file and takes what comes, so a
    /// request is only fetched for near where it starts (opening the file,
    /// its index, a seek) or within the stretch ahead; beyond that it waits
    /// for the stretch to reach it, rather than the whole book coming down.
    private func wantedByPlayer() -> (part: Int, chunk: Int)? {
        // Newest first: the player's latest request is what it needs now;
        // an older one (from before a seek) is left over.
        for request in pending.reversed() {
            guard let index = partIndex(of: request), let part = parts[index] else { continue }
            let start = request.dataRequest?.requestedOffset ?? 0
            let offset = request.dataRequest?.currentOffset ?? 0
            let chunk = Int(offset / Int64(Self.chunkSize))
            guard part.length == nil || part.contentType == nil || !part.chunks.contains(chunk) else { continue }
            if offset - start < Self.startOfRequest || isWithinStretch(part: index, chunk: chunk) { return (index, chunk) }
        }
        return nil
    }

    /// How much of a request is fetched however far ahead it is.
    private static let startOfRequest: Int64 = 4 * 1024 * 1024

    /// Whether a chunk lies between the playhead and `aheadSeconds` on.
    private func isWithinStretch(part target: Int, chunk: Int) -> Bool {
        var remaining = aheadSeconds
        var index = playhead.part
        var from = playhead.seconds
        while remaining > 0, parts.indices.contains(index), index <= target {
            guard let part = parts[index], let length = part.length, part.duration > 0 else { return index == target }
            if index == target {
                let perSecond = Double(length) / part.duration
                let first = Int64(max(from, 0) * perSecond) / Int64(Self.chunkSize)
                let last = Int64((from + remaining) * perSecond) / Int64(Self.chunkSize)
                return Int64(chunk) >= first && Int64(chunk) <= last
            }
            remaining -= max(part.duration - from, 0)
            index += 1
            from = 0
        }
        return false
    }

    /// The first chunk missing between the playhead and `aheadSeconds` on,
    /// across the book's files.
    private func wantedAhead() -> (part: Int, chunk: Int)? {
        var remaining = aheadSeconds
        var index = playhead.part
        var from = playhead.seconds
        while remaining > 0, parts.indices.contains(index) {
            guard let part = parts[index] else { return nil }
            guard let length = part.length, part.duration > 0 else { return (index, 0) }
            let perSecond = Double(length) / part.duration
            let first = Int(Int64(max(from, 0) * perSecond) / Int64(Self.chunkSize))
            let lastByte = min(length - 1, Int64((from + remaining) * perSecond))
            let last = Int(lastByte / Int64(Self.chunkSize))
            if first <= last, let missing = (first...last).first(where: { !part.chunks.contains($0) }) {
                return (index, missing)
            }
            remaining -= max(part.duration - from, 0)
            index += 1
            from = 0
        }
        return nil
    }

    private func startFetch(part index: Int, chunk: Int) {
        // Already on its way there: let it run, rather than cancel a chunk
        // half downloaded.
        if let fetch, fetch.part == index, fetch.chunk <= chunk, chunk - fetch.chunk <= 4 { return }
        guard let part = parts[index] else { return }
        cancelFetch()
        retry?.cancel()
        var request = URLRequest(url: part.url)
        request.setValue("bytes=\(Int64(chunk) * Int64(Self.chunkSize))-", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        fetch = Fetch(part: index, chunk: chunk, task: task)
        task.resume()
        #if DEBUG
        print("DEBUG listen ahead: fetching part \(index) from chunk \(chunk) (\(part.chunks.count) saved)")
        #endif
    }

    private func cancelFetch() {
        fetch?.task.cancel()
        fetch = nil
    }

    /// Saves every whole chunk in the buffer (and the last, short one at the
    /// end of the file), then answers the player and decides what's next.
    private func saveChunks(final: Bool) {
        guard var current = fetch, let length = parts[current.part]?.length else { return }
        let size = Self.chunkSize
        while true {
            let chunkEnd = min(Int64(current.chunk + 1) * Int64(size), length)
            let needed = Int(chunkEnd - Int64(current.chunk) * Int64(size))
            guard needed > 0, current.buffer.count >= needed || (final && !current.buffer.isEmpty) else { break }
            let bytes = current.buffer.prefix(needed)
            let file = parts[current.part]!.directory.appending(path: "c\(current.chunk)")
            if (try? bytes.write(to: file, options: .atomic)) != nil, bytes.count == needed {
                parts[current.part]?.chunks.insert(current.chunk)
                #if DEBUG
                if current.chunk % 20 == 0 { print("DEBUG listen ahead: saved part \(current.part) chunk \(current.chunk) (\(parts[current.part]?.chunks.count ?? 0) saved)") }
                #endif
            }
            current.buffer.removeFirst(min(needed, current.buffer.count))
            current.chunk += 1
            if Int64(current.chunk) * Int64(size) >= length { break }
        }
        fetch = current
        serve()
        // On to the next chunk only while it's missing and still wanted;
        // otherwise schedule picks again.
        let next = (current.part, current.chunk)
        let atEnd = Int64(current.chunk) * Int64(size) >= length
        if atEnd || parts[next.0]?.chunks.contains(next.1) == true || !(isWanted(next)) {
            cancelFetch()
            schedule()
        }
    }

    private func isWanted(_ target: (part: Int, chunk: Int)) -> Bool {
        if let wanted = wantedByPlayer(), wanted.part == target.part, wanted.chunk >= target.chunk { return true }
        guard let ahead = wantedAhead() else { return false }
        return ahead.part == target.part && ahead.chunk >= target.chunk
    }

    // MARK: Letting go

    /// Lets go of what's well behind the playhead: earlier files, and the
    /// current file's chunks more than a minute back.
    private func prune() {
        let fileManager = FileManager.default
        for index in parts.indices where index < playhead.part {
            guard let part = parts[index], !part.chunks.isEmpty else { continue }
            for chunk in part.chunks { try? fileManager.removeItem(at: part.directory.appending(path: "c\(chunk)")) }
            parts[index]?.chunks = []
        }
        guard parts.indices.contains(playhead.part), let part = parts[playhead.part], let length = part.length, part.duration > 0 else { return }
        let perSecond = Double(length) / part.duration
        let keepFrom = Int(Int64(max(playhead.seconds - Self.keepBehind, 0) * perSecond) / Int64(Self.chunkSize))
        for chunk in part.chunks where chunk < keepFrom {
            try? fileManager.removeItem(at: part.directory.appending(path: "c\(chunk)"))
            parts[playhead.part]?.chunks.remove(chunk)
        }
    }
}

// MARK: - AVPlayer's loader

nonisolated extension ListenAhead: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard partIndex(of: loadingRequest) != nil else { return false }
        pending.append(loadingRequest)
        serve()
        schedule()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
        schedule()
    }
}

// MARK: - The download

nonisolated extension ListenAhead: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let current = fetch, current.task === dataTask, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        var total: Int64?
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") {
            total = Int64(range[range.index(after: slash)...])
        } else if http.statusCode == 200 {
            // The whole file from the start, whatever was asked.
            total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            fetch?.chunk = 0
            fetch?.buffer = Data()
        } else {
            completionHandler(.cancel)
            return
        }
        if let total, parts[current.part]?.length != total {
            parts[current.part]?.length = total
            try? Data(String(total).utf8).write(to: parts[current.part]!.directory.appending(path: "length"))
        }
        if parts[current.part]?.contentType == nil {
            let type = http.mimeType.flatMap(Self.type(forMIME:)) ?? "com.apple.m4a-audio"
            parts[current.part]?.contentType = type
            try? Data(type.utf8).write(to: parts[current.part]!.directory.appending(path: "type"))
        }
        completionHandler(.allow)
        serve()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard fetch?.task === dataTask else { return }
        fetch?.buffer.append(data)
        serve()
        if (fetch?.buffer.count ?? 0) >= Self.chunkSize { saveChunks(final: false) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard fetch?.task === task else { return }
        if error == nil {
            saveChunks(final: true)
            cancelFetch()
            schedule()
            return
        }
        // No signal: what's saved plays on, and the download tries again.
        #if DEBUG
        print("DEBUG listen ahead: download stopped (\(error!.localizedDescription)); trying again in 5 s")
        #endif
        cancelFetch()
        let again = DispatchWorkItem { [weak self] in self?.schedule() }
        retry = again
        queue.asyncAfter(deadline: .now() + 5, execute: again)
    }
}
#endif
