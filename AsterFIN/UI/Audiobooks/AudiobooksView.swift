//
//  AudiobooksView.swift
//  AsterFIN
//
//  The Audiobooks tab: what's being listened to, what's new, and every book
//  by title, author or series; a book's page with its chapters; and the
//  player, as a bar on the tab and full screen.
//

import SwiftUI

enum AudiobookSection: String, CaseIterable, Identifiable {
    case books = "Books"
    case authors = "Authors"
    case series = "Series"

    var id: String { rawValue }
}

// MARK: - Audiobooks tab

struct AudiobooksView: View {
    /// One book library, when opened from the Library tab; else all of them.
    var library: BaseItem? = nil

    @Environment(AppSession.self) private var session
    @State private var model = AudiobookLibrary()
    @State private var section: AudiobookSection = .books
    /// Where focus goes on pressing down from the hero: the first book below.
    @FocusState private var focusedBook: String?

    /// The hero's books: those partway through, then the newest, as Home
    /// picks its titles.
    private var featured: [Audiobook] {
        var picks: [Audiobook] = []
        for book in model.continueListening.prefix(4) + model.recentlyAdded.prefix(5) where !picks.contains(where: { $0.id == book.id }) {
            picks.append(book)
        }
        return Array(picks.prefix(8))
    }

    private var libraries: [BaseItem] {
        library.map { [$0] } ?? session.bookLibraries
    }

    var body: some View {
        let featured = featured
        let hasHero = model.hasLoaded && !featured.isEmpty
        ScrollView(.vertical) {
            // A plain VStack, as on Home: focus can only move from the hero to
            // a book that exists. The grid below stays lazy.
            VStack(alignment: .leading, spacing: 20) {
                if hasHero {
                    HeroCarousel(items: featured.map(\.cover), moveDown: {
                        focusedBook = (model.continueListening.first ?? model.recentlyAdded.first)?.id
                    }, focusChanged: { focused in
                        if focused { focusedBook = nil }
                    }, card: { item, focused in
                        AnyView(Group {
                            if let book = featured.first(where: { $0.id == item.id }) {
                                AudiobookHeroCard(book: book, isFocused: focused)
                            }
                        })
                    }, onSelect: { item in
                        // Listen straight away, as Play on a title does.
                        guard let book = featured.first(where: { $0.id == item.id }), let client = session.client else { return }
                        session.audiobooks.play(book, client: client)
                    })
                }
                // Only once loaded: the header shown first would take focus on
                // Apple TV, and the hero arriving above would push it down.
                if model.hasLoaded || !model.books.isEmpty {
                    header
                        .padding(.horizontal, Lockup.screenPadding)
                        #if os(tvOS)
                        .padding(.top, hasHero ? 0 : 40)
                        #else
                        .padding(.top, hasHero ? 0 : 8)
                        #endif
                        .tvFocusSection()
                }

                #if os(tvOS)
                // Elsewhere the book playing shows on every tab (see
                // `AudioAccessory`).
                if session.audiobooks.book != nil {
                    AudiobookBar()
                        .padding(.horizontal, Lockup.screenPadding)
                }
                #endif

                if model.books.isEmpty, let error = model.errorMessage {
                    MessageView(systemImage: "exclamationmark.triangle", title: "Couldn't load", detail: error) {
                        Task { await load() }
                    }
                    .frame(height: Lockup.emptyStateHeight)
                } else if model.books.isEmpty, model.hasLoaded {
                    MessageView(systemImage: "books.vertical", title: "No audiobooks yet")
                        .frame(height: Lockup.emptyStateHeight)
                } else if model.books.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: Lockup.emptyStateHeight)
                } else {
                    content
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        // Full-bleed under the hero, as on Home; the rows keep their margins.
        .ignoresSafeArea(edges: hasHero ? .all : [])
        // Again each time the tab shows, so listening done elsewhere (or
        // just now) moves Continue Listening along.
        .task(id: session.audiobooks.book?.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .books:
            Shelf(title: "Continue Listening", items: model.continueListening) { book in
                AudiobookLockup(book: book, focus: $focusedBook)
            }
            Shelf(title: "Recently Added", items: model.recentlyAdded) { book in
                AudiobookLockup(book: book, focus: $focusedBook)
            }
            sectionTitle("All Books")
            AudiobookGrid(books: model.books)
        case .authors:
            sectionTitle("Authors")
            AudiobookShelfGrid(shelves: model.authors)
        case .series:
            sectionTitle("Series")
            AudiobookShelfGrid(shelves: model.series)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.top, 20)
    }

    /// As on the Music tab: the title and the section picker beside it on a
    /// TV, the picker below it elsewhere.
    private var header: some View {
        let title = Text(library?.displayTitle ?? "Audiobooks")
            .font(.largeTitle.weight(.bold))
        let picker = Picker("Section", selection: $section) {
            ForEach(AudiobookSection.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        #if os(tvOS)
        return HStack(alignment: .firstTextBaseline) {
            title
            Spacer()
            picker.frame(width: 740)
        }
        #else
        return VStack(alignment: .leading, spacing: 12) {
            title
            picker
        }
        #endif
    }

    private func load() async {
        guard let client = session.client else { return }
        await model.load(client: client, libraries: libraries)
    }
}

// MARK: - Grids and lockups

struct AudiobookGrid: View {
    let books: [Audiobook]

    private let columns = [GridItem(.adaptive(minimum: Lockup.squareWidth, maximum: Lockup.squareWidth), spacing: Lockup.gridSpacing, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Lockup.gridRowSpacing) {
            ForEach(books) { book in
                AudiobookLockup(book: book)
            }
        }
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.vertical, 20)
        .tvFocusSection()
    }
}

/// A book's cover, how far through it is, its title and author.
/// A book as a page of the Audiobooks hero. A book has only its square
/// cover, so the cover, blurred, fills the banner behind the cover itself,
/// its title, author and how far along it is.
struct AudiobookHeroCard: View {
    let book: Audiobook
    let isFocused: Bool

    @Environment(AppSession.self) private var session
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// An iPhone held upright has no room for the cover beside the text, so
    /// the cover goes above it, smaller.
    private var stacked: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact && verticalSizeClass == .regular
        #else
        false
        #endif
    }

    private static let stackedCoverSize: CGFloat = 150

    #if os(tvOS)
    private static let coverSize: CGFloat = 420
    private static let titleSize: CGFloat = 60
    private static let overviewWidth: CGFloat = 900
    #else
    private static let coverSize: CGFloat = 200
    private static let titleSize: CGFloat = 32
    private static let overviewWidth: CGFloat = 560
    #endif

    private var backgroundURL: URL? {
        session.client?.posterURL(for: book.cover, width: 600)
    }

    /// "4 hr 12 min left", or the whole length before it's started.
    private var timeText: String? {
        guard book.duration > 0 else { return nil }
        if book.progress > 0, !book.isFinished {
            let left = book.duration * (1 - book.progress)
            return MusicFormat.length(ticks: Int64(left * 10_000_000)).map { "\($0) left" }
        }
        return book.lengthText
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The cover, blurred and darkened, as the backdrop.
            RemoteImage(url: backgroundURL, contentMode: .fill) { Color.black }
                .blur(radius: 60)
                .overlay(Color.black.opacity(0.35))
                .extendsUnderSidebar()
            LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.9)], startPoint: UnitPoint(x: 0.5, y: 0.35), endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .leading, endPoint: .center)

            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 48))
            layout {
                AudiobookCover(book: book, size: stacked ? Self.stackedCoverSize : Self.coverSize, width: 900)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                VStack(alignment: .leading, spacing: 16) {
                    if let series = book.series {
                        Text([series, book.seriesIndex.map { "Book \($0)" }].compactMap { $0 }.joined(separator: " · ").uppercased())
                            .font(.headline.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Text(book.title)
                        .font(.system(size: Self.titleSize, weight: .bold))
                        .lineLimit(2)
                    if let author = book.author {
                        Text(author)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if book.progress > 0, !book.isFinished {
                        ProgressBar(progress: book.progress)
                            .frame(maxWidth: 360)
                            .frame(height: 6)
                    }
                    if let overview = book.overview {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .frame(maxWidth: Self.overviewWidth, alignment: .leading)
                    }
                    HStack(spacing: 14) {
                        Image(systemName: "play.fill")
                        Text(book.resumePoint != nil ? "Resume" : "Listen")
                        if let timeText {
                            Text("·  \(timeText)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(.white.opacity(isFocused ? 1 : 0.9), in: Capsule())
                    .foregroundStyle(.black)
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.bottom, HeroCard.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .combine)
    }
}

struct AudiobookLockup: View {
    let book: Audiobook
    var size: CGFloat = Lockup.squareWidth
    /// Lets a page move focus here (by book id), e.g. down from the hero.
    var focus: FocusState<String?>.Binding? = nil

    private var subtitle: String? {
        if let index = book.seriesIndex, let series = book.series {
            return "\(series) \(index)"
        }
        return book.author
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: book) {
                AudiobookCover(book: book, size: size, width: 500)
                    .overlay(alignment: .bottom) {
                        if book.progress > 0, !book.isFinished {
                            ProgressBar(progress: book.progress)
                                .frame(height: 5)
                                .padding(10)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if book.isFinished {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(8)
                        }
                    }
            }
            .cardButtonStyle()
            .optionallyFocused(focus, equals: book.id)
            .keyboardTarget(opening: book)
            .accessibilityLabel([book.title, book.author].compactMap { $0 }.joined(separator: ", "))

            Text(book.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: size, alignment: .leading)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: size, alignment: .leading)
            }
        }
    }
}

/// A book's cover, square.
struct AudiobookCover: View {
    let book: Audiobook
    let size: CGFloat
    var width = 800

    @Environment(AppSession.self) private var session

    private var url: URL? {
        #if os(iOS)
        // A downloaded book's cover shows offline too.
        if let saved = AudiobookDownloads.shared.coverURL(for: book.id) { return saved }
        #endif
        return session.client?.posterURL(for: book.cover, width: width)
    }

    var body: some View {
        RemoteImage(url: url, systemImage: "book.closed.fill")
            .frame(width: size, height: size)
    }
}

/// Authors or series: the first book's cover, the name and how many books.
struct AudiobookShelfGrid: View {
    let shelves: [AudiobookShelf]

    private let columns = [GridItem(.adaptive(minimum: Lockup.squareWidth, maximum: Lockup.squareWidth), spacing: Lockup.gridSpacing, alignment: .top)]

    var body: some View {
        if shelves.isEmpty {
            MessageView(systemImage: "books.vertical", title: "Nothing here yet")
                .frame(height: Lockup.emptyStateHeight)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Lockup.gridRowSpacing) {
                ForEach(shelves) { shelf in
                    AudiobookShelfLockup(shelf: shelf)
                }
            }
            .padding(.horizontal, Lockup.screenPadding)
            .padding(.vertical, 20)
            .tvFocusSection()
        }
    }
}

struct AudiobookShelfLockup: View {
    let shelf: AudiobookShelf
    var size: CGFloat = Lockup.squareWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: shelf) {
                ZStack {
                    // A second cover peeking out behind, for a stack of books.
                    if shelf.books.count > 1 {
                        AudiobookCover(book: shelf.books[1], size: size * 0.9, width: 400)
                            .opacity(0.5)
                            .offset(x: size * 0.05, y: -size * 0.05)
                    }
                    AudiobookCover(book: shelf.books[0], size: size * 0.9, width: 500)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                        .offset(x: -size * 0.03, y: size * 0.03)
                }
                .frame(width: size, height: size)
            }
            .cardButtonStyle()
            .keyboardTarget(opening: shelf)
            .accessibilityLabel("\(shelf.name), \(shelf.books.count) books")

            Text(shelf.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: size, alignment: .leading)
            Text("\(shelf.books.count) book\(shelf.books.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: size, alignment: .leading)
        }
    }
}

/// An author's books, or a series in order.
struct AudiobookShelfView: View {
    let shelf: AudiobookShelf

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(shelf.name)
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.top, Lockup.pageTopPadding)
                Text(shelf.kind == .series ? "Series · \(shelf.books.count) books" : "\(shelf.books.count) book\(shelf.books.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Lockup.screenPadding)
                AudiobookGrid(books: shelf.books)
            }
            .padding(.bottom, Lockup.pageBottomPadding)
        }
        .scrollClipDisabled()
    }
}

// MARK: - A book's page

struct AudiobookView: View {
    @State private var book: Audiobook

    @Environment(AppSession.self) private var session
    #if os(iOS)
    @AppStorage(AppSettings.downloadsEnabledKey) private var downloadsEnabled = true
    #endif

    init(book: Audiobook) {
        #if os(iOS)
        _book = State(initialValue: AudiobookDownloads.shared.withLocalProgress(book))
        #else
        _book = State(initialValue: book)
        #endif
    }

    private var player: AudiobookPlayer { session.audiobooks }
    private var isLoaded: Bool { player.book?.id == book.id }

    /// How far in, from the player while it has this book.
    private var elapsed: TimeInterval {
        if isLoaded { return player.bookElapsed }
        guard let point = book.resumePoint else { return book.isFinished ? book.duration : 0 }
        return book.offset(ofPart: point.part) + point.seconds
    }

    private var infoLine: String {
        var parts: [String] = []
        if let index = book.seriesIndex, let series = book.series {
            parts.append("Book \(index) of \(series)")
        } else if let series = book.series {
            parts.append(series)
        }
        if let year = book.year { parts.append(String(year)) }
        if let length = book.lengthText { parts.append(length) }
        return parts.joined(separator: " · ")
    }

    private var progressText: String? {
        if book.isFinished, !isLoaded { return "Finished" }
        guard elapsed > 0, book.duration > 0 else { return nil }
        let left = MusicFormat.length(ticks: Int64(max(book.duration - elapsed, 0) * 10_000_000)) ?? ""
        return "\(left) left"
    }

    var body: some View {
        ZStack {
            RemoteImage(url: session.client?.posterURL(for: book.cover, width: 400)) { Color(white: 0.08) }
                .blur(radius: 80)
                .overlay(Color.black.opacity(0.72))
                .ignoresSafeArea()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    header
                        .padding(.horizontal, MusicMetrics.pagePadding)
                        .padding(.top, MusicMetrics.pageTopPadding)
                        .tvFocusSection()

                    if !book.chapters.isEmpty {
                        chapterList
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        }
        .task(id: book.id) { await refresh() }
        // Where listening got to, once the player lets go of the book.
        .onChange(of: isLoaded) { _, loaded in
            if !loaded { Task { await refresh() } }
        }
    }

    private var header: some View {
        MusicPageHeader {
            AudiobookCover(book: book, size: MusicMetrics.pageArtwork)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        } details: {
            VStack(alignment: .leading, spacing: 16) {
                Text(book.title)
                    .font(.system(size: MusicMetrics.pageTitleSize, weight: .bold))
                    .lineLimit(2)
                if let author = book.author {
                    Text(author)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(infoLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let progressText {
                    HStack(spacing: 12) {
                        ProgressBar(progress: book.duration > 0 ? elapsed / book.duration : 0)
                            .frame(width: 200, height: 5)
                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let overview = book.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: 1000, alignment: .leading)
                }

                ActionRows {
                    ActionButton(title: playTitle, systemImage: isLoaded && player.isPlaying ? "pause.fill" : "play.fill", prominent: true) {
                        if isLoaded {
                            player.togglePlayPause()
                            player.isNowPlayingPresented = true
                        } else {
                            play(from: nil)
                        }
                    }
                } second: {
                    if book.resumePoint != nil || isLoaded {
                        ActionButton(title: "From the Beginning", systemImage: "backward.end.fill") {
                            play(from: book.chapters.first ?? AudiobookChapter(id: 0, part: 0, start: 0, title: ""))
                        }
                    }
                    #if os(iOS)
                    if downloadsEnabled {
                        AudiobookDownloadButton(book: book)
                    }
                    #endif
                }
                .padding(.top, 8)
            }
        }
    }

    private var playTitle: String {
        if isLoaded { return player.isPlaying ? "Pause" : "Resume" }
        return book.resumePoint != nil ? "Resume" : "Play"
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chapters")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 8)
            ForEach(book.chapters) { chapter in
                AudiobookChapterRow(
                    chapter: chapter,
                    startText: MusicFormat.clock(book.offset(ofPart: chapter.part) + chapter.start),
                    isCurrent: isLoaded && player.currentChapter?.id == chapter.id
                ) {
                    play(from: chapter)
                }
            }
        }
        .padding(.horizontal, MusicMetrics.pagePadding)
        .tvFocusSection()
    }

    private func play(from chapter: AudiobookChapter?) {
        guard let client = session.client else { return }
        player.play(book, from: chapter, client: client)
    }

    /// The parts' listening state, fresh from the server.
    private func refresh() async {
        guard let client = session.client,
              let fresh = try? await client.items([
                  "ids": book.parts.map(\.id).joined(separator: ","),
                  "fields": AudiobookLibrary.fields,
              ]).items, !fresh.isEmpty else { return }
        #if os(iOS)
        book = AudiobookDownloads.shared.withLocalProgress(book.updating(fresh))
        #else
        book = book.updating(fresh)
        #endif
    }
}

struct AudiobookChapterRow: View {
    let chapter: AudiobookChapter
    let startText: String
    var isCurrent = false
    var action: () -> Void

    #if os(tvOS)
    private static let padding = EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
    private static let cornerRadius: CGFloat = 12
    private static let iconWidth: CGFloat = 40
    #else
    private static let padding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    private static let cornerRadius: CGFloat = 10
    private static let iconWidth: CGFloat = 24
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: Self.iconWidth)
                Text(chapter.title)
                    .font(.callout.weight(isCurrent ? .semibold : .medium))
                    .lineLimit(1)
                Spacer()
                Text(startText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(Color.white.opacity(isCurrent ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chapter.title), starts at \(startText)")
        .keyboardTarget(action: action)
    }
}

#if os(iOS)
/// Download, its progress, or Downloaded with a way to remove it.
struct AudiobookDownloadButton: View {
    let book: Audiobook

    @Environment(AppSession.self) private var session
    @State private var errorMessage: String?
    @State private var confirmRemove = false

    private let downloads = AudiobookDownloads.shared

    var body: some View {
        let record = downloads.record(for: book.id)
        Group {
            switch record?.state {
            case nil:
                ActionButton(title: "Download", systemImage: "arrow.down.circle") { start() }
            case .downloading:
                ActionButton(title: "Downloading \(Int((record.map(downloads.progress) ?? 0) * 100))%", systemImage: "stop.circle") {
                    downloads.remove(book.id)
                }
            case .finished:
                ActionButton(title: "Downloaded", systemImage: "checkmark.circle.fill") { confirmRemove = true }
            case .failed:
                ActionButton(title: "Retry Download", systemImage: "exclamationmark.arrow.circlepath") { start() }
            }
        }
        .confirmationDialog("Remove this download?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { downloads.remove(book.id) }
        } message: {
            Text("This frees \(DownloadStore.format(record?.bytesOnDisk ?? 0)). The book can still be played from the server.")
        }
        .alert("Couldn't Download", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func start() {
        guard let client = session.client else { return }
        Task {
            do {
                try await downloads.start(book, client: client, canDownload: session.canDownload)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif

// MARK: - Player

/// The book playing, on the Audiobooks tab; opens the full player.
struct AudiobookBar: View {
    @Environment(AppSession.self) private var session

    #if os(tvOS)
    private static let spacing: CGFloat = 20
    private static let artworkSize: CGFloat = 80
    private static let padding = EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
    #else
    private static let spacing: CGFloat = 12
    private static let artworkSize: CGFloat = 48
    private static let padding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 16)
    #endif

    var body: some View {
        let player = session.audiobooks
        if let book = player.book {
            Button {
                player.isNowPlayingPresented = true
            } label: {
                HStack(spacing: Self.spacing) {
                    AudiobookCover(book: book, size: Self.artworkSize, width: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text([player.currentChapter?.title, book.author].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                    Image(systemName: "chevron.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(Self.padding)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Stop", systemImage: "stop.fill") { session.stopAudio() }
            }
            .keyboardTarget { player.isNowPlayingPresented = true }
            .accessibilityLabel("Now playing: \(book.title)")
            .tvFocusSection()
        }
    }
}

/// The speed button and its menu. Its own view so it redraws only when the
/// speed changes: inside the player, which redraws every half second as
/// the time moves, the open menu was rebuilt each time and flickered.
struct AudiobookSpeedMenu: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let player = session.audiobooks
        Menu {
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(AudiobookRates.choices, id: \.self) { rate in
                    Text(AudiobookRates.label(rate)).tag(rate)
                }
            }
        } label: {
            Text(AudiobookRates.label(player.rate))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                #if os(tvOS)
                .frame(minWidth: 76, minHeight: 76)
                #else
                .frame(minWidth: 46, minHeight: 46)
                #endif
        }
        #if !os(tvOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .background(Capsule().fill(player.rate == 1 ? Color(white: 0.3) : Color.accentColor))
        .foregroundStyle(.white)
        #endif
        .accessibilityLabel("Speed, \(AudiobookRates.label(player.rate))")
    }
}

/// The full-screen audiobook player: cover, chapter progress, skips, speed
/// and the chapter list.
struct AudiobookNowPlayingView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.coverDismiss) private var dismiss
    @FocusState private var focusedControl: String?
    @State private var showChapters = false

    private var player: AudiobookPlayer { session.audiobooks }

    var body: some View {
        ZStack {
            RemoteImage(url: player.book.flatMap { session.client?.posterURL(for: $0.cover, width: 400) }) { Color(white: 0.06) }
                .blur(radius: 100, opaque: true)
                .overlay(Color.black.opacity(0.7))
                .ignoresSafeArea()

            if let book = player.book {
                #if os(tvOS)
                // The cover on top, everything else under it; the chapter
                // list, when open, beside that column.
                HStack(alignment: .center, spacing: 80) {
                    VStack(spacing: 28) {
                        artwork(book, size: 440)
                        info(book, titleSize: 44, centered: true)
                        progress
                        controls
                        errorText
                    }
                    .frame(width: 900)
                    .tvFocusSection()

                    if showChapters {
                        chapterList(book)
                            .frame(width: 760, height: 820)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.3), value: showChapters)
                #else
                phoneLayout(book)
                #endif
            } else {
                MessageView(systemImage: "book.closed", title: "Nothing playing")
            }
        }
        #if !os(tvOS)
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.white)
            .accessibilityLabel("Close")
            .padding(Lockup.screenPadding)
        }
        #endif
        #if !os(tvOS)
        // Stop ends it: the player closes and the bar goes away.
        .overlay(alignment: .topTrailing) {
            Button {
                session.stopAudio()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.white)
            .accessibilityLabel("Stop")
            .padding(Lockup.screenPadding)
        }
        #endif
        .tvPlayPauseCommand { player.togglePlayPause() }
        .onChange(of: player.book == nil) { _, empty in
            if empty { dismiss() }
        }
        .onAppear { focusedControl = "play" }
    }

    private func artwork(_ book: Audiobook, size: CGFloat) -> some View {
        AudiobookCover(book: book, size: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 300 ? 20 : 14))
            .shadow(color: .black.opacity(0.6), radius: size > 300 ? 40 : 20, y: size > 300 ? 16 : 8)
    }

    private func info(_ book: Audiobook, titleSize: CGFloat, centered: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
            Text(book.title)
                .font(.system(size: titleSize, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(centered ? .center : .leading)
            if let author = book.author {
                Text(author)
                    .font(.title3.weight(.semibold))
            }
            if let chapter = player.currentChapter {
                Text(chapter.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The chapter's progress, and how much of the book is left.
    private var progress: some View {
        let bounds = player.chapterBounds
        let length = bounds.end - bounds.start
        let into = min(max(player.currentTime - bounds.start, 0), length)
        let bookLeft = max(player.bookDuration - player.bookElapsed, 0) / Double(player.rate)
        return VStack(spacing: 8) {
            ProgressBar(progress: length > 0 ? into / length : 0)
            HStack {
                Text(MusicFormat.clock(into))
                Spacer()
                Text((MusicFormat.length(ticks: Int64(bookLeft * 10_000_000)) ?? "0 min") + " left")
                Spacer()
                Text("-" + MusicFormat.clock(max(length - into, 0)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = player.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// The skips and chapter buttons, then speed and the chapter list: in
    /// one row on a TV, a second row elsewhere so a phone fits them.
    @ViewBuilder
    private var controls: some View {
        #if os(tvOS)
        HStack(spacing: PlayerControl.spacing) {
            transport
            extras
        }
        #else
        VStack(spacing: 14) {
            HStack(spacing: PlayerControl.spacing) { transport }
            HStack(spacing: 16) { extras }
        }
        #endif
    }

    @ViewBuilder
    private var transport: some View {
        PlayerControl(systemImage: "backward.end.fill", label: "Previous Chapter") {
            player.previousChapter()
        }
        .focused($focusedControl, equals: "previous")
        PlayerControl(systemImage: "gobackward.15", label: "Back 15 Seconds") {
            player.skip(by: -AudiobookPlayer.skipBackSeconds)
        }
        .focused($focusedControl, equals: "back")
        PlayerControl(systemImage: player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pause" : "Play", prominent: true) {
            player.togglePlayPause()
        }
        .focused($focusedControl, equals: "play")
        PlayerControl(systemImage: "goforward.30", label: "Ahead 30 Seconds") {
            player.skip(by: AudiobookPlayer.skipForwardSeconds)
        }
        .focused($focusedControl, equals: "forward")
        PlayerControl(systemImage: "forward.end.fill", label: "Next Chapter") {
            player.nextChapter()
        }
        .focused($focusedControl, equals: "next")
    }

    @ViewBuilder
    private var extras: some View {
        AudiobookSpeedMenu()
            .focused($focusedControl, equals: "speed")
        if !(player.book?.chapters.isEmpty ?? true) {
            PlayerControl(systemImage: "list.bullet", label: "Chapters", active: showChapters) {
                showChapters.toggle()
            }
            .focused($focusedControl, equals: "chapters")
        }
        #if os(tvOS)
        // No close button on the TV: Stop ends it (its place saved), and
        // Back just hides it.
        PlayerControl(systemImage: "stop.fill", label: "Stop") {
            session.stopAudio()
        }
        .focused($focusedControl, equals: "stop")
        #endif
    }

    private func chapterList(_ book: Audiobook) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(book.chapters) { chapter in
                        AudiobookChapterRow(
                            chapter: chapter,
                            startText: MusicFormat.clock(book.offset(ofPart: chapter.part) + chapter.start),
                            isCurrent: player.currentChapter?.id == chapter.id
                        ) {
                            player.jump(to: chapter)
                        }
                        .id(chapter.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                if let current = player.currentChapter?.id {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
        }
        .tvFocusSection()
    }

    #if !os(tvOS)
    /// The cover on top with everything centered under it, unless there
    /// isn't the height (a phone on its side): then the cover beside the
    /// controls. The chapters go below.
    private func phoneLayout(_ book: Audiobook) -> some View {
        GeometryReader { proxy in
            let stacked = proxy.size.height >= 560
            // Clamped: the first layout pass can be zero-sized.
            let coverSize = max(min(proxy.size.width - 48, proxy.size.height * 0.42, 420), 0)
            ScrollView(.vertical) {
                VStack(spacing: 20) {
                    if stacked {
                        VStack(spacing: 20) {
                            if showChapters {
                                HStack(spacing: 16) {
                                    artwork(book, size: 96)
                                    info(book, titleSize: 20)
                                    Spacer(minLength: 0)
                                }
                            } else {
                                artwork(book, size: coverSize)
                                info(book, titleSize: 24, centered: true)
                            }
                            progress
                            controls
                            errorText
                        }
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 24)
                    } else {
                        HStack(alignment: .center, spacing: 28) {
                            artwork(book, size: max(min(proxy.size.height - 60, showChapters ? 140 : 260), 0))
                            VStack(alignment: .leading, spacing: 14) {
                                info(book, titleSize: 22)
                                progress
                                controls
                                errorText
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                    if showChapters {
                        chapterList(book)
                            .frame(height: stacked ? max(260, proxy.size.height - 330) : 260)
                            .frame(maxWidth: 700)
                            .padding(.horizontal, 24)
                    }
                }
                .padding(.top, stacked ? 68 : 20)
                .padding(.bottom, 24)
                .frame(width: proxy.size.width)
            }
            .scrollIndicators(.hidden)
            .animation(.easeInOut(duration: 0.3), value: showChapters)
        }
    }
    #endif
}
