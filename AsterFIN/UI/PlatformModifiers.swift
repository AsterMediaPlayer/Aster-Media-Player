//
//  PlatformModifiers.swift
//  AsterFIN
//
//  Cross-platform stand-ins for tvOS-only SwiftUI modifiers. On tvOS each
//  one applies the real modifier; on iOS, where there's no remote to move
//  focus or press Menu and Play/Pause, it leaves the view as it is.
//

import SwiftUI

extension View {
    /// Groups the view's focusable children so the remote can move focus into
    /// them as a block (`focusSection()` on tvOS).
    @ViewBuilder
    func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    /// The tvOS lift-and-tilt card button style; a plain button elsewhere.
    @ViewBuilder
    func cardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }

    /// Mac: mirrors and blurs a full-bleed picture under the sidebar, which
    /// floats over the content in Liquid Glass and only looks like glass with
    /// something beneath it. Use on the picture alone, not text over it.
    @ViewBuilder
    func extendsUnderSidebar() -> some View {
        #if os(macOS)
        backgroundExtensionEffect()
        #else
        self
        #endif
    }

    /// The remote's Back/Menu button (`onExitCommand` on tvOS).
    @ViewBuilder
    func tvExitCommand(perform action: (() -> Void)?) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }

    /// The remote's Play/Pause button (`onPlayPauseCommand` on tvOS).
    @ViewBuilder
    func tvPlayPauseCommand(perform action: (() -> Void)?) -> some View {
        #if os(tvOS)
        onPlayPauseCommand(perform: action)
        #else
        self
        #endif
    }
}

#if os(tvOS)
import UIKit

/// Holding the remote's Play/Pause, wherever focus is. SwiftUI only has the
/// press (`onPlayPauseCommand`), so a long-press recognizer for that button
/// goes on the window. Once it recognizes a hold, the press is cancelled, so
/// the press handler doesn't also run.
struct PlayPauseHoldDetector: UIViewRepresentable {
    /// Whether a hold counts now; otherwise the button is left alone (so a
    /// video's own Play/Pause is never held up).
    var isEnabled: () -> Bool = { true }
    var onHold: () -> Void

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isEnabled = isEnabled
        view.onHold = onHold
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.isEnabled = isEnabled
        view.onHold = onHold
    }

    final class HostView: UIView {
        var isEnabled: () -> Bool = { true } {
            didSet { gate.isEnabled = isEnabled }
        }
        var onHold: (() -> Void)?
        private var recognizer: UILongPressGestureRecognizer?
        private let gate = Gate()

        /// Lets the hold begin only while it's wanted.
        private final class Gate: NSObject, UIGestureRecognizerDelegate {
            var isEnabled: () -> Bool = { true }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                isEnabled()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window else { return }
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
            hold.allowedTouchTypes = []
            hold.minimumPressDuration = 0.6
            hold.cancelsTouchesInView = true
            hold.delegate = gate
            window.addGestureRecognizer(hold)
            recognizer = hold
        }

        @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { onHold?() }
        }
    }
}
#endif
