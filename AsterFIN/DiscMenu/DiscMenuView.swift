//
//  DiscMenuView.swift
//  AsterFIN
//
//  Draws a disc menu full screen: background, layers, title and buttons on a
//  16:9 canvas, driven by the Siri Remote or a game controller.
//

import AVFoundation
import SwiftUI

struct DiscMenuView: View {
    let document: DiscMenuDocument
    let itemId: String

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppSettings.discMenuSoundsKey) private var soundsEnabled = true
    @State private var controller: DiscMenuController?
    @State private var playback: PlaybackRequest?
    @FocusState private var canvasFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let canvas = Self.canvasRect(in: geo.size)
            ZStack {
                Color.black
                if let controller {
                    Button {
                        controller.select()
                    } label: {
                        DiscCanvasContent(controller: controller, canvas: canvas, reduceMotion: reduceMotion)
                    }
                    .buttonStyle(DiscCanvasButtonStyle())
                    .focusEffectDisabled()
                    .focused($canvasFocused)
                    #if os(tvOS)
                    .onMoveCommand { controller.move($0) }
                    #endif
                    .tvExitCommand { controller.hardwareBack() }
                    .tvPlayPauseCommand { controller.playPause() }
                    .frame(width: canvas.width, height: canvas.height)
                    .position(x: canvas.midX, y: canvas.midY)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if controller == nil, let client = session.client {
                let created = DiscMenuController(document: document, itemId: itemId, client: client, soundsEnabled: soundsEnabled)
                controller = created
                created.open()
            }
            canvasFocused = true
        }
        .onChange(of: controller?.pendingPlayback) { _, request in
            guard let request, let controller else { return }
            controller.pendingPlayback = nil
            controller.suspendForPlayback()
            playback = request
        }
        .onChange(of: controller?.shouldClose) { _, close in
            if close == true { dismiss() }
        }
        .onDisappear {
            if playback == nil { controller?.close() }
        }
        .fullScreenCover(item: $playback, onDismiss: {
            canvasFocused = true
            Task { await controller?.resumeAfterPlayback() }
        }) { request in
            PlayerView(request: request) { playback = nil }
        }
        .alert("Disc Menu", isPresented: Binding(get: { controller?.alertMessage != nil }, set: { if !$0 { controller?.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller?.alertMessage ?? "")
        }
    }

    /// The largest 16:9 rectangle that fits the display, centred (letterboxed
    /// on anything that isn't 16:9).
    static func canvasRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        var width = size.width
        var height = width * 9 / 16
        if height > size.height {
            height = size.height
            width = height * 16 / 9
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// No press or focus chrome: the canvas draws its own focus.
struct DiscCanvasButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Canvas

struct DiscCanvasContent: View {
    let controller: DiscMenuController
    let canvas: CGRect
    let reduceMotion: Bool

    var body: some View {
        let screen = controller.screen
        let style = DiscMenuStyle(canvas: CGRect(origin: .zero, size: canvas.size), theme: screen.theme)
        let animate = !reduceMotion && screen.transitionStyle != "none" && screen.transitionDuration > 0
        ZStack(alignment: .topLeading) {
            DiscBackgroundView(background: screen.background, controller: controller, style: style, crossfadeDuration: animate ? screen.transitionDuration : 0)

            DiscLayersView(layers: screen.layout.layers ?? [], style: style, resolver: DiscPictureResolver(client: controller.client, itemId: controller.itemId))
                .id(screen.layout.layers ?? [])
                .transition(animate ? .asymmetric(insertion: .opacity.animation(.easeOut(duration: screen.transitionDuration)), removal: .identity) : .identity)

            DiscScreenView(screen: screen, controller: controller, style: style, generation: controller.generation)
                .id(controller.generation)
                .transition(DiscMenuTransitions.transition(style: screen.transitionStyle, direction: controller.direction, duration: controller.animateChange ? screen.transitionDuration : 0, canvas: canvas.size, reduceMotion: reduceMotion))
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
        .coordinateSpace(.named("disc-canvas"))
    }
}

// MARK: - Screen: title and buttons

struct DiscScreenView: View {
    let screen: DiscResolvedScreen
    let controller: DiscMenuController
    let style: DiscMenuStyle
    let generation: Int

    private var showTitle: Bool { screen.layout.hideTitle != true }
    private var resolver: DiscPictureResolver { DiscPictureResolver(client: controller.client, itemId: controller.itemId) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if screen.positioned {
                DiscCanvasLayout(style: style) {
                    if showTitle {
                        titleView
                            .layoutValue(key: DiscPlacementKey.self, value: screen.layout.titlePosition ?? DiscPosition(x: 0, y: 0, w: 100))
                    }
                    ForEach(Array(screen.entries.enumerated()), id: \.offset) { index, entry in
                        button(entry, index: index)
                            .layoutValue(key: DiscPlacementKey.self, value: entry.position)
                    }
                }
            } else {
                VStack(alignment: style.horizontalAlignment, spacing: 0) {
                    if showTitle, screen.layout.titlePosition == nil {
                        titleView
                            .padding(.bottom, style.titleFont * 0.75)
                    }
                    VStack(alignment: style.horizontalAlignment, spacing: style.baseEm * 0.5) {
                        ForEach(Array(screen.entries.enumerated()), id: \.offset) { index, entry in
                            button(entry, index: index)
                        }
                    }
                }
                .padding(style.baseEm * 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: style.horizontalAlignment, vertical: .center))

                if showTitle, let position = screen.layout.titlePosition {
                    DiscCanvasLayout(style: style) {
                        titleView.layoutValue(key: DiscPlacementKey.self, value: position)
                    }
                }
            }
        }
        .frame(width: style.canvas.width, height: style.canvas.height, alignment: .topLeading)
    }

    private var titleView: some View {
        DiscText(text: screen.title, size: style.titleFont, style: style)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func button(_ entry: DiscMenuEntry, index: Int) -> some View {
        DiscButtonView(
            entry: entry,
            isFocused: controller.focusIndex == index,
            style: style,
            defaultStyle: screen.layout.buttonStyle,
            resolver: resolver
        )
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("disc-canvas"))
        } action: { frame in
            controller.reportFrame(frame, index: index, generation: generation)
        }
    }
}

// MARK: - Absolute placement

nonisolated struct DiscPlacementKey: LayoutValueKey {
    static let defaultValue: DiscPosition? = nil
}

/// Places each child at its `DiscPosition` (percent of the canvas), shifted
/// by its anchor as a fraction of its own size.
struct DiscCanvasLayout: Layout {
    let style: DiscMenuStyle

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        style.canvas.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            guard let position = subview[DiscPlacementKey.self] else {
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
                continue
            }
            let width = position.w.map { style.px($0) }
            let height = position.h.map { style.py($0) }
            let natural = subview.sizeThatFits(ProposedViewSize(width: width, height: height))
            let finalWidth = width ?? natural.width
            let finalHeight = height ?? natural.height
            let shift = DiscMenuRules.anchorShift(position.anchor)
            let x = bounds.minX + style.px(position.x) + CGFloat(shift.x) * finalWidth
            let y = bounds.minY + style.py(position.y) + CGFloat(shift.y) * finalHeight
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: finalWidth, height: finalHeight))
        }
    }
}

// MARK: - Buttons

struct DiscButtonView: View {
    let entry: DiscMenuEntry
    let isFocused: Bool
    let style: DiscMenuStyle
    let defaultStyle: String?
    let resolver: DiscPictureResolver

    private var styleName: String {
        let name = entry.style ?? defaultStyle ?? "frame"
        return ["text", "frame", "glow", "arrow"].contains(name) ? name : "frame"
    }

    private var sized: Bool {
        entry.position?.w != nil || entry.position?.h != nil
    }

    var body: some View {
        Group {
            if let thumb = entry.thumbURL {
                chapterButton(thumb)
            } else if let image = resolver.url(forPicture: entry.image) {
                artworkButton(image)
            } else {
                textButton
            }
        }
        .accessibilityLabel(entry.label)
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    // Text styles: frame (default), text, glow, arrow.
    private var textButton: some View {
        let size = style.buttonFont
        let accent = style.accent
        let isFrame = styleName == "frame"
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if styleName == "arrow" {
                Text("▶")
                    .font(style.font(size: size))
                    .foregroundStyle(accent)
                    .padding(.trailing, size * 0.5)
                    .opacity(isFocused ? 1 : 0)
            }
            VStack(alignment: style.horizontalAlignment, spacing: 0) {
                DiscText(text: entry.label, size: size, style: style, color: (styleName == "text" && isFocused) ? accent : style.textColor)
                if let sub = entry.sub {
                    Text(sub)
                        .font(style.font(size: size * 0.65))
                        .textCase(style.textCase)
                        .foregroundStyle(style.textColor.opacity(0.75))
                        .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 2)
                }
            }
        }
        .padding(.vertical, size * 0.5)
        .padding(.horizontal, size * 1.25)
        .frame(maxWidth: sized ? .infinity : nil, alignment: style.frameAlignment)
        .background(
            RoundedRectangle(cornerRadius: size * 0.4)
                .fill(isFrame ? Color.black.opacity(isFocused ? 0.75 : 0.5) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.4)
                .stroke(isFrame && isFocused ? accent : Color.clear, lineWidth: 2)
        )
        .shadow(color: styleName == "glow" && isFocused ? accent : .clear, radius: 10)
        .shadow(color: styleName == "glow" && isFocused ? accent : .clear, radius: 22)
    }

    // Artwork: the picture is the button; the label is only its accessible name.
    private func artworkButton(_ image: URL) -> some View {
        let focusImage = resolver.url(forPicture: entry.imageFocus)
        let shown = (isFocused && focusImage != nil) ? focusImage : image
        let plainFocus = isFocused && focusImage == nil
        return RemoteImage(url: shown, contentMode: .fit) { Color.clear }
            .frame(
                maxWidth: sized ? .infinity : style.canvas.width * 0.4,
                maxHeight: sized ? .infinity : style.canvas.height * 0.25,
                alignment: .center
            )
            .brightness(plainFocus ? 0.15 : 0)
            .shadow(color: plainFocus ? style.accent : .clear, radius: 10)
    }

    // Scene selection: a 16:9 thumbnail with "Label · time" below.
    private func chapterButton(_ thumb: URL) -> some View {
        let captionSize = style.vh * 1.6
        let padding = captionSize * 0.3
        return GeometryReader { geo in
            let imageWidth = max(0, geo.size.width - padding * 2)
            VStack(alignment: .leading, spacing: padding) {
                RemoteImage(url: thumb, contentMode: .fill) { Color.black }
                    .frame(width: imageWidth, height: imageWidth * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: captionSize * 0.3))
                Text(entry.label + (entry.sub.map { " · \($0)" } ?? ""))
                    .font(style.font(size: captionSize))
                    .textCase(style.textCase)
                    .foregroundStyle(style.textColor)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 2)
            }
            .padding(padding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .background(RoundedRectangle(cornerRadius: captionSize * 0.4).fill(Color.black.opacity(isFocused ? 0.65 : 0.35)))
            .overlay(RoundedRectangle(cornerRadius: captionSize * 0.4).stroke(isFocused ? style.accent : Color.clear, lineWidth: 2))
            .clipped()
        }
    }
}

// MARK: - Backgrounds

struct DiscBackgroundView: View {
    let background: DiscBackground?
    let controller: DiscMenuController
    let style: DiscMenuStyle
    let crossfadeDuration: Double

    private var resolver: DiscPictureResolver { DiscPictureResolver(client: controller.client, itemId: controller.itemId) }

    private var key: String {
        guard let background else { return "none" }
        return (try? String(data: JSONEncoder().encode(background), encoding: .utf8)) ?? "none"
    }

    var body: some View {
        ZStack {
            Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255)

            if let trailer = controller.trailer {
                DiscTrailerLayer(player: trailer.player)
                    .opacity(trailer.isPlaying ? 1 : 0)
                    .animation(.easeIn(duration: 0.8), value: trailer.isPlaying)
            }

            still
                .id(key)
                .transition(crossfadeDuration > 0 ? .asymmetric(insertion: .identity, removal: .opacity.animation(.easeIn(duration: crossfadeDuration))) : .identity)
        }
        .frame(width: style.canvas.width, height: style.canvas.height)
        .clipped()
    }

    @ViewBuilder
    private var still: some View {
        switch background?.source {
        case "color":
            (Color(hex: background?.color) ?? Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255))
        case "trailer":
            ZStack {
                if controller.trailer == nil || controller.trailer?.isPlaying != true, let poster = resolver.url(forPicture: background?.poster) {
                    RemoteImage(url: poster, contentMode: .fill) { Color.clear }
                }
                Color.black.opacity(DiscMenuRules.clamp(background?.dim, 0...1, default: 0.25))
            }
        case "jellyfin", "tmdb", "fanart", "image":
            ZStack {
                if let url = resolver.url(forBackground: background) {
                    RemoteImage(url: url, contentMode: .fill) { Color.clear }
                }
                Color.black.opacity(DiscMenuRules.clamp(background?.dim, 0...1, default: 0.4))
            }
        default:
            Color.clear
        }
    }
}

/// An AVPlayerLayer that cover-fits the canvas.
struct DiscTrailerLayer: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

// MARK: - Layers

struct DiscLayersView: View {
    let layers: [DiscLayer]
    let style: DiscMenuStyle
    let resolver: DiscPictureResolver

    var body: some View {
        DiscCanvasLayout(style: style) {
            ForEach(Array(layers.enumerated()), id: \.offset) { _, layer in
                if let position = layer.position {
                    layerView(layer)
                        .opacity(DiscMenuRules.clamp(layer.opacity, 0...1, default: 1))
                        .layoutValue(key: DiscPlacementKey.self, value: position)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func layerView(_ layer: DiscLayer) -> some View {
        switch layer.type {
        case "panel":
            let radius = CGFloat(DiscMenuRules.clamp(layer.radius, 0...100, default: 0)) * style.vh
            let borderWidth = CGFloat(DiscMenuRules.clamp(layer.borderWidth, 0...100, default: 0)) * style.vh
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(hex: layer.fill) ?? .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(borderWidth > 0 ? (Color(hex: layer.borderColor) ?? .clear) : .clear, lineWidth: borderWidth)
                )
        case "image":
            if let url = resolver.url(forPicture: layer.image) {
                switch layer.fit {
                case "cover":
                    RemoteImage(url: url, contentMode: .fill) { Color.clear }.clipped()
                case "fill":
                    RemoteImage(url: url, contentMode: .fill, stretch: true) { Color.clear }
                default:
                    RemoteImage(url: url, contentMode: .fit) { Color.clear }
                }
            }
        default:
            EmptyView()
        }
    }
}
