//
//  Components.swift
//  AsterFIN
//
//  Lockups, shelves and small pieces shared by the browsing screens, styled
//  after the Apple TV app.
//

import SwiftUI

/// Card and grid sizes. tvOS sizes are for a 1920-point-wide screen seen
/// from the sofa; iOS sizes fit three posters (or two landscape cards)
/// across a phone, and adaptive grids add columns on an iPad.
enum Lockup {
    #if os(tvOS)
    static let landscapeWidth: CGFloat = 400
    static let landscapeHeight: CGFloat = 225
    static let posterWidth: CGFloat = 240
    static let posterHeight: CGFloat = 360
    /// Album and playlist artwork.
    static let squareWidth: CGFloat = 240
    /// Live TV channel tiles.
    static let channelWidth: CGFloat = 280
    static let cornerRadius: CGFloat = 14
    static let gridSpacing: CGFloat = 40
    static let gridRowSpacing: CGFloat = 48
    /// The inset from the screen's left and right edges.
    static let screenPadding: CGFloat = 80
    static let shelfSpacing: CGFloat = 36
    /// Room above and below a shelf's cards for the focused card to grow into.
    static let shelfVerticalPadding: CGFloat = 30
    /// Cast and crew: the round photo, the column under it, and the gap.
    static let personPhotoSize: CGFloat = 200
    static let personWidth: CGFloat = 220
    static let personSpacing: CGFloat = 28
    /// Between the photo and the name.
    static let personLabelSpacing: CGFloat = 10
    /// Icon-only buttons beside the text buttons on a detail page (heart,
    /// watched, more): the icon's box and font, chosen so the buttons come
    /// out as tall as the text ones.
    static let iconButtonSize: CGFloat = 44
    static let iconButtonFont: Font = .title3
    /// Above a page's title, and below its last row.
    static let pageTopPadding: CGFloat = 40
    static let pageBottomPadding: CGFloat = 80
    /// Between a page's sections and shelves.
    static let sectionSpacing: CGFloat = 30
    /// Between a page's action buttons.
    static let buttonSpacing: CGFloat = 20
    /// The height given to a page's "nothing here" message.
    static let emptyStateHeight: CGFloat = 500
    /// A library's tile on the Library and Anime pages.
    static let libraryTileWidth: CGFloat = 440
    static let libraryTileHeight: CGFloat = 248
    /// Under a grid card's artwork: the gap, the title and the year line,
    /// for the collection grid's fixed cell height.
    static let gridTitleHeight: CGFloat = 80
    #else
    static let landscapeWidth: CGFloat = 175
    static let landscapeHeight: CGFloat = 98
    static let posterWidth: CGFloat = 110
    static let posterHeight: CGFloat = 165
    static let squareWidth: CGFloat = 110
    static let channelWidth: CGFloat = 110
    static let cornerRadius: CGFloat = 10
    static let gridSpacing: CGFloat = 12
    static let gridRowSpacing: CGFloat = 20
    static let screenPadding: CGFloat = 16
    static let shelfSpacing: CGFloat = 12
    static let shelfVerticalPadding: CGFloat = 8
    static let personPhotoSize: CGFloat = 80
    static let personWidth: CGFloat = 96
    static let personSpacing: CGFloat = 12
    static let personLabelSpacing: CGFloat = 6
    /// The height of a headline label, so icon and text buttons match.
    static let iconButtonSize: CGFloat = 22
    static let iconButtonFont: Font = .headline
    static let pageTopPadding: CGFloat = 8
    static let pageBottomPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let buttonSpacing: CGFloat = 12
    static let emptyStateHeight: CGFloat = 320
    /// The size of the landscape cards in the shelves beside them.
    static let libraryTileWidth: CGFloat = landscapeWidth
    static let libraryTileHeight: CGFloat = landscapeHeight
    #endif
}

extension Lockup {
    /// The width in pixels to ask for a picture that fills the screen. tvOS
    /// lays out 1920 points across at the TV's scale, so that's 3840 on a 4K
    /// set and 1920 on a 1080p one; iOS keeps 1920.
    static func fullScreenImageWidth(displayScale: CGFloat) -> Int {
        #if os(tvOS)
        Int(1920 * displayScale)
        #else
        1920
        #endif
    }

    /// Pixels to ask for a poster card: its width at the sharpest screen it
    /// shows on (2× on a 4K TV, 3× on iPhone), and nothing more.
    #if os(tvOS)
    static let posterImageWidth = 480
    #else
    static let posterImageWidth = 330
    #endif

    /// A poster card's picture. At quality 80 it's about 40% smaller than at
    /// 90, with no difference you can see at card size. Cards and the grid's
    /// look-ahead both use this, so they ask for the same URL and share the cache.
    static func posterImageURL(for item: BaseItem, client: JellyfinClient?) -> URL? {
        client?.posterURL(for: item, width: posterImageWidth, quality: 80)
    }
}

// MARK: - Shelf

/// A titled horizontal row of lockups.
struct Shelf<Item: Identifiable & Hashable, Content: View>: View {
    let title: String
    let items: [Item]
    var spacing: CGFloat = Lockup.shelfSpacing
    /// Mac: the item the keyboard has selected in this shelf, highlighted
    /// and scrolled into view (see `isKeyboardSelected`); nil for none.
    var keyboardSelection: Item.ID?
    @ViewBuilder var content: (Item) -> Content

    @Environment(\.sectionLead) private var lead

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, Lockup.screenPadding)
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: spacing) {
                            ForEach(items) { item in
                                content(item)
                                    .environment(\.isKeyboardSelected, keyboardSelection == item.id)
                                    // The section's first card, for focus after a tab is picked.
                                    .environment(\.itemLead, item.id == items.first?.id ? lead : nil)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, Lockup.screenPadding)
                        .padding(.vertical, Lockup.shelfVerticalPadding)
                    }
                    .scrollClipDisabled()
                    .onChange(of: keyboardSelection) { _, selection in
                        guard let selection else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            reader.scrollTo(selection)
                        }
                    }
                }
            }
            .tvFocusSection()
        }
    }
}

/// The first card of the section a show's page has just switched to (its
/// first episode, song, related show or person), for focus to go to after a
/// tab is picked rather than back up the page.
struct SectionLead {
    let focus: FocusState<Bool>.Binding
    /// The page's focus scope, and whether the lead is its preferred focus
    /// right now (just after a tab was picked).
    let scope: Namespace.ID
    let active: Bool
}

extension View {
    /// Marks this as the section's lead, when `lead` is given.
    @ViewBuilder
    func sectionLead(_ lead: SectionLead?) -> some View {
        if let lead {
            #if os(tvOS)
            focused(lead.focus)
                .prefersDefaultFocus(lead.active, in: lead.scope)
            #else
            focused(lead.focus)
            #endif
        } else {
            self
        }
    }
}

extension EnvironmentValues {
    /// Set on a show page's section: its first card takes it (`SectionLead`).
    @Entry var sectionLead: SectionLead? = nil
    /// Handed by a shelf to its first item only: the lockup puts it on its
    /// link, the view that takes focus.
    @Entry var itemLead: SectionLead? = nil

    /// Mac: this lockup is the one the keyboard has selected. The Mac has no
    /// focus engine to move between cards, so pages with shelves keep their
    /// own selection, moved with the arrow keys, and lockups draw it.
    @Entry var isKeyboardSelected = false
}

extension View {
    /// A lockup's artwork as the keyboard's selection: outlined and lifted,
    /// like a focused card on Apple TV.
    func keyboardSelectionHighlight(_ selected: Bool) -> some View {
        overlay {
            if selected {
                Rectangle()
                    .strokeBorder(.white, lineWidth: 3)
            }
        }
        .scaleEffect(selected ? 1.05 : 1)
        .shadow(color: .black.opacity(selected ? 0.5 : 0), radius: 10, y: 4)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

// MARK: - Lockups

extension EnvironmentValues {
    /// Set by the Apple TV's UIKit-hosted grid's header and footer: a lockup
    /// opens its title through `openItem`, as a NavigationLink can't find
    /// the stack from a hosted root.
    @Entry var opensItemsWithAction = false
    /// Set in the Apple TV grid's cells: the cell itself takes focus, opens
    /// the title and shows the menu, so the lockup draws its artwork plain,
    /// lifted when `hostedCellFocused` says the cell has focus.
    @Entry var lockupsAreStatic = false
    @Entry var hostedCellFocused = false
}

/// A lockup's link to its title: a NavigationLink, or a Button through
/// `openItem` where a NavigationLink can't reach the stack, or just the
/// artwork where the cell around it does the work.
struct ItemLink<Label: View>: View {
    let item: BaseItem
    @ViewBuilder var label: () -> Label

    @Environment(\.opensItemsWithAction) private var opensWithAction
    @Environment(\.lockupsAreStatic) private var isStatic
    @Environment(\.hostedCellFocused) private var cellFocused
    @Environment(\.openItem) private var openItem

    var body: some View {
        if isStatic {
            label()
                .scaleEffect(cellFocused ? 1.1 : 1)
                .shadow(color: .black.opacity(cellFocused ? 0.5 : 0), radius: 16, y: 10)
                .animation(.easeOut(duration: 0.18), value: cellFocused)
        } else if opensWithAction, let openItem {
            Button(action: { openItem(item) }, label: label)
        } else {
            NavigationLink(value: item, label: label)
        }
    }
}

/// 16:9 artwork with a title underneath, the Apple TV app's standard lockup.
struct LandscapeLockup: View {
    let item: BaseItem
    var showSeriesTitle = true
    var width: CGFloat = Lockup.landscapeWidth
    /// Lets a parent move focus to this lockup by item id.
    var focus: FocusState<String?>.Binding? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.isKeyboardSelected) private var isKeyboardSelected
    @State private var editedUserData: UserItemData?

    private var height: CGFloat { width * 9 / 16 }
    private var shown: BaseItem { item.withUserData(editedUserData) }

    /// The section's first card, for focus after a tab is picked.
    @Environment(\.itemLead) private var itemLead

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ItemLink(item: item) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: session.client?.landscapeURL(for: item, width: 800), systemImage: item.kind == .episode ? "tv" : "film")
                        .frame(width: width, height: height)
                    if let progress = shown.progressFraction {
                        ProgressBar(progress: progress)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }
                    if item.kind == .episode, shown.userData?.played != true, shown.progressFraction == nil {
                        UnplayedBadge()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(12)
                    }
                }
                .frame(width: width, height: height)
            }
            .sectionLead(itemLead)
            .cardButtonStyle()
            .keyboardSelectionHighlight(isKeyboardSelected)
            .keyboardTarget(opening: item)
            .itemActions(for: item, userData: $editedUserData.or(item.userData))
            .optionallyFocused(focus, equals: item.id)
            .accessibilityLabel(accessibilityTitle)
            .onChange(of: item.userData) { _, _ in editedUserData = nil }

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    private var primaryTitle: String {
        if item.kind == .episode, showSeriesTitle, let series = item.seriesName {
            return series
        }
        return item.displayTitle
    }

    private var accessibilityTitle: String {
        [primaryTitle, subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    private var subtitle: String? {
        switch item.kind {
        case .episode:
            let code = item.episodeCode
            let name = showSeriesTitle ? item.name : nil
            let parts = [code, name].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .series:
            return item.yearText
        case .movie:
            return item.yearText
        case .musicVideo:
            // The show it's from (the OP/ED plugin writes it as the album),
            // and who sings it: "The Apothecary Diaries · Uru".
            let artists = (item.artists ?? []).filter { !$0.isEmpty }.joined(separator: ", ")
            let parts = [item.album, artists.isEmpty ? nil : artists].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        default:
            return nil
        }
    }
}

/// 2:3 poster artwork with the title underneath.
struct PosterLockup: View {
    let item: BaseItem
    var width: CGFloat = Lockup.posterWidth
    /// Lets a parent move focus to this lockup by item id.
    var focus: FocusState<String?>.Binding? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.isKeyboardSelected) private var isKeyboardSelected
    @State private var editedUserData: UserItemData?

    private var shown: BaseItem { item.withUserData(editedUserData) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ItemLink(item: item) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: Lockup.posterImageURL(for: item, client: session.client), systemImage: item.kind == .series ? "tv" : "film")
                        .frame(width: width, height: width * 1.5)
                    if let progress = shown.progressFraction {
                        ProgressBar(progress: progress)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                }
                .frame(width: width, height: width * 1.5)
            }
            .cardButtonStyle()
            .optionallyFocused(focus, equals: item.id)
            .keyboardSelectionHighlight(isKeyboardSelected)
            .keyboardTarget(opening: item)
            .itemActions(for: item, userData: $editedUserData.or(item.userData))
            .accessibilityLabel(item.yearText.map { "\(item.displayTitle), \($0)" } ?? item.displayTitle)
            .onChange(of: item.userData) { _, _ in editedUserData = nil }

            Text(item.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            if let year = item.yearText {
                Text(year)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Long-press actions

extension View {
    /// Adds the clickpad long-press menu for titles that have one. `userData`
    /// holds the lockup's local copy, so a change shows on it at once.
    @ViewBuilder
    func itemActions(for item: BaseItem, userData: Binding<UserItemData?>) -> some View {
        if ItemActionsMenu.supports(item) {
            contextMenu { ItemActionsMenu(item: item, userData: userData) }
        } else {
            self
        }
    }
}

extension BaseItem {
    /// This item with locally changed user data, when there is any.
    func withUserData(_ edited: UserItemData?) -> BaseItem {
        guard let edited else { return self }
        var copy = self
        copy.userData = edited
        return copy
    }
}

extension Binding where Value == UserItemData? {
    /// Reads `fallback` until something is written.
    func or(_ fallback: UserItemData?) -> Binding<UserItemData?> {
        Binding(get: { wrappedValue ?? fallback }, set: { wrappedValue = $0 })
    }
}

/// Play, jump to the show or season, and toggle watched and favourite.
struct ItemActionsMenu: View {
    let item: BaseItem
    @Binding var userData: UserItemData?

    @Environment(AppSession.self) private var session
    @Environment(\.openItem) private var openItem

    static func supports(_ item: BaseItem) -> Bool {
        switch item.kind {
        case .movie, .series, .season, .episode, .video, .musicVideo, .recording: return true
        default: return false
        }
    }

    private var resumeTicks: Int64 { userData?.playbackPositionTicks ?? 0 }
    private var played: Bool { userData?.played ?? false }
    private var favorite: Bool { userData?.isFavorite ?? false }
    private var playsItself: Bool { item.kind != .series && item.kind != .season }

    var body: some View {
        if playsItself {
            Button {
                play(from: resumeTicks)
            } label: {
                Label(resumeTicks > 0 ? "Resume" : "Play", systemImage: "play.fill")
            }
            if resumeTicks > 0 {
                Button {
                    play(from: 0)
                } label: {
                    Label("Play from Beginning", systemImage: "arrow.counterclockwise")
                }
            }
        }
        if let openItem {
            // Stub items are enough: the title page loads the full item.
            if item.kind == .episode || item.kind == .season, let seriesId = item.seriesId {
                Button {
                    openItem(BaseItem(id: seriesId, name: item.seriesName, type: ItemKind.series.rawValue))
                } label: {
                    Label("Go to Series", systemImage: "tv")
                }
            }
            if item.kind == .episode, let seasonId = item.seasonId {
                Button {
                    openItem(BaseItem(id: seasonId, name: item.seasonName, type: ItemKind.season.rawValue))
                } label: {
                    Label("Go to Season", systemImage: "square.stack")
                }
            }
        }
        Button {
            setPlayed(!played)
        } label: {
            Label(played ? "Mark as Unwatched" : "Mark as Watched", systemImage: played ? "eye.slash" : "checkmark.circle")
        }
        Button {
            setFavorite(!favorite)
        } label: {
            Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.slash" : "heart")
        }
    }

    private func play(from ticks: Int64) {
        session.router.play(PlaybackRequest(itemId: item.id, startTicks: ticks))
    }

    private func setPlayed(_ value: Bool) {
        var data = userData ?? UserItemData()
        data.played = value
        if value {
            data.playbackPositionTicks = 0
            data.playedPercentage = nil
            data.unplayedItemCount = 0
        }
        update(to: data) { try await $0.setPlayed(item.id, value) }
    }

    private func setFavorite(_ value: Bool) {
        var data = userData ?? UserItemData()
        data.isFavorite = value
        update(to: data) { try await $0.setFavorite(item.id, value) }
    }

    /// Shows the change right away and puts it back if the server refuses.
    private func update(to data: UserItemData, _ send: @escaping (JellyfinClient) async throws -> Void) {
        guard let client = session.client else { return }
        let previous = userData
        userData = data
        Task {
            do {
                try await send(client)
                session.userDataChanged()
            } catch {
                userData = previous
            }
        }
    }
}

/// A cast or crew member: round picture, name and role.
struct PersonLockup: View {
    let person: PersonInfo

    @Environment(AppSession.self) private var session

    /// The section's first card, for focus after a tab is picked.
    @Environment(\.itemLead) private var itemLead

    var body: some View {
        VStack(spacing: Lockup.personLabelSpacing) {
            NavigationLink(value: person) {
                RemoteImage(url: session.client?.personImageURL(person), systemImage: "person.fill")
                    .frame(width: Lockup.personPhotoSize, height: Lockup.personPhotoSize)
                    .clipShape(Circle())
            }
            .sectionLead(itemLead)
            .cardButtonStyle()
            .keyboardTarget(opening: person)
            .clipShape(Circle())
            .accessibilityLabel([person.name, person.role].compactMap { $0 }.joined(separator: ", "))

            Text(person.name ?? "")
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Lockup.personWidth)
    }
}

/// A library (user view) as a wide tile.
struct LibraryTile: View {
    let library: BaseItem
    /// Lets a page move focus here (by library id), e.g. down from a hero.
    var focus: FocusState<String?>.Binding? = nil

    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationLink(value: library) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: session.client?.landscapeURL(for: library, width: 800), systemImage: icon)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                Text(library.displayTitle)
                    #if os(tvOS)
                    .font(.title3.weight(.semibold))
                    .padding(20)
                    #else
                    .font(.headline)
                    .padding(10)
                    #endif
            }
            .frame(width: Lockup.libraryTileWidth, height: Lockup.libraryTileHeight)
        }
        .cardButtonStyle()
        .optionallyFocused(focus, equals: library.id)
        .keyboardTarget(opening: library)
        .accessibilityLabel(library.displayTitle)
    }

    private var icon: String {
        switch library.collectionType {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "boxsets": return "square.stack"
        default: return "folder"
        }
    }
}

// MARK: - Small pieces

struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: max(6, geo.size.width * progress))
            }
        }
        .frame(height: 6)
    }
}

/// A progress bar that can be dragged to a new place (iPhone, iPad, Mac),
/// as the video player's timeline can: `scrubbing` follows the finger, for
/// the times beside it to show where it's going, and `commit` is called with
/// the place let go at. On Apple TV, where the remote has its own skip
/// buttons, it's the plain bar.
struct ScrubBar: View {
    let progress: Double
    @Binding var scrubbing: Double?
    /// One VoiceOver adjustment, as a share of the bar (30 s of the length).
    var accessibilityStep: Double = 0.05
    var commit: (Double) -> Void

    var body: some View {
        #if os(tvOS)
        ProgressBar(progress: progress)
        #else
        GeometryReader { proxy in
            ProgressBar(progress: scrubbing ?? progress)
                .scaleEffect(y: scrubbing == nil ? 1 : 1.6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard proxy.size.width > 0 else { return }
                            scrubbing = min(max(value.location.x / proxy.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            if let place = scrubbing { commit(place) }
                            scrubbing = nil
                        }
                )
        }
        // A finger-sized strip around the thin bar.
        .frame(height: 28)
        .animation(.easeOut(duration: 0.15), value: scrubbing == nil)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? accessibilityStep : -accessibilityStep
            commit(min(max(progress + step, 0), 1))
        }
        #endif
    }
}

struct UnplayedBadge: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 16, height: 16)
            .shadow(radius: 3)
    }
}

/// A rounded metadata chip such as "4K" or "PG-13".
struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.6), lineWidth: 2))
    }
}

/// "2019 · PG-13 · 2 hr 9 min · Action, Adventure" with quality badges.
struct MetadataLine: View {
    let item: BaseItem
    /// A show's page: how many episodes are left to watch, after the years.
    var showsUnwatched = false

    private var parts: [String] {
        var parts = item.metadataLine
        if showsUnwatched, item.kind == .series, let unplayed = item.userData?.unplayedItemCount, unplayed > 0 {
            parts.insert("\(unplayed) unwatched", at: item.yearText == nil ? 0 : 1)
        }
        return parts
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(parts.joined(separator: "  ·  "))
            if item.is4K {
                Badge(text: "4K")
            } else if item.isHD {
                Badge(text: "HD")
            }
            if let rating = item.communityRating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").font(.caption).accessibilityHidden(true)
                    Text(String(format: "%.1f", rating))
                }
                .accessibilityLabel("Rated \(String(format: "%.1f", rating)) out of 10")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// A list of lockups in a grid, poster or landscape.
struct ItemGrid: View {
    let items: [BaseItem]
    var landscape = false
    /// Lets a parent move focus into the grid by item id.
    var focus: FocusState<String?>.Binding? = nil

    @Environment(AppSession.self) private var session
    /// How many of `items` have had their pictures fetched ahead.
    @State private var warmed = 0

    private var columns: [GridItem] {
        if landscape {
            return [GridItem(.adaptive(minimum: Lockup.landscapeWidth, maximum: Lockup.landscapeWidth), spacing: Lockup.gridSpacing, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: Lockup.posterWidth, maximum: Lockup.posterWidth), spacing: Lockup.gridSpacing, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Lockup.gridRowSpacing) {
            ForEach(items) { item in
                if landscape {
                    LandscapeLockup(item: item, focus: focus)
                } else {
                    PosterLockup(item: item, focus: focus)
                }
            }
        }
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.vertical, 40)
        // Each page of titles as it arrives: its pictures fetched ahead, the
        // same ones the cards ask for, so scrolling finds them waiting.
        .task(id: items.count) {
            if items.count < warmed { warmed = 0 }
            let fresh = items.dropFirst(warmed)
            warmed = items.count
            let client = session.client
            let urls = fresh.compactMap { item in
                landscape ? client?.landscapeURL(for: item, width: 800) : Lockup.posterImageURL(for: item, client: client)
            }
            await ImageStore.shared.warm(urls, client: client)
        }
    }
}

/// An error or empty-state message in the middle of a screen.
struct MessageView: View {
    let systemImage: String
    let title: String
    var detail: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                #if os(tvOS)
                .font(.system(size: 64, weight: .light))
                #else
                .font(.system(size: 44, weight: .light))
                #endif
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
            if let retry {
                Button("Try Again", action: retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Prominent pill button used on detail pages.
struct ActionButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    /// Lets a parent move focus to this button by id.
    var focus: FocusState<String?>.Binding? = nil
    var focusID: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            #if os(tvOS)
            FocusRevealingLabel(title: title, systemImage: systemImage)
            #else
            Label(title, systemImage: systemImage)
                .font(.headline)
                // Never wrap: a squeezed row would stack the title letter by letter.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
            #endif
        }
        .actionButtonStyle(prominent: prominent)
        .accessibilityLabel(title)
        .optionallyFocused(focus, equals: focusID)
        // The prominent button is the page's main action (Play), where the
        // keyboard starts.
        .keyboardTarget(isDefault: prominent, action: action)
    }
}

#if os(tvOS)
/// A button's icon alone, matching the icon-only buttons beside it, with the
/// title sliding out beside it while the button has focus. Keeps a row of
/// actions compact from the sofa while still saying what each one does.
private struct FocusRevealingLabel: View {
    let title: String
    let systemImage: String
    /// True while the enclosing button is focused.
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(Lockup.iconButtonFont)
            if isFocused {
                // Fades in and out where it sits as the button widens and
                // narrows; sliding in from the side, it was seen flying past.
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .frame(minWidth: Lockup.iconButtonSize, minHeight: Lockup.iconButtonSize)
        .padding(.horizontal, isFocused ? 10 : 0)
        // Nothing shows past the button's edge while it narrows.
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}
#endif

struct IconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    /// Lets a parent move focus to this button by id.
    var focus: FocusState<String?>.Binding? = nil
    var focusID: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Lockup.iconButtonFont)
                .frame(width: Lockup.iconButtonSize, height: Lockup.iconButtonSize)
        }
        .actionButtonStyle()
        .accessibilityLabel(accessibilityLabel)
        .optionallyFocused(focus, equals: focusID)
        .keyboardTarget(action: action)
    }
}

extension View {
    /// The look of a page's action buttons. Grey with white content, or
    /// white with black for the main action. On tvOS a focused button turns
    /// white with black content too, and lifts, so it reads clearly from the
    /// sofa; the system style's off-white focus washed out white labels.
    func actionButtonStyle(prominent: Bool = false) -> some View {
        #if os(tvOS)
        buttonStyle(TVActionButtonStyle(prominent: prominent))
            .menuStyle(.button)
        #else
        buttonStyle(.borderedProminent)
            .tint(prominent ? .white : Color(white: 0.3))
            .foregroundStyle(prominent ? .black : .white)
        #endif
    }
}

#if os(tvOS)
private struct TVActionButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, prominent: prominent)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let prominent: Bool
        /// True while the button is focused.
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let lit = isFocused || prominent
            configuration.label
                .foregroundStyle(lit ? Color.black : Color.white)
                .padding(16)
                .background(Capsule().fill(lit ? Color.white : Color(white: 0.3)))
                .scaleEffect(isFocused && !configuration.isPressed ? 1.1 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.15), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}
#endif

/// A page's action buttons: on one row, except on a phone held upright, where
/// one row is too narrow and they split across two. Each row scrolls sideways
/// if it still runs out of room.
struct ActionRows<First: View, Second: View>: View {
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Compact width with regular height: a phone upright. An iPad, or a
    /// phone on its side, keeps everything on one row.
    private var isPortraitPhone: Bool {
        horizontalSizeClass == .compact && verticalSizeClass == .regular
    }
    #endif

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 20) {
            first
            second
        }
        #else
        if isPortraitPhone {
            VStack(alignment: .leading, spacing: 10) {
                row { first }
                row { second }
            }
        } else {
            row {
                first
                second
            }
        }
        #endif
    }

    #if !os(tvOS)
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) { content() }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
    #endif
}

extension View {
    /// Applies `focused(_:equals:)` only when a binding was supplied.
    @ViewBuilder
    func optionallyFocused(_ binding: FocusState<String?>.Binding?, equals value: String) -> some View {
        if let binding {
            self.focused(binding, equals: value)
        } else {
            self
        }
    }
}
