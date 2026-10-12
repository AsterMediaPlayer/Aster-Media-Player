//
//  KeyboardTargets.swift
//  AsterFIN
//
//  Arrow-key navigation on the Mac, the way the Apple TV's focus engine
//  moves: cards, tiles, rows and buttons that opt in with
//  `keyboardTarget(action:)` report where they are, an arrow picks the
//  nearest one that way, and Return activates it. The Mac has no such
//  engine for SwiftUI views, and a focusable view inside a focusable page
//  shares its focus there, so selection is kept here instead and the cards
//  draw it. Elsewhere the modifier does nothing.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif
#if DEBUG && os(macOS)
import os
#endif

extension View {
    /// Makes this view a stop for the Mac's arrow keys; Return runs `action`.
    /// A default stop (a page's Play button) takes the selection as it
    /// appears, so a page opened with the keyboard starts there.
    @ViewBuilder
    func keyboardTarget(isDefault: Bool = false, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        modifier(KeyboardTargetModifier(isDefault: isDefault, action: action))
        #else
        self
        #endif
    }

    /// Marks a navigation page, so only the stops on the page in front count
    /// (the Mac keeps the page underneath alive).
    /// A pushed page also goes back (Esc) by dismissing itself, as its
    /// back button does.
    @ViewBuilder
    func keyboardPage(pushed: Bool = false) -> some View {
        #if os(macOS)
        modifier(KeyboardPageModifier(pushed: pushed))
        #else
        self
        #endif
    }

    /// An arrow-key stop for a navigation link: Return opens `value`'s page.
    @ViewBuilder
    func keyboardTarget<Value: Hashable>(opening value: Value) -> some View {
        #if os(macOS)
        modifier(KeyboardLinkTargetModifier(value: value))
        #else
        self
        #endif
    }
}

#if os(macOS)
/// The arrow-key stops on screen and the one selected. Frames come in as
/// views move, so they aren't observed; only the selection is.
@MainActor
@Observable
final class KeyboardTargets {
    static let shared = KeyboardTargets()

    struct Target {
        var frame: CGRect
        /// The tab the stop is on; the sidebar keeps other tabs alive.
        var tab: AppTab?
        /// The navigation page it's on; the page underneath stays alive too.
        var page: UUID?
        var action: () -> Void
    }

    private(set) var selected: UUID?
    @ObservationIgnored private var targets: [UUID: Target] = [:]

    func update(_ id: UUID, frame: CGRect, tab: AppTab?, page: UUID?, action: @escaping () -> Void) {
        targets[id] = Target(frame: frame, tab: tab, page: page, action: action)
    }

    /// Each tab's navigation pages in the order they appeared; the last is
    /// the one in front.
    @ObservationIgnored private var pages: [AppTab?: [UUID]] = [:]

    /// How each pushed page goes back: its own dismiss action.
    @ObservationIgnored private var dismissals: [UUID: () -> Void] = [:]

    /// Each page's last selection, given back when the keyboard returns to
    /// it after a page opened over it closes.
    @ObservationIgnored private var lastSelections: [UUID: UUID] = [:]

    func pageAppeared(_ page: UUID, on tab: AppTab?, dismiss: (() -> Void)?) {
        pages[tab, default: []].removeAll { $0 == page }
        pages[tab, default: []].append(page)
        dismissals[page] = dismiss
        #if DEBUG
        sidebarDebugLog.notice("page appeared \(page.uuidString.prefix(4), privacy: .public) tab=\(tab?.rawValue ?? "nil", privacy: .public) pushed=\(dismiss != nil) stack=\(self.pages[tab]?.map { String($0.uuidString.prefix(4)) }.joined(separator: ",") ?? "", privacy: .public)")
        #endif
    }

    func pageDisappeared(_ page: UUID, on tab: AppTab?) {
        pages[tab]?.removeAll { $0 == page }
        dismissals[page] = nil
        lastSelections[page] = nil
        // Back on the page underneath: its card from before is selected again.
        if let front = pages[tab]?.last, let saved = lastSelections[front], targets[saved] != nil {
            selected = saved
        }
        #if DEBUG
        sidebarDebugLog.notice("page disappeared \(page.uuidString.prefix(4), privacy: .public) tab=\(tab?.rawValue ?? "nil", privacy: .public) stack=\(self.pages[tab]?.map { String($0.uuidString.prefix(4)) }.joined(separator: ",") ?? "", privacy: .public)")
        #endif
    }

    /// Esc: dismisses the pushed page in front on `tab`; false at a first page.
    func goBack(on tab: AppTab) -> Bool {
        guard let front = pages[tab]?.last, let dismiss = dismissals[front] else { return false }
        dismiss()
        return true
    }

    func remove(_ id: UUID) {
        targets[id] = nil
        if selected == id { selected = nil }
    }

    func clearSelection() {
        selected = nil
    }

    /// Selects a page's default stop as it appears, over whatever was
    /// selected on the page before.
    func selectDefault(_ id: UUID) {
        selected = id
    }

    /// Moves the selection, or activates it for `.select`. `.ignored` when
    /// there's nothing that way, so the caller can move on (to the sidebar).
    func handle(_ key: KeyboardNavigation.Key, on tab: AppTab) -> KeyPress.Result {
        let front = pages[tab]?.last
        let showing = targets.filter { target in
            (target.value.tab == tab || target.value.tab == nil)
                && (target.value.page == nil || target.value.page == front)
        }
        #if DEBUG
        let counts = Dictionary(grouping: targets.values, by: { $0.tab?.rawValue ?? "none" }).mapValues(\.count)
        sidebarDebugLog.notice("targets key=\(String(describing: key), privacy: .public) tab=\(tab.rawValue, privacy: .public) counts=\(String(describing: counts), privacy: .public) selected=\(String(describing: self.selected.flatMap { self.targets[$0]?.frame }), privacy: .public)")
        #endif
        if key == .select {
            guard let selected, let target = showing[selected] else { return .ignored }
            target.action()
            return .handled
        }
        guard key != .exit, !showing.isEmpty else { return .ignored }
        guard let selected, let current = showing[selected] else {
            // Nothing chosen yet: the first stop showing, top left first.
            guard let first = firstVisible(in: showing) else { return .ignored }
            select(first)
            return .handled
        }
        guard let next = nearest(to: current.frame, going: key, excluding: selected, in: showing) else {
            #if DEBUG
            let frames = showing.values.map { "(\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height)))" }.sorted()
            let allPages = pages.map { "\($0.key?.rawValue ?? "nil"):\($0.value.count)" }.joined(separator: " ")
            let otherPages = targets.values.filter { $0.tab == tab && $0.page != front }.count
            sidebarDebugLog.notice("targets none \(String(describing: key), privacy: .public) from=\(String(describing: current.frame), privacy: .public) showing=\(showing.count) samePageHidden=\(otherPages) pages=\(allPages, privacy: .public) frames=\(frames.joined(separator: " "), privacy: .public)")
            #endif
            return .ignored
        }
        select(next)
        return .handled
    }

    private func select(_ id: UUID) {
        selected = id
        if let page = targets[id]?.page { lastSelections[page] = id }
        if let frame = targets[id]?.frame {
            #if DEBUG
            sidebarDebugLog.notice("targets selected frame=\(String(describing: frame), privacy: .public) window=\(String(describing: Self.windowBounds), privacy: .public)")
            #endif
            Self.scrollIntoView(frame)
        }
    }

    private func firstVisible(in showing: [UUID: Target]) -> UUID? {
        let bounds = Self.windowBounds
        return showing
            .filter { bounds.isEmpty || bounds.intersects($0.value.frame) }
            .min { ($0.value.frame.minY, $0.value.frame.minX) < ($1.value.frame.minY, $1.value.frame.minX) }?
            .key
    }

    /// The stop that way whose distance along the arrow, plus twice how far
    /// it's off to the side, is least, as the tvOS focus engine weighs it.
    private func nearest(to frame: CGRect, going key: KeyboardNavigation.Key, excluding current: UUID, in showing: [UUID: Target]) -> UUID? {
        let slack: CGFloat = 4
        var best: (id: UUID, score: CGFloat)?
        for (id, target) in showing where id != current {
            let other = target.frame
            let along: CGFloat
            let across: CGFloat
            switch key {
            case .right:
                guard other.minX >= frame.maxX - slack else { continue }
                along = other.minX - frame.maxX
                across = abs(other.midY - frame.midY)
            case .left:
                guard other.maxX <= frame.minX + slack else { continue }
                along = frame.minX - other.maxX
                across = abs(other.midY - frame.midY)
            case .down:
                guard other.minY >= frame.maxY - slack else { continue }
                along = other.minY - frame.maxY
                across = abs(other.midX - frame.midX)
            case .up:
                guard other.maxY <= frame.minY + slack else { continue }
                along = frame.minY - other.maxY
                across = abs(other.midX - frame.midX)
            case .select, .exit:
                return nil
            }
            let score = max(along, 0) + across * 2
            if best.map({ score < $0.score }) ?? true {
                best = (id, score)
            }
        }
        return best?.id
    }

    // MARK: Window

    private static var contentView: NSView? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView
    }

    /// The window's content in SwiftUI's global space (top left at zero).
    private static var windowBounds: CGRect {
        contentView.map { CGRect(origin: .zero, size: $0.bounds.size) } ?? .zero
    }

    /// Scrolls every scroll view holding `frame` (a shelf sideways, then
    /// the page down) so all of it shows, innermost first.
    private static func scrollIntoView(_ frame: CGRect) {
        guard let content = contentView else { return }
        var rect = frame
        if !content.isFlipped {
            rect.origin.y = content.bounds.height - frame.maxY
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let holders = scrollViews(in: content).compactMap { scrollView -> (NSView, CGFloat)? in
            guard let document = scrollView.documentView else { return nil }
            let documentFrame = document.convert(document.bounds, to: content)
            guard documentFrame.contains(center) else { return nil }
            return (document, documentFrame.width * documentFrame.height)
        }
        .sorted { $0.1 < $1.1 }
        let margin: CGFloat = 24
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            for (document, _) in holders {
                let inDocument = document.convert(rect, from: content).insetBy(dx: -margin, dy: -margin)
                document.scrollToVisible(inDocument)
            }
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView { found.append(scrollView) }
        for subview in view.subviews {
            found += scrollViews(in: subview)
        }
        return found
    }
}

extension EnvironmentValues {
    /// The sidebar tab a view is on, so arrow-key stops in tabs kept alive
    /// behind the one showing are left out.
    @Entry var keyboardTab: AppTab?
    /// The navigation page a view is on (see `keyboardPage()`).
    @Entry var keyboardPage: UUID?
}

/// Gives a navigation page an identity for the keyboard, and says when it
/// comes to the front.
private struct KeyboardPageModifier: ViewModifier {
    var pushed = false

    @Environment(\.keyboardTab) private var tab
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.keyboardPage, id)
            .onAppear {
                KeyboardTargets.shared.pageAppeared(id, on: tab, dismiss: pushed ? { dismiss() } : nil)
            }
            .onDisappear { KeyboardTargets.shared.pageDisappeared(id, on: tab) }
    }
}

/// A navigation link's stop: opens the page its value leads to.
private struct KeyboardLinkTargetModifier<Value: Hashable>: ViewModifier {
    let value: Value

    @Environment(\.openItem) private var openItem

    func body(content: Content) -> some View {
        content.modifier(KeyboardTargetModifier { [openItem, value] in
            openItem?.push(value)
        })
    }
}

/// Registers a view as an arrow-key stop and draws the selection on it.
private struct KeyboardTargetModifier: ViewModifier {
    var isDefault = false
    let action: () -> Void

    /// Missing in covers drawn above the tab view (Now Playing, say).
    @Environment(KeyboardNavigation.self) private var keyboard: KeyboardNavigation?
    @Environment(\.keyboardTab) private var tab
    @Environment(\.keyboardPage) private var page
    @State private var id = UUID()

    private var targets: KeyboardTargets { KeyboardTargets.shared }

    func body(content: Content) -> some View {
        content
            .keyboardSelectionHighlight(targets.selected == id && keyboard?.inSidebar != true)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                targets.update(id, frame: frame, tab: tab, page: page, action: action)
            }
            .onAppear {
                if isDefault { targets.selectDefault(id) }
            }
            .onDisappear { targets.remove(id) }
    }
}
#endif
