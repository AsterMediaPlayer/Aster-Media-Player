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
