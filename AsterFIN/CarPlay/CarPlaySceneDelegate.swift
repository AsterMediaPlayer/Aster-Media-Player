//
//  CarPlaySceneDelegate.swift
//  AsterFIN
//
//  AsterFIN's music in CarPlay: tabs of recent, albums, artists and
//  playlists, each opening a list of tracks, then the system Now Playing
//  screen. CarPlay audio apps are limited to these templates; playback
//  itself is the phone's music player, which already feeds Now Playing and
//  answers the car's controls.
//

#if canImport(CarPlay)
import CarPlay
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var session: AppSession { AppSession.shared }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(rootTemplate(), animated: false, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    // MARK: Tabs

    private func rootTemplate() -> CPTemplate {
        guard session.client != nil else {
            let template = CPListTemplate(title: "Aster", sections: [])
            template.emptyViewTitleVariants = ["Sign in on your iPhone"]
            template.emptyViewSubtitleVariants = ["Open Aster on your iPhone and sign in to your Jellyfin server."]
            return template
        }
        return CPTabBarTemplate(templates: [
            tab("Recent", systemImage: "clock") { [weak self] in await self?.recentSections() ?? [] },
            tab("Albums", systemImage: "square.stack") { [weak self] in await self?.albumSections() ?? [] },
            tab("Artists", systemImage: "music.mic") { [weak self] in await self?.artistSections() ?? [] },
            tab("Playlists", systemImage: "music.note.list") { [weak self] in await self?.playlistSections() ?? [] },
        ])
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
        guard let client = session.client else { return [] }
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
        guard let client = session.client else { return [] }
        let albums = (try? await client.items([
            "includeItemTypes": "MusicAlbum",
            "recursive": "true",
            "sortBy": "SortName",
            "limit": String(limit),
        ]).items) ?? []
        return [CPListSection(items: albums.map(albumItem))]
    }

    private func artistSections() async -> [CPListSection] {
        guard let client = session.client else { return [] }
        let artists = (try? await client.albumArtists(limit: limit).items) ?? []
        return [CPListSection(items: artists.map(artistItem))]
    }

    private func playlistSections() async -> [CPListSection] {
        guard let client = session.client else { return [] }
        let playlists = (try? await client.playlists(mediaType: "Audio")) ?? []
        return [CPListSection(items: playlists.map(albumItem))]
    }

    // MARK: Rows

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

    private func artistItem(_ artist: BaseItem) -> CPListItem {
        let item = CPListItem(text: artist.displayTitle, detailText: nil)
        item.accessoryType = .disclosureIndicator
        loadArtwork(for: artist, into: item)
        item.handler = { [weak self] _, completion in
            self?.openArtist(artist)
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
        guard let client = session.client, let url = client.posterURL(for: item, width: 200) else { return }
        Task {
            if let image = await ImageStore.shared.image(for: url, client: client) {
                row.setImage(image)
            }
        }
    }

    // MARK: Screens

    private func openTracks(of album: BaseItem) {
        guard let client = session.client else { return }
        let template = CPListTemplate(title: album.displayTitle, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        Task {
            let isPlaylist = album.kind == .playlist
            let tracks = (try? await isPlaylist ? client.playlistItems(playlistId: album.id) : client.albumTracks(albumId: album.id)) ?? []
            template.emptyViewTitleVariants = ["No songs"]
            guard !tracks.isEmpty else { return }
            template.updateSections([
                CPListSection(items: [shuffleItem { tracks }]),
                CPListSection(items: trackItems(Array(tracks.prefix(limit)))),
            ])
        }
    }

    private func openArtist(_ artist: BaseItem) {
        guard let client = session.client else { return }
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

    /// Plays on the phone's music player and shows CarPlay's Now Playing.
    private func play(_ tracks: [BaseItem], startingAt index: Int, shuffled: Bool = false) {
        guard let client = session.client else { return }
        session.music.play(tracks, startingAt: index, shuffled: shuffled, client: client)
        guard let controller = interfaceController, controller.topTemplate !== CPNowPlayingTemplate.shared else { return }
        controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
#endif
