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
    case home, movies, shows, anime, music, audiobooks, liveTV, library, downloads, settings, search

    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .anime: "Anime"
        case .music: "Music"
        case .audiobooks: "Audiobooks"
        case .liveTV: "Live TV"
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
        case .music: "music.note"
        case .audiobooks: "books.vertical.fill"
        case .liveTV: "antenna.radiowaves.left.and.right"
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
        return order.filter { !hidden.contains($0) && session.hasContent(for: $0) && ($0 != .downloads || downloadsEnabled) }
    }

    var body: some View {
        @Bindable var player = session.music
        @Bindable var audiobooks = session.audiobooks
        tabView
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        // The song or book playing, under the tab bar on every tab.
        .tabViewBottomAccessory(isEnabled: session.isAudioLoaded) {
            AudioAccessory()
        }
        #endif
        #if os(tvOS)
        // The remote's Play/Pause pauses music or a book from anywhere
        // (the players and videos handle it themselves while showing).
        .onPlayPauseCommand {
            session.toggleAudio()
        }
        #endif
        #if os(macOS)
        // Settings lives in its own window on the Mac (⌘,); this opens it
        // from the foot of the sidebar too, under the song or book playing.
        .tabViewSidebarBottomBar {
            if session.isAudioLoaded {
                AudioAccessory()
                Divider()
            }
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Settings (⌘,)")
            // Where it is, for the keyboard's outline (below the last tab).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                keyboard.settingsButtonFrame = frame
                #if DEBUG
                sidebarDebugLog.notice("settings button frame=\(String(describing: frame), privacy: .public)")
                #endif
            }
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
        .background {
            Color.clear
                .appCover(item: $linkedPlayback, onDismiss: {
                    // Progress changed, so Continue Watching and Next Up should too.
                    session.userDataChanged()
                }) { request in
                    PlayerView(request: request) { linkedPlayback = nil }
                }
        }
        .task {
            guard let client = session.client else { return }
            await session.refreshUserConfiguration()
            let views = (try? await client.userViews()) ?? []
            session.noteLibraries(views)
            await session.detectAnimeLibraries(among: views)
            await followPendingLinks()
        }
        .onChange(of: session.router.pendingItemId) { _, _ in
            Task { await followPendingLinks() }
        }
        .onChange(of: session.router.pendingPlayItemId) { _, _ in
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
        .onAppear { claimKeyboard() }
        .onChange(of: tab) { _, _ in
            KeyboardTargets.shared.clearSelection()
            claimKeyboard()
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
        .overlay {
            // The keyboard's tab in the sidebar, before Return opens it,
            // measured from the window's top left, so it ignores the safe area.
            ZStack(alignment: .topLeading) {
                if let frame = keyboard.highlightFrame {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.tint, lineWidth: 2.5)
                        .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .animation(.easeOut(duration: 0.15), value: frame)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        #endif
    }

    #if os(macOS)
    /// Takes the keyboard once the view is in its window (set as it
    /// appears, focus doesn't take), so no click is needed first.
    private func claimKeyboard() {
        Task { keyboardFocused = true }
        #if DEBUG
        Task {
            try? await Task.sleep(for: .seconds(2))
            sidebarDebugLog.notice("window at launch tabs=\(shownTabs.map(\.rawValue).joined(separator: ","), privacy: .public)\n\(WindowSidebar.debugDescribeWindow(), privacy: .public)")
            let appMenu = NSApp.mainMenu?.items.first?.submenu?.items.map { "\($0.title)[\($0.keyEquivalent)|\($0.keyEquivalentModifierMask.rawValue)|enabled=\($0.isEnabled)]" } ?? []
            sidebarDebugLog.notice("app menu: \(appMenu.joined(separator: "  "), privacy: .public)")
        }
        #endif
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
                measureHighlight()
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
        #if DEBUG
        sidebarDebugLog.notice("enterSidebar isShown=\(String(describing: WindowSidebar.isShown), privacy: .public)\n\(WindowSidebar.debugDescribeWindow(), privacy: .public)")
        #endif
        keyboard.inSidebar = true
        keyboard.sidebarHighlight = tab
        // Slides out if hidden; it's put away again on the way out.
        WindowSidebar.setShown(true)
        measureHighlight()
        // Again once the sidebar has slid out.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            measureHighlight()
        }
    }

    /// Where the keyboard's tab sits in the sidebar, for drawing its outline.
    /// The system draws the sidebar's rows itself and ignores styling on
    /// our tab labels, so the outline is drawn over the row instead.
    private func measureHighlight() {
        if keyboard.inSidebar, keyboard.settingsHighlighted {
            keyboard.highlightFrame = keyboard.settingsButtonFrame
            return
        }
        guard keyboard.inSidebar, let highlight = keyboard.sidebarHighlight,
              let index = shownTabs.firstIndex(of: highlight) else {
            keyboard.highlightFrame = nil
            return
        }
        keyboard.highlightFrame = WindowSidebar.rowFrame(index)
    }

    private func leaveSidebar() {
        #if DEBUG
        sidebarDebugLog.notice("leaveSidebar isShown=\(String(describing: WindowSidebar.isShown), privacy: .public)")
        #endif
        keyboard.inSidebar = false
        keyboard.sidebarHighlight = nil
        keyboard.settingsHighlighted = false
        keyboard.highlightFrame = nil
        // As on Apple TV, the sidebar goes away once the keyboard leaves it,
        // however it came to be open. Collapsing it takes the window's key
        // focus with it, so the content is given it back, now and again
        // once the slide is over.
        WindowSidebar.setShown(false)
        restoreKeyboardFocus()
    }

    /// Gives the keyboard back to the page after something took the window's
    /// key focus with it (the sidebar collapsing, a page closing): now, and
    /// again once the animation is over.
    private func restoreKeyboardFocus() {
        WindowSidebar.returnKeyboardToContent()
        claimKeyboard()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            WindowSidebar.returnKeyboardToContent()
            claimKeyboard()
            #if DEBUG
            sidebarDebugLog.notice("restoreKeyboardFocus firstResponder=\(String(describing: (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder.map { type(of: $0) }), privacy: .public)")
            #endif
        }
    }
    #endif

    #if os(iOS)
    /// What the More tab shows: downloads running or failed, when the
    /// Downloads tab is one of those under More (past the bar's first four).
    private var moreTabDownloadState: MoreTabDownloadIndicator.State {
        let tabs = shownTabs
        guard tabs.count > 5, let position = tabs.firstIndex(of: .downloads), position >= 4 else { return .idle }
        let records = DownloadStore.shared.records
        if records.contains(where: { $0.state == .failed }) { return .failed }
        if records.contains(where: { $0.state == .downloading }) { return .downloading }
        return .idle
    }
    #endif

    /// The tabs themselves, apart from the modifiers below so the compiler
    /// can type-check the body in reasonable time.
    private var tabView: some View {
        TabView(selection: $tab) {
            ForEach(shownTabs, id: \.self) { item in
                tab(for: item)
            }
        }
    }

    private func tab(for item: AppTab) -> some TabContent<AppTab> {
        let role: TabRole? = item == .search ? .search : nil
        #if os(iOS)
        // Only iPhone and iPad have downloads to count.
        return Tab(item.title, systemImage: item.systemImage, value: item, role: role) {
            content(for: item)
        }
        .badge(badgeCount(for: item))
        #elseif os(macOS)
        return Tab(item.title, systemImage: item.systemImage, value: item, role: role) {
            content(for: item)
                .environment(\.keyboardTab, item)
        }
        #else
        return Tab(item.title, systemImage: item.systemImage, value: item, role: role) {
            content(for: item)
        }
        #endif
    }

    /// Downloads in progress, on the Downloads tab (and so on More when it's
    /// there). Zero shows no badge.
    #if os(iOS)
    private func badgeCount(for tab: AppTab) -> Int {
        tab == .downloads ? DownloadStore.shared.records.filter { $0.state == .downloading }.count : 0
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
        case .music: BrowseStack { MusicView() }
        case .audiobooks: BrowseStack { AudiobooksView() }
        case .liveTV: BrowseStack { LiveTVView() }
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
    /// Where the highlighted tab's row is, in the window from its top left.
    var highlightFrame: CGRect?
    /// The Settings button under the tabs is highlighted instead of a tab.
    var settingsHighlighted = false
    /// Where that button is, for its outline.
    @ObservationIgnored var settingsButtonFrame: CGRect?

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
            #if os(iOS)
            .background(MoreBarHider(hidden: !path.wrappedValue.isEmpty))
            #endif
    }

    private var content: some View {
        root()
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
    }

    /// A page pushed on the stack. Pushed pages don't inherit what's set on
    /// the stack or the tab, so it's passed on: the open action (Return on a
    /// card, menus), and on the Mac the keyboard's tab and page.
    @ViewBuilder
    private func pushed(_ page: some View) -> some View {
        #if os(macOS)
        page
            .environment(\.openItem, openAction)
            .keyboardPage(pushed: true)
            .environment(\.keyboardTab, keyboardTab)
            .environment(keyboard)
        #else
        page
            .environment(\.openItem, openAction)
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
