//
//  ProfileTile.swift
//  AsterFIN
//
//  A person in the household: their picture (or initial on their colour)
//  and name. On Apple TV the tile lifts and brightens with focus; on a Mac
//  under the pointer. The one being switched to shows a spinner while the
//  others dim.
//

import SwiftUI

/// Sizes for the picker: TV-sized on tvOS, phone-sized elsewhere.
enum ProfileLayout {
    #if os(tvOS)
    static let tileSize: CGFloat = 180
    static let tileSpacing: CGFloat = 48
    static let buttonSize: CGFloat = 44
    static let nameFont: Font = .title3
    #else
    static let tileSize: CGFloat = 88
    static let tileSpacing: CGFloat = 20
    static let buttonSize: CGFloat = 30
    static let nameFont: Font = .headline
    #endif
}

extension Color {
    /// `#RRGGBB` (or `RRGGBB`); a grey for anything else.
    init(profileHex hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = Color(white: 0.3)
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The circle: the initial on the colour, with the picture over it once
/// it arrives (and only the initial if there's none, or it doesn't).
struct ProfileAvatarView: View {
    let initial: String
    let colorHex: String
    let imageURL: URL?
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(profileHex: colorHex))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
            if let imageURL {
                RemoteImage(url: imageURL) { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension ProfileAvatarView {
    init(profile: HouseholdProfile, size: CGFloat) {
        self.init(initial: profile.initial, colorHex: profile.colorHex, imageURL: profile.imageURL, size: size)
    }
}

struct ProfileTile: View {
    let profile: HouseholdProfile
    /// Being switched to: a spinner over the picture.
    var isSwitching = false
    /// Another is being switched to: faded back.
    var isDimmed = false
    var size: CGFloat = ProfileLayout.tileSize

    /// Focus on Apple TV (the tile is a button's label).
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    private var isLifted: Bool { isFocused || isHovered }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ProfileAvatarView(profile: profile, size: size)
                if isSwitching {
                    Circle().fill(.black.opacity(0.45))
                    ProgressView()
                        .tint(.white)
                        #if os(tvOS)
                        .scaleEffect(1.6)
                        #endif
                }
            }
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(.white.opacity(ringOpacity), lineWidth: isLifted ? 4 : 2.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if profile.requiresPin {
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(size * 0.07)
                        .background(Circle().fill(Color(white: 0.15)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                        .offset(x: size * 0.02, y: size * 0.02)
                }
            }
            .shadow(color: .black.opacity(isLifted ? 0.45 : 0), radius: 24, y: 12)
            .scaleEffect(isSwitching ? 1.1 : (isLifted ? 1.08 : 1))
            VStack(spacing: 2) {
                Text(profile.name)
                    .font(ProfileLayout.nameFont)
                    .foregroundStyle(isLifted ? .primary : .secondary)
                    .lineLimit(1)
                if profile.isCurrent {
                    Text("Watching now")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size * 1.4)
        .opacity(isDimmed ? 0.35 : 1)
        .animation(.easeOut(duration: 0.18), value: isLifted)
        .animation(.easeInOut(duration: 0.25), value: isSwitching)
        .animation(.easeInOut(duration: 0.25), value: isDimmed)
        #if !os(tvOS)
        .onHover { isHovered = $0 }
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profile.accessibilityDescription)
    }

    private var ringOpacity: Double {
        if isLifted { return 0.9 }
        if profile.isCurrent { return 0.45 }
        return 0
    }
}

/// The tile's button: the tile draws its own focus and hover, so the
/// system's lift and platter stay out of it; a press squeezes it.
struct ProfileTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
