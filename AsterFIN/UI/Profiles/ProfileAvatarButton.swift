//
//  ProfileAvatarButton.swift
//  AsterFIN
//
//  Who's watching, small, wherever the main screen has room for it: the
//  Home page's bar, the Apple TV sidebar, the Mac sidebar. Pressing it
//  asks who's watching.
//

import SwiftUI

struct ProfileAvatarButton: View {
    var size: CGFloat = ProfileLayout.buttonSize
    /// The name beside the picture (sidebars have the room).
    var showsName = false

    @Environment(AppSession.self) private var session
    private var household: HouseholdProfiles { HouseholdProfiles.shared }

    var body: some View {
        Button {
            session.presentProfilePicker()
        } label: {
            HStack(spacing: 12) {
                if let current = household.current {
                    ProfileAvatarView(profile: current, size: size)
                } else {
                    ProfileAvatarView(initial: String((session.userName ?? "?").prefix(1)).uppercased(),
                                      colorHex: Bonfire.defaultAvatarColor, imageURL: nil, size: size)
                }
                if showsName {
                    Text(household.current?.name ?? session.userName ?? "")
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch profile")
        .accessibilityValue(household.current?.name ?? session.userName ?? "")
    }
}
