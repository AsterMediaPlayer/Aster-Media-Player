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
    #endif
}

// MARK: - Shelf

/// A titled horizontal row of lockups.
struct Shelf<Item: Identifiable & Hashable, Content: View>: View {
    let title: String
    let items: [Item]
    var spacing: CGFloat = Lockup.shelfSpacing
    @ViewBuilder var content: (Item) -> Content

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, Lockup.screenPadding)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: spacing) {
                        ForEach(items) { item in
                            content(item)
                        }
                    }
                    .padding(.horizontal, Lockup.screenPadding)
                    .padding(.vertical, Lockup.shelfVerticalPadding)
                }
                .scrollClipDisabled()
            }
            .tvFocusSection()
        }
    }
}

// MARK: - Lockups

/// 16:9 artwork with a title underneath, the Apple TV app's standard lockup.
struct LandscapeLockup: View {
    let item: BaseItem
    var showSeriesTitle = true
    var width: CGFloat = Lockup.landscapeWidth
    /// Lets a parent move focus to this lockup by item id.
    var focus: FocusState<String?>.Binding? = nil

    @Environment(AppSession.self) private var session
    @State private var editedUserData: UserItemData?

    private var height: CGFloat { width * 9 / 16 }
    private var shown: BaseItem { item.withUserData(editedUserData) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: item) {
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
            .cardButtonStyle()
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
        default:
            return nil
        }
    }
}

/// 2:3 poster artwork with the title underneath.
struct PosterLockup: View {
    let item: BaseItem
    var width: CGFloat = Lockup.posterWidth

    @Environment(AppSession.self) private var session
    @State private var editedUserData: UserItemData?

    private var shown: BaseItem { item.withUserData(editedUserData) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: item) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: session.client?.posterURL(for: item, width: 500), systemImage: item.kind == .series ? "tv" : "film")
                        .frame(width: width, height: width * 1.5)
                    if let progress = shown.progressFraction {
                        ProgressBar(progress: progress)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                    if item.kind == .series, let unplayed = shown.userData?.unplayedItemCount, unplayed > 0 {
                        CountBadge(count: unplayed)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(10)
                    }
                }
                .frame(width: width, height: width * 1.5)
            }
            .cardButtonStyle()
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

    var body: some View {
        VStack(spacing: 10) {
            NavigationLink(value: person) {
                RemoteImage(url: session.client?.personImageURL(person), systemImage: "person.fill")
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
            }
            .cardButtonStyle()
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
        .frame(width: 220)
    }
}

/// A library (user view) as a wide tile.
struct LibraryTile: View {
    let library: BaseItem

    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationLink(value: library) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: session.client?.landscapeURL(for: library, width: 800), systemImage: icon)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                Text(library.displayTitle)
                    .font(.title3.weight(.semibold))
                    .padding(20)
            }
            .frame(width: 440, height: 248)
        }
        .cardButtonStyle()
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

struct UnplayedBadge: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 16, height: 16)
            .shadow(radius: 3)
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor, in: Capsule())
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

    var body: some View {
        HStack(spacing: 14) {
            Text(item.metadataLine.joined(separator: "  ·  "))
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
                    LandscapeLockup(item: item)
                } else {
                    PosterLockup(item: item)
                }
            }
        }
        .padding(.horizontal, Lockup.screenPadding)
        .padding(.vertical, 40)
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
                .font(.system(size: 64, weight: .light))
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
            Label(title, systemImage: systemImage)
                .font(.headline)
                // Never wrap: a squeezed row would stack the title letter by letter.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? .white : Color(white: 0.3))
        .foregroundStyle(prominent ? .black : .white)
        .optionallyFocused(focus, equals: focusID)
    }
}

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
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(white: 0.3))
        .foregroundStyle(.white)
        .accessibilityLabel(accessibilityLabel)
        .optionallyFocused(focus, equals: focusID)
    }
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
