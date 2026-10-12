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
/// The window's sidebar, shown, hidden and pointed at for the keyboard.
/// SwiftUI has no binding for a sidebar-style tab view's sidebar on the Mac.
/// Underneath it's an AppKit split view (sidebar, then content), which says
/// whether the sidebar shows, and the sidebar answers the same toggle action
/// as View › Show Sidebar. Its rows are a table, which says where a row is.
@MainActor
enum WindowSidebar {
    private static var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    private static var splitView: NSSplitView? {
        first(NSSplitView.self, in: window?.contentView)
    }

    /// Whether the sidebar is showing; nil when it can't be found.
    static var isShown: Bool? {
        guard let split = splitView, let sidebar = split.arrangedSubviews.first else { return nil }
        return !(split.isSubviewCollapsed(sidebar) || sidebar.isHidden || sidebar.frame.width < 1)
    }

    /// Slides the sidebar in or out.
    static func setShown(_ shown: Bool) {
        guard let current = isShown, current != shown else { return }
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

    /// Gives the keyboard back to the window's content. Collapsing the
    /// sidebar can leave the window with no first responder, and then no
    /// key reaches the app until something is clicked.
    static func returnKeyboardToContent() {
        guard let window, let content = window.contentView else { return }
        if window.firstResponder !== content {
            window.makeFirstResponder(content)
        }
    }

    /// Where sidebar row `index` is, in the window's content from its top
    /// left (as a full-window SwiftUI overlay measures); nil if not found.
    static func rowFrame(_ index: Int) -> CGRect? {
        guard let content = window?.contentView,
              let sidebar = splitView?.arrangedSubviews.first,
              let table = first(NSTableView.self, in: sidebar),
              index >= 0, index < table.numberOfRows else { return nil }
        var frame = table.convert(table.rect(ofRow: index), to: content)
        if !content.isFlipped {
            frame.origin.y = content.bounds.height - frame.maxY
        }
        return frame
    }

    private static func first<View: NSView>(_ type: View.Type, in view: NSView?) -> View? {
        guard let view else { return nil }
        if let match = view as? View { return match }
        for subview in view.subviews {
            if let match = first(type, in: subview) { return match }
        }
        return nil
    }

    #if DEBUG
    /// Temporary: what the window is made of, to find the sidebar.
    static func debugDescribeWindow() -> String {
        var lines: [String] = ["isShown=\(String(describing: isShown))"]
        if let sidebar = splitView?.arrangedSubviews.first, let table = first(NSTableView.self, in: sidebar) {
            lines.append("table \(type(of: table)) rows=\(table.numberOfRows)")
            for row in 0..<table.numberOfRows {
                let view = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                let label = view?.accessibilityLabel() ?? view.map { first(NSTextField.self, in: $0)?.stringValue ?? "?" } ?? "nil"
                lines.append("row \(row) y=\(Int(rowFrame(row)?.minY ?? -1)) label=\(label) cell=\(view.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        } else {
            lines.append("no sidebar table")
        }
        return lines.joined(separator: " | ")
    }
    #endif
}
#endif
