//
//  SidecarHint.swift
//  AsterFIN
//
//  On an iPad used as a Mac's display (Sidecar), a single finger isn't a
//  pointer: Sidecar keeps one-finger drags to itself and never passes them
//  to apps, so a swipe on a page does nothing, and the app can't even tell
//  it was tried. Two fingers scroll. While the window is on such a display
//  the page shows how, until the viewer scrolls that way once.
//

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
@Observable
final class SidecarHint {
    static let shared = SidecarHint()

    private(set) var isShown = false
    private var observers: [Any] = []
    private var scrollMonitor: Any?
    private var hideTask: Task<Void, Never>?
    /// Scroll seen while the hint shows; a little adds up to learned.
    private var scrolled: CGFloat = 0
    private var learnedKey: String { "sidecarScrollHintLearned" }
    /// How long the hint stays if nothing's scrolled.
    private static let timeout: Duration = .seconds(12)

    /// Starts watching which display the window is on.
    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.windowChanged(note.object as? NSWindow) }
            })
        }
        // The hint goes once the viewer scrolls the way it shows.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                // Precise scrolling comes as many small steps; any add up.
                self.scrolled += max(abs(event.scrollingDeltaY), abs(event.deltaY))
                if self.scrolled >= 8 { self.learned() }
            }
            return event
        }
        windowChanged(NSApp.keyWindow ?? NSApp.mainWindow)
    }

    private func windowChanged(_ window: NSWindow?) {
        guard !UserDefaults.standard.bool(forKey: learnedKey), let window, window.isVisible else { return }
        let onSidecar = Self.isSidecar(window.screen)
        if onSidecar != isShown {
            withAnimation(.easeInOut(duration: 0.3)) { isShown = onSidecar }
            hideTask?.cancel()
            if onSidecar {
                scrolled = 0
                // Not forever: away by itself, and back on the next visit.
                hideTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.timeout)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { self?.isShown = false }
                }
            }
        }
    }

    private func learned() {
        hideTask?.cancel()
        UserDefaults.standard.set(true, forKey: learnedKey)
        withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
    }

    /// Whether `screen` is an iPad used as a display. macOS names a Sidecar
    /// display after the iPad; the display is virtual (no built-in flag)
    /// and comes from Apple.
    static func isSidecar(_ screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        let name = screen.localizedName.lowercased()
        if name.contains("ipad") || name.contains("sidecar") { return true }
        // The display's model code, "iPad" as four letters, whatever the name's language.
        guard let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
        return CGDisplayModelNumber(number) == 0x6950_6164
    }
}

/// "Scroll with two fingers": two fingertips sliding up, repeating.
struct SidecarScrollHintView: View {
    @State private var up = false

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                ForEach(0..<2, id: \.self) { finger in
                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 6))
                        .offset(x: finger == 0 ? -12 : 12, y: up ? -16 : 16)
                }
            }
            .frame(width: 52, height: 56)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: up)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scroll with two fingers")
                    .font(.headline)
                Text("On an iPad used as a display, one finger doesn't move the page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
        .onAppear { up = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scroll with two fingers. On an iPad used as a display, one finger doesn't move the page.")
    }
}
#endif
