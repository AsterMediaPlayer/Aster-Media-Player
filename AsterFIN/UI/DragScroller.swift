//
//  DragScroller.swift
//  AsterFIN
//
//  A finger on an iPad used as a Mac's display (Sidecar) arrives as a mouse
//  press and drag, and a Mac scroll view only follows a wheel or a trackpad.
//  This makes a mostly vertical drag scroll the page under the pointer,
//  tracking the finger and coasting when it lifts, on every page and under
//  every banner.
//

#if os(macOS)
import AppKit
import os

private let dragLog = Logger(subsystem: "app.asterfin.debug", category: "dragscroll")

@MainActor
final class DragScroller {
    static let shared = DragScroller()

    private enum State { case idle, undecided, scrolling, notOurs }

    private var monitor: Any?
    private var isEnabled: () -> Bool = { true }
    private var state = State.idle
    private var scrollView: NSScrollView?
    private weak var window: NSWindow?
    /// Where the press began, and where the pointer was last, in window
    /// coordinates (y up).
    private var start = CGPoint.zero
    private var last = CGPoint.zero
    private var lastTime: TimeInterval = 0
    /// Points a second, finger up positive, smoothed.
    private var velocity: CGFloat = 0
    private var coast: Timer?

    /// Starts following drags in the app's windows, except while `isEnabled`
    /// says no (a player covering the window, which has its own drags).
    func install(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
        guard monitor == nil else { return }
        #if DEBUG
        dragLog.notice("installing the drag scroller")
        // Temporary: what an iPad display's touches arrive as.
        _ = NSEvent.addLocalMonitorForEvents(matching: .any) { event in
            // Everything but the pointer merely moving.
            switch event.type {
            case .mouseMoved, .cursorUpdate, .periodic, .flagsChanged, .mouseEntered, .mouseExited: break
            default:
                dragLog.notice("event type=\(event.type.rawValue) at=\(String(describing: event.locationInWindow), privacy: .public) window=\(event.window != nil) desc=\(String(describing: event).prefix(160), privacy: .public)")
            }
            return event
        }
        #endif
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            stopCoasting()
            start = event.locationInWindow
            last = start
            lastTime = event.timestamp
            velocity = 0
            window = event.window
            scrollView = verticalScrollView(under: event)
            // No AppKit scroll view to move directly (SwiftUI draws its own):
            // the drag becomes wheel events, which the page already follows.
            state = isEnabled() && window != nil ? .undecided : .notOurs
            #if DEBUG
            dragLog.notice("down enabled=\(self.isEnabled()) appkitScrollView=\(self.scrollView != nil) window=\(self.window != nil)")
            #endif
            return event

        case .leftMouseDragged:
            if state == .undecided {
                let dx = event.locationInWindow.x - start.x
                let dy = event.locationInWindow.y - start.y
                if abs(dy) >= 6, abs(dy) > abs(dx) * 1.3 {
                    state = .scrolling
                } else if abs(dx) >= 6 || abs(dy) >= 6 {
                    // Sideways, or too slanted: the pages' own drags.
                    state = .notOurs
                }
            }
            guard state == .scrolling else { return event }
            let delta = event.locationInWindow.y - last.y
            last = event.locationInWindow
            let elapsed = event.timestamp - lastTime
            lastTime = event.timestamp
            if elapsed > 0.001 {
                velocity = velocity * 0.6 + (delta / CGFloat(elapsed)) * 0.4
            }
            scroll(by: delta)
            return pointerAway(from: event)

        case .leftMouseUp:
            defer { state = .idle }
            guard state == .scrolling else { return event }
            // A pause before letting go isn't a fling.
            if event.timestamp - lastTime > 0.08 { velocity = 0 }
            startCoasting()
            return pointerAway(from: event)

        default:
            return event
        }
    }

    // MARK: Scrolling

    /// Moves what's shown by `delta` points, a finger moving up showing what's
    /// below, held inside the page's ends.
    private func scroll(by delta: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else {
            sendWheel(deltaY: delta)
            return
        }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += document.isFlipped ? delta : -delta
        origin = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func startCoasting() {
        guard abs(velocity) > 150 else { return }
        coast = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.velocity *= 0.95
                if abs(self.velocity) < 20 {
                    self.stopCoasting()
                } else {
                    self.scroll(by: self.velocity / 60)
                }
            }
        }
    }

    private func stopCoasting() {
        coast?.invalidate()
        coast = nil
    }

    /// A scroll wheel turn of `deltaY` points at where the drag began, sent
    /// straight to the window, as a wheel or trackpad would (so no system-wide
    /// event posting, which needs the accessibility permission). A finger
    /// moving up is a negative delta: the content below comes into view.
    private func sendWheel(deltaY: CGFloat) {
        guard let window, abs(deltaY) >= 0.5,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: Int32(deltaY.rounded()), wheel2: 0, wheel3: 0) else { return }
        // The event's place: the press's point, in the screen's coordinates
        // as Core Graphics has them (y down from the top of the main screen).
        let onScreen = window.convertPoint(toScreen: start)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: onScreen.x, y: mainHeight - onScreen.y)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        #if DEBUG
        dragLog.notice("wheel delta=\(deltaY) at=\(String(describing: event.locationInWindow), privacy: .public) window=\(event.windowNumber)")
        #endif
        window.sendEvent(event)
    }

    // MARK: What's under the pointer

    /// The nearest scroll view above the pointer that has more to show up or
    /// down than it does at once; a sideways row or the sidebar doesn't count.
    private func verticalScrollView(under event: NSEvent) -> NSScrollView? {
        guard let window = event.window, let content = window.contentView else { return nil }
        var view = (content.superview ?? content).hitTest(event.locationInWindow)
        while let current = view {
            if let scroll = current as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 1 {
                return scroll
            }
            view = current.superview
        }
        return nil
    }

    /// The same event with the pointer moved far below the window: what the
    /// drag started on (a card, a button, the banner) sees the pointer leave
    /// and lets go without opening or playing anything, as a touch screen's
    /// scroll cancels a tap. Horizontal position is kept.
    private func pointerAway(from event: NSEvent) -> NSEvent {
        let away = CGPoint(x: event.locationInWindow.x, y: start.y - 20_000)
        return NSEvent.mouseEvent(
            with: event.type, location: away, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure
        ) ?? event
    }
}
#endif
