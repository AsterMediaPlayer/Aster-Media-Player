//
//  DiscMenuStyle.swift
//  AsterFIN
//
//  Translates a menu's Theme into fonts, colours and sizes for a given canvas
//  (CLIENT_GUIDE §5.2). The web reference measures in em and vh; here one
//  "em" is a fraction of the canvas height so everything scales with the TV.
//

import SwiftUI

nonisolated extension Color {
    /// Exactly `#rrggbb`, otherwise nil.
    init?(hex: String?) {
        guard DiscMenuRules.isHexColor(hex), let hex else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: String(hex.dropFirst())).scanHexInt64(&value) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

struct DiscMenuStyle {
    let canvas: CGRect
    let theme: DiscTheme
    let accent: Color
    let textColor: Color
    /// The base unit: the overlay's font size in the web reference.
    let baseEm: CGFloat
    /// Font size of button text.
    let buttonFont: CGFloat
    /// Font size of the screen title.
    let titleFont: CGFloat

    init(canvas: CGRect, theme: DiscTheme) {
        self.canvas = canvas
        self.theme = theme
        accent = Color(hex: theme.accent) ?? Color(red: 0x3D / 255, green: 0xDC / 255, blue: 0x84 / 255)
        textColor = Color(hex: theme.textColor) ?? .white
        baseEm = canvas.height * 0.024
        if let size = theme.fontSize, size.isFinite, size > 0 {
            let clamped = min(10, max(1, size))
            buttonFont = canvas.height * clamped / 100
            titleFont = canvas.height * clamped * 1.6 / 100
        } else {
            buttonFont = baseEm * 1.25
            titleFont = baseEm * 2
        }
    }

    /// Percent of the canvas width and height, as points.
    func px(_ percent: Double) -> CGFloat { canvas.width * percent / 100 }
    func py(_ percent: Double) -> CGFloat { canvas.height * percent / 100 }
    /// 1 vh: one percent of the canvas height.
    var vh: CGFloat { canvas.height / 100 }

    func font(size: CGFloat) -> Font {
        let weight: Font.Weight = theme.bold == true ? .bold : .regular
        switch theme.font {
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "mono": return .system(size: size, weight: weight, design: .monospaced)
        case "condensed": return .system(size: size, weight: weight).width(.condensed)
        case "wide": return .system(size: size, weight: weight).width(.expanded)
        default: return .system(size: size, weight: weight, design: .default)
        }
    }

    func tracking(size: CGFloat) -> CGFloat {
        guard let spacing = theme.letterSpacing, spacing.isFinite else { return 0 }
        return size * min(1, max(0, spacing))
    }

    var textCase: Text.Case? {
        theme.uppercase == true ? .uppercase : nil
    }

    var textAlignment: TextAlignment {
        switch theme.align {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch theme.align {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    var frameAlignment: Alignment {
        switch theme.align {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }
}

/// Styled menu text: theme font, case, tracking and the soft shadow.
struct DiscText: View {
    let text: String
    let size: CGFloat
    let style: DiscMenuStyle
    var color: Color? = nil

    var body: some View {
        Text(text)
            .font(style.font(size: size))
            .tracking(style.tracking(size: size))
            .textCase(style.textCase)
            .foregroundStyle(color ?? style.textColor)
            .multilineTextAlignment(style.textAlignment)
            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 2)
    }
}
