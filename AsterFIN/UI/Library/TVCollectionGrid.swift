//
//  TVCollectionGrid.swift
//  AsterFIN
//
//  The Apple TV's grid of titles, as a UIKit collection view. The cells are
//  what take focus, as in any UIKit app on Apple TV: the focus engine knows
//  every cell's place from the layout, rows not yet made included, scrolls
//  to the focused one and remembers it. Each cell hosts a SwiftUI lockup for
//  its looks only; the cell opens the title when selected and shows the
//  long-press menu. Nothing here moves focus by hand, beyond telling the
//  collection view which title to prefer when a page opens or a letter is
//  picked.
//
//  (Hosting focusable SwiftUI buttons in the cells instead, as Swiftfin
//  does, was tried first: the engine saw their frames wrongly whenever a
//  row was partly off the screen, and presses went astray.)
//

#if os(tvOS)
import SwiftUI
import UIKit

/// Trailing room for the floating Now Playing panel, read inside a hosted
/// root (the grid's header), which has its own environment.
struct MiniPlayerRoom: ViewModifier {
    @Environment(\.themeMiniInset) private var themeMiniInset

    func body(content: Content) -> some View {
        content
            .padding(.trailing, themeMiniInset)
            .animation(.smooth(duration: 0.4), value: themeMiniInset)
    }
}

/// Lets the page that owns a grid scroll it to a letter's section.
final class TVGridProxy {
    fileprivate var scrollToSection: ((String) -> Void)?

    func scrollTo(section key: String) {
        scrollToSection?(key)
    }
}

/// Titles in sections (one section, with any key, when the grid isn't
/// lettered), with the page's own content above them as the grid's header
/// and, if wanted, below them as its footer.
struct TVCollectionGrid: UIViewRepresentable {
    var sections: [IndexSection]
    var landscape = false
    /// Each section's key shown in the margin beside its first row.
    var showsLetters = false
    var proxy: TVGridProxy? = nil
    /// On a page with nothing above the grid that should take focus first
    /// (no hero), the first title takes focus when the grid first fills,
    /// rather than the sort picker above it.
    var focusesFirstItemInitially = false
    /// Called as scrolling nears the bottom, for the next page of titles.
    var onNearBottom: (() -> Void)? = nil
    var header: AnyView? = nil
    var footer: AnyView? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.openItem) private var openItem
    @Environment(\.themeMiniInset) private var themeMiniInset

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TVGridContainer {
        let view = context.coordinator.makeContainer(hasHeader: header != nil, hasFooter: footer != nil)
        proxy?.scrollToSection = { [weak coordinator = context.coordinator] key in coordinator?.scroll(toSection: key) }
        return view
    }

    func updateUIView(_ view: TVGridContainer, context: Context) {
        proxy?.scrollToSection = { [weak coordinator = context.coordinator] key in coordinator?.scroll(toSection: key) }
        context.coordinator.update(
            sections: sections,
            landscape: landscape,
            showsLetters: showsLetters,
            header: header,
            footer: footer,
            hosting: Hosting(session: session, openItem: openItem, miniInset: themeMiniInset),
            onNearBottom: onNearBottom,
            focusesFirstItemInitially: focusesFirstItemInitially
        )
    }
}

extension TVCollectionGrid {
    /// What every hosted SwiftUI root is given: each cell and the header are
    /// their own SwiftUI trees, and don't see the page's environment.
    struct Hosting {
        let session: AppSession
        let openItem: OpenItemAction?
        let miniInset: CGFloat
    }

    enum Kind {
        static let header = "tvgrid-header"
        static let footer = "tvgrid-footer"
        static let letter = "tvgrid-letter"
    }

    enum Edge {
        case top, bottom
    }

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        private(set) weak var collectionView: TVGridCollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<String, String>!
        private var items: [String: BaseItem] = [:]
        /// Changes made from the menu (watched, favourite), shown at once
        /// and kept until the server sends the title afresh.
        private var editedUserData: [String: UserItemData] = [:]
        private var sections: [IndexSection] = []
        private var landscape = false
        private var showsLetters = false
        private var hasHeader = false
        private var hasFooter = false
        /// Room on the right for the floating Now Playing panel.
        private var trailingInset: CGFloat = 0
        private var hosting: Hosting?
        private var header: AnyView?
        private var footer: AnyView?
        private var onNearBottom: (() -> Void)?
        /// Asks for the next page once per fill, not on every scroll tick.
        private var nearBottomArmed = true
        /// Whether a title has ever had focus, so the first title is only
        /// preferred before then.
        private var hasFocusedACell = false
        private var focusesFirstItemInitially = false
        /// The title to focus at the next focus update: a picked letter's first.
        private var pendingFocus: IndexPath?

        private var itemWidth: CGFloat { landscape ? Lockup.landscapeWidth : Lockup.posterWidth }
        private var itemHeight: CGFloat { (landscape ? Lockup.landscapeHeight : Lockup.posterHeight) + Lockup.gridTitleHeight }
        private var rowHeight: CGFloat { itemHeight + Lockup.gridRowSpacing }

        // MARK: Diagnostics

        #if DEBUG
        private var focusObservers: [any NSObjectProtocol] = []
        private static var gridCount = 0
        fileprivate lazy var gridTag: String = {
            Self.gridCount += 1
            return "grid\(Self.gridCount)"
        }()

        /// Logs each move the focus engine makes into, out of or within the
        /// grid, and each one it couldn't. Temporary, for diagnosis.
        private func startFocusLogging() {
            let center = NotificationCenter.default
            focusObservers.append(center.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.logFocus("moved", note) }
            })
            focusObservers.append(center.addObserver(forName: UIFocusSystem.movementDidFailNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.logFocus("FAILED", note) }
            })
        }

        private func logFocus(_ what: String, _ note: Notification) {
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
                  let collectionView else { return }
            let previous = context.previouslyFocusedView
            let next = context.nextFocusedView
            let involved = [previous, next].contains { $0?.isDescendant(of: collectionView) == true }
            guard involved || (previous == nil && next == nil) else { return }
            func describe(_ view: UIView?) -> String {
                guard let view else { return "nil" }
                let frame = view.convert(view.bounds, to: nil)
                var path = view.isDescendant(of: collectionView) ? "header/letter" : "outside"
                var cellView: UIView? = view
                while let candidate = cellView, !(candidate is TVGridCell) { cellView = candidate.superview }
                if let cell = cellView as? TVGridCell, let indexPath = collectionView.indexPath(for: cell) {
                    path = "\(indexPath.section).\(indexPath.item)"
                }
                let size = frame.isNull || frame.isInfinite ? "?" : "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
                return "\(type(of: view))[\(path)] (\(size))"
            }
            var heading: [String] = []
            if context.focusHeading.contains(.up) { heading.append("up") }
            if context.focusHeading.contains(.down) { heading.append("down") }
            if context.focusHeading.contains(.left) { heading.append("left") }
            if context.focusHeading.contains(.right) { heading.append("right") }
            let paths = collectionView.indexPathsForVisibleItems.sorted()
            let visible = paths.isEmpty ? "none" : "\(paths.first!.section).\(paths.first!.item)…\(paths.last!.section).\(paths.last!.item) (\(paths.count))"
            print("DEBUG focus: \(gridTag) \(what) \(heading.joined(separator: "+")) from \(describe(previous)) to \(describe(next)); offset \(Int(collectionView.contentOffset.y)) of \(Int(collectionView.contentSize.height)); cells \(visible)")
        }
        #endif

        // MARK: Setup

        func makeContainer(hasHeader: Bool, hasFooter: Bool) -> TVGridContainer {
            self.hasHeader = hasHeader
            self.hasFooter = hasFooter
            #if DEBUG
            startFocusLogging()
            #endif
            let view = TVGridCollectionView(frame: .zero, collectionViewLayout: makeLayout())
            view.backgroundColor = .clear
            // A focused card lifts past its cell, and the last column past the view.
            view.clipsToBounds = false
            // The page places the view; UIKit mustn't add the screen's own insets as well.
            view.contentInsetAdjustmentBehavior = .never
            view.contentInset.bottom = Lockup.pageBottomPadding
            view.delegate = self
            view.prefetchDataSource = self
            // Back from a title's page, focus returns to its cell.
            view.remembersLastFocusedIndexPath = true
            collectionView = view

            let cellRegistration = UICollectionView.CellRegistration<TVGridCell, String> { [unowned self] cell, _, id in
                guard let item = items[id] else { return }
                cell.configure = { [unowned self] focused in cellConfiguration(for: shown(item), focused: focused) }
                cell.setNeedsUpdateConfiguration()
            }
            let headerRegistration = UICollectionView.SupplementaryRegistration<TVGridHostCell>(elementKind: Kind.header) { [unowned self] view, _, _ in
                view.contentConfiguration = boundaryConfiguration(header)
            }
            let footerRegistration = UICollectionView.SupplementaryRegistration<TVGridHostCell>(elementKind: Kind.footer) { [unowned self] view, _, _ in
                view.contentConfiguration = boundaryConfiguration(footer)
            }
            let letterRegistration = UICollectionView.SupplementaryRegistration<TVGridHostCell>(elementKind: Kind.letter) { [unowned self] view, _, indexPath in
                let keys = dataSource.snapshot().sectionIdentifiers
                let key = keys.indices.contains(indexPath.section) ? keys[indexPath.section] : ""
                view.contentConfiguration = UIHostingConfiguration {
                    Text(key)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: Lockup.screenPadding, alignment: .center)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                        .ignoresSafeArea()
                }
                .margins(.all, 0)
            }

            dataSource = UICollectionViewDiffableDataSource<String, String>(collectionView: view) { collectionView, indexPath, id in
                collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
            }
            dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
                switch kind {
                case Kind.header:
                    return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
                case Kind.footer:
                    return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
                default:
                    return collectionView.dequeueConfiguredReusableSupplementary(using: letterRegistration, for: indexPath)
                }
            }

            let container = TVGridContainer(collectionView: view)
            container.topGuide.resolve = { [weak self] in self?.boundaryBeyond(.top) ?? [] }
            container.bottomGuide.resolve = { [weak self] in self?.boundaryBeyond(.bottom) ?? [] }
            return container
        }

        /// Rows of as many titles as fit, each section led by its letter in
        /// the margin, with the page's header above and footer below.
        private func makeLayout() -> UICollectionViewCompositionalLayout {
            let configuration = UICollectionViewCompositionalLayoutConfiguration()
            // Insets are from the view's own edges; the page has placed it.
            configuration.contentInsetsReference = .none
            // Rows across a letter boundary are spaced like rows within one.
            configuration.interSectionSpacing = Lockup.gridRowSpacing
            let fullWidth = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(600))
            var boundary: [NSCollectionLayoutBoundarySupplementaryItem] = []
            if hasHeader {
                boundary.append(NSCollectionLayoutBoundarySupplementaryItem(layoutSize: fullWidth, elementKind: Kind.header, alignment: .top))
            }
            if hasFooter {
                boundary.append(NSCollectionLayoutBoundarySupplementaryItem(layoutSize: fullWidth, elementKind: Kind.footer, alignment: .bottom))
            }
            configuration.boundarySupplementaryItems = boundary

            return UICollectionViewCompositionalLayout(sectionProvider: { [unowned self] index, _ in
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .absolute(itemWidth), heightDimension: .absolute(itemHeight)))
                // One item given: the group repeats it across its width.
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(itemHeight)),
                    subitems: [item])
                group.interItemSpacing = .fixed(Lockup.gridSpacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = Lockup.gridRowSpacing
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: index == 0 ? 40 : 0,
                    leading: Lockup.screenPadding,
                    bottom: 0,
                    trailing: Lockup.screenPadding + trailingInset)
                if showsLetters {
                    // Anchored to the section's own corner, not its inset
                    // content, so it sits in the margin level with the first row.
                    section.supplementaryContentInsetsReference = .none
                    let letter = NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(Lockup.screenPadding), heightDimension: .absolute(60)),
                        elementKind: Kind.letter,
                        alignment: .topLeading)
                    letter.extendsBoundary = false
                    letter.zIndex = 1
                    section.boundarySupplementaryItems = [letter]
                }
                return section
            }, configuration: configuration)
        }

        // MARK: Updates

        func update(sections: [IndexSection], landscape: Bool, showsLetters: Bool, header: AnyView?, footer: AnyView?,
                    hosting: Hosting, onNearBottom: (() -> Void)?, focusesFirstItemInitially: Bool) {
            self.hosting = hosting
            self.header = header
            self.footer = footer
            self.onNearBottom = onNearBottom
            self.focusesFirstItemInitially = focusesFirstItemInitially
            let boundaryChanged = hasHeader != (header != nil) || hasFooter != (footer != nil)
            hasHeader = header != nil
            hasFooter = footer != nil
            let needsLayout = self.landscape != landscape || self.showsLetters != showsLetters || trailingInset != hosting.miniInset
            self.landscape = landscape
            self.showsLetters = showsLetters
            trailingInset = hosting.miniInset
            applyIfChanged(sections)
            if boundaryChanged {
                collectionView?.setCollectionViewLayout(makeLayout(), animated: false)
            } else if needsLayout {
                collectionView?.collectionViewLayout.invalidateLayout()
            }
            refreshBoundaryViews()
        }

        /// A new snapshot when the titles or their sections change; a
        /// reconfigure for titles whose details changed (watched, say).
        private func applyIfChanged(_ new: [IndexSection]) {
            let newItems = Dictionary(new.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let sameShape = new.map(\.key) == sections.map(\.key)
                && new.map { $0.items.map(\.id) } == sections.map { $0.items.map(\.id) }
            let changed = newItems.compactMap { id, item in
                if let old = items[id], old != item { id } else { nil }
            }
            // The server's fresh word on a title replaces the menu's edit.
            for id in changed { editedUserData[id] = nil }
            items = newItems
            sections = new
            guard !sameShape || !changed.isEmpty else { return }
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            for section in new {
                snapshot.appendSections([section.key])
                // Ids are unique across the grid; a repeat would stop the apply.
                var seen = Set<String>()
                snapshot.appendItems(section.items.map(\.id).filter { seen.insert($0).inserted }, toSection: section.key)
            }
            if sameShape {
                snapshot.reconfigureItems(changed)
            }
            let wasEmpty = dataSource.snapshot().numberOfItems == 0
            dataSource.apply(snapshot, animatingDifferences: false)
            nearBottomArmed = true
            if wasEmpty, snapshot.numberOfItems > 0 {
                afterFirstFill()
            }
        }

        private func afterFirstFill() {
            guard let collectionView else { return }
            collectionView.layoutIfNeeded()
            // Fewer titles than a screen: the next page without a scroll.
            if collectionView.contentSize.height < collectionView.bounds.height {
                fireNearBottom()
            }
            guard focusesFirstItemInitially, !hasFocusedACell else { return }
            // The header's controls are in this collection view, so if focus
            // settled on them, this moves it to the first title (asked for in
            // `indexPathForPreferredFocusedView`). Elsewhere, it does nothing.
            collectionView.setNeedsFocusUpdate()
            collectionView.updateFocusIfNeeded()
        }

        /// Re-hosts the header and footer that are on screen, so the page's
        /// changes (sort, letters, the hero's titles) show.
        private func refreshBoundaryViews() {
            guard let collectionView else { return }
            for view in collectionView.visibleSupplementaryViews(ofKind: Kind.header) {
                (view as? TVGridHostCell)?.contentConfiguration = boundaryConfiguration(header)
            }
            for view in collectionView.visibleSupplementaryViews(ofKind: Kind.footer) {
                (view as? TVGridHostCell)?.contentConfiguration = boundaryConfiguration(footer)
            }
        }

        /// Brings a letter's section to the top and focuses its first title
        /// (the letters scroll away with the header, so focus can't stay there).
        func scroll(toSection key: String) {
            guard let collectionView else { return }
            let snapshot = dataSource.snapshot()
            guard let section = snapshot.indexOfSection(key), snapshot.numberOfItems(inSection: key) > 0 else { return }
            let target = IndexPath(item: 0, section: section)
            collectionView.scrollToItem(at: target, at: .top, animated: false)
            collectionView.layoutIfNeeded()
            pendingFocus = target
            collectionView.setNeedsFocusUpdate()
            collectionView.updateFocusIfNeeded()
        }

        // MARK: Beyond the edges

        /// The header or footer, for a press from the first or last row when
        /// it has scrolled off: it only exists while on screen, so it is
        /// brought just inside the edge first. The rows themselves need
        /// nothing of the kind: the focus engine knows them from the layout.
        private func boundaryBeyond(_ edge: Edge) -> [any UIFocusEnvironment] {
            guard let collectionView,
                  let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
                  focused.isDescendant(of: collectionView) else { return [] }
            let from = focused.convert(focused.bounds, to: collectionView)
            let kind = edge == .bottom ? Kind.footer : Kind.header
            let first = IndexPath(item: 0, section: 0)
            guard edge == .bottom ? hasFooter : hasHeader,
                  let attributes = collectionView.collectionViewLayout.layoutAttributesForSupplementaryView(ofKind: kind, at: first),
                  !attributes.frame.intersects(from) else { return [] }
            // Nothing of the grid's own in between, or the engine would have found it.
            let between = edge == .bottom
                ? CGRect(x: 0, y: from.maxY, width: collectionView.contentSize.width, height: max(0, attributes.frame.minY - from.maxY))
                : CGRect(x: 0, y: attributes.frame.maxY, width: collectionView.contentSize.width, height: max(0, from.minY - attributes.frame.maxY))
            let rowsBetween = (collectionView.collectionViewLayout.layoutAttributesForElements(in: between) ?? [])
                .contains { $0.representedElementCategory == .cell && $0.frame.intersects(between) }
            guard !rowsBetween else { return [] }
            let bounds = collectionView.bounds
            var offset = collectionView.contentOffset
            switch edge {
            case .bottom where attributes.frame.minY + 2 > bounds.maxY:
                offset.y += attributes.frame.minY + 2 - bounds.maxY
            case .top where attributes.frame.maxY - 2 < bounds.minY:
                offset.y -= bounds.minY - (attributes.frame.maxY - 2)
            default:
                break
            }
            let insets = collectionView.adjustedContentInset
            let highest = max(-insets.top, collectionView.contentSize.height + insets.bottom - bounds.height)
            offset.y = min(max(offset.y, -insets.top), highest)
            if offset != collectionView.contentOffset {
                collectionView.setContentOffset(offset, animated: false)
                collectionView.layoutIfNeeded()
            }
            return collectionView.supplementaryView(forElementKind: kind, at: first).map { [$0] } ?? []
        }

        // MARK: Hosting

        private func shown(_ item: BaseItem) -> BaseItem {
            item.withUserData(editedUserData[item.id])
        }

        private func cellConfiguration(for item: BaseItem, focused: Bool) -> any UIContentConfiguration {
            let width = itemWidth
            let height = itemHeight
            let landscape = landscape
            return UIHostingConfiguration {
                hosted(Group {
                    if landscape {
                        LandscapeLockup(item: item)
                    } else {
                        PosterLockup(item: item)
                    }
                }, inCell: true, focused: focused)
                .frame(width: width, height: height, alignment: .top)
            }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
        }

        private func boundaryConfiguration(_ content: AnyView?) -> any UIContentConfiguration {
            UIHostingConfiguration {
                hosted(content ?? AnyView(EmptyView()), inCell: false, focused: false)
            }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
        }

        /// Gives a hosted root what the lockups, hero and menus read from the
        /// environment. In a cell the lockup is drawn plain (the cell has the
        /// focus, the press and the menu); in the header and footer lockups
        /// open through `openItem`, as a NavigationLink can't find the stack
        /// from a hosted root. The safe area is ignored: a cell poking past
        /// the screen's edge is given the whole overhang as an inset, which
        /// squashed its content until it scrolled in.
        @ViewBuilder
        private func hosted(_ content: some View, inCell: Bool, focused: Bool) -> some View {
            if let hosting {
                content
                    .environment(hosting.session)
                    .environment(\.openItem, hosting.openItem)
                    .environment(\.themeMiniInset, hosting.miniInset)
                    .environment(\.opensItemsWithAction, true)
                    .environment(\.lockupsAreStatic, inCell)
                    .environment(\.hostedCellFocused, focused)
                    .ignoresSafeArea()
            } else {
                content
                    .ignoresSafeArea()
            }
        }

        // MARK: Focus and selection

        func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
            if let pendingFocus, collectionView.numberOfSections > pendingFocus.section,
               collectionView.numberOfItems(inSection: pendingFocus.section) > pendingFocus.item {
                return pendingFocus
            }
            if focusesFirstItemInitially, !hasFocusedACell,
               collectionView.numberOfSections > 0, collectionView.numberOfItems(inSection: 0) > 0 {
                return IndexPath(item: 0, section: 0)
            }
            return nil
        }

        func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            if let next = context.nextFocusedIndexPath {
                hasFocusedACell = true
                if next == pendingFocus { pendingFocus = nil }
            }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            guard let id = dataSource.itemIdentifier(for: indexPath), let item = items[id] else { return }
            hosting?.openItem?(item)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let remaining = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
            if nearBottomArmed, remaining < 3 * rowHeight {
                fireNearBottom()
            }
        }

        private func fireNearBottom() {
            guard let onNearBottom else { return }
            nearBottomArmed = false
            onNearBottom()
        }

        // MARK: Long-press menu

        /// The same choices as `ItemActionsMenu`, as a UIKit menu on the cell.
        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
            guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath),
                  let item = items[id], ItemActionsMenu.supports(item) else { return nil }
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                MainActor.assumeIsolated { self?.menu(for: item) }
            })
        }

        private func menu(for item: BaseItem) -> UIMenu {
            guard let hosting else { return UIMenu() }
            let session = hosting.session
            let data = shown(item).userData
            let resumeTicks = data?.playbackPositionTicks ?? 0
            let played = data?.played ?? false
            let favorite = data?.isFavorite ?? false
            var actions: [UIAction] = []
            if item.kind != .series && item.kind != .season {
                actions.append(UIAction(title: resumeTicks > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { _ in
                    MainActor.assumeIsolated { session.router.play(PlaybackRequest(itemId: item.id, startTicks: resumeTicks)) }
                })
                if resumeTicks > 0 {
                    actions.append(UIAction(title: "Play from Beginning", image: UIImage(systemName: "arrow.counterclockwise")) { _ in
                        MainActor.assumeIsolated { session.router.play(PlaybackRequest(itemId: item.id, startTicks: 0)) }
                    })
                }
            }
            if let openItem = hosting.openItem {
                // Stub items are enough: the title page loads the full item.
                if item.kind == .episode || item.kind == .season, let seriesId = item.seriesId {
                    actions.append(UIAction(title: "Go to Series", image: UIImage(systemName: "tv")) { _ in
                        MainActor.assumeIsolated { openItem(BaseItem(id: seriesId, name: item.seriesName, type: ItemKind.series.rawValue)) }
                    })
                }
                if item.kind == .episode, let seasonId = item.seasonId {
                    actions.append(UIAction(title: "Go to Season", image: UIImage(systemName: "square.stack")) { _ in
                        MainActor.assumeIsolated { openItem(BaseItem(id: seasonId, name: item.seasonName, type: ItemKind.season.rawValue)) }
                    })
                }
            }
            actions.append(UIAction(title: played ? "Mark as Unwatched" : "Mark as Watched", image: UIImage(systemName: played ? "eye.slash" : "checkmark.circle")) { [weak self] _ in
                MainActor.assumeIsolated {
                    var edited = data ?? UserItemData()
                    edited.played = !played
                    if !played {
                        edited.playbackPositionTicks = 0
                        edited.playedPercentage = nil
                        edited.unplayedItemCount = 0
                    }
                    self?.update(item, to: edited) { try await $0.setPlayed(item.id, !played) }
                }
            })
            actions.append(UIAction(title: favorite ? "Remove from Favorites" : "Add to Favorites", image: UIImage(systemName: favorite ? "heart.slash" : "heart")) { [weak self] _ in
                MainActor.assumeIsolated {
                    var edited = data ?? UserItemData()
                    edited.isFavorite = !favorite
                    self?.update(item, to: edited) { try await $0.setFavorite(item.id, !favorite) }
                }
            })
            return UIMenu(children: actions)
        }

        /// Shows the change on the card right away and puts it back if the
        /// server refuses.
        private func update(_ item: BaseItem, to data: UserItemData, _ send: @escaping (JellyfinClient) async throws -> Void) {
            guard let hosting, let client = hosting.session.client else { return }
            let previous = editedUserData[item.id]
            editedUserData[item.id] = data
            redraw(item.id)
            Task {
                do {
                    try await send(client)
                    hosting.session.userDataChanged()
                } catch {
                    editedUserData[item.id] = previous
                    redraw(item.id)
                }
            }
        }

        private func redraw(_ id: String) {
            guard let collectionView, let indexPath = dataSource.indexPath(for: id) else { return }
            (collectionView.cellForItem(at: indexPath) as? TVGridCell)?.setNeedsUpdateConfiguration()
        }

        // MARK: Prefetching

        /// The pictures of rows about to show, decoded ahead, so a lockup
        /// finds its picture in the cache as it comes on screen.
        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let client = hosting?.session.client else { return }
            let urls = indexPaths
                .compactMap { dataSource.itemIdentifier(for: $0) }
                .compactMap { items[$0] }
                .compactMap { item in
                    landscape ? client.landscapeURL(for: item, width: 800) : Lockup.posterImageURL(for: item, client: client)
                }
            ImageStore.shared.prefetch(urls, client: client)
        }
    }
}

/// Holds the collection view, with a focus guide along its top and bottom
/// edges for presses towards a header or footer that has scrolled off.
final class TVGridContainer: UIView {
    let collectionView: TVGridCollectionView
    let topGuide = TVGridEdgeGuide()
    let bottomGuide = TVGridEdgeGuide()

    init(collectionView: TVGridCollectionView) {
        self.collectionView = collectionView
        super.init(frame: .zero)
        clipsToBounds = false
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addLayoutGuide(topGuide)
        addLayoutGuide(bottomGuide)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topGuide.topAnchor.constraint(equalTo: topAnchor),
            topGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            topGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            topGuide.heightAnchor.constraint(equalToConstant: 1),
            bottomGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomGuide.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A focus guide that works out where it leads when asked, so it can bring
/// the header or footer it leads to on screen first.
final class TVGridEdgeGuide: UIFocusGuide {
    var resolve: (() -> [any UIFocusEnvironment])?

    override var preferredFocusEnvironments: [any UIFocusEnvironment]! {
        get { resolve?() ?? [] }
        set {}
    }
}

final class TVGridCollectionView: UICollectionView {}

/// A title's cell: the thing that takes focus. Its hosted lockup is drawn
/// again with the cell's focus, so the artwork lifts.
final class TVGridCell: UICollectionViewCell {
    /// Makes the cell's content for whether it has focus.
    var configure: ((Bool) -> any UIContentConfiguration)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        if let configure {
            contentConfiguration = configure(state.isFocused)
        }
    }

    /// The focused card lifts over its neighbours; the cells after it would
    /// otherwise draw over its edge.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        layer.zPosition = isFocused ? 100 : 0
    }

    // The layout's attributes set the z order again on each pass; the lifted
    // card stays on top.
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if isFocused {
            layer.zPosition = 100
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configure = nil
        layer.zPosition = 0
    }
}

/// Hosts the header, footer and letters: a cell, as only cells can take a
/// hosting configuration. Never focused itself.
final class TVGridHostCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { false }
}
#endif
