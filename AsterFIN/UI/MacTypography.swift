//
//  MacTypography.swift
//  AsterFIN
//
//  The Mac's text sizes. macOS sets its text styles for dense document
//  windows (body at 13 points, a caption at 10) and, unlike iOS and tvOS,
//  doesn't scale them with Dynamic Type. Aster's pages are shared with the
//  Apple TV and iPhone and read as a media app's should at those sizes, so
//  on the Mac they came out cramped.
//
//  These declarations shadow SwiftUI's own text styles inside this module,
//  so every `.font(.title3)`, `.font(.callout.weight(.semibold))` and so on
//  in the app takes the Mac sizes below without changing where it's used.
//  A Mac window is about as many points across as the TV's 1920, seen from
//  nearer, so these are about two thirds of tvOS's own sizes, keeping its
//  order (a callout a touch bigger than body, as on the TV). A text style
//  asked for by name (`.system(.callout)`) still gets the Mac's.
//

import SwiftUI

#if os(macOS)
extension Font {
    static var largeTitle: Font { .system(size: 48) }
    static var title: Font { .system(size: 40) }
    static var title2: Font { .system(size: 32) }
    static var title3: Font { .system(size: 28) }
    static var headline: Font { .system(size: 22, weight: .semibold) }
    static var body: Font { .system(size: 18) }
    static var callout: Font { .system(size: 20) }
    static var subheadline: Font { .system(size: 18) }
    static var footnote: Font { .system(size: 15) }
    static var caption: Font { .system(size: 16) }
    static var caption2: Font { .system(size: 15) }
}

extension View {
    /// A window's defaults on the Mac: text without a font of its own at
    /// the body size above, and controls (buttons, pickers, toggles,
    /// fields) a size up, to sit with it.
    func macWindowTypography() -> some View {
        font(.body)
            .controlSize(.large)
    }
}
#endif
