//
//  GeneralSettingsView.swift
//  AsterFIN
//
//  Settings ▸ General, and its Tab Bar page.
//

import SwiftUI

/// Settings ▸ General: how the app itself works on this device: the tab
/// bar (iPhone and iPad), controllers and an iPad used as a display (Mac),
/// and the welcome screen.
struct GeneralSettingsView: View {
    @Environment(AppSession.self) private var session
    #if os(macOS)
    @AppStorage(AppSettings.swapControllerButtonsKey) private var swapControllerButtons = false
    @AppStorage(AppSettings.sidecarHintKey) private var sidecarHint = true
    #endif

    var body: some View {
        SettingsPage(title: "General") {
            #if os(iOS)
            Section {
                SettingsCategory.tabBar.link
            }
            #endif
            #if os(macOS)
            Section("Controllers") {
                Toggle("Swap A/B and X/Y", isOn: $swapControllerButtons)
                SettingsNote("A game controller moves through Aster like the arrow keys. Normally the bottom button (A) opens and the right one (B) goes back, and X pauses. Swapped, they follow Nintendo's layout: the right button opens, the bottom one goes back, and Y pauses.")
            }
            Section("iPad as a Display") {
                Toggle("Show the two-finger scroll tip", isOn: $sidecarHint)
                SettingsNote("On an iPad used as a display (Sidecar), one finger doesn't move the page; two do. The tip shows once each time the app opens there, until you've scrolled that way.")
            }
            #endif
            // The welcome screen offers Aster's Jellyfin plugins.
            if session.isJellyfin {
                Section {
                    Button("Show Welcome Screen") {
                        session.showWelcomeAgain()
                    }
                } footer: {
                    SettingsNote("Shows the welcome screen again, with Aster's server plugins to switch on.")
                }
            }
        }
    }
}

// MARK: - Tab Bar

#if os(iOS)
/// Which tabs show on iPhone and iPad, and in what order. The list is
/// always in edit mode, so each row can be dragged; the switch hides it.
struct TabBarSettingsView: View {
    @Environment(AppSession.self) private var session
    @AppStorage(AppSettings.tabOrderKey) private var tabOrder = ""
    @AppStorage(AppSettings.hiddenTabsKey) private var hiddenTabs = ""

    /// Every tab in its chosen order, less those this server has nothing for.
    private var tabs: [AppTab] {
        TabLayout.order(from: tabOrder).filter { session.hasContent(for: $0) }
    }

    var body: some View {
        let hidden = TabLayout.hidden(from: hiddenTabs)
        SettingsPage(title: "Tab Bar") {
            Section {
                ForEach(tabs, id: \.self) { tab in
                    Toggle(isOn: Binding(
                        get: { !hidden.contains(tab) },
                        set: { shown in
                            var updated = hidden
                            if shown { updated.remove(tab) } else { updated.insert(tab) }
                            hiddenTabs = TabLayout.encode(AppTab.allCases.filter(updated.contains))
                        }
                    )) {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .disabled(TabLayout.alwaysShown.contains(tab))
                }
                .onMove(perform: move)
            } footer: {
                SettingsNote(UIDevice.current.userInterfaceIdiom == .pad
                    ? "Drag to change the order, and switch tabs off to hide them. Home and Settings always show."
                    : "Drag to change the order, and switch tabs off to hide them. The tab bar holds four tabs; the rest are under More. Home and Settings always show.")
            }
            Section {
                Button("Reset to Default") {
                    tabOrder = ""
                    hiddenTabs = ""
                }
                .disabled(tabOrder.isEmpty && hiddenTabs.isEmpty)
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    /// Moves a tab within the list shown, keeping the place of any tab the
    /// server has nothing for (and so isn't listed) in the full order.
    private func move(from source: IndexSet, to destination: Int) {
        var shown = tabs
        shown.move(fromOffsets: source, toOffset: destination)
        var remaining = shown.makeIterator()
        let full = TabLayout.order(from: tabOrder).map { tab in
            session.hasContent(for: tab) ? (remaining.next() ?? tab) : tab
        }
        tabOrder = TabLayout.encode(full)
    }
}
#endif
