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

    /// Every size here is the Apple TV-sized original times this.
    static let scale: CGFloat = 0.8
    static let width: CGFloat = 220 * scale

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4 * Self.scale) {
                    // Who's watching, above the tabs; pressing it asks.
                    if session.hasProfiles {
                        SidebarProfileRow()
                        Divider()
                            .opacity(0.4)
                            .padding(.vertical, 6 * Self.scale)
                    }
                    ForEach(tabs, id: \.self) { item in
                        SidebarRow(
                            title: item.title, systemImage: item.systemImage,
                            isSelected: item == selected,
                            hasKeyboard: item == keyboardTab && !keyboardOnSettings
                        ) { choose(item) }
                    }
                }
                .padding(.horizontal, 14 * Self.scale)
                // Below the window's buttons.
                .padding(.top, 60)
                .padding(.bottom, 12 * Self.scale)
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
                .padding(.horizontal, 14 * Self.scale)
                .padding(.vertical, 12 * Self.scale)
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

/// The person watching: their picture and name, lit under the pointer
/// like the rows below; pressing it asks who's watching.
private struct SidebarProfileRow: View {
    @State private var isHovered = false

    var body: some View {
        ProfileAvatarButton(size: 28 * MacSidebar.scale, showsName: true)
            .foregroundStyle(.white)
            .padding(.horizontal, 14 * MacSidebar.scale)
            .padding(.vertical, 9 * MacSidebar.scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14 * MacSidebar.scale, style: .continuous)
                    .fill(.white.opacity(isHovered ? 0.1 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14 * MacSidebar.scale, style: .continuous))
            .onHover { isHovered = $0 }
            .help("Switch profile")
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
            HStack(spacing: 14 * MacSidebar.scale) {
                Image(systemName: systemImage)
                    .font(.system(size: 18 * MacSidebar.scale, weight: .medium))
                    .frame(width: 28 * MacSidebar.scale)
                Text(title)
                    .font(.system(size: 17 * MacSidebar.scale, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14 * MacSidebar.scale)
            .padding(.vertical, 11 * MacSidebar.scale)
            .background(
                RoundedRectangle(cornerRadius: 14 * MacSidebar.scale, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.22 : (isHovered || hasKeyboard) ? 0.1 : 0))
            )
            .overlay {
                if hasKeyboard {
                    RoundedRectangle(cornerRadius: 14 * MacSidebar.scale, style: .continuous)
                        .strokeBorder(.white, lineWidth: 2.5 * MacSidebar.scale)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14 * MacSidebar.scale, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
