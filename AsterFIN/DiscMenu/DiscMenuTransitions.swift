//
//  DiscMenuTransitions.swift
//  AsterFIN
//
//  Screen transitions (CLIENT_GUIDE §5.4): fade, slide, rise, zoom and wipe.
//  The leaving screen eases in while the arriving one eases out, together.
//

import SwiftUI

enum DiscMenuTransitions {
    /// `direction` is +1 going forward and -1 going back.
    static func transition(style: String, direction: Int, duration: Double, canvas: CGSize, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion, duration > 0 else { return .identity }
        let s = CGFloat(direction >= 0 ? 1 : -1)
        let inAnimation = Animation.easeOut(duration: duration)
        let outAnimation = Animation.easeIn(duration: duration)
        switch style {
        case "fade":
            return .asymmetric(insertion: .opacity.animation(inAnimation), removal: .opacity.animation(outAnimation))
        case "slide":
            let shift = canvas.width * 0.08 * s
            return .asymmetric(
                insertion: .opacity.combined(with: .offset(x: shift)).animation(inAnimation),
                removal: .opacity.combined(with: .offset(x: -shift)).animation(outAnimation)
            )
        case "rise":
            let shift = canvas.height * 0.06 * s
            return .asymmetric(
                insertion: .opacity.combined(with: .offset(y: shift)).animation(inAnimation),
                removal: .opacity.combined(with: .offset(y: -shift)).animation(outAnimation)
            )
        case "zoom":
            let forward = direction >= 0
            return .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: forward ? 0.92 : 1.08)).animation(inAnimation),
                removal: .opacity.combined(with: .scale(scale: forward ? 1.08 : 0.92)).animation(outAnimation)
            )
        case "wipe":
            return .asymmetric(
                insertion: .modifier(active: WipeModifier(progress: 0, fromLeading: direction >= 0), identity: WipeModifier(progress: 1, fromLeading: direction >= 0)).animation(inAnimation),
                removal: .opacity.animation(outAnimation)
            )
        default:
            return .identity
        }
    }
}

/// Reveals its content from one side to the other.
struct WipeModifier: ViewModifier, Animatable {
    var progress: CGFloat
    var fromLeading: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask(alignment: fromLeading ? .leading : .trailing) {
            GeometryReader { geo in
                Rectangle()
                    .frame(width: geo.size.width * max(0, min(1, progress)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fromLeading ? .leading : .trailing)
            }
        }
    }
}
