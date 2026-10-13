//
//  AudiobookLibrary.swift
//  AsterFIN
//
//  The server's audiobooks, gathered into books. Jellyfin lists audiobook
//  files, not books: an .m4b is a whole book with its chapters inside, but a
//  book kept as a folder of MP3s is one item per file. Files in the same
//  folder with the same album are taken as the parts of one book. Authors
//  and series often aren't tagged, so they also come from the folders, laid
//  out as Author/[Series/]Book/.
//

import Foundation
import Observation

/// A place in a book's chapter list: which part (file) it's in, and how far
/// into that part it starts.
struct AudiobookChapter: Identifiable, Hashable {
    let id: Int
    let part: Int
    let start: TimeInterval
    let title: String
}

struct Audiobook: Identifiable, Hashable {
    /// The file's id for a one-file book, or the first part's for the rest.
    let id: String
    let title: String
    let author: String?
    let series: String?
    /// Its place in the series, when the file name or tags give one.
    let seriesIndex: Int?
    /// The book's files in order; never empty.
    let parts: [BaseItem]

    /// The item whose cover and description stand for the book.
    var cover: BaseItem { parts[0] }
    var overview: String? { parts.lazy.compactMap(\.overview).first }
    var year: Int? { cover.productionYear }
    var dateAdded: String? { cover.dateCreated }

    /// Each part's length, in seconds.
    var partDurations: [TimeInterval] {
        parts.map { TimeInterval($0.runTimeTicks ?? 0) / 10_000_000 }
    }

    var duration: TimeInterval { partDurations.reduce(0, +) }

    /// Seconds into the book where `part` begins.
    func offset(ofPart part: Int) -> TimeInterval {
        partDurations.prefix(max(part, 0)).reduce(0, +)
    }

    /// The chapters across every part: an .m4b's own chapters, and for a
    /// part without any, the part itself. Empty for a single file with none.
    var chapters: [AudiobookChapter] {
        var list: [AudiobookChapter] = []
        for (index, part) in parts.enumerated() {
            let own = (part.chapters ?? []).sorted { $0.startPositionTicks < $1.startPositionTicks }
            if own.isEmpty {
                guard parts.count > 1 else { continue }
                list.append(AudiobookChapter(id: list.count, part: index, start: 0, title: part.name ?? "Part \(index + 1)"))
            } else {
                for chapter in own {
                    let title = chapter.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(list.count + 1)"
                    list.append(AudiobookChapter(id: list.count, part: index, start: TimeInterval(chapter.startPositionTicks) / 10_000_000, title: title))
                }
            }
        }
        return list
    }

    /// Where listening left off, from what Jellyfin recorded: the last part
    /// started and how far into it, or the start of the part after the last
    /// one finished. Nil before the book is started and once it's finished.
    var resumePoint: (part: Int, seconds: TimeInterval)? {
        guard let last = parts.lastIndex(where: { ($0.userData?.playbackPositionTicks ?? 0) > 0 || $0.userData?.played == true }) else { return nil }
        let data = parts[last].userData
        if let ticks = data?.playbackPositionTicks, ticks > 0 {
            return (last, TimeInterval(ticks) / 10_000_000)
        }
        return last + 1 < parts.count ? (last + 1, 0) : nil
    }

    var isFinished: Bool { parts.last?.userData?.played == true && resumePoint == nil }

    /// How much has been listened to, 0 to 1.
    var progress: Double {
        guard duration > 0 else { return 0 }
        if isFinished { return 1 }
        guard let point = resumePoint else { return 0 }
        return min((offset(ofPart: point.part) + point.seconds) / duration, 1)
    }

    /// When any part was last played (ISO 8601, so it sorts as text).
    var lastPlayed: String? {
        parts.compactMap { $0.userData?.lastPlayedDate }.max()
    }

    /// "8 hr 12 min" for the whole book.
    var lengthText: String? {
        MusicFormat.length(ticks: parts.reduce(0) { $0 + ($1.runTimeTicks ?? 0) })
    }

    /// A copy with the parts' listening state refreshed from the server.
    func updating(_ fresh: [BaseItem]) -> Audiobook {
        let byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Audiobook(id: id, title: title, author: author, series: series, seriesIndex: seriesIndex, parts: parts.map { byId[$0.id] ?? $0 })
    }

    /// A book from one file, as Search finds them: no folder to read the
    /// author or series from.
    init(item: BaseItem) {
        self.init(id: item.id, title: item.displayTitle, author: item.albumArtist ?? item.artistText, series: nil, seriesIndex: nil, parts: [item])
    }

    init(id: String, title: String, author: String?, series: String?, seriesIndex: Int?, parts: [BaseItem]) {
        self.id = id
        self.title = title
        self.author = author
        self.series = series
        self.seriesIndex = seriesIndex
        self.parts = parts
    }
}

/// An author's books, or a series in order: what an author or series page shows.
struct AudiobookShelf: Identifiable, Hashable {
    enum Kind: Hashable {
        case author, series
    }

    let kind: Kind
    let name: String
    let books: [Audiobook]

    var id: String { "\(kind)-\(name)" }
}

@Observable
final class AudiobookLibrary {
    private(set) var books: [Audiobook] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    /// Books started and not finished, most recently played first.
    var continueListening: [Audiobook] {
        books.filter { $0.resumePoint != nil }
            .sorted { ($0.lastPlayed ?? "") > ($1.lastPlayed ?? "") }
    }

    var recentlyAdded: [Audiobook] {
        Array(books.sorted { ($0.dateAdded ?? "") > ($1.dateAdded ?? "") }.prefix(20))
    }

    var authors: [AudiobookShelf] {
        shelves(.author) { $0.author }
    }

    var series: [AudiobookShelf] {
        shelves(.series) { $0.series }
    }

    private func shelves(_ kind: AudiobookShelf.Kind, by key: (Audiobook) -> String?) -> [AudiobookShelf] {
        Dictionary(grouping: books.filter { key($0) != nil }) { key($0) ?? "" }
            .map { name, books in
                let ordered = kind == .series
                    ? books.sorted { ($0.seriesIndex ?? .max, $0.title) < ($1.seriesIndex ?? .max, $1.title) }
                    : books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return AudiobookShelf(kind: kind, name: name, books: ordered)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Fetches every book in `libraries`. Keeps what's showing while it
    /// reloads, so coming back to the tab doesn't flash empty.
    func load(client: JellyfinClient, libraries: [BaseItem]) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            var all: [Audiobook] = []
            for library in libraries {
                async let folders = client.items([
                    "parentId": library.id,
                    "includeItemTypes": "Folder",
                    "recursive": "true",
                    "fields": "ParentId",
                    "enableUserData": "false",
                ])
                async let files = client.items([
                    "parentId": library.id,
                    "includeItemTypes": "AudioBook",
                    "recursive": "true",
                    "fields": Self.fields,
                    "sortBy": "SortName",
                    "sortOrder": "Ascending",
                ])
                all += Self.books(from: try await files.items, folders: try await folders.items)
            }
            #if os(iOS)
            // Listening done offline counts, and goes to the server.
            let downloads = AudiobookDownloads.shared
            let fromServer = all
            Task { await downloads.sync(with: fromServer, client: client) }
            all = fromServer.map(downloads.withLocalProgress)
            #endif
            books = all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch {
            if books.isEmpty { errorMessage = error.localizedDescription }
        }
        hasLoaded = true
        isLoading = false
    }

    /// What a book needs from each file: chapters, length, its folder.
    static let fields = "Overview,ProductionYear,RunTimeTicks,ParentId,DateCreated,Chapters,PrimaryImageAspectRatio"

    /// Groups files into books, and reads authors and series from the
    /// folders the files sit in.
    static func books(from files: [BaseItem], folders: [BaseItem]) -> [Audiobook] {
        let folderById = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        /// The folder names from just inside the library down to `id`.
        func chain(_ id: String?) -> [String] {
            var names: [String] = []
            var current = id
            var seen = Set<String>()
            while let id = current, let folder = folderById[id], seen.insert(id).inserted {
                // The library's own top folder has no folder above it.
                guard let parent = folder.parentId, folderById[parent] != nil else { break }
                names.insert(folder.displayTitle, at: 0)
                current = parent
            }
            return names
        }

        // Parts of one book share a folder and an album; a file with no
        // album is a book of its own.
        let groups = Dictionary(grouping: files) { file in
            "\(file.parentId ?? "")|\(file.album.flatMap { $0.isEmpty ? nil : $0 } ?? file.id)"
        }
        let booksPerFolder = Dictionary(grouping: groups.values) { $0[0].parentId ?? "" }.mapValues(\.count)

        return groups.values.map { group in
            let parts = group.sorted {
                ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0, $0.displayTitle) < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0, $1.displayTitle)
            }
            let first = parts[0]
            var folders = chain(first.parentId)
            let authorFolder = folders.isEmpty ? nil : folders.removeFirst()
            // A folder holding just this book is the book's own, not a series.
            if booksPerFolder[first.parentId ?? ""] == 1, !folders.isEmpty {
                folders.removeLast()
            }
            let series = folders.first
            let title = parts.count > 1 ? (first.album ?? first.displayTitle) : first.displayTitle
            return Audiobook(
                id: first.id,
                title: title,
                author: authorFolder ?? first.albumArtist ?? first.artistText,
                series: series,
                seriesIndex: series != nil && parts.count == 1 ? first.indexNumber : nil,
                parts: parts
            )
        }
    }
}

/// The listening speed chosen for each book, kept on this device.
enum AudiobookRates {
    private static let key = "AsterFIN.audiobookRates"
    static let choices: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static func rate(for bookId: String) -> Float {
        let stored = UserDefaults.standard.dictionary(forKey: key)?[bookId] as? Double
        return stored.map(Float.init) ?? 1
    }

    static func setRate(_ rate: Float, for bookId: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[bookId] = rate == 1 ? nil : Double(rate)
        UserDefaults.standard.set(all, forKey: key)
    }

    /// "1×", "1.25×".
    static func label(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
