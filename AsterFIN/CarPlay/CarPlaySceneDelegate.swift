//
//  CarPlaySceneDelegate.swift
//  AsterFIN
//
//  AsterFIN's music and audiobooks in CarPlay: a Music tab (recent, albums,
//  artists, playlists, each opening a list of tracks), a Listening tab
//  (audiobooks in progress, then recently added) and a Browse tab (authors,
//  series and all books); a book opens to its chapters. Playback then shows
//  the system Now Playing screen. CarPlay audio apps are limited to list and
//  grid templates, and the car decides where tabs go (a sidebar on a wide
//  screen). Playback itself is the phone's music or audiobook player, which
//  already feeds Now Playing and answers the car's controls.
//

#if canImport(CarPlay)
import CarPlay
import CoreMedia
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var session: AppSession { AppSession.shared }
    /// The server's audiobooks, loaded when the Audiobooks tab is opened.
    private let books = AudiobookLibrary()
    private var booksLoad: Task<Void, Never>?
    /// Whether Now Playing is set up for music (rather than a book).
    private var isShowingMusic = false
    private var observingNowPlaying = false
    /// Favorites changed from the car, by song id, until the server's copy
    /// of the song catches up.
    private var favorites: [String: Bool] = [:]

    /// iOS 26.4's list header (its buttons go in a wide screen's top bar) and
    /// playback progress on covers. With these on and Music's cover row, the
    /// car's template host (CarPlayTemplateUIHost, on an iOS 27.0 pre-release)
    /// once looped in layout and was killed by the watchdog; turn off to
    /// leave them out.
    private static let usesNewestTemplates = true

    /// Music's row of recently played album covers. Kept apart from the rest
    /// so it can be switched off alone (CarPlay Simulator on the iOS 27
    /// pre-release has frozen with it).
    private static let usesMusicCoverRow = false

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(rootTemplate(), animated: false, completion: nil)
        if session.music.current != nil {
            setUpNowPlaying(music: true)
        } else if session.audiobooks.book != nil {
            setUpNowPlaying(music: false)
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    // MARK: Tabs

    private func rootTemplate() -> CPTemplate {
        guard session.jellyfin != nil else {
            let template = CPListTemplate(title: "Aster", sections: [])
            template.emptyViewTitleVariants = ["Sign in on your iPhone"]
            template.emptyViewSubtitleVariants = ["Open Aster on your iPhone and sign in to your Jellyfin server."]
            return template
        }
        // Two tabs: Music and Audiobooks. The Audiobooks tab goes in once the
        // server's book libraries are known, which can be after the car
        // connects.
        let music = musicTab()
        let audiobooks = audiobookTab()
        let tabBar = CPTabBarTemplate(templates: session.bookLibraries.isEmpty ? [music] : [music, audiobooks])
        if session.bookLibraries.isEmpty {
            Task { [weak self, weak tabBar] in
                await self?.findBookLibraries()
                guard let self, let tabBar, !self.session.bookLibraries.isEmpty else { return }
                tabBar.updateTemplates([music, audiobooks])
            }
        }
        return tabBar
    }

    /// A tab whose list fills in once its items arrive from the server.
    private func tab(_ title: String, systemImage: String, load: @escaping () async -> [CPListSection]) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabTitle = title
        template.tabImage = UIImage(systemName: systemImage)
        template.emptyViewTitleVariants = ["Loading…"]
        Task {
            let sections = await load()
            template.emptyViewTitleVariants = ["Nothing here yet"]
            template.updateSections(sections)
        }
        return template
    }

    /// The most a list may show; CarPlay caps lists for safety.
    private var limit: Int { CPListTemplate.maximumItemCount }

    private func recentSections() async -> [CPListSection] {
        guard let client = session.jellyfin else { return [] }
        async let played = client.items([
            "includeItemTypes": "Audio",
            "recursive": "true",
            "filters": "IsPlayed",
            "sortBy": "DatePlayed",
            "sortOrder": "Descending",
            "limit": "20",
        ])
        async let added = client.latest(parentId: nil, limit: 20, includeTypes: "MusicAlbum")
        let songs = (try? await played.items) ?? []
        let albums = (try? await added) ?? []
        var sections: [CPListSection] = []
        if !songs.isEmpty {
            sections.append(CPListSection(items: trackItems(songs), header: "Recently Played", sectionIndexTitle: nil))
        }
        if !albums.isEmpty {
            sections.append(CPListSection(items: albums.map(albumItem), header: "Recently Added", sectionIndexTitle: nil))
        }
        return sections
    }

    private func albumSections() async -> [CPListSection] {
        guard let client = session.jellyfin else { return [] }
        let albums = (try? await client.items([
            "includeItemTypes": "MusicAlbum",
            "recursive": "true",
            "sortBy": "SortName",
            "limit": String(limit),
        ]).items) ?? []
        return [CPListSection(items: albums.map(albumItem))]
    }

    private func artistSections() async -> [CPListSection] {
        guard let client = session.jellyfin else { return [] }
        let artists = (try? await client.albumArtists(limit: limit).items) ?? []
        return artistGrid(artists)
    }

    /// Artists as a grid of round pictures with their names, a section for
    /// each first letter (the car's index jumps between them). Each picture
    /// starts as a placeholder and is swapped in as it arrives, so the grid
    /// shows at once.
    private func artistGrid(_ artists: [BaseItem]) -> [CPListSection] {
        let size = CPListImageRowItemImageGridElement.maximumImageSize
        let scale = interfaceController?.carTraitCollection.displayScale ?? 2
        let placeholder = placeholderImage("person.fill", size: size, scale: scale)
        let groups = Dictionary(grouping: artists) { artist in
            artist.displayTitle.first.map { $0.isLetter ? String($0).uppercased() : "#" } ?? "#"
        }
        var loads: [(BaseItem, CPListImageRowItemImageGridElement)] = []
        let sections = groups.keys.sorted { a, b in a == "#" ? false : b == "#" ? true : a < b }.map { letter -> CPListSection in
            let group = groups[letter] ?? []
            let elements = group.map { artist in
                let element = CPListImageRowItemImageGridElement(image: placeholder, imageShape: .circular, title: artist.displayTitle, accessorySymbolName: nil)
                loads.append((artist, element))
                return element
            }
            let row = CPListImageRowItem(text: nil, imageGridElements: elements, allowsMultipleLines: true)
            row.listImageRowHandler = { [weak self] _, index, completion in
                if group.indices.contains(index) { self?.openArtist(group[index]) }
                completion()
            }
            return CPListSection(items: [row], header: letter, sectionIndexTitle: letter)
        }
        if let client = session.jellyfin {
            Task {
                for (artist, element) in loads {
                    guard let url = client.posterURL(for: artist, width: 200),
                          let image = await ImageStore.shared.image(for: url, client: client) else { continue }
                    element.image = image
                }
            }
        }
        return sections
    }

    /// A grey square with a symbol, for a picture that hasn't come yet. Drawn
    /// in standard range: the renderer's default (extended range, wide
    /// colour) isn't something the car's display process can decode.
    private func placeholderImage(_ systemName: String, size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.systemGray4.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            let symbol = UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: size.height * 0.45))?
                .withTintColor(.systemGray, renderingMode: .alwaysOriginal)
            if let symbol {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
            }
        }
    }

    private func playlistSections() async -> [CPListSection] {
        guard let client = session.jellyfin else { return [] }
        let playlists = (try? await client.playlists(mediaType: "Audio")) ?? []
        return [CPListSection(items: playlists.map(albumItem))]
    }

    /// Music: a row of the albums played last, then the menu, filled in with
    /// one update once the covers are in, as the Audiobooks tab is.
    private func musicTab() -> CPListTemplate {
        guard Self.usesMusicCoverRow else {
            let template = CPListTemplate(title: "Music", sections: musicMenu())
            template.tabTitle = "Music"
            template.tabImage = UIImage(systemName: "music.note")
            return template
        }
        let template = CPListTemplate(title: "Music", sections: [])
        template.tabTitle = "Music"
        template.tabImage = UIImage(systemName: "music.note")
        template.emptyViewTitleVariants = ["Loading…"]
        Task { [weak self, weak template] in
            guard let self, let template else { return }
            var sections = self.musicMenu()
            if let row = await self.recentAlbumsRow() {
                sections.insert(CPListSection(items: [row], header: "Recently Played", sectionIndexTitle: nil), at: 0)
            }
            template.updateSections(sections)
        }
        return template
    }

    /// The albums of the songs played last, as covers with the album and
    /// artist beneath; a tap opens the album.
    private func recentAlbumsRow() async -> CPListImageRowItem? {
        guard let client = session.jellyfin else { return nil }
        let songs = (try? await client.items([
            "includeItemTypes": "Audio",
            "recursive": "true",
            "filters": "IsPlayed",
            "sortBy": "DatePlayed",
            "sortOrder": "Descending",
            "limit": "40",
        ]).items) ?? []
        var seen = Set<String>()
        let picks = Array(songs.filter { song in song.albumId.map { seen.insert($0).inserted } ?? false }.prefix(8))
        // Built as Audiobooks' Continue Listening row is: covers loaded first
        // and handed over as the server sent them.
        var picked: [BaseItem] = []
        var elements: [CPListImageRowItemRowElement] = []
        for song in picks {
            guard let url = client.posterURL(for: song, width: 400),
                  let image = await ImageStore.shared.image(for: url, client: client) else { continue }
            elements.append(CPListImageRowItemRowElement(image: image, title: song.album ?? song.displayTitle, subtitle: song.albumArtist ?? song.artists?.first))
            picked.append(song)
        }
        guard !elements.isEmpty else { return nil }
        let row = CPListImageRowItem(text: nil, elements: elements, allowsMultipleLines: false)
        row.listImageRowHandler = { [weak self] _, index, completion in
            if picked.indices.contains(index), let albumId = picked[index].albumId {
                self?.openTracks(id: albumId, title: picked[index].album ?? picked[index].displayTitle, isPlaylist: false)
            }
            completion()
        }
        return row
    }

    /// Music's menu: each row opens its list.
    private func musicMenu() -> [CPListSection] {
        [CPListSection(items: [
            menuRow("Recent", systemImage: "clock") { [weak self] in await self?.recentSections() ?? [] },
            menuRow("Albums", systemImage: "square.stack") { [weak self] in await self?.albumSections() ?? [] },
            menuRow("Artists", systemImage: "music.mic") { [weak self] in await self?.artistSections() ?? [] },
            menuRow("Playlists", systemImage: "music.note.list") { [weak self] in await self?.playlistSections() ?? [] },
        ])]
    }

    /// The phone's main screen is what finds the server's libraries, and with
    /// the phone locked it may never open: ask the server here.
    private func findBookLibraries() async {
        guard session.bookLibraries.isEmpty, let views = try? await session.client?.libraries() else { return }
        session.noteLibraries(views)
    }

    /// The books, loaded once however many ask while it's under way.
    private func loadBooks() async {
        guard let client = session.jellyfin else { return }
        await findBookLibraries()
        if booksLoad == nil {
            let libraries = session.bookLibraries
            booksLoad = Task { await books.load(client: client, libraries: libraries) }
        }
        await booksLoad?.value
        booksLoad = nil
    }

    /// The Audiobooks tab: a row of the books in progress, then rows to
    /// browse. On a car that shows list headers (iOS 26.4) the header's
    /// buttons also go to the same places, and a wide screen puts them in
    /// its top bar.
    private func audiobookTab() -> CPListTemplate {
        let template = CPListTemplate(title: "Audiobooks", sections: [])
        template.tabTitle = "Audiobooks"
        template.tabImage = UIImage(systemName: "headphones")
        template.emptyViewTitleVariants = ["Loading…"]
        Task { [weak self, weak template] in
            guard let self, let template else { return }
            await self.loadBooks()
            template.emptyViewTitleVariants = ["No audiobooks yet"]
            // The book being listened to goes in the header, when the car
            // shows one, and so isn't repeated in the row beneath.
            var featured: Audiobook?
            if Self.usesNewestTemplates, #available(iOS 26.4, *), let (header, book) = await self.listeningHeader() {
                template.listHeader = header
                featured = book
            }
            template.updateSections(await self.audiobookSections(excluding: featured))
        }
        return template
    }

    private func audiobookSections(excluding featured: Audiobook? = nil) async -> [CPListSection] {
        guard !books.books.isEmpty else { return [] }
        var sections: [CPListSection] = []
        let continuing = Array(books.continueListening.filter { $0.id != featured?.id }.prefix(8))
        if #available(iOS 26.4, *), let row = await continueRow(continuing) {
            sections.append(CPListSection(items: [row]))
        } else if !continuing.isEmpty {
            // Without covers in a row, the books themselves.
            sections.append(CPListSection(items: continuing.prefix(4).map(bookItem), header: "Continue Listening", sectionIndexTitle: nil))
        }
        let rows = destinations().map { destination in
            menuRow(destination.title, systemImage: destination.systemImage) { destination.load() }
        }
        sections.append(CPListSection(items: rows))
        return sections
    }

    /// A place to go from the Audiobooks tab.
    private struct Destination {
        let title: String
        let systemImage: String
        let load: () -> [CPListSection]
    }

    private func destinations() -> [Destination] {
        var all: [Destination] = []
        if !books.continueListening.isEmpty {
            all.append(Destination(title: "Continue Listening", systemImage: "play.circle") { [weak self] in
                guard let self else { return [] }
                return [CPListSection(items: self.books.continueListening.prefix(self.limit).map(self.bookItem))]
            })
        }
        if !books.series.isEmpty {
            all.append(Destination(title: "Series", systemImage: "rectangle.stack") { [weak self] in self?.shelfSections(\.series) ?? [] })
        }
        all.append(Destination(title: "Recently Added", systemImage: "book") { [weak self] in
            guard let self else { return [] }
            return [CPListSection(items: self.books.recentlyAdded.map(self.bookDetailItem))]
        })
        if !books.authors.isEmpty {
            all.append(Destination(title: "Authors", systemImage: "person.2") { [weak self] in self?.shelfSections(\.authors) ?? [] })
        }
        all.append(Destination(title: "All Books", systemImage: "books.vertical") { [weak self] in
            guard let self else { return [] }
            return [CPListSection(items: self.books.books.prefix(self.limit).map(self.bookDetailItem))]
        })
        return all
    }

    /// The cover of a book, sized for the car.
    private func cover(of book: Audiobook, width: Int = 400) async -> UIImage? {
        guard let client = session.jellyfin, let url = client.posterURL(for: book.cover, width: width) else { return nil }
        return await ImageStore.shared.image(for: url, client: client)
    }

    /// Books in progress as one row of covers with titles and progress; a
    /// tap plays the book.
    @available(iOS 26.4, *)
    private func continueRow(_ continuing: [Audiobook]) async -> CPListImageRowItem? {
        var picked: [Audiobook] = []
        var elements: [CPListImageRowItemRowElement] = []
        for book in continuing {
            guard let image = await cover(of: book) else { continue }
            // How far in goes in the subtitle, unless the car draws it.
            let percent = Int((book.progress * 100).rounded())
            let subtitle = Self.usesNewestTemplates ? book.author : [book.author, percent > 0 ? "\(percent)%" : nil].compactMap { $0 }.joined(separator: " · ")
            let element = CPListImageRowItemRowElement(image: image, title: book.title, subtitle: subtitle)
            if Self.usesNewestTemplates {
                element.playbackConfiguration = CPPlaybackConfiguration(
                    preferredPresentation: .audio,
                    playbackAction: .play,
                    elapsedTime: CMTime(seconds: book.duration * book.progress, preferredTimescale: 1),
                    duration: CMTime(seconds: book.duration, preferredTimescale: 1)
                )
            }
            elements.append(element)
            picked.append(book)
        }
        guard !elements.isEmpty else { return nil }
        let row = CPListImageRowItem(text: nil, elements: elements, allowsMultipleLines: false)
        row.listImageRowHandler = { [weak self] _, index, completion in
            if picked.indices.contains(index) { self?.play(picked[index]) }
            completion()
        }
        return row
    }

    /// A header for the book being listened to: its cover with how far in,
    /// its title and author, and buttons to resume it and to open its
    /// chapters (the header's picture itself can't be tapped; CarPlay's
    /// header buttons are pictures, with no titles). None when no book is
    /// under way.
    @available(iOS 26.4, *)
    private func listeningHeader() async -> (CPListTemplateDetailsHeader, Audiobook)? {
        guard let book = books.continueListening.first, let image = await cover(of: book) else { return nil }
        var buttons: [CPButton] = []
        if let icon = UIImage(systemName: "play.fill") {
            buttons.append(CPButton(image: icon) { [weak self] _ in self?.play(book) })
        }
        if let icon = UIImage(systemName: "list.bullet") {
            buttons.append(CPButton(image: icon) { [weak self] _ in self?.openBook(book) })
        }
        let left = Duration.seconds(book.duration * (1 - book.progress))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        let header = CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: image),
            title: book.title,
            subtitle: [book.author, "\(left) left"].compactMap { $0 }.joined(separator: " · "),
            actionButtons: buttons
        )
        header.playbackConfiguration = CPPlaybackConfiguration(
            preferredPresentation: .audio,
            playbackAction: .play,
            elapsedTime: CMTime(seconds: book.duration * book.progress, preferredTimescale: 1),
            duration: CMTime(seconds: book.duration, preferredTimescale: 1)
        )
        return (header, book)
    }

    /// Authors or series, each opening its books.
    private func shelfSections(_ shelves: KeyPath<AudiobookLibrary, [AudiobookShelf]>) -> [CPListSection] {
        let items = books[keyPath: shelves].prefix(limit).map { shelf -> CPListItem in
            let item = CPListItem(text: shelf.name, detailText: shelf.books.count == 1 ? "1 book" : "\(shelf.books.count) books")
            item.accessoryType = .disclosureIndicator
            if let cover = shelf.books.first?.cover { loadArtwork(for: cover, into: item) }
            item.handler = { [weak self] _, completion in
                self?.pushList(shelf.name) { [weak self] in
                    guard let self else { return [] }
                    return [CPListSection(items: shelf.books.prefix(self.limit).map(self.bookDetailItem))]
                }
                completion()
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    // MARK: Rows

    /// A row that opens a list loaded on demand.
    private func menuRow(_ title: String, systemImage: String, load: @escaping () async -> [CPListSection]) -> CPListItem {
        let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: systemImage))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.pushList(title, load: load)
            completion()
        }
        return item
    }

    /// A book opening its page, with where to start.
    private func bookDetailItem(_ book: Audiobook) -> CPListItem {
        let item = bookItem(book)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.openBook(book)
            completion()
        }
        return item
    }

    /// A book, playing from where listening left off.
    private func bookItem(_ book: Audiobook) -> CPListItem {
        let item = CPListItem(text: book.title, detailText: book.author)
        if book.progress > 0, !book.isFinished {
            item.playbackProgress = CGFloat(book.progress)
        }
        loadArtwork(for: book.cover, into: item)
        item.handler = { [weak self] _, completion in
            self?.play(book)
            completion()
        }
        return item
    }

    /// An album or playlist, opening its tracks.
    private func albumItem(_ album: BaseItem) -> CPListItem {
        let item = CPListItem(text: album.displayTitle, detailText: album.albumArtist ?? album.artists?.first)
        item.accessoryType = .disclosureIndicator
        loadArtwork(for: album, into: item)
        item.handler = { [weak self] _, completion in
            self?.openTracks(of: album)
            completion()
        }
        return item
    }

    /// Songs that play in order from the one chosen.
    private func trackItems(_ tracks: [BaseItem]) -> [CPListItem] {
        tracks.enumerated().map { index, track in
            let item = CPListItem(text: track.displayTitle, detailText: track.artists?.first ?? track.albumArtist)
            loadArtwork(for: track, into: item)
            item.handler = { [weak self] _, completion in
                self?.play(tracks, startingAt: index)
                completion()
            }
            return item
        }
    }

    private func shuffleItem(_ tracks: @escaping () async -> [BaseItem]) -> CPListItem {
        let item = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"))
        item.handler = { [weak self] _, completion in
            Task {
                let songs = await tracks()
                if !songs.isEmpty { self?.play(songs, startingAt: 0, shuffled: true) }
                completion()
            }
        }
        return item
    }

    private func loadArtwork(for item: BaseItem, into row: CPListItem) {
        guard let client = session.jellyfin, let url = client.posterURL(for: item, width: 200) else { return }
        Task {
            if let image = await ImageStore.shared.image(for: url, client: client) {
                row.setImage(image)
            }
        }
    }

    // MARK: Screens

    private func pushList(_ title: String, load: @escaping () async -> [CPListSection]) {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        Task {
            let sections = await load()
            template.emptyViewTitleVariants = ["Nothing here yet"]
            template.updateSections(sections)
        }
    }

    /// A book's page: play or resume, then its chapters to start from.
    private func openBook(_ book: Audiobook) {
        let started = book.progress > 0 && !book.isFinished
        let length = Duration.seconds(book.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        let start = CPListItem(text: started ? "Resume" : "Play", detailText: [book.author, length].compactMap { $0 }.joined(separator: " · "), image: UIImage(systemName: "play.fill"))
        start.handler = { [weak self] _, completion in
            self?.play(book)
            completion()
        }
        var sections = [CPListSection(items: [start])]
        let chapters = book.chapters
        if chapters.count > 1 {
            let items = chapters.prefix(limit - 1).map { chapter -> CPListItem in
                let at = book.offset(ofPart: chapter.part) + chapter.start
                let item = CPListItem(text: chapter.title, detailText: Duration.seconds(at).formatted(.time(pattern: .hourMinuteSecond)))
                item.handler = { [weak self] _, completion in
                    self?.play(book, from: chapter)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: items, header: "Chapters", sectionIndexTitle: nil))
        }
        let template = CPListTemplate(title: book.title, sections: sections)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func openTracks(of album: BaseItem) {
        openTracks(id: album.id, title: album.displayTitle, isPlaylist: album.kind == .playlist)
    }

    /// An album's or playlist's tracks, opened at once from its id and name.
    private func openTracks(id: String, title: String, isPlaylist: Bool) {
        guard let client = session.jellyfin else { return }
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        Task {
            let tracks = (try? await isPlaylist ? client.playlistItems(playlistId: id) : client.albumTracks(albumId: id)) ?? []
            template.emptyViewTitleVariants = ["No songs"]
            guard !tracks.isEmpty else { return }
            template.updateSections([
                CPListSection(items: [shuffleItem { tracks }]),
                CPListSection(items: trackItems(Array(tracks.prefix(limit)))),
            ])
        }
    }

    private func openArtist(_ artist: BaseItem) {
        guard let client = session.jellyfin else { return }
        let template = CPListTemplate(title: artist.displayTitle, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        Task { [weak self] in
            guard let self else { return }
            let albums = (try? await client.artistAlbums(artistId: artist.id)) ?? []
            let shuffle = shuffleItem { (try? await client.artistTracks(artistId: artist.id)) ?? [] }
            let mix = CPListItem(text: "Instant Mix", detailText: nil, image: UIImage(systemName: "wand.and.stars"))
            mix.handler = { [weak self] _, completion in
                Task {
                    let songs = (try? await client.instantMix(for: artist.id)) ?? []
                    if !songs.isEmpty { self?.play(songs, startingAt: 0) }
                    completion()
                }
            }
            template.emptyViewTitleVariants = ["No albums"]
            template.updateSections([
                CPListSection(items: [shuffle, mix]),
                CPListSection(items: albums.prefix(limit).map(albumItem), header: "Albums", sectionIndexTitle: nil),
            ])
        }
    }

    /// Plays a book on the phone's audiobook player and shows CarPlay's Now Playing.
    private func play(_ book: Audiobook, from chapter: AudiobookChapter? = nil) {
        guard let client = session.jellyfin else { return }
        session.audiobooks.play(book, from: chapter, client: client)
        showNowPlaying(music: false)
    }

    /// Plays on the phone's music player and shows CarPlay's Now Playing.
    private func play(_ tracks: [BaseItem], startingAt index: Int, shuffled: Bool = false) {
        guard let client = session.jellyfin else { return }
        session.music.play(tracks, startingAt: index, shuffled: shuffled, client: client)
        showNowPlaying(music: true)
    }

    // MARK: Now Playing

    /// CarPlay's one Now Playing screen, set up for what's playing: music gets
    /// its buttons (favorite, add to a playlist, shuffle, repeat), Up Next
    /// and a link to the album; a book gets none of them.
    private func showNowPlaying(music: Bool) {
        setUpNowPlaying(music: music)
        let template = CPNowPlayingTemplate.shared
        guard let controller = interfaceController, controller.topTemplate !== template else { return }
        controller.pushTemplate(template, animated: true, completion: nil)
    }

    /// Readies Now Playing without showing it: also used when the car
    /// connects with music already playing from the phone, so the car's own
    /// Now Playing button opens it with the buttons in place.
    private func setUpNowPlaying(music: Bool) {
        let template = CPNowPlayingTemplate.shared
        isShowingMusic = music
        if !observingNowPlaying {
            template.add(self)
            observingNowPlaying = true
        }
        // Music's Up Next is the queue; a book's is its chapters. The title
        // line opens the album, or the book's page.
        template.isUpNextButtonEnabled = true
        template.upNextTitle = music ? "Up Next" : "Chapters"
        template.isAlbumArtistButtonEnabled = true
        if music {
            watchMusic()
        } else {
            watchBook()
        }
    }

    // MARK: Now Playing: books

    /// Redraws a book's buttons now, and again when its speed or the book
    /// changes, for as long as a book is what's showing. (Skipping back 15
    /// and ahead 30 seconds are the screen's own controls, from the player's
    /// remote commands.)
    private func watchBook() {
        guard !isShowingMusic else { return }
        withObservationTracking {
            updateBookButtons()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchBook() }
        }
    }

    private func updateBookButtons() {
        let player = session.audiobooks
        guard let book = player.book else {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
            return
        }
        var buttons: [CPNowPlayingButton] = [
            CPNowPlayingImageButton(image: speedImage(player.rate)) { [weak self] _ in
                self?.pickSpeed()
            },
        ]
        if book.chapters.count > 1 {
            if let image = UIImage(systemName: "backward.end.fill") {
                buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in
                    self?.session.audiobooks.previousChapter()
                })
            }
            if let image = UIImage(systemName: "forward.end.fill") {
                buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in
                    self?.session.audiobooks.nextChapter()
                })
            }
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    /// The speed as the button's picture ("1.1×"), drawn as a plain
    /// one-colour template CarPlay tints like its own buttons.
    private func speedImage(_ rate: Float) -> UIImage {
        let size = CPNowPlayingButtonMaximumImageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = interfaceController?.carTraitCollection.displayScale ?? 2
        format.preferredRange = .standard
        let text = AudiobookRates.label(rate) as NSString
        var fontSize = size.height * 0.5
        var attributes: [NSAttributedString.Key: Any] = [:]
        var textSize = CGSize.zero
        // Shrinks "1.75×" until it fits the button.
        repeat {
            attributes = [.font: UIFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: UIColor.black]
            textSize = text.size(withAttributes: attributes)
            fontSize -= 1
        } while textSize.width > size.width && fontSize > 8
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// The speeds, the one in use ticked; picking one goes back.
    private func pickSpeed() {
        let current = session.audiobooks.rate
        let items = AudiobookRates.choices.map { rate -> CPListItem in
            let item = CPListItem(text: AudiobookRates.label(rate), detailText: nil)
            item.isPlaying = rate == current
            item.handler = { [weak self] _, completion in
                self?.session.audiobooks.setRate(rate)
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Speed", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// The book's chapters, the one playing marked; picking one goes there.
    private func showChapters() {
        let player = session.audiobooks
        guard let book = player.book else { return }
        let current = player.currentChapter?.id
        let items = book.chapters.prefix(limit).map { chapter -> CPListItem in
            let at = book.offset(ofPart: chapter.part) + chapter.start
            let item = CPListItem(text: chapter.title, detailText: Duration.seconds(at).formatted(.time(pattern: .hourMinuteSecond)))
            item.isPlaying = chapter.id == current
            item.handler = { [weak self] _, completion in
                self?.session.audiobooks.jump(to: chapter)
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Chapters", sections: [CPListSection(items: Array(items))])
        template.emptyViewTitleVariants = ["No chapters"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// Redraws the buttons now, and again whenever the song, shuffle or
    /// repeat changes, for as long as music is what's showing.
    private func watchMusic() {
        guard isShowingMusic else { return }
        withObservationTracking {
            updateMusicButtons()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchMusic() }
        }
    }

    private func updateMusicButtons() {
        let player = session.music
        guard let song = player.current else {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
            return
        }
        let favorite = favorites[song.id] ?? song.userData?.isFavorite ?? false
        var buttons: [CPNowPlayingButton] = []
        if let image = UIImage(systemName: favorite ? "heart.fill" : "heart") {
            buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in
                self?.setFavorite(song, !favorite)
            })
        }
        if let image = UIImage(systemName: "text.badge.plus") {
            buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in
                self?.pickPlaylist(for: song)
            })
        }
        if let image = UIImage(systemName: player.isShuffled ? "shuffle.circle.fill" : "shuffle") {
            buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in
                self?.session.music.toggleShuffle()
            })
        }
        let repeatSymbol = switch player.repeatMode {
        case .off: "repeat"
        case .all: "repeat.circle.fill"
        case .one: "repeat.1.circle.fill"
        }
        if let image = UIImage(systemName: repeatSymbol) {
            buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in
                self?.session.music.cycleRepeat()
            })
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    /// Favorites or unfavorites a song on the server; the heart changes at
    /// once and changes back if the server says no.
    private func setFavorite(_ song: BaseItem, _ favorite: Bool) {
        guard let client = session.jellyfin else { return }
        favorites[song.id] = favorite
        updateMusicButtons()
        Task { [weak self] in
            do {
                try await client.setFavorite(song.id, favorite)
            } catch {
                self?.favorites[song.id] = !favorite
                self?.updateMusicButtons()
            }
        }
    }

    /// The person's playlists; picking one adds the song and goes back.
    private func pickPlaylist(for song: BaseItem) {
        guard let client = session.jellyfin else { return }
        pushList("Add to Playlist") { [weak self] in
            let playlists = (try? await client.playlists(mediaType: "Audio")) ?? []
            let items = playlists.prefix(self?.limit ?? 100).map { playlist -> CPListItem in
                let item = CPListItem(text: playlist.displayTitle, detailText: nil, image: UIImage(systemName: "music.note.list"))
                item.handler = { [weak self] _, completion in
                    Task { [weak self] in
                        let added = (try? await client.addToPlaylist(playlist.id, itemIds: [song.id])) != nil
                        completion()
                        self?.interfaceController?.popTemplate(animated: true, completion: nil)
                        self?.showMessage(added ? "Added to \(playlist.displayTitle)" : "Couldn't add to \(playlist.displayTitle)")
                    }
                }
                return item
            }
            return [CPListSection(items: Array(items))]
        }
    }

    /// A short message with an OK button.
    private func showMessage(_ text: String) {
        let alert = CPAlertTemplate(titleVariants: [text], actions: [
            CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            },
        ])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }
}

extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    /// The songs still to come, picking one plays it; for a book, its chapters.
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard isShowingMusic else {
            showChapters()
            return
        }
        pushList("Up Next") { [weak self] in
            guard let self else { return [] }
            let items = self.session.music.upNext.prefix(self.limit).map { track -> CPListItem in
                let item = CPListItem(text: track.displayTitle, detailText: track.artistText)
                self.loadArtwork(for: track, into: item)
                item.handler = { [weak self] _, completion in
                    self?.session.music.skip(to: track)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    completion()
                }
                return item
            }
            return [CPListSection(items: Array(items))]
        }
    }

    /// The album the song is from; for a book, its page.
    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard isShowingMusic else {
            if let book = session.audiobooks.book { openBook(book) }
            return
        }
        guard let song = session.music.current, let albumId = song.albumId else { return }
        openTracks(id: albumId, title: song.album ?? song.displayTitle, isPlaylist: false)
    }
}
#endif
