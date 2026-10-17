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
    private static let workQueue = DispatchQueue(label: "app.asterfin.listen-ahead")
    private var queue: DispatchQueue { Self.workQueue }
    /// Downloads report on the same queue.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = workQueue
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: shared, delegateQueue: delegateQueue)
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

    /// A download of a part from a chunk on, filling `buffer` until a whole
    /// chunk can be saved, and stopping at `end` (a chunk it doesn't fetch).
    /// One fills the stretch ahead; others serve the player's requests, each
    /// on its own, so reading a file's index and a seek don't fight over one.
    private struct Fetch {
        let part: Int
        var chunk: Int
        let end: Int
        var buffer = Data()
        let task: URLSessionDataTask
        let isAhead: Bool
    }

    private var bookId: String?
    /// The book's files; nil for one AVPlayer can't open as it is.
    private var parts: [Part?] = []
    private var aheadSeconds: TimeInterval = 0
    private var playhead: (part: Int, seconds: TimeInterval) = (0, 0)
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var fetches: [Fetch] = []
    private var retry: DispatchWorkItem?
    /// Downloads for the player's requests running at once, at most.
    private static let requestFetchLimit = 3

    private static var root: URL {
        URL.cachesDirectory.appending(path: "ListenAhead", directoryHint: .isDirectory)
    }

    // MARK: The player's side

    /// The part to play through the cache, or nil when Listen Ahead is off or
    /// the file can't be opened as it is (it then streams as before).
    @MainActor
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
            cancelFetches()
        }
    }

    /// The book was heard to the end: its cache goes.
    func finished(bookId: String) {
        queue.async { [self] in
            guard bookId == self.bookId else { return }
            cancelFetches()
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
        cancelFetches()
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
        for fetch in fetches where fetch.part == index && fetch.chunk == chunk && within < fetch.buffer.count {
            let count = min(fetch.buffer.count - within, Int(limit), Int(length - offset))
            return fetch.buffer.subdata(in: within..<within + count)
        }
        return nil
    }

    // MARK: Fetching

    /// Starts what's needed: a download for each waiting request that's
    /// missing bytes no download is bringing, and one filling the stretch
    /// ahead. Downloads nobody needs any more stop.
    private func schedule() {
        // The player's requests.
        for request in pending.reversed() {
            guard let index = partIndex(of: request), let part = parts[index] else { continue }
            let offset = request.dataRequest?.currentOffset ?? 0
            let chunk = Int(offset / Int64(Self.chunkSize))
            let known = part.length != nil && part.contentType != nil
            guard !known || !part.chunks.contains(chunk), !isComing(part: index, chunk: chunk) else { continue }
            guard fetches.filter({ !$0.isAhead }).count < Self.requestFetchLimit else { break }
            startFetch(part: index, from: chunk, to: requestEnd(of: request, part: index, from: chunk), isAhead: false)
        }
        // The stretch ahead.
        if !fetches.contains(where: \.isAhead), let ahead = wantedAhead(), !isComing(part: ahead.part, chunk: ahead.chunk) {
            startFetch(part: ahead.part, from: ahead.chunk, to: ahead.end, isAhead: true)
        }
    }

    /// Whether a download is on its way to `chunk`, near enough to reach it soon.
    private func isComing(part index: Int, chunk: Int) -> Bool {
        fetches.contains { $0.part == index && $0.chunk <= chunk && chunk < $0.end && chunk - $0.chunk <= 4 }
    }

    /// Where a request's download stops: its own end, or for one to the end
    /// of the file, a few MB on (or the end of the stretch ahead, if further);
    /// the stretch fills the rest as the book goes on.
    private func requestEnd(of request: AVAssetResourceLoadingRequest, part index: Int, from chunk: Int) -> Int {
        let size = Int64(Self.chunkSize)
        let total = parts[index]?.length.map { Int(($0 + size - 1) / size) } ?? Int.max
        if let data = request.dataRequest, !data.requestsAllDataToEndOfResource {
            let last = data.requestedOffset + Int64(data.requestedLength) - 1
            return min(total, Int(last / size) + 1)
        }
        let first = chunk + Int(Self.startOfRequest / size)
        let stretch = stretchEnd(part: index) ?? 0
        return min(total, max(first, stretch))
    }

    /// How much of an open-ended request is fetched however far ahead it is.
    private static let startOfRequest: Int64 = 4 * 1024 * 1024

    /// The chunk the stretch ahead ends before, in `part`; nil when the
    /// stretch doesn't reach it.
    private func stretchEnd(part target: Int) -> Int? {
        var remaining = aheadSeconds
        var index = playhead.part
        var from = playhead.seconds
        while remaining > 0, parts.indices.contains(index), index <= target {
            guard let part = parts[index], let length = part.length, part.duration > 0 else { return nil }
            if index == target {
                let perSecond = Double(length) / part.duration
                let lastByte = min(length - 1, Int64((from + remaining) * perSecond))
                return Int(lastByte / Int64(Self.chunkSize)) + 1
            }
            remaining -= max(part.duration - from, 0)
            index += 1
            from = 0
        }
        return nil
    }

    /// The first chunk missing between the playhead and `aheadSeconds` on,
    /// across the book's files, and where that file's stretch ends.
    private func wantedAhead() -> (part: Int, chunk: Int, end: Int)? {
        var remaining = aheadSeconds
        var index = playhead.part
        var from = playhead.seconds
        while remaining > 0, parts.indices.contains(index) {
            guard let part = parts[index] else { return nil }
            guard let length = part.length, part.duration > 0 else { return (index, 0, 1) }
            let perSecond = Double(length) / part.duration
            let first = Int(Int64(max(from, 0) * perSecond) / Int64(Self.chunkSize))
            let lastByte = min(length - 1, Int64((from + remaining) * perSecond))
            let last = Int(lastByte / Int64(Self.chunkSize))
            if first <= last, let missing = (first...last).first(where: { !part.chunks.contains($0) }) {
                return (index, missing, last + 1)
            }
            remaining -= max(part.duration - from, 0)
            index += 1
            from = 0
        }
        return nil
    }

    private func startFetch(part index: Int, from chunk: Int, to end: Int, isAhead: Bool) {
        guard let part = parts[index], chunk < end else { return }
        retry?.cancel()
        var request = URLRequest(url: part.url)
        request.setValue("bytes=\(Int64(chunk) * Int64(Self.chunkSize))-", forHTTPHeaderField: "Range")
        let task = Self.session.dataTask(with: request)
        fetches.append(Fetch(part: index, chunk: chunk, end: end, task: task, isAhead: isAhead))
        task.resume()
        #if DEBUG
        print("DEBUG listen ahead: fetching part \(index) chunks \(chunk)..<\(end == Int.max ? -1 : end) for \(isAhead ? "the stretch ahead" : "the player") (\(part.chunks.count) saved)")
        #endif
    }

    private func cancelFetches() {
        for fetch in fetches { fetch.task.cancel() }
        fetches = []
    }

    private func stop(_ task: URLSessionTask) {
        task.cancel()
        fetches.removeAll { $0.task === task }
    }

    /// Saves every whole chunk a download holds (and the last, short one at
    /// the end of the file), answers the player, and ends the download once
    /// it has reached its end or the next chunk is already saved.
    private func saveChunks(of task: URLSessionTask, final: Bool) {
        guard let position = fetches.firstIndex(where: { $0.task === task }) else { return }
        var current = fetches[position]
        guard let part = parts[current.part], let length = part.length else { return }
        let size = Self.chunkSize
        var finished = false
        while true {
            let start = Int64(current.chunk) * Int64(size)
            guard start < length, current.chunk < current.end else {
                finished = true
                break
            }
            let needed = Int(min(Int64(size), length - start))
            guard current.buffer.count >= needed || (final && !current.buffer.isEmpty) else { break }
            let bytes = current.buffer.prefix(needed)
            if bytes.count == needed, parts[current.part]?.chunks.contains(current.chunk) == false {
                if (try? bytes.write(to: part.directory.appending(path: "c\(current.chunk)"), options: .atomic)) != nil {
                    parts[current.part]?.chunks.insert(current.chunk)
                    #if DEBUG
                    if current.chunk % 20 == 0 { print("DEBUG listen ahead: saved part \(current.part) chunk \(current.chunk) (\(parts[current.part]?.chunks.count ?? 0) saved)") }
                    #endif
                }
            }
            current.buffer.removeFirst(min(needed, current.buffer.count))
            current.chunk += 1
            // Further on is already here: no need to download it again.
            if parts[current.part]?.chunks.contains(current.chunk) == true {
                finished = true
                break
            }
        }
        fetches[position] = current
        serve()
        if finished || final {
            stop(task)
            schedule()
        }
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
        for chunk in part.chunks where chunk < keepFrom && chunk > 0 {
            // The file's first chunk stays: its index is read on every open.
            try? fileManager.removeItem(at: part.directory.appending(path: "c\(chunk)"))
            parts[playhead.part]?.chunks.remove(chunk)
        }
        // The stretch ahead moved on past what its download was fetching.
        for fetch in fetches where fetch.isAhead && fetch.part < playhead.part {
            stop(fetch.task)
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
    }
}

// MARK: - The downloads

nonisolated extension ListenAhead: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let position = fetches.firstIndex(where: { $0.task === dataTask }), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let index = fetches[position].part
        var total: Int64?
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") {
            total = Int64(range[range.index(after: slash)...])
        } else if http.statusCode == 200 {
            // The whole file from the start, whatever was asked.
            total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            fetches[position].chunk = 0
            fetches[position].buffer = Data()
        } else {
            completionHandler(.cancel)
            stop(dataTask)
            return
        }
        if let total, parts[index]?.length != total {
            parts[index]?.length = total
            try? Data(String(total).utf8).write(to: parts[index]!.directory.appending(path: "length"))
        }
        if parts[index]?.contentType == nil {
            let type = http.mimeType.flatMap(Self.type(forMIME:)) ?? "com.apple.m4a-audio"
            parts[index]?.contentType = type
            try? Data(type.utf8).write(to: parts[index]!.directory.appending(path: "type"))
        }
        completionHandler(.allow)
        serve()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let position = fetches.firstIndex(where: { $0.task === dataTask }) else { return }
        fetches[position].buffer.append(data)
        serve()
        if fetches[position].buffer.count >= Self.chunkSize { saveChunks(of: dataTask, final: false) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard fetches.contains(where: { $0.task === task }) else { return }
        if error == nil {
            saveChunks(of: task, final: true)
            return
        }
        // No signal: what's saved plays on, and the downloads try again.
        #if DEBUG
        print("DEBUG listen ahead: download stopped (\(error!.localizedDescription)); trying again in 5 s")
        #endif
        stop(task)
        let again = DispatchWorkItem { [weak self] in self?.schedule() }
        retry = again
        queue.asyncAfter(deadline: .now() + 5, execute: again)
    }
}
#endif
