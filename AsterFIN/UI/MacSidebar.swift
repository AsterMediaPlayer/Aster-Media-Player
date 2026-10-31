//
//  MacSidebar.swift
//  AsterFIN
//
//  The Mac's sidebar, drawn here rather than by the system so it looks as
//  it does on Apple TV and iPad: white icons and titles, the tab showing in
//  a soft lighter shape, sliding out over the page. The system's sidebar
//  takes its icon and selection colours from the system, which can't be
//  changed to match.
//

#if os(macOS)
import SwiftUI

/// Whether the sidebar is out, shared with the View menu's command.
@MainActor
@Observable
final class MacSidebarState {
    static let shared = MacSidebarState()

    var isShown = true
    /// Brought out by the mouse reaching the window's left edge, so it goes
    /// back in when the mouse leaves it; one opened any other way stays.
    private(set) var revealedByMouse = false

    static let slide = Animation.easeInOut(duration: 0.25)

    func show(byMouse: Bool = false) {
        guard !isShown else { return }
        revealedByMouse = byMouse
        withAnimation(Self.slide) { isShown = true }
    }

    func hide() {
        revealedByMouse = false
        guard isShown else { return }
        withAnimation(Self.slide) { isShown = false }
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }
}

/// The panel: a row for each tab, and Settings (with the song or book
/// playing above it) at the foot.
struct MacSidebar: View {
    let tabs: [AppTab]
    let selected: AppTab
    /// The tab the keyboard is on, and whether it's on Settings instead.
    var keyboardTab: AppTab?
    var keyboardOnSettings = false
    let choose: (AppTab) -> Void
    let openSettings: () -> Void

    @Environment(AppSession.self) private var session

    static let width: CGFloat = 270

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tabs, id: \.self) { item in
                        SidebarRow(
                            title: item.title, systemImage: item.systemImage,
                            isSelected: item == selected,
                            hasKeyboard: item == keyboardTab && !keyboardOnSettings
                        ) { choose(item) }
                    }
                }
                .padding(.horizontal, 14)
                // Below the window's buttons.
                .padding(.top, 60)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            VStack(spacing: 0) {
                if session.isAudioLoaded {
                    AudioAccessory()
                    Divider().opacity(0.4)
                }
                SidebarRow(
                    title: "Settings", systemImage: "gearshape.fill",
                    isSelected: false, hasKeyboard: keyboardOnSettings, action: openSettings
                )
                .help("Settings (⌘,)")
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
        }
        // Under the title bar, as the system's was.
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.colorScheme, .dark)
    }
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let hasKeyboard: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.22 : (isHovered || hasKeyboard) ? 0.1 : 0))
            )
            .overlay {
                if hasKeyboard {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white, lineWidth: 2.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
