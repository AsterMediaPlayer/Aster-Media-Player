//
//  MainTabView.swift
//  AsterFIN
//
//  The Apple TV app's sidebar navigation: Home, Movies, TV Shows, Music,
//  Live TV, Library, Settings and Search. Also lands Top Shelf links.
//

import SwiftUI
#if DEBUG && os(macOS)
import AppKit
import os

/// Temporary: the Mac sidebar and keyboard, read with `log show`.
let sidebarDebugLog = Logger(subsystem: "app.asterfin.debug", category: "sidebar")
#endif

enum AppTab: String, CaseIterable, Hashable {
    case home, movies, shows, anime, music, audiobooks, upcoming, liveTV, channels, library, downloads, settings, search

    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .anime: "Anime"
        case .upcoming: "Upcoming"
        case .music: "Music"
        case .audiobooks: "Audiobooks"
        case .liveTV: "Live TV"
        case .channels: "Channels"
        case .library: "Library"
        case .downloads: "Downloads"
        case .settings: "Settings"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film.fill"
        case .shows: "tv.fill"
        case .anime: "sparkles"
        case .upcoming: "calendar"
        case .music: "music.note"
        case .audiobooks: "books.vertical.fill"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .channels: "tv.and.mediabox"
        case .library: "square.stack.fill"
        case .downloads: "arrow.down.circle.fill"
        case .settings: "gearshape.fill"
        case .search: "magnifyingglass"
        }
    }
}

/// The tab order and hidden tabs chosen in Settings › Tab Bar on iPhone and
/// iPad, stored as comma-separated tab names. Tabs missing from a stored
/// order (new ones, say) follow in their usual place.
enum TabLayout {
    /// Home is where the app opens, and Settings is where a hidden tab is
    /// brought back, so neither can be hidden.
    static let alwaysShown: Set<AppTab> = [.home, .settings]

    static func order(from stored: String) -> [AppTab] {
        let saved = stored.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }
        var seen = Set<AppTab>()
        return (saved + AppTab.allCases).filter { seen.insert($0).inserted }
    }

    static func hidden(from stored: String) -> Set<AppTab> {
        Set(stored.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }).subtracting(alwaysShown)
    }

    static func encode(_ tabs: some Sequence<AppTab>) -> String {
        tabs.map(\.rawValue).joined(separator: ",")
    }
}

struct MainTabView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.tabOrderKey) private var tabOrder = ""
    @AppStorage(AppSettings.hiddenTabsKey) private var hiddenTabs = ""
    @AppStorage(AppSettings.downloadsEnabledKey) private var downloadsEnabled = true
    @State private var tab: AppTab = .home
    @State private var homePath = NavigationPath()
    @State private var linkedPlayback: PlaybackRequest?
    #if os(macOS)
    @State private var keyboard = KeyboardNavigation()
    @FocusState private var keyboardFocused: Bool
    @Environment(\.openSettings) private var openSettings
    private var sidebar: MacSidebarState { MacSidebarState.shared }
    #endif

    /// The tabs to show, in order: tvOS's fixed sidebar, or on iPhone and
    /// iPad the viewer's choice. Tabs the server has nothing for are left out.
    private var shownTabs: [AppTab] {
        #if os(tvOS)
        let order = AppTab.allCases
        let hidden: Set<AppTab> = []
        #else
        let order = TabLayout.order(from: tabOrder)
        let hidden = TabLayout.hidden(from: hiddenTabs)
        #endif
        return order.filter {
            !hidden.contains($0) && session.hasContent(for: $0)
                && ($0 != .downloads || downloadsEnabled)
        }
    }

    var body: some View {
        @Bindable var player = session.music
        @Bindable var audiobooks = session.audiobooks
        tabView
        #if os(iOS)
        // The song or book playing, under the tab bar on every tab.
        .tabViewBottomAccessory(isEnabled: session.isAudioLoaded) {
            AudioAccessory()
        }
        #endif
        #if os(tvOS)
        // The remote's Play/Pause pauses an opening or ending playing while
        // browsing, else music or a book, from anywhere (the players and
        // videos handle it themselves while showing). Held, it brings focus
        // to the Now Playing panel.
        .onPlayPauseCommand {
            if session.themeDeck.isActive {
                session.themeDeck.togglePlaying()
            } else {
                session.toggleAudio()
            }
        }
        .background {
            PlayPauseHoldDetector(isEnabled: { session.themeDeck.isActive }) {
                session.focusThemePanel()
            }
            .allowsHitTesting(false)
        }
        #endif
        // A tab hidden while showing hands over to Home.
        .onChange(of: shownTabs) { _, tabs in
            if !tabs.contains(tab) { tab = .home }
        }
        // Music can start from any tab (Search, Library), so the player is
        // presented from here rather than from the Music screen.
        .appCover(isPresented: $player.isNowPlayingPresented) {
            NowPlayingView()
        }
        // Each presentation needs its own host view.
        .background {
            Color.clear
                .appCover(isPresented: $audiobooks.isNowPlayingPresented) {
                    AudiobookNowPlayingView()
                }
        }
        // The Now Playing panel's opening or ending, full screen, from any
        // page the panel (or the slim one) shows on.
        .background {
            Color.clear
                .appCover(isPresented: Binding(get: { session.themeFullScreen }, set: { session.themeFullScreen = $0 })) {
                    ThemeDeckFullScreen(deck: session.themeDeck) { session.themeFullScreen = false }
                }
        }
        .background {
            Color.clear
                .appCover(item: $linkedPlayback, onDismiss: {
                    // Progress changed, so Continue Watching and Next Up should too.
                    session.userDataChanged()
                }) { request in
                    PlayerView(request: request) { linkedPlayback = nil }
                }
        }
        // Settings that follow the user, and whether the server has any
        // channels (playlists tagged as one), alongside the loading below
        // rather than holding it up.
        .task {
            if let client = session.jellyfin { await SettingsSync.pull(client: client) }
            await session.refreshChannels()
        }
        // The tracking accounts, as any Aster app last left them.
        .task {
            if let client = session.client, let user = session.userId {
                await TrackerAccounts.shared.load(client: client, userId: user)
            }
        }
        .task {
            guard let client = session.client else { return }
            await session.refreshUserConfiguration()
            let views = (try? await client.libraries()) ?? []
            session.noteLibraries(views)
            await session.refreshUpcoming()
            await session.detectAnimeLibraries(among: views)
            await session.detectAnimeMusic(among: views)
            await followPendingLinks()
        }
        // Back from the background: changes made on another device since.
        .onChange(of: scenePhase) { old, phase in
            #if os(iOS)
            // Leaving: a fresh twelve hours for the On Now widget.
            if phase == .background { ChannelTuner.writeOnNowGuide() }
            #endif
            guard phase == .active, old == .background else { return }
            if let client = session.client, let user = session.userId {
                Task { await TrackerAccounts.shared.load(client: client, userId: user) }
            }
            guard let client = session.jellyfin else { return }
            Task {
                await SettingsSync.pull(client: client)
                await session.refreshChannels()
            }
        }
        .onChange(of: session.router.pendingItemId) { _, _ in
            Task { await followPendingLinks() }
        }
        .onChange(of: session.router.pendingPlayItemId) { _, _ in
            Task { await followPendingLinks() }
        }
        .onChange(of: session.router.pendingChannelId) { _, _ in
            Task { await followPendingLinks() }
        }
        .onChange(of: session.router.pendingDownloads) { _, _ in
            Task { await followPendingLinks() }
        }
        .onChange(of: session.router.pendingPlayback) { _, _ in
            if let request = session.router.takePlayback() {
                linkedPlayback = request
            }
        }
        #if os(macOS)
        // The window's one keyboard handler (see `KeyboardNavigation`): a
        // focusable page inside a focusable page shares its focus on the
        // Mac, so pages register what the keys do rather than taking focus.
        .environment(keyboard)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear {
            claimKeyboard()
            // A pen on an iPad used as a display scrolls the page; a finger
            // can't, and the page says to use two.
            DragScroller.shared.install { WindowCovers.shared.covers.isEmpty }
            SidecarHint.shared.install()
        }
        .onChange(of: tab) { _, _ in
            KeyboardTargets.shared.clearSelection()
            // Away once a tab is chosen, however it was (a click, the
            // keyboard, a link), then the page gets the keyboard back.
            sidebar.hide()
            clearKeyboardInSidebar()
            restoreKeyboardFocus()
        }
        .onKeyPress(.upArrow) { routeKey(.up) }
        .onKeyPress(.downArrow) { routeKey(.down) }
        .onKeyPress(.leftArrow) { routeKey(.left) }
        .onKeyPress(.rightArrow) { routeKey(.right) }
        .onKeyPress(.return) { routeKey(.select) }
        .onKeyPress(.escape) { routeKey(.exit) }
        // Space pauses or resumes music or a book from any page.
        .onKeyPress(.space) {
            guard WindowCovers.shared.covers.isEmpty, session.isAudioLoaded else { return .ignored }
            session.toggleAudio()
            return .handled
        }
        // The window's keyboard handling takes key presses before the menu
        // bar sees them, so Settings… (⌘,) is opened from here too.
        .onKeyPress(characters: [","]) { press in
            #if DEBUG
            sidebarDebugLog.notice("comma key modifiers=\(press.modifiers.rawValue)")
            #endif
            guard press.modifiers.contains(.command) else { return .ignored }
            openSettings()
            return .handled
        }
        #endif
    }

    #if os(macOS)
    /// Takes the keyboard once the view is in its window (set as it
    /// appears, focus doesn't take), so no click is needed first.
    private func claimKeyboard() {
        Task { keyboardFocused = true }
    }

    /// The page showing gets the key first. Left past its leading edge, or
    /// up past its top, moves into the sidebar (sliding it out if hidden),
    /// where up and down move a highlight, Return opens that tab and gives
    /// it the keyboard, and right or Esc go back without switching; either
    /// way the sidebar slides away again. Nothing here while a cover (the
    /// player) is up.
    private func routeKey(_ key: KeyboardNavigation.Key) -> KeyPress.Result {
        #if DEBUG
        sidebarDebugLog.notice("routeKey \(String(describing: key), privacy: .public) inSidebar=\(keyboard.inSidebar) highlight=\(keyboard.sidebarHighlight?.rawValue ?? "nil", privacy: .public) tab=\(tab.rawValue, privacy: .public)")
        #endif
        guard WindowCovers.shared.covers.isEmpty else { return .ignored }
        if keyboard.inSidebar {
            switch key {
            case .up, .down:
                let tabs = shownTabs
                if keyboard.settingsHighlighted {
                    // Settings sits under the last tab.
                    if key == .up {
                        keyboard.settingsHighlighted = false
                        keyboard.sidebarHighlight = tabs.last
                    }
                } else {
                    let current = keyboard.sidebarHighlight.flatMap { tabs.firstIndex(of: $0) } ?? tabs.firstIndex(of: tab) ?? 0
                    if key == .down, current == tabs.count - 1 {
                        keyboard.settingsHighlighted = true
                        keyboard.sidebarHighlight = nil
                    } else {
                        keyboard.sidebarHighlight = tabs[key == .up ? max(current - 1, 0) : min(current + 1, tabs.count - 1)]
                    }
                }
            case .select:
                if keyboard.settingsHighlighted {
                    openSettings()
                } else if let chosen = keyboard.sidebarHighlight {
                    tab = chosen
                }
                leaveSidebar()
            case .right, .exit:
                leaveSidebar()
            case .left:
                break
            }
            return .handled
        }
        // Esc goes back a page, as the back button does.
        if key == .exit {
            guard KeyboardTargets.shared.goBack(on: tab) else { return .ignored }
            // Closing the page takes the window's key focus with it.
            restoreKeyboardFocus()
            return .handled
        }
        // A page's own handling applies at its top level, not under a page
        // pushed over it.
        let atRoot = tab != .home || homePath.isEmpty
        if atRoot, let handler = keyboard.handler(for: tab) {
            if handler(key) == .handled { return .handled }
        } else if KeyboardTargets.shared.handle(key, on: tab) == .handled {
            // Every other page: the nearest card or button that way.
            return .handled
        }
        if key == .left || key == .up {
            enterSidebar()
            return .handled
        }
        return .ignored
    }

    private func enterSidebar() {
        keyboard.inSidebar = true
        keyboard.sidebarHighlight = tab
        // Slides out if it's away; it's put away again on the way out.
        sidebar.show()
    }

    private func leaveSidebar() {
        clearKeyboardInSidebar()
        // As on Apple TV, the sidebar goes away once the keyboard leaves it,
        // however it came to be open.
        sidebar.hide()
        restoreKeyboardFocus()
    }

    /// The keyboard is no longer in the sidebar (it left, a tab was picked
    /// with the mouse, or the sidebar was closed another way).
    private func clearKeyboardInSidebar() {
        keyboard.inSidebar = false
        keyboard.sidebarHighlight = nil
        keyboard.settingsHighlighted = false
    }

    /// Gives the keyboard back to the page after something took the window's
    /// key focus with it (a page closing): now, and again once the
    /// animation is over.
    private func restoreKeyboardFocus() {
        WindowSidebar.returnKeyboardToContent()
        claimKeyboard()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            WindowSidebar.returnKeyboardToContent()
            claimKeyboard()
        }
    }

    /// The window on the Mac: the tab showing, with the sidebar sliding out
    /// over it from the left (Apple TV's, drawn here: see `MacSidebar`).
    /// Only the tab showing is kept; Home's place is held in `homePath`.
    private var macTabs: some View {
        ZStack(alignment: .leading) {
            content(for: tab)
                .environment(\.keyboardTab, tab)
                .id(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if sidebar.isShown {
                // While the sidebar's out, a click on the page only puts it
                // away; it never reaches what's under it (a Play button, say).
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { sidebar.hide() }
                    .transition(.opacity)
                MacSidebar(
                    tabs: shownTabs, selected: tab,
                    keyboardTab: keyboard.inSidebar ? keyboard.sidebarHighlight : nil,
                    keyboardOnSettings: keyboard.inSidebar && keyboard.settingsHighlighted,
                    choose: { tab = $0 },
                    openSettings: { openSettings() }
                )
                // Back in when the mouse leaves it, if the mouse brought it out.
                .onHover { inside in
                    if !inside, sidebar.revealedByMouse { sidebar.hide() }
                }
                .transition(.move(edge: .leading))
                .zIndex(1)
            } else {
                // The mouse reaching the window's left edge brings it out.
                Color.clear
                    .frame(width: 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside, WindowCovers.shared.covers.isEmpty { sidebar.show(byMouse: true) }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if SidecarHint.shared.isShown, WindowCovers.shared.covers.isEmpty {
                SidecarScrollHintView()
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Show or hide the sidebar (⌃⌘S)")
            }
        }
        // Closed by its own button or the menu while the keyboard was in it.
        .onChange(of: sidebar.isShown) { _, shown in
            if !shown, keyboard.inSidebar {
                clearKeyboardInSidebar()
                restoreKeyboardFocus()
            }
        }
    }
    #endif

    #if os(iOS)
    /// What the More tab shows: downloads running or failed, when the
    /// Downloads tab is one of those under More (past the bar's first four).
    private var moreTabDownloadState: MoreTabDownloadIndicator.State {
        let tabs = shownTabs
        guard tabs.count > 5, let position = tabs.firstIndex(of: .downloads), position >= 4 else { return .idle }
        // The counts, not the records: see `DownloadStore.downloadingCount`.
        let store = DownloadStore.shared
        if store.hasFailed { return .failed }
        if store.downloadingCount > 0 { return .downloading }
        return .idle
    }
    #endif

    /// The tabs themselves, apart from the modifiers below so the compiler
    /// can type-check the body in reasonable time.
    private var tabView: some View {
        #if os(macOS)
        macTabs
        #else
        TabView(selection: $tab) {
            ForEach(shownTabs, id: \.self) { item in
                tab(for: item)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #endif
    }

    #if !os(macOS)
    private func tab(for item: AppTab) -> some TabContent<AppTab> {
        let role: TabRole? = item == .search ? .search : nil
        #if os(iOS)
        // Only iPhone and iPad have downloads to count.
        return Tab(item.title, systemImage: item.systemImage, value: item, role: role) {
            content(for: item)
        }
        .badge(badgeCount(for: item))
        #else
        return Tab(item.title, systemImage: item.systemImage, value: item, role: role) {
            content(for: item)
        }
        #endif
    }
    #endif

    /// Downloads in progress, on the Downloads tab (and so on More when it's
    /// there). Zero shows no badge.
    #if os(iOS)
    private func badgeCount(for tab: AppTab) -> Int {
        tab == .downloads ? DownloadStore.shared.downloadingCount : 0
    }
    #endif

    @ViewBuilder
    private func content(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            BrowseStack(path: $homePath) { HomeView() }
                #if os(iOS)
                // Home is always there, so it hosts the More tab's indicator.
                .background(MoreTabDownloadIndicator(state: moreTabDownloadState))
                #endif
        case .movies: BrowseStack { TypeGridView(kind: .movie) }
        case .shows: BrowseStack { TypeGridView(kind: .series) }
        case .anime: BrowseStack { AnimeView() }
        case .upcoming: BrowseStack { UpcomingView() }
        case .music: BrowseStack { MusicView() }
        case .audiobooks: BrowseStack { AudiobooksView() }
        case .liveTV: BrowseStack { LiveTVView() }
        case .channels: BrowseStack { ChannelsView() }
        case .library: BrowseStack { LibraryView() }
        case .downloads:
            #if os(iOS)
            BrowseStack { DownloadsView() }
            #else
            EmptyView()
            #endif
        case .settings: BrowseStack { SettingsView() }
        case .search: BrowseStack { SearchView() }
        }
    }

    /// Opens or plays whatever the Top Shelf asked for. Pages open on the Home
    /// tab's stack so Back returns somewhere sensible.
    private func followPendingLinks() async {
        guard let client = session.client else { return }
        if let id = session.router.pendingPlayItemId {
            session.router.clear()
            if let item = try? await client.item(id) {
                linkedPlayback = PlaybackRequest(itemId: item.id, startTicks: item.userData?.playbackPositionTicks ?? 0)
            }
            return
        }
        #if os(iOS)
        if session.router.pendingDownloads {
            session.router.clear()
            tab = .downloads
            return
        }
        #endif
        if let id = session.router.pendingChannelId {
            session.router.clear()
            // On a cold launch the channels aren't loaded yet.
            if ChannelTuner.live(channelId: id) == nil { await session.refreshChannels() }
            if let live = ChannelTuner.live(channelId: id) {
                linkedPlayback = PlaybackRequest(entry: live.entry)
            }
            return
        }
        if let id = session.router.pendingItemId {
            session.router.clear()
            if let item = try? await client.item(id) {
                tab = .home
                homePath = NavigationPath()
                homePath.append(item)
            }
        }
    }
}

#if os(iOS)
/// On iPhone, tabs past the fifth sit under iOS's More tab, whose own
/// navigation bar stacks above the tab's. Once the tab has pushed a page,
/// this hides More's bar so there's one back button, the tab's, which steps
/// back a page. At the tab's top level More's "back to the list" shows again.
/// SwiftUI's toolbar visibility doesn't reach More's bar, so this goes
/// through UIKit; tabs that aren't under More are left alone.
private struct MoreBarHider: UIViewControllerRepresentable {
    var hidden: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // Usually in the hierarchy already, so the bar changes in the same
        // update as the push and the page slides in at its final height.
        // Animating it, or waiting a turn, let the page arrive low and then
        // jump up as the bar left. The first time, the controller joins the
        // hierarchy after this runs, so that one waits.
        if !Self.apply(hidden, from: controller) {
            let hidden = hidden
            DispatchQueue.main.async { [weak controller] in
                guard let controller else { return }
                Self.apply(hidden, from: controller)
            }
        }
    }

    /// Sets the More bar's visibility when `controller` is under More.
    /// Returns false when it isn't in a tab bar controller yet.
    @discardableResult
    private static func apply(_ hidden: Bool, from controller: UIViewController) -> Bool {
        guard let more = controller.tabBarController?.moreNavigationController else { return false }
        var ancestor = controller.parent
        while let current = ancestor, current !== more {
            ancestor = current.parent
        }
        if ancestor === more, more.isNavigationBarHidden != hidden {
            more.setNavigationBarHidden(hidden, animated: false)
        }
        return true
    }
}
#endif

#if os(iOS)
/// Pulses the iPhone's More tab while a download under it runs, in red once
/// one has failed. Tab bar icons can't be animated, so the icon is swapped
/// between full and faded copies on a timer; with Reduce Motion it stays
/// steady. Goes through UIKit because the More tab belongs to it.
private struct MoreTabDownloadIndicator: UIViewControllerRepresentable {
    enum State: Equatable {
        case idle, downloading, failed
    }

    var state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    final class Coordinator {
        var timer: Timer?
        var original: (image: UIImage?, selected: UIImage?)?
        var dimmed = false
        var shownState: State = .idle

        deinit { timer?.invalidate() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let state = state
        let reduceMotion = reduceMotion
        let coordinator = context.coordinator
        // The controller joins the hierarchy after the first update.
        DispatchQueue.main.async { [weak controller] in
            guard let tabs = controller?.tabBarController,
                  tabs.traitCollection.horizontalSizeClass == .compact else { return }
            Self.apply(state, reduceMotion: reduceMotion, to: tabs.moreNavigationController.tabBarItem, coordinator: coordinator)
        }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        if let tabs = controller.tabBarController, let original = coordinator.original {
            tabs.moreNavigationController.tabBarItem.image = original.image
            tabs.moreNavigationController.tabBarItem.selectedImage = original.selected
        }
    }

    private static func apply(_ state: State, reduceMotion: Bool, to item: UITabBarItem, coordinator: Coordinator) {
        guard state != coordinator.shownState else { return }
        coordinator.shownState = state
        coordinator.timer?.invalidate()
        coordinator.timer = nil
        if coordinator.original == nil {
            coordinator.original = (item.image, item.selectedImage)
        }
        guard state != .idle, let base = coordinator.original?.image else {
            item.image = coordinator.original?.image
            item.selectedImage = coordinator.original?.selected
            return
        }
        // Full and faded copies: the system's tint while downloading, red
        // once a download has failed.
        let full: UIImage
        let faded: UIImage
        if state == .failed {
            full = base.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            faded = base.withTintColor(.systemRed.withAlphaComponent(0.35), renderingMode: .alwaysOriginal)
        } else {
            full = base
            faded = base.withTintColor(.secondaryLabel.withAlphaComponent(0.3), renderingMode: .alwaysOriginal)
        }
        let show: (Bool) -> Void = { dim in
            item.image = dim ? faded : full
            item.selectedImage = dim ? faded : full
        }
        coordinator.dimmed = false
        show(false)
        guard !reduceMotion else { return }
        coordinator.timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator else { return }
                coordinator.dimmed.toggle()
                show(coordinator.dimmed)
            }
        }
    }
}
#endif

/// Pushes an item's page onto the surrounding browse stack.
#if os(macOS)
/// The Mac's keyboard navigation: the arrows and Return go to the page
/// showing (a page registers what they do there), and left past a page's
/// edge moves into the sidebar, as on Apple TV. Owned by `MainTabView`.
@MainActor
@Observable
final class KeyboardNavigation {
    enum Key {
        case up, down, left, right, select, exit
    }

    /// The keyboard is in the sidebar, moving between tabs.
    var inSidebar = false
    /// The tab the keyboard is on in the sidebar, opened with Return.
    var sidebarHighlight: AppTab?
    /// The Settings button under the tabs is highlighted instead of a tab.
    var settingsHighlighted = false

    @ObservationIgnored private var handlers: [AppTab: (Key) -> KeyPress.Result] = [:]

    /// What the keys do on `tab`'s top page. Return `.ignored` for a key
    /// the page doesn't use, such as left at its leading edge.
    func register(_ tab: AppTab, handler: @escaping (Key) -> KeyPress.Result) {
        handlers[tab] = handler
    }

    func unregister(_ tab: AppTab) {
        handlers[tab] = nil
    }

    func handler(for tab: AppTab) -> ((Key) -> KeyPress.Result)? {
        handlers[tab]
    }
}
#endif

struct OpenItemAction {
    let open: (BaseItem) -> Void
    /// Pushes any page the stack knows (a person, say), for code that has
    /// the value a link would carry.
    var push: (any Hashable) -> Void = { _ in }

    func callAsFunction(_ item: BaseItem) { open(item) }
}

extension EnvironmentValues {
    @Entry var openItem: OpenItemAction? = nil
}

/// A navigation stack that knows how to open items, libraries and people.
/// Given a path binding, the owner can push pages into it.
struct BrowseStack<Root: View>: View {
    var path: Binding<NavigationPath>? = nil
    @ViewBuilder var root: () -> Root
    /// Used when the owner does not supply a path.
    @State private var ownPath = NavigationPath()
    #if os(macOS)
    @Environment(KeyboardNavigation.self) private var keyboard: KeyboardNavigation?
    @Environment(\.keyboardTab) private var keyboardTab
    #endif

    /// The stack's path: the owner's, or its own.
    private var currentPath: Binding<NavigationPath> { path ?? $ownPath }

    @Environment(AppSession.self) private var session
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// An opening or ending playing, and no page showing its full panel:
    /// the slim one floats on the right of whatever's open. Not on a phone,
    /// which has no room beside the page.
    private var showsMiniPlayer: Bool {
        #if os(iOS)
        guard sizeClass == .regular else { return false }
        #endif
        return session.themeDeck.isActive && session.themePanelPage == nil
    }

    private var miniInset: CGFloat { showsMiniPlayer ? ThemeMiniPlayer.inset : 0 }

    /// The slim panel goes on each page, the stack's first and every one
    /// pushed: on the Apple TV a pushed page covers anything laid over the
    /// stack itself. Only the top page shows, so only one is seen.
    private var miniPlayerHost: ThemeMiniPlayerHost {
        ThemeMiniPlayerHost(shows: showsMiniPlayer, openAction: openAction)
    }

    /// Lets menus and the Mac keyboard, which can't use navigation links,
    /// push pages.
    private var openAction: OpenItemAction {
        let path = currentPath
        return OpenItemAction(open: { path.wrappedValue.append($0) }, push: { path.wrappedValue.append($0) })
    }

    var body: some View {
        let path = currentPath
        NavigationStack(path: path) { content }
            .environment(\.openItem, openAction)
            .environment(\.themeMiniInset, miniInset)
            #if os(iOS)
            .background(MoreBarHider(hidden: !path.wrappedValue.isEmpty))
            #endif
    }

    private var content: some View {
        root()
            .modifier(miniPlayerHost)
            .keyboardPage()
            .navigationDestination(for: BaseItem.self) { item in
                pushed(destination(for: item))
            }
            .navigationDestination(for: PersonInfo.self) { person in
                pushed(PersonView(person: person))
            }
            .navigationDestination(for: Audiobook.self) { book in
                pushed(AudiobookView(book: book))
            }
            .navigationDestination(for: AudiobookShelf.self) { shelf in
                pushed(AudiobookShelfView(shelf: shelf))
            }
            // A title to request from Seerr, pushed as a library title's page is.
            .navigationDestination(for: SeerrTitle.self) { title in
                pushed(SeerrTitlePage(title: title))
            }
    }

    /// A page pushed on the stack. Pushed pages don't inherit what's set on
    /// the stack or the tab, so it's passed on: the open action (Return on a
    /// card, menus), and on the Mac the keyboard's tab and page.
    @ViewBuilder
    private func pushed(_ page: some View) -> some View {
        #if os(macOS)
        page
            .environment(\.openItem, openAction)
            .environment(\.themeMiniInset, miniInset)
            .modifier(miniPlayerHost)
            .keyboardPage(pushed: true)
            .environment(\.keyboardTab, keyboardTab)
            .environment(keyboard)
        #else
        page
            .environment(\.openItem, openAction)
            .environment(\.themeMiniInset, miniInset)
            .modifier(miniPlayerHost)
        #endif
    }

    @ViewBuilder
    private func destination(for item: BaseItem) -> some View {
        switch item.kind {
        case .collectionFolder, .userView, .folder, .boxSet:
            if item.collectionType == "livetv" {
                LiveTVView()
            } else if item.collectionType == "music" {
                MusicView(library: item)
            } else if item.collectionType == "books" {
                AudiobooksView(library: item)
            } else {
                LibraryGridView(parent: item)
            }
        case .musicAlbum:
            AlbumView(item: item)
        case .playlist:
            if item.mediaType == "Video" {
                VideoPlaylistView(playlist: item)
            } else {
                AlbumView(item: item)
            }
        case .musicArtist:
            ArtistView(artist: item)
        case .audioBook:
            // Found by Search: the file as a book of its own.
            AudiobookView(book: Audiobook(item: item))
        case .audio:
            // A song opens its album, where it can be played in context.
            if let albumId = item.albumId {
                AlbumView(item: BaseItem(id: albumId, name: item.album, type: ItemKind.musicAlbum.rawValue))
            } else {
                ItemDetailView(item: item)
            }
        default:
            ItemDetailView(item: item)
        }
    }
}
