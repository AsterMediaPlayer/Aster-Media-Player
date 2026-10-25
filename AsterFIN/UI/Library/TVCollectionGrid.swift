//
//  TVCollectionGrid.swift
//  AsterFIN
//
//  The Apple TV's grid of titles, as a UIKit collection view, the way
//  Swiftfin builds its library grid. Each cell hosts a SwiftUI lockup, and
//  the cells themselves are never focusable (`canFocusItemAt` says no), so
//  the focus engine moves between the lockups' buttons by where they are and
//  scrolls the collection view to keep up. Nothing here moves focus itself.
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

    func makeUIView(context: Context) -> TVGridCollectionView {
        let view = context.coordinator.makeCollectionView(hasHeader: header != nil, hasFooter: footer != nil)
        proxy?.scrollToSection = { [weak coordinator = context.coordinator] key in coordinator?.scroll(toSection: key) }
        return view
    }

    func updateUIView(_ view: TVGridCollectionView, context: Context) {
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

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        private(set) weak var collectionView: TVGridCollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<String, String>!
        private var items: [String: BaseItem] = [:]
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
        /// Where focus last was in the grid, for `preferredFocusEnvironments`.
        fileprivate(set) var lastFocusedIndexPath: IndexPath?
        /// Whether a title has ever had focus, so the first title is only
        /// preferred before then.
        fileprivate(set) var hasFocusedACell = false
        fileprivate var focusesFirstItemInitially = false

        private var itemWidth: CGFloat { landscape ? Lockup.landscapeWidth : Lockup.posterWidth }
        private var itemHeight: CGFloat { (landscape ? Lockup.landscapeHeight : Lockup.posterHeight) + Lockup.gridTitleHeight }
        private var rowHeight: CGFloat { itemHeight + Lockup.gridRowSpacing }

        // MARK: Setup

        func makeCollectionView(hasHeader: Bool, hasFooter: Bool) -> TVGridCollectionView {
            self.hasHeader = hasHeader
            self.hasFooter = hasFooter
            let view = TVGridCollectionView(frame: .zero, collectionViewLayout: makeLayout())
            view.coordinator = self
            view.backgroundColor = .clear
            // A focused card lifts past its cell, and the last column past the view.
            view.clipsToBounds = false
            // The page places the view; UIKit mustn't add the screen's own insets as well.
            view.contentInsetAdjustmentBehavior = .never
            view.contentInset.bottom = Lockup.pageBottomPadding
            view.delegate = self
            view.prefetchDataSource = self
            // Cells are never focused, so there is nothing to remember.
            view.remembersLastFocusedIndexPath = false
            collectionView = view

            let cellRegistration = UICollectionView.CellRegistration<TVGridCell, String> { [unowned self] cell, _, id in
                guard let item = items[id] else { return }
                cell.contentConfiguration = cellConfiguration(for: item)
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
            return view
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
            // settled on them, this moves it to the first title (via
            // `preferredFocusEnvironments`). Elsewhere, it does nothing.
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

        func scroll(toSection key: String) {
            guard let collectionView else { return }
            let snapshot = dataSource.snapshot()
            guard let section = snapshot.indexOfSection(key), snapshot.numberOfItems(inSection: key) > 0 else { return }
            collectionView.scrollToItem(at: IndexPath(item: 0, section: section), at: .top, animated: true)
        }

        // MARK: Hosting

        private func cellConfiguration(for item: BaseItem) -> any UIContentConfiguration {
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
                })
                .frame(width: width, height: height, alignment: .top)
            }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
        }

        private func boundaryConfiguration(_ content: AnyView?) -> any UIContentConfiguration {
            UIHostingConfiguration {
                hosted(content ?? AnyView(EmptyView()))
            }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
        }

        /// Gives a hosted root what the lockups, hero and menus read from the
        /// environment, and has lockups open through `openItem`: a
        /// NavigationLink can't find the stack from inside a hosted cell.
        @ViewBuilder
        private func hosted(_ content: some View) -> some View {
            if let hosting {
                content
                    .environment(hosting.session)
                    .environment(\.openItem, hosting.openItem)
                    .environment(\.themeMiniInset, hosting.miniInset)
                    .environment(\.opensItemsWithAction, true)
            } else {
                content
            }
        }

        // MARK: Delegate

        /// The Swiftfin trick: the cell never takes focus, so the lockup's
        /// button inside it does, and the focus engine moves between buttons.
        func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
            false
        }

        func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            // Set when the view taking focus is inside a cell, focused or not.
            if let next = context.nextFocusedIndexPath {
                lastFocusedIndexPath = next
                hasFocusedACell = true
            }
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

/// Prefers the title that last had focus (coming back from a title's page)
/// or, before any has, the first title, over the header's controls.
final class TVGridCollectionView: UICollectionView {
    weak var coordinator: TVCollectionGrid.Coordinator?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        guard let coordinator else { return [] }
        if let path = coordinator.lastFocusedIndexPath, let cell = cellForItem(at: path) {
            return [cell]
        }
        if coordinator.focusesFirstItemInitially, !coordinator.hasFocusedACell,
           numberOfSections > 0, numberOfItems(inSection: 0) > 0,
           let first = cellForItem(at: IndexPath(item: 0, section: 0)) {
            return [first]
        }
        return []
    }
}

/// A title's cell. Never focused itself; the lockup's button inside it is.
final class TVGridCell: UICollectionViewCell {
    private var hostsFocus = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The focused card lifts (the card button style) over its neighbours;
    /// the cells after it would otherwise draw over its edge.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if let next = context.nextFocusedView, next.isDescendant(of: self) {
            hostsFocus = true
            layer.zPosition = 100
            superview?.bringSubviewToFront(self)
        } else if let previous = context.previouslyFocusedView, previous.isDescendant(of: self) {
            hostsFocus = false
            layer.zPosition = 0
        }
    }

    // The layout's attributes set the z order again on each pass; the lifted
    // card stays on top.
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if hostsFocus {
            layer.zPosition = 100
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostsFocus = false
        layer.zPosition = 0
    }
}

/// Hosts the header, footer and letters: a cell, as only cells can take a
/// hosting configuration.
final class TVGridHostCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
