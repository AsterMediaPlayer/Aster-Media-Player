//
//  PlatformTypes.swift
//  AsterFIN
//
//  The few UIKit types the app shares across screens, named so the Mac
//  (AppKit) gets its own: images, colors, and a view that shows an
//  AVPlayer's picture. Code that only makes sense on one platform stays
//  behind `#if os(...)` where it is used.
//

import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#else
import AppKit

typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// The image's bitmap, for drawing it into a CGContext (UIImage's
    /// `cgImage`; an NSImage has to be asked for one).
    var platformCGImage: CGImage? {
        #if canImport(UIKit)
        cgImage
        #else
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}

/// A view that is just an `AVPlayerLayer`: the picture, with no controls,
/// and touches and clicks pass through it. UIKit lets a view's own layer be
/// the player layer; AppKit hosts it (set the layer, then ask for one).
#if canImport(UIKit)
final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    // layerClass above makes this layer an AVPlayerLayer.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}
#else
final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = playerLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Hands the player over again once in the window: given it before, the
    /// layer sometimes stayed black though the video played.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let current = playerLayer.player else { return }
        playerLayer.player = nil
        playerLayer.player = current
    }
}
#endif

/// An AVPlayer's picture in SwiftUI. `onCreate` runs once the view exists,
/// for work that needs its layer.
struct VideoLayerView {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    var onCreate: ((PlayerLayerHostView) -> Void)?

    private func make() -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.videoGravity = gravity
        view.playerLayer.player = player
        onCreate?(view)
        return view
    }

    private func update(_ view: PlayerLayerHostView) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != gravity {
            view.playerLayer.videoGravity = gravity
        }
    }
}

#if canImport(UIKit)
extension VideoLayerView: UIViewRepresentable {
    func makeUIView(context: Context) -> PlayerLayerHostView { make() }
    func updateUIView(_ view: PlayerLayerHostView, context: Context) { update(view) }
}
#else
extension VideoLayerView: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerLayerHostView { make() }
    func updateNSView(_ view: PlayerLayerHostView, context: Context) { update(view) }
}
#endif

#if os(macOS)
/// The window, for the keyboard.
@MainActor
enum WindowSidebar {
    /// Gives the keyboard back to the window's content. Something closing
    /// (a page, a cover) can leave the window with no first responder, and
    /// then no key reaches the app until something is clicked.
    static func returnKeyboardToContent() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else { return }
        if window.firstResponder !== content {
            window.makeFirstResponder(content)
        }
    }
}
#endif
