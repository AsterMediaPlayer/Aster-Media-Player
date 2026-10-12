//
//  DiscMenuController.swift
//  AsterFIN
//
//  Navigation state of an open disc menu (CLIENT_GUIDE §4.3–4.7): the screen
//  stack, page and focus memory, actions, scene selection, the trailer layer
//  and the hand-off to playback.
//

import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Which screen is on the stack: one from the document, or a generated
/// scene-selection screen.
nonisolated enum DiscScreenRef: Hashable, Sendable {
    case menu(String)
    case chapters(String)
}

/// A screen with its inherited settings resolved and its page laid out.
struct DiscResolvedScreen {
    var ref: DiscScreenRef
    var title: String
    var theme: DiscTheme
    var background: DiscBackground?
    var layout: DiscLayout
    var audio: DiscAudio?
    var entries: [DiscMenuEntry]
    var positioned: Bool
    var page: Int
    var pageCount: Int

    var transitionStyle: String { layout.transition?.style ?? "none" }
    var transitionDuration: Double {
        Double(min(2000, max(0, layout.transition?.durationMs ?? 300))) / 1000
    }
}

@Observable
final class DiscMenuController {
    let itemId: String
    let client: JellyfinClient
    let audio = DiscMenuAudio()

    private(set) var document: DiscMenuDocument
    private(set) var screen: DiscResolvedScreen
    private(set) var focusIndex = 0
    /// Bumped on every screen or page change; the view keys the screen on it.
    private(set) var generation = 0
    /// +1 going forward (submenu, More), -1 going back (Back, Home, Previous).
    private(set) var direction = 1
    /// False when the screen must be replaced without animation.
    private(set) var animateChange = false
    private(set) var trailer: DiscTrailerPlayer?
    private(set) var isSuspended = false

    var pendingPlayback: PlaybackRequest?
    var alertMessage: String?
    var shouldClose = false

    private var stack: [DiscScreenRef]
    private var pageMemory: [DiscScreenRef: Int] = [:]
    private var focusMemory: [DiscScreenRef: Int] = [:]
    private var generated: [DiscScreenRef: DiscMenuScreenSpec] = [:]
    private var frames: [Int: [Int: CGRect]] = [:]

    init(document: DiscMenuDocument, itemId: String, client: JellyfinClient, soundsEnabled: Bool) {
        self.document = document
        self.itemId = itemId
        self.client = client
        self.audio.enabled = soundsEnabled
        let root = DiscScreenRef.menu(document.root)
        stack = [root]
        screen = Self.resolve(root, page: 0, document: document, generated: [:])
    }

    // MARK: Lifecycle

    func open() {
        focusIndex = 0
        animateChange = true
        generation += 1
        syncPresentation()
        preloadPictures()
    }

    func close() {
        audio.stop()
        trailer?.stop()
        trailer = nil
        shouldClose = true
    }

    /// Pauses music and the trailer while the player is up.
    func suspendForPlayback() {
        isSuspended = true
        audio.suspend()
        trailer?.pause()
    }

    /// Playback ended: re-fetch the document and show the same screen again.
    func resumeAfterPlayback() async {
        isSuspended = false
        if let fresh = try? await client.discMenu(for: itemId) {
            document = fresh
        }
        // Drop screens that no longer exist; generated screens are rebuilt on demand.
        stack = stack.filter { ref in
            switch ref {
            case .menu(let key): return document.menus[key] != nil
            case .chapters: return generated[ref] != nil
            }
        }
        if stack.isEmpty { stack = [.menu(document.root)] }
        animateChange = false
        rebuild(keepFocus: true)
        audio.resume()
        trailer?.play()
    }

    // MARK: Geometry from the view

    func reportFrame(_ frame: CGRect, index: Int, generation: Int) {
        frames[generation, default: [:]][index] = frame
    }

    private var currentFrames: [CGRect]? {
        guard let measured = frames[generation], measured.count >= screen.entries.count, !screen.entries.isEmpty else { return nil }
        return screen.entries.indices.map { measured[$0] ?? .zero }
    }

    // MARK: Input

    #if os(tvOS)
    func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: move(dx: -1, dy: 0)
        case .right: move(dx: 1, dy: 0)
        case .up: move(dx: 0, dy: -1)
        case .down: move(dx: 0, dy: 1)
        @unknown default: return
        }
    }
    #endif

    /// Moves focus one step: -1/1 on each axis, left/up being negative.
    func move(dx: Int, dy: Int) {
        guard !screen.entries.isEmpty else { return }
        let target: Int
        if let rects = currentFrames {
            target = DiscMenuRules.moveFocus(rects: rects, current: focusIndex, dx: dx, dy: dy)
        } else {
            // Frames not measured yet: step through the drawing order.
            let step = (dx + dy) > 0 ? 1 : -1
            target = (focusIndex + step + screen.entries.count) % screen.entries.count
        }
        guard target != focusIndex else { return }
        focusIndex = target
        focusMemory[screen.ref] = target
        audio.play(.move)
    }

    func select() {
        guard screen.entries.indices.contains(focusIndex) else { return }
        activate(screen.entries[focusIndex])
    }

    /// A touch at a point on the canvas: highlights and activates the entry
    /// under it, if any. The point is in the same space as the reported frames.
    func tap(at point: CGPoint) {
        guard let rects = currentFrames,
              let hit = rects.indices.last(where: { rects[$0].contains(point) }) else { return }
        focusIndex = hit
        focusMemory[screen.ref] = hit
        activate(screen.entries[hit])
    }

    /// Whether Back steps to an earlier page or screen rather than closing.
    var canGoBack: Bool { screen.page > 0 || stack.count > 1 }

    /// The remote's Back/Menu button: a page back, then a screen back, then close.
    func hardwareBack() {
        audio.play(.back)
        if screen.page > 0 {
            changePage(by: -1)
        } else if stack.count > 1 {
            pop()
        } else {
            close()
        }
    }

    func playPause() {
        guard screen.entries.indices.contains(focusIndex) else { return }
        let entry = screen.entries[focusIndex]
        switch entry.kind {
        case .playFeature, .playExtra, .playSequence, .playChapter:
            activate(entry)
        default:
            break
        }
    }

    // MARK: Actions

    func activate(_ entry: DiscMenuEntry) {
        switch entry.kind {
        case .submenu:
            guard let key = entry.menu, document.menus[key] != nil else { return }
            audio.play(.select)
            push(.menu(key))
        case .back:
            audio.play(.back)
            if stack.count > 1 { pop() } else { close() }
        case .home:
            audio.play(.back)
            home()
        case .pagePrev:
            audio.play(.back)
            changePage(by: -1)
        case .pageNext:
            audio.play(.select)
            changePage(by: 1)
        case .chapters:
            audio.play(.select)
            openChapters(from: entry)
        case .playFeature:
            audio.play(.select)
            var start: Int64 = 0
            if let chapter = entry.startChapter, let chapters = document.chapters, chapter >= 1, chapter <= chapters.count {
                start = chapters[chapter - 1].startTicks
            }
            pendingPlayback = PlaybackRequest(itemId: itemId, startTicks: start)
        case .playExtra:
            audio.play(.select)
            guard let extra = entry.itemId else {
                alertMessage = "\"\(entry.label)\" isn't available in this library."
                return
            }
            pendingPlayback = PlaybackRequest(itemId: extra)
        case .playSequence:
            audio.play(.select)
            guard let ids = entry.itemIds, !ids.isEmpty else {
                alertMessage = "None of \"\(entry.label)\" is available in this library."
                return
            }
            pendingPlayback = PlaybackRequest(itemIds: ids)
        case .playChapter:
            audio.play(.select)
            pendingPlayback = PlaybackRequest(itemId: itemId, startTicks: entry.startTicks ?? 0)
        case .unknown:
            break
        }
    }

    private func push(_ ref: DiscScreenRef) {
        pageMemory[ref] = 0
        focusMemory[ref] = nil
        stack.append(ref)
        direction = 1
        animateChange = true
        rebuild(keepFocus: false)
    }

    private func pop() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        direction = -1
        animateChange = true
        rebuild(keepFocus: true)
    }

    private func home() {
        stack = [.menu(document.root)]
        pageMemory = [:]
        direction = -1
        animateChange = true
        rebuild(keepFocus: true)
    }

    private func changePage(by delta: Int) {
        let next = screen.page + delta
        guard next >= 0, next < screen.pageCount else { return }
        pageMemory[screen.ref] = next
        focusMemory[screen.ref] = 0
        direction = delta > 0 ? 1 : -1
        animateChange = true
        rebuild(keepFocus: false)
    }

    // MARK: Scene selection

    private func openChapters(from entry: DiscMenuEntry) {
        let chapters = document.chapters ?? []
        guard !chapters.isEmpty else {
            alertMessage = "This title has no chapter markers."
            return
        }
        let ref = DiscScreenRef.chapters("\(entry.menu ?? "")|\(entry.label)")
        let styling = entry.menu.flatMap { document.menus[$0] }
        let perPage = min(24, max(1, entry.perPage ?? 6))

        var entries: [DiscMenuEntry] = chapters.enumerated().map { position, chapter in
            let name = (chapter.name?.isEmpty == false) ? chapter.name! : "Chapter \(position + 1)"
            let thumb = chapter.hasImage == true ? client.chapterImageURL(itemId: itemId, index: chapter.index, stamp: chapter.imageStamp) : nil
            return DiscMenuEntry(action: DiscAction.playChapter.rawValue, label: name, sub: DiscMenuRules.formatTicks(chapter.startTicks), thumbURL: thumb, startTicks: chapter.startTicks)
        }
        if let styling {
            entries.append(contentsOf: styling.entries)
        } else {
            entries.append(DiscMenuEntry(action: DiscAction.back.rawValue, label: "Back"))
        }

        var layout = styling?.layout ?? DiscLayout()
        if DiscMenuRules.effectiveLayout(document: document.layout, screen: styling?.layout).flow == nil {
            layout.flow = DiscMenuRules.defaultChapterFlow(perPage: perPage)
        }

        generated[ref] = DiscMenuScreenSpec(
            title: styling?.title ?? entry.label,
            entries: entries,
            background: styling?.background,
            theme: styling?.theme,
            layout: layout,
            audio: styling?.audio,
            maxPerPage: perPage
        )
        push(ref)
    }

    // MARK: Resolution

    private func spec(for ref: DiscScreenRef) -> DiscMenuScreenSpec? {
        switch ref {
        case .menu(let key): return document.menus[key]
        case .chapters: return generated[ref]
        }
    }

    private static func resolve(_ ref: DiscScreenRef, page: Int, document: DiscMenuDocument, generated: [DiscScreenRef: DiscMenuScreenSpec]) -> DiscResolvedScreen {
        let spec: DiscMenuScreenSpec
        switch ref {
        case .menu(let key):
            spec = document.menus[key] ?? DiscMenuScreenSpec(title: "", entries: [])
        case .chapters:
            spec = generated[ref] ?? DiscMenuScreenSpec(title: "", entries: [])
        }
        let laid = DiscMenuRules.entriesForPage(document: document, screen: spec, page: page)
        return DiscResolvedScreen(
            ref: ref,
            title: spec.title,
            theme: DiscMenuRules.effectiveTheme(document: document.theme, screen: spec.theme),
            background: DiscMenuRules.effectiveBackground(document: document.background, screen: spec.background),
            layout: DiscMenuRules.effectiveLayout(document: document.layout, screen: spec.layout),
            audio: DiscMenuRules.effectiveAudio(document: document.audio, screen: spec.audio),
            entries: laid.entries,
            positioned: laid.positioned,
            page: laid.page,
            pageCount: laid.pageCount
        )
    }

    private func rebuild(keepFocus: Bool) {
        guard let ref = stack.last else { return }
        let resolved = Self.resolve(ref, page: pageMemory[ref] ?? 0, document: document, generated: generated)
        let remembered = keepFocus ? (focusMemory[ref] ?? 0) : 0
        let focus = resolved.entries.isEmpty ? 0 : min(remembered, resolved.entries.count - 1)
        let duration = (animateChange && resolved.transitionStyle != "none") ? resolved.transitionDuration : 0
        let apply = {
            self.screen = resolved
            self.focusIndex = focus
            self.generation += 1
        }
        if duration > 0 {
            withAnimation(.easeOut(duration: duration), apply)
        } else {
            withAnimation(nil, apply)
        }
        frames = frames.filter { $0.key >= generation - 1 }
        syncPresentation()
    }

    /// Music, button sounds and the trailer layer follow the current screen.
    private func syncPresentation() {
        audio.apply(screen.audio, document: document, client: client)
        syncTrailer()
    }

    private func syncTrailer() {
        guard let background = screen.background, background.source == "trailer" else {
            trailer?.stop()
            trailer = nil
            return
        }
        let trailers = document.trailers ?? []
        let index = max(0, background.trailerIndex ?? 0)
        guard index < trailers.count, trailers[index].kind == "local", let trailerId = trailers[index].itemId else {
            trailer?.stop()
            trailer = nil
            return
        }
        let muted = background.muted ?? true
        if let existing = trailer, existing.trailerId == trailerId, existing.isMuted == muted {
            return
        }
        trailer?.stop()
        let player = DiscTrailerPlayer(trailerId: trailerId, url: client.videoStreamURL(itemId: trailerId), muted: muted)
        trailer = player
        if !isSuspended { player.play() }
    }

    // MARK: Pictures

    /// Every picture of every screen, fetched when the menu opens.
    private func preloadPictures() {
        var urls: [URL] = []
        let resolver = DiscPictureResolver(client: client, itemId: itemId)
        func add(_ reference: String?) {
            if let url = resolver.url(forPicture: reference) { urls.append(url) }
        }
        func addBackground(_ background: DiscBackground?) {
            if let url = resolver.url(forBackground: background) { urls.append(url) }
            add(background?.poster)
        }
        addBackground(document.background)
        for layer in document.layout?.layers ?? [] { add(layer.image) }
        for menu in document.menus.values {
            addBackground(menu.background)
            for layer in menu.layout?.layers ?? [] { add(layer.image) }
            for entry in menu.entries {
                add(entry.image)
                add(entry.imageFocus)
            }
        }
        ImageStore.shared.prefetch(urls, client: client)
    }
}

// MARK: - Picture references

/// Turns a menu's picture references into URLs, accepting only what §4.8 allows.
nonisolated struct DiscPictureResolver: Sendable {
    let client: JellyfinClient
    let itemId: String

    func url(forPicture reference: String?) -> URL? {
        guard let reference, DiscMenuRules.isSafeImage(reference) else { return nil }
        if reference.hasPrefix("asset:") {
            let segments = reference.dropFirst("asset:".count).split(separator: "/").map(String.init)
            return client.discAssetURL(path: segments)
        }
        return URL(string: reference)
    }

    func url(forAudio reference: String?) -> URL? {
        guard let reference, DiscMenuRules.isSafeAudio(reference) else { return nil }
        if reference.hasPrefix("asset:") {
            let segments = reference.dropFirst("asset:".count).split(separator: "/").map(String.init)
            return client.discAssetURL(path: segments)
        }
        return URL(string: reference)
    }

    /// The still picture of a background, if it has one.
    func url(forBackground background: DiscBackground?) -> URL? {
        guard let background else { return nil }
        switch background.source {
        case "jellyfin":
            let kind = ImageKind(rawValue: background.imageType ?? "Backdrop") ?? .backdrop
            return client.imageURL(itemId: itemId, kind: kind, index: max(0, background.index ?? 0), maxWidth: 1920)
        case "tmdb":
            guard DiscMenuRules.isTmdbPath(background.tmdbFilePath), let path = background.tmdbFilePath else { return nil }
            let size = ["w780", "w1280", "original"].contains(background.tmdbSize ?? "") ? background.tmdbSize! : "w1280"
            return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
        case "fanart":
            guard DiscMenuRules.isFanartId(background.fanartId), DiscMenuRules.isItemId(itemId), let fanartId = background.fanartId else { return nil }
            return client.fanartURL(itemId: itemId, fanartId: fanartId)
        case "image":
            return url(forPicture: background.image)
        default:
            return nil
        }
    }
}

// MARK: - Trailer layer

/// A looping, cover-fitted local trailer behind the menu. Persists across
/// screens that use the same trailer.
@Observable
final class DiscTrailerPlayer {
    let trailerId: String
    let isMuted: Bool
    let player: AVQueuePlayer
    private(set) var isPlaying = false
    /// How many times the video has come back around to the start.
    private(set) var loops = 0
    private let timeRange: CMTimeRange
    private var looper: AVPlayerLooper?
    private var observation: NSKeyValueObservation?
    private var loopObservation: NSKeyValueObservation?

    /// `timeRange` loops just part of the video, e.g. an episode's opening.
    init(trailerId: String, url: URL, muted: Bool, timeRange: CMTimeRange = .invalid) {
        self.trailerId = trailerId
        self.isMuted = muted
        self.timeRange = timeRange
        let item = AVPlayerItem(url: url)
        player = AVQueuePlayer()
        player.isMuted = muted
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: item, timeRange: timeRange)
        self.looper = looper
        observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                self?.isPlaying = playing
            }
        }
        loopObservation = looper.observe(\.loopCount, options: [.new]) { [weak self] observed, _ in
            let count = observed.loopCount
            Task { @MainActor [weak self] in
                self?.loops = count
            }
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    /// Back to the start of the loop, without reloading anything.
    func restart() {
        player.seek(to: timeRange.isValid ? timeRange.start : .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
        observation = nil
        loopObservation = nil
    }
}
