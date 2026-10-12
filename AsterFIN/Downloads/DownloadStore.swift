//
//  DownloadStore.swift
//  AsterFIN
//
//  Movies and episodes saved for offline viewing on iPhone and iPad. The
//  server prepares each one as an HLS stream at the chosen quality, and
//  AVFoundation saves it segment by segment, carrying on in the background
//  and resuming after interruptions. A downloaded title plays from the
//  device whether or not the server can be reached.
//

#if !os(tvOS)
import AVFoundation
import Foundation
import Observation

/// The quality downloads are made at.
nonisolated enum DownloadQuality: String, CaseIterable, Identifiable, Sendable {
    case original, high, medium, low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .high: "High · 1080p"
        case .medium: "Medium · 720p"
        case .low: "Low · 480p"
        }
    }

    var detail: String {
        switch self {
        case .original: "The video as it is, when the device can play it. Largest files."
        case .high: "Up to 8 Mbps, about 3.5 GB an hour."
        case .medium: "Up to 4 Mbps, about 1.8 GB an hour."
        case .low: "Up to 1.5 Mbps, about 0.7 GB an hour."
        }
    }

    var maxBitrate: Int {
        switch self {
        case .original: 120_000_000
        case .high: 8_000_000
        case .medium: 4_000_000
        case .low: 1_500_000
        }
    }

    var maxWidth: Int? {
        switch self {
        case .original: nil
        case .high: 1920
        case .medium: 1280
        case .low: 854
        }
    }
}

/// The download settings (Settings › Downloads), read where they're needed.
enum DownloadSettings {
    private static var defaults: UserDefaults { .standard }

    /// On unless switched off.
    static var enabled: Bool {
        defaults.object(forKey: AppSettings.downloadsEnabledKey) as? Bool ?? true
    }

    /// Whether the first-download setup has been through.
    static var isSetUp: Bool {
        defaults.bool(forKey: AppSettings.downloadsSetUpKey)
    }

    /// The most downloads may take, in bytes; nil for no limit.
    static var storageLimit: Int64? {
        let gigabytes = defaults.integer(forKey: AppSettings.downloadStorageLimitKey)
        return gigabytes > 0 ? Int64(gigabytes) * 1_000_000_000 : nil
    }

    static var quality: DownloadQuality {
        DownloadQuality(rawValue: defaults.string(forKey: AppSettings.downloadQualityKey) ?? "") ?? .high
    }

    /// HEVC makes smaller files but takes a server longer to prepare
    /// without hardware encoding, so H.264 is the default.
    static var allowHEVC: Bool {
        defaults.bool(forKey: AppSettings.downloadHEVCKey)
    }

    static var includeSubtitles: Bool {
        defaults.object(forKey: AppSettings.downloadSubtitlesKey) as? Bool ?? true
    }

    static var useCellular: Bool {
        defaults.bool(forKey: AppSettings.downloadCellularKey)
    }
}

/// One downloaded (or downloading) title, kept in the store's index.
nonisolated struct DownloadRecord: Codable, Identifiable, Sendable, Hashable {
    enum State: String, Codable, Sendable {
        case downloading, finished, failed
    }

    /// The item's id.
    var id: String
    var item: BaseItem
    var mediaSourceId: String?
    var quality: String
    var state: State
    var progress: Double = 0
    /// Where the saved stream is, relative to the app's home directory, as
    /// AVFoundation advises: the container's path changes between installs.
    var assetPath: String?
    /// The size expected before it finishes, then the size on disk.
    var expectedBytes: Int64
    var bytesOnDisk: Int64 = 0
    /// The subtitle track saved with it, if any.
    var subtitleTrack: MediaStream?
    var segments: [MediaSegment] = []
    /// Where viewing got to, kept here so offline resumes work.
    var positionTicks: Int64 = 0
    var added: Date
    var errorMessage: String?
}

enum DownloadError: LocalizedError {
    case disabled
    case notAllowed
    case noRoom(needed: Int64, available: Int64)
    case overLimit(needed: Int64, remaining: Int64)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Downloads are turned off in Settings › Downloads."
        case .notAllowed:
            "Your Jellyfin account isn't allowed to download media. The server's administrator can allow it in the user's settings."
        case .noRoom(let needed, let available):
            "This needs about \(DownloadStore.format(needed)), and the device has \(DownloadStore.format(available)) free."
        case .overLimit(let needed, let remaining):
            "This needs about \(DownloadStore.format(needed)), and \(DownloadStore.format(remaining)) of your downloads limit is left. Raise the limit or remove a download in Settings › Downloads."
        case .server(let message):
            message
        }
    }
}

@Observable
final class DownloadStore: NSObject {
    static let shared = DownloadStore()

    /// One background session per network rule: a session's cellular access
    /// is fixed when it's made.
    static let wifiSessionID = "app.asterfin.downloads"
    static let cellularSessionID = "app.asterfin.downloads.cellular"

    /// Newest first.
    private(set) var records: [DownloadRecord] = []

    @ObservationIgnored private var wifiSession: AVAssetDownloadURLSession?
    @ObservationIgnored private var cellularSession: AVAssetDownloadURLSession?
    @ObservationIgnored private var tasks: [String: AVAssetDownloadTask] = [:]
    /// Background relaunches waiting for the sessions to deliver their events.
    @ObservationIgnored private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var backgroundEventsDelivered = false

    override private init() {
        super.init()
        records = Self.loadIndex()
        wifiSession = makeSession(Self.wifiSessionID, cellular: false)
        cellularSession = makeSession(Self.cellularSessionID, cellular: true)
        Task { await reattach() }
    }

    private func makeSession(_ identifier: String, cellular: Bool) -> AVAssetDownloadURLSession {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.allowsCellularAccess = cellular
        configuration.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
    }

    /// Picks up downloads still running from an earlier launch; any the
    /// system no longer has were interrupted.
    private func reattach() async {
        for session in [wifiSession, cellularSession].compactMap({ $0 }) {
            for task in await session.allTasks {
                if let task = task as? AVAssetDownloadTask, let id = task.taskDescription {
                    tasks[id] = task
                }
            }
        }
        var changed = false
        for index in records.indices where records[index].state == .downloading && tasks[records[index].id] == nil {
            records[index].state = .failed
            records[index].errorMessage = "The download was interrupted."
            changed = true
        }
        if changed { saveIndex() }
    }

    // MARK: Looking up

    func record(for itemId: String) -> DownloadRecord? {
        records.first { $0.id == itemId }
    }

    /// The finished download of an item, ready to play.
    func playable(_ itemId: String) -> DownloadRecord? {
        guard let record = record(for: itemId), record.state == .finished, let url = assetURL(for: record),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return record
    }

    func assetURL(for record: DownloadRecord) -> URL? {
        guard let path = record.assetPath else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: Self.homeRelative(path))
    }

    /// A path inside the app's container, relative to its home directory.
    /// iOS gives the container as /private/var/... or /var/... (one is a link
    /// to the other), so an absolute path is cut at its Library folder, where
    /// AVFoundation keeps downloads, rather than at the home path.
    private static func homeRelative(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        for home in [NSHomeDirectory(), URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path] {
            if path.hasPrefix(home + "/") { return String(path.dropFirst(home.count + 1)) }
        }
        if let library = path.range(of: "/Library/") {
            return String(path[path.index(after: library.lowerBound)...])
        }
        return path
    }

    /// The saved subtitle cues for a download, if it has some.
    func subtitleCues(for itemId: String) -> [SubtitleCue]? {
        guard let data = try? Data(contentsOf: Self.folder(for: itemId).appending(path: "subtitles.json")) else { return nil }
        return try? JSONDecoder().decode([SubtitleCue].self, from: data)
    }

    /// The picture saved for a download's row.
    func artworkURL(for itemId: String) -> URL? {
        let url = Self.folder(for: itemId).appending(path: "artwork.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Space

    /// What downloads take now, counting the expected size of those still
    /// coming, so a new one can't overrun the limit as they finish.
    var reservedBytes: Int64 {
        records.reduce(0) { total, record in
            total + (record.state == .finished ? record.bytesOnDisk : record.state == .downloading ? record.expectedBytes : 0)
        }
    }

    var usedBytes: Int64 {
        records.filter { $0.state == .finished }.reduce(0) { $0 + $1.bytesOnDisk }
    }

    /// Free space on the device for things the person asked for.
    static var freeBytes: Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func checkRoom(for bytes: Int64) throws {
        // Leave the device some breathing room.
        if let free = Self.freeBytes, bytes > free - 500_000_000 {
            throw DownloadError.noRoom(needed: bytes, available: max(free, 0))
        }
        if let limit = DownloadSettings.storageLimit, reservedBytes + bytes > limit {
            throw DownloadError.overLimit(needed: bytes, remaining: max(limit - reservedBytes, 0))
        }
    }

    // MARK: Downloading

    /// Asks the server for the title at the chosen quality and starts saving
    /// it, with its skip markers, artwork and, if wanted, a subtitle track.
    func start(_ item: BaseItem, client: JellyfinClient, preferences: PlaybackPreferences, canDownload: Bool) async throws {
        guard DownloadSettings.enabled else { throw DownloadError.disabled }
        guard canDownload else { throw DownloadError.notAllowed }
        if let existing = record(for: item.id), existing.state != .failed { return }

        let quality = DownloadSettings.quality
        let info = try await client.playbackInfo(
            itemId: item.id,
            startTicks: 0,
            maxBitrate: quality.maxBitrate,
            // Subtitles come separately; never burn one into the file.
            subtitleStreamIndex: -1,
            allowDirect: false,
            profile: .download(maxBitrate: quality.maxBitrate, maxWidth: quality.maxWidth, allowHEVC: DownloadSettings.allowHEVC)
        )
        if let code = info.errorCode {
            throw DownloadError.server("The server couldn't prepare this title (\(code)).")
        }
        guard let source = info.mediaSources.first, let path = source.transcodingUrl,
              let url = client.absoluteURL(serverRelative: path) else {
            throw DownloadError.server("The server didn't offer a stream to download.")
        }

        // The size to expect: the stream's bitrate over the running time.
        let seconds = Double(item.runTimeTicks ?? source.runTimeTicks ?? 0) / 10_000_000
        let bitrate = Double(min(quality.maxBitrate, source.bitrate ?? quality.maxBitrate))
        let expected = Int64(bitrate * seconds / 8)
        try checkRoom(for: expected)

        var subtitle: MediaStream?
        if DownloadSettings.includeSubtitles {
            let tracks = (source.mediaStreams ?? []).filter { $0.type == "Subtitle" }
            let chosen = PlaybackCoordinator.resolveSubtitle(for: PlaybackQueueItem(itemId: item.id), source: source, among: tracks, preferences: preferences)
            subtitle = tracks.first { $0.index == chosen && PlaybackCoordinator.isTextTrack($0) }
        }

        let folder = Self.folder(for: item.id)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        records.removeAll { $0.id == item.id }
        records.insert(DownloadRecord(
            id: item.id,
            item: item,
            mediaSourceId: source.id,
            quality: quality.rawValue,
            state: .downloading,
            expectedBytes: expected,
            subtitleTrack: subtitle,
            added: Date()
        ), at: 0)
        saveIndex()

        let configuration = AVAssetDownloadConfiguration(asset: AVURLAsset(url: url), title: item.displayTitle)
        if let artwork = client.landscapeURL(for: item, width: 600), let data = try? await client.data(from: artwork) {
            configuration.artworkData = data
            try? data.write(to: folder.appending(path: "artwork.jpg"))
        }
        guard let session = DownloadSettings.useCellular ? cellularSession : wifiSession else { return }
        let task = session.makeAssetDownloadTask(downloadConfiguration: configuration)
        task.taskDescription = item.id
        tasks[item.id] = task
        task.resume()

        // Skip markers and the subtitle track while the video downloads.
        let mediaSourceId = source.id
        Task {
            if let segments = try? await client.mediaSegments(itemId: item.id) {
                update(item.id) { $0.segments = segments }
            }
            if let subtitle, let index = subtitle.index,
               let cues = try? await client.subtitleCues(itemId: item.id, mediaSourceId: mediaSourceId, streamIndex: index),
               let data = try? JSONEncoder().encode(cues) {
                try? data.write(to: folder.appending(path: "subtitles.json"))
            }
        }
    }

    /// Starts a failed download again from the beginning.
    func retry(_ itemId: String, client: JellyfinClient, preferences: PlaybackPreferences, canDownload: Bool) async throws {
        guard let record = record(for: itemId) else { return }
        remove(itemId)
        try await start(record.item, client: client, preferences: preferences, canDownload: canDownload)
    }

    /// Stops a download, or deletes a finished one, and its files.
    func remove(_ itemId: String) {
        tasks[itemId]?.cancel()
        tasks[itemId] = nil
        if let record = record(for: itemId), let url = assetURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: Self.folder(for: itemId))
        records.removeAll { $0.id == itemId }
        saveIndex()
    }

    func removeAll() {
        for id in records.map(\.id) { remove(id) }
    }

    /// Remembers where viewing got to, for resuming offline.
    func notePosition(itemId: String, ticks: Int64) {
        guard record(for: itemId) != nil else { return }
        update(itemId) { $0.positionTicks = ticks }
    }

    private func update(_ itemId: String, save: Bool = true, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == itemId }) else { return }
        change(&records[index])
        if save { saveIndex() }
    }

    private func finish(_ itemId: String, error: (any Error)?) {
        tasks[itemId] = nil
        guard let record = record(for: itemId) else { return }
        if let error {
            // A removed download is cancelled; nothing left to update.
            if (error as NSError).code == NSURLErrorCancelled { return }
            update(itemId) {
                $0.state = .failed
                $0.errorMessage = error.localizedDescription
            }
            return
        }
        var size: Int64 = 0
        if let url = assetURL(for: record) {
            size = Self.size(of: url)
        }
        update(itemId) {
            $0.state = .finished
            $0.progress = 1
            $0.bytesOnDisk = size
            $0.errorMessage = nil
        }
    }

    private func noteLocation(_ location: URL, for itemId: String) {
        let path = Self.homeRelative(location.path)
        update(itemId) { $0.assetPath = path }
    }

    // MARK: Background relaunch

    /// Waits until the system has delivered the events it relaunched the
    /// app for, so SwiftUI can then tell it the app is done.
    func waitForBackgroundEvents() async {
        if backgroundEventsDelivered {
            backgroundEventsDelivered = false
            return
        }
        await withCheckedContinuation { backgroundWaiters.append($0) }
    }

    // MARK: Files

    private static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    static func folder(for itemId: String) -> URL {
        root.appending(path: itemId, directoryHint: .isDirectory)
    }

    private static var indexURL: URL { root.appending(path: "index.json") }

    private static func loadIndex() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([DownloadRecord].self, from: data)) ?? []
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }

    /// A saved stream is a package of many files.
    private static func size(of url: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

// The sessions deliver on the main queue, so each callback is on the main actor.
extension DownloadStore: AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        guard let id = assetDownloadTask.taskDescription else { return }
        MainActor.assumeIsolated { noteLocation(location, for: id) }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.taskDescription else { return }
        MainActor.assumeIsolated { noteLocation(location, for: id) }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected > 0 else { return }
        let fraction = min(loaded / expected, 1)
        // Progress changes often; the index is saved when the state does.
        MainActor.assumeIsolated { update(id, save: false) { $0.progress = fraction } }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = task.taskDescription else { return }
        MainActor.assumeIsolated { finish(id, error: error) }
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
