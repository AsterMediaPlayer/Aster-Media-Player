//
//  AppCover.swift
//  AsterFIN
//
//  Full-screen presentation on every platform: the player, disc menus, Now
//  Playing. Apple TV, iPhone and iPad use SwiftUI's `fullScreenCover`. macOS
//  has none, so there the view covers the whole window instead, drawn by
//  the root (`appCoverHost()`) rather than inside the page that asked for
//  it, so the sidebar is covered too. Esc closes the top one, like Back.
//

import SwiftUI

extension View {
    /// `fullScreenCover(item:onDismiss:content:)`, or a window-filling cover on macOS.
    @ViewBuilder
    func appCover<Item: Identifiable, Cover: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Cover
    ) -> some View {
        #if os(macOS)
        modifier(WindowItemCover(item: item, onDismiss: onDismiss, cover: content))
        #else
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    /// `fullScreenCover(isPresented:onDismiss:content:)`, or a window-filling cover on macOS.
    @ViewBuilder
    func appCover<Cover: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Cover
    ) -> some View {
        #if os(macOS)
        modifier(WindowItemCover(
            item: Binding(
                get: { isPresented.wrappedValue ? PresentedFlag() : nil },
                set: { isPresented.wrappedValue = $0 != nil }
            ),
            onDismiss: onDismiss,
            cover: { _ in content() }
        ))
        #else
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    /// Draws the window's covers over everything. Applied once, at the root.
    @ViewBuilder
    func appCoverHost() -> some View {
        #if os(macOS)
        modifier(WindowCoverHost())
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    /// Set inside a macOS window cover: closes it. SwiftUI's `dismiss` only
    /// knows real presentations, so a view that closes itself calls this
    /// when it's there (see `CoverDismiss`).
    @Entry var closeWindowCover: WindowCoverClose?
}

/// Closes one macOS window cover. Compared by the cover it closes, so the
/// environment value only counts as changed for a different cover.
struct WindowCoverClose: Equatable {
    let coverID: UUID
    let action: () -> Void

    static func == (lhs: WindowCoverClose, rhs: WindowCoverClose) -> Bool {
        lhs.coverID == rhs.coverID
    }
}

/// What a presented view calls to close itself: the window cover's close
/// on macOS, SwiftUI's `dismiss` everywhere else.
@MainActor
struct CoverDismiss {
    fileprivate var closeWindowCover: WindowCoverClose?
    fileprivate var dismiss: DismissAction

    func callAsFunction() {
        if let closeWindowCover {
            closeWindowCover.action()
        } else {
            dismiss()
        }
    }
}

extension EnvironmentValues {
    /// Closes the presented view this is read in; use instead of `dismiss`
    /// in anything shown with `appCover`.
    var coverDismiss: CoverDismiss {
        CoverDismiss(closeWindowCover: closeWindowCover, dismiss: dismiss)
    }
}

#if os(macOS)
/// Stands in for an item when a cover is presented by a Bool.
private struct PresentedFlag: Identifiable {
    var id: Int { 0 }
}

/// The covers showing in the window, oldest first; the last is on top.
@MainActor
@Observable
final class WindowCovers {
    static let shared = WindowCovers()

    struct Cover: Identifiable {
        let id: UUID
        var view: AnyView
        /// Clears the presenting binding, as dismissing a cover does.
        var close: () -> Void
    }

    private(set) var covers: [Cover] = []

    func show(_ id: UUID, view: AnyView, close: @escaping () -> Void) {
        if let index = covers.firstIndex(where: { $0.id == id }) {
            covers[index].view = view
            covers[index].close = close
        } else {
            covers.append(Cover(id: id, view: view, close: close))
        }
    }

    func hide(_ id: UUID) {
        covers.removeAll { $0.id == id }
    }

    func isShowing(_ id: UUID) -> Bool {
        covers.contains { $0.id == id }
    }
}

/// Puts the presenting view's cover in the window while its item is set,
/// and takes it down (calling `onDismiss`) once the item is cleared.
private struct WindowItemCover<Item: Identifiable, Cover: View>: ViewModifier {
    @Binding var item: Item?
    var onDismiss: (() -> Void)?
    let cover: (Item) -> Cover

    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id, initial: true) { _, _ in sync() }
            .onDisappear {
                // The page that presented it is gone, so its cover goes too.
                if WindowCovers.shared.isShowing(id) {
                    WindowCovers.shared.hide(id)
                }
            }
    }

    private func sync() {
        let covers = WindowCovers.shared
        if let item {
            let close = { [binding = $item] in binding.wrappedValue = nil }
            let view = cover(item).environment(\.closeWindowCover, WindowCoverClose(coverID: id, action: close))
            covers.show(id, view: AnyView(view), close: close)
        } else if covers.isShowing(id) {
            covers.hide(id)
            onDismiss?()
        }
    }
}

/// The window's root: its content, with the covers stacked on top.
private struct WindowCoverHost: ViewModifier {
    private var covers: WindowCovers { WindowCovers.shared }

    func body(content: Content) -> some View {
        content
            // A cover fills the window, so the window's toolbar (sidebar
            // button, back, title) goes while one is up.
            .toolbar(covers.covers.isEmpty ? .automatic : .hidden, for: .windowToolbar)
            .overlay {
                ZStack {
                    ForEach(covers.covers) { cover in
                        cover.view
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: covers.covers.map(\.id))
            }
            .background {
                // Esc closes the top cover, as Back does on the other platforms.
                if let top = covers.covers.last {
                    Button("Close", action: top.close)
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                }
            }
    }
}
#endif
